import Foundation

enum CLIEntrypoint {
    static func shouldRun(arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        let knownCommands: Set<String> = [
            "auth",
            "issues",
            "agile-boards",
            "saved-queries",
            "install-cli",
            "cli",
            "help",
            "--help",
            "-h"
        ]
        return knownCommands.contains(first)
    }

    static func runAndExit(arguments: [String]) async -> Never {
        let exitCode = await CLIRunner.run(arguments: Array(arguments.dropFirst()))
        exit(Int32(exitCode))
    }
}

private enum CLIRunner {
    static func run(arguments: [String]) async -> Int {
        guard let command = arguments.first else {
            CLIOutput.printHelp()
            return 0
        }

        let remaining = Array(arguments.dropFirst())
        do {
            switch command {
            case "help", "--help", "-h":
                CLIOutput.printHelp()
                return 0
            case "auth":
                return try await runAuth(arguments: remaining)
            case "saved-queries":
                return try await runSavedQueries(arguments: remaining)
            case "issues":
                return try await runIssues(arguments: remaining)
            case "agile-boards":
                return try await runAgileBoards(arguments: remaining)
            case "install-cli":
                return try await runInstallCLI(arguments: remaining)
            case "cli":
                return try await runCLI(arguments: remaining)
            default:
                throw CLIError.invalidCommand(command)
            }
        } catch {
            CLIOutput.printError(error.localizedDescription)
            return 1
        }
    }

    private static func runCLI(arguments: [String]) async throws -> Int {
        guard let subcommand = arguments.first else {
            CLIOutput.printHelp()
            return 0
        }
        switch subcommand {
        case "install":
            return try await runInstallCLI(arguments: Array(arguments.dropFirst()))
        default:
            throw CLIError.invalidCommand("cli \(subcommand)")
        }
    }

    private static func runAuth(arguments: [String]) async throws -> Int {
        guard let subcommand = arguments.first else {
            CLIOutput.printAuthHelp()
            return 0
        }
        let remaining = Array(arguments.dropFirst())

        switch subcommand {
        case "status":
            if remaining.contains("--help") || remaining.contains("-h") {
                CLIOutput.printAuthHelp()
                return 0
            }
            printAuthStatus()
            return 0
        case "login":
            if remaining.contains("--help") || remaining.contains("-h") {
                CLIOutput.printAuthHelp()
                return 0
            }
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--token", "--base-url"],
                flagOptions: []
            )
            let token = parsed.options["--token"] ?? ProcessInfo.processInfo.environment["YOUTRACK_TOKEN"]
            guard let token, !token.isEmpty else {
                throw CLIError.missingConfiguration("token")
            }

            let store = AppConfigurationStore()
            let baseURLOverride = parsed.options["--base-url"] ?? ProcessInfo.processInfo.environment["YOUTRACK_BASE_URL"]
            let baseURL = try resolveBaseURL(override: baseURLOverride, store: store, required: true)
            if baseURLOverride != nil || store.loadBaseURL() == nil {
                store.save(baseURL: baseURL)
            }
            try store.save(token: token)

            CLIOutput.printInfo("Token saved. Base URL: \(baseURL.absoluteString)")
            return 0
        default:
            throw CLIError.invalidCommand("auth \(subcommand)")
        }
    }

    private static func printAuthStatus() {
        let store = AppConfigurationStore()
        let baseURL = store.loadBaseURL()?.absoluteString ?? "(not set)"
        let token = store.loadToken()

        if let token, !token.isEmpty {
            let suffix = token.suffix(4)
            CLIOutput.printInfo("Signed in via token (****\(suffix)).")
        } else {
            CLIOutput.printInfo("Not signed in. Run: youtrek auth login --base-url <url> --token <pat>")
        }
        CLIOutput.printInfo("Base URL: \(baseURL)")
    }

    private static func runSavedQueries(arguments: [String]) async throws -> Int {
        guard let subcommand = arguments.first else {
            CLIOutput.printSavedQueriesHelp()
            return 0
        }
        let remaining = Array(arguments.dropFirst())

        switch subcommand {
        case "list":
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--base-url", "--token"],
                flagOptions: ["--json", "--offline"]
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printSavedQueriesHelp()
                return 0
            }
            if parsed.flags.contains("--offline") {
                throw CLIError.offlineUnsupported("saved-queries")
            }

            let connection = try resolveConnection(options: parsed)
            let repository = YouTrackSavedQueryRepository(configuration: connection.configuration)
            let savedQueries = try await repository.fetchSavedQueries()

            if parsed.flags.contains("--json") {
                let output = savedQueries.map(SavedQueryOutput.init)
                CLIOutput.printJSON(output)
            } else {
                CLIOutput.printSavedQueries(savedQueries)
            }
            return 0
        default:
            throw CLIError.invalidCommand("saved-queries \(subcommand)")
        }
    }

    private static func runIssues(arguments: [String]) async throws -> Int {
        guard let subcommand = arguments.first else {
            CLIOutput.printIssuesHelp()
            return 0
        }
        let remaining = Array(arguments.dropFirst())

        switch subcommand {
        case "list":
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--query", "--saved", "--top", "--base-url", "--token"],
                flagOptions: ["--json", "--offline"]
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printIssuesHelp()
                return 0
            }

            let pageSize = parsed.options["--top"].flatMap(Int.init) ?? 50
            let page = IssueQuery.Page(size: pageSize, offset: 0)

            let query: IssueQuery
            if let rawQuery = parsed.options["--query"] {
                query = IssueQuery(rawQuery: rawQuery, search: "", filters: [], sort: nil, page: page)
            } else if let savedName = parsed.options["--saved"] {
                if parsed.flags.contains("--offline") {
                    throw CLIError.offlineUnsupported("saved search resolution")
                }
                let connection = try resolveConnection(options: parsed)
                let savedQueryRepository = YouTrackSavedQueryRepository(configuration: connection.configuration)
                let savedQueries = try await savedQueryRepository.fetchSavedQueries()
                guard let saved = savedQueries.first(where: { $0.name.caseInsensitiveCompare(savedName) == .orderedSame }) else {
                    throw CLIError.missingConfiguration("saved search named \"\(savedName)\"")
                }
                query = IssueQuery.saved(saved.query, page: page)
            } else {
                query = IssueQuery(rawQuery: nil, search: "", filters: [], sort: .updated(descending: true), page: page)
            }

            if parsed.flags.contains("--offline") {
                let store = IssueLocalStore()
                let issues = await store.loadIssues(for: query)
                if parsed.flags.contains("--json") {
                    let output = issues.map { IssueSummaryOutput(issue: $0) }
                    CLIOutput.printJSON(output)
                } else {
                    CLIOutput.printIssues(issues)
                }
                return 0
            }

            let connection = try resolveConnection(options: parsed)
            let issueRepository = YouTrackIssueRepository(configuration: connection.configuration)
            let issues = try await issueRepository.fetchIssues(query: query)
            let store = IssueLocalStore()
            await store.saveRemoteIssues(issues, for: query)

            if parsed.flags.contains("--json") {
                let output = issues.map { IssueSummaryOutput(issue: $0) }
                CLIOutput.printJSON(output)
            } else {
                CLIOutput.printIssues(issues)
            }
            return 0
        default:
            throw CLIError.invalidCommand("issues \(subcommand)")
        }
    }

    private static func runAgileBoards(arguments: [String]) async throws -> Int {
        guard let subcommand = arguments.first else {
            CLIOutput.printAgileBoardsHelp()
            return 0
        }
        let remaining = Array(arguments.dropFirst())

        switch subcommand {
        case "list":
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--base-url", "--token"],
                flagOptions: ["--json", "--offline"]
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printAgileBoardsHelp()
                return 0
            }

            if parsed.flags.contains("--offline") {
                let store = IssueBoardLocalStore()
                let boards = await store.loadBoards()
                if parsed.flags.contains("--json") {
                    let output = boards.map(AgileBoardOutput.init)
                    CLIOutput.printJSON(output)
                } else {
                    CLIOutput.printAgileBoards(boards)
                }
                return 0
            }

            let connection = try resolveConnection(options: parsed)
            let repository = YouTrackIssueBoardRepository(configuration: connection.configuration)
            let boards = try await repository.fetchBoards()
            let store = IssueBoardLocalStore()
            await store.saveRemoteBoards(boards)

            if parsed.flags.contains("--json") {
                let output = boards.map(AgileBoardOutput.init)
                CLIOutput.printJSON(output)
            } else {
                CLIOutput.printAgileBoards(boards)
            }
            return 0
        default:
            throw CLIError.invalidCommand("agile-boards \(subcommand)")
        }
    }

    private static func runInstallCLI(arguments: [String]) async throws -> Int {
        let parsed = try parseOptions(
            arguments,
            valueOptions: ["--path"],
            flagOptions: ["--force", "--help"]
        )
        if parsed.flags.contains("--help") {
            CLIOutput.printInstallHelp()
            return 0
        }

        let pathString = parsed.options["--path"] ?? CLIInstaller.defaultInstallPath
        let installURL = URL(fileURLWithPath: pathString)
        let message = try CLIInstaller.installSymlink(at: installURL, force: parsed.flags.contains("--force"))
        CLIOutput.printInfo(message)
        return 0
    }

    private static func parseOptions(
        _ arguments: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String>
    ) throws -> CLIParsedOptions {
        var parsed = CLIParsedOptions()
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--help" || arg == "-h" {
                parsed.flags.insert("--help")
                index += 1
                continue
            }
            if flagOptions.contains(arg) {
                parsed.flags.insert(arg)
                index += 1
                continue
            }
            if valueOptions.contains(arg) {
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingArgument(arg)
                }
                parsed.options[arg] = arguments[index]
                index += 1
                continue
            }
            throw CLIError.invalidOption(arg)
        }

        return parsed
    }

    private static func resolveConnection(options: CLIParsedOptions) throws -> CLIConnection {
        let store = AppConfigurationStore()
        let baseURLOverride = options.options["--base-url"] ?? ProcessInfo.processInfo.environment["YOUTRACK_BASE_URL"]
        let baseURL = try resolveBaseURL(override: baseURLOverride, store: store, required: true)
        let tokenOverride = options.options["--token"] ?? ProcessInfo.processInfo.environment["YOUTRACK_TOKEN"]
        let token = resolveToken(override: tokenOverride, store: store)
        guard let token, !token.isEmpty else {
            throw CLIError.missingConfiguration("token")
        }
        return CLIConnection(configuration: YouTrackAPIConfiguration(baseURL: baseURL, tokenProvider: .constant(token)))
    }

    private static func resolveBaseURL(override: String?, store: AppConfigurationStore, required: Bool) throws -> URL {
        if let override {
            guard let url = URL(string: override) else {
                throw CLIError.invalidValue(option: "--base-url", value: override)
            }
            return url
        }
        if let stored = store.loadBaseURL() {
            return stored
        }
        if required {
            throw CLIError.missingConfiguration("base URL")
        }
        return URL(string: "http://localhost")!
    }

    private static func resolveToken(override: String?, store: AppConfigurationStore) -> String? {
        if let override, !override.isEmpty {
            return override
        }
        return store.loadToken()
    }
}

private struct CLIParsedOptions {
    var options: [String: String] = [:]
    var flags: Set<String> = []
}

private struct CLIConnection {
    let configuration: YouTrackAPIConfiguration
}

    private enum CLIError: LocalizedError {
        case invalidCommand(String)
        case invalidOption(String)
        case invalidValue(option: String, value: String)
        case missingArgument(String)
        case missingConfiguration(String)
        case offlineUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .invalidCommand(let command):
                return "Unknown command: \(command). Run `youtrek --help` for usage."
        case .invalidOption(let option):
            return "Unknown option: \(option). Run `youtrek --help` for usage."
        case .invalidValue(let option, let value):
            return "Invalid value for \(option): \(value)"
            case .missingArgument(let option):
                return "Missing value for \(option)."
            case .missingConfiguration(let item):
                return "Missing \(item). Set it with `youtrek auth login` or pass a flag."
            case .offlineUnsupported(let feature):
                return "Offline mode cannot resolve \(feature). Use a direct query or go online."
            }
        }
    }

private struct CLIOutput {
    static func printHelp() {
        print(
            """
            YouTrek CLI

            Usage:
              youtrek <command> [subcommand] [options]

            Commands:
              auth status
              auth login --base-url <url> --token <pat>
              issues list [--query <ytql>] [--saved <name>] [--top <n>] [--offline] [--json]
              agile-boards list [--offline] [--json]
              saved-queries list [--json]
              install-cli [--path <path>] [--force]

            Run `youtrek <command> --help` for details.
            """
        )
    }

    static func printAuthHelp() {
        print(
            """
            Auth commands:
              youtrek auth status
              youtrek auth login --base-url <url> --token <pat>
            """
        )
    }

    static func printIssuesHelp() {
        print(
            """
            Issues commands:
              youtrek issues list [--query <ytql>] [--saved <name>] [--top <n>] [--offline] [--json]
            """
        )
    }

    static func printSavedQueriesHelp() {
        print(
            """
            Saved queries commands:
              youtrek saved-queries list [--json]

            Note: offline mode is not supported for saved queries.
            """
        )
    }

    static func printAgileBoardsHelp() {
        print(
            """
            Agile boards commands:
              youtrek agile-boards list [--offline] [--json]
            """
        )
    }

    static func printInstallHelp() {
        print(
            """
            Install CLI alias:
              youtrek install-cli [--path <path>] [--force]

            Default path:
              /usr/local/bin/youtrek
            """
        )
    }

    static func printInfo(_ message: String) {
        print(message)
    }

    static func printError(_ message: String) {
        fputs("error: \(message)\n", stderr)
    }

    static func printIssues(_ issues: [IssueSummary]) {
        if issues.isEmpty {
            print("No issues found.")
            return
        }

        let formatter = makeDateFormatter()
        let rows = issues.map { issue in
            [
                issue.readableID,
                truncate(issue.title, limit: 60),
                issue.projectName,
                formatter.string(from: issue.updatedAt),
                issue.assignee?.displayName ?? "-",
                issue.status.displayName,
                issue.priority.displayName
            ]
        }

        printTable(headers: ["ID", "Title", "Project", "Updated", "Assignee", "Status", "Priority"], rows: rows)
    }

    static func printSavedQueries(_ savedQueries: [SavedQuery]) {
        if savedQueries.isEmpty {
            print("No saved queries found.")
            return
        }

        let rows = savedQueries.map { query in
            [
                query.name,
                truncate(query.query, limit: 80)
            ]
        }

        printTable(headers: ["Name", "Query"], rows: rows)
    }

    static func printAgileBoards(_ boards: [IssueBoard]) {
        if boards.isEmpty {
            print("No agile boards found.")
            return
        }

        let rows = boards.map { board in
            [
                board.name,
                board.isFavorite ? "Yes" : "No",
                board.projectNames.joined(separator: ", "),
                board.id
            ]
        }

        printTable(headers: ["Name", "Favorite", "Projects", "ID"], rows: rows)
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } catch {
            printError("Failed to encode JSON: \(error.localizedDescription)")
        }
    }

    private static func printTable(headers: [String], rows: [[String]]) {
        let columnCount = headers.count
        var widths = headers.map { $0.count }

        for row in rows {
            for index in 0..<min(columnCount, row.count) {
                widths[index] = max(widths[index], row[index].count)
            }
        }

        let headerLine = headers.enumerated().map { index, header in
            header.padded(to: widths[index])
        }.joined(separator: "  ")

        let separatorLine = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")

        print(headerLine)
        print(separatorLine)
        for row in rows {
            let line = row.enumerated().map { index, value in
                value.padded(to: widths[index])
            }.joined(separator: "  ")
            print(line)
        }
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return String(value[..<end]) + "..."
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }
}

private extension String {
    func padded(to length: Int) -> String {
        let padding = max(0, length - count)
        if padding == 0 { return self }
        return self + String(repeating: " ", count: padding)
    }
}

private struct IssueSummaryOutput: Encodable {
    let id: String
    let title: String
    let project: String
    let updatedAt: Date
    let assignee: String?
    let status: String
    let priority: String
    let tags: [String]

    init(issue: IssueSummary) {
        self.id = issue.readableID
        self.title = issue.title
        self.project = issue.projectName
        self.updatedAt = issue.updatedAt
        self.assignee = issue.assignee?.displayName
        self.status = issue.status.displayName
        self.priority = issue.priority.displayName
        self.tags = issue.tags
    }
}

private extension IssueSummaryOutput {
    init(_ issue: IssueSummary) {
        self.init(issue: issue)
    }
}

private struct SavedQueryOutput: Encodable {
    let id: String
    let name: String
    let query: String

    init(_ savedQuery: SavedQuery) {
        self.id = savedQuery.id
        self.name = savedQuery.name
        self.query = savedQuery.query
    }
}

private struct AgileBoardOutput: Encodable {
    let id: String
    let name: String
    let isFavorite: Bool
    let projects: [String]

    init(_ board: IssueBoard) {
        self.id = board.id
        self.name = board.name
        self.isFavorite = board.isFavorite
        self.projects = board.projectNames
    }
}
