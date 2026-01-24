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
        case "comment":
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--id", "--text", "--base-url", "--token"],
                flagOptions: ["--json"]
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printIssuesHelp()
                return 0
            }

            let issueID = parsed.options["--id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !issueID.isEmpty else {
                throw CLIError.missingArgument("--id")
            }
            let text = parsed.options["--text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw CLIError.missingArgument("--text")
            }

            let connection = try resolveConnection(options: parsed)
            let issueRepository = YouTrackIssueRepository(configuration: connection.configuration)
            let comment = try await issueRepository.addComment(issueReadableID: issueID, text: text)

            if parsed.flags.contains("--json") {
                CLIOutput.printJSON(IssueCommentOutput(comment: comment, issueID: issueID))
            } else {
                CLIOutput.printInfo("Added comment to \(issueID).")
            }
            return 0
        case "statuses":
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--project", "--fields", "--base-url", "--token"],
                flagOptions: []
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printIssuesHelp()
                return 0
            }

            let projectIdentifier = parsed.options["--project"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !projectIdentifier.isEmpty else {
                throw CLIError.missingArgument("--project")
            }

            let connection = try resolveConnection(options: parsed)
            let projectRepo = YouTrackProjectRepository(configuration: connection.configuration)
            let projects = try await projectRepo.fetchProjects()
            guard let project = resolveProject(projects, identifier: projectIdentifier) else {
                throw CLIError.invalidValue(option: "--project", value: projectIdentifier)
            }

            let fieldRepo = YouTrackIssueFieldRepository(configuration: connection.configuration)
            let fields = try await fieldRepo.fetchFields(projectID: project.id)
            guard let statusField = findStatusField(in: fields) else {
                throw CLIError.missingConfiguration("status field for project \"\(project.displayName)\"")
            }
            guard let bundleID = statusField.bundleID else {
                throw CLIError.missingConfiguration("status bundle for project \"\(project.displayName)\"")
            }

            let path = statusBundlePath(kind: statusField.kind, bundleID: bundleID)
            let fieldsParam = parsed.options["--fields"]
                ?? "id,name,values(id,name,localizedName,ordinal,color(background,foreground))"
            let client = YouTrackAPIClient(configuration: connection.configuration)
            let data = try await client.get(
                path: path,
                queryItems: [URLQueryItem(name: "fields", value: fieldsParam)]
            )
            if let raw = String(data: data, encoding: .utf8) {
                print(raw)
            } else {
                CLIOutput.printError("Received non-UTF8 response data.")
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
                flagOptions: ["--json", "--offline", "--favorites"]
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printAgileBoardsHelp()
                return 0
            }

            if parsed.flags.contains("--offline") {
                let store = IssueBoardLocalStore()
                let boards = await store.loadBoards()
                let filtered = parsed.flags.contains("--favorites") ? boards.filter(\.isFavorite) : boards
                if parsed.flags.contains("--json") {
                    let output = filtered.map(AgileBoardOutput.init)
                    CLIOutput.printJSON(output)
                } else {
                    CLIOutput.printAgileBoards(filtered)
                }
                return 0
            }

            let connection = try resolveConnection(options: parsed)
            let repository = YouTrackIssueBoardRepository(configuration: connection.configuration)
            let boards = try await repository.fetchBoards()
            let store = IssueBoardLocalStore()
            await store.saveRemoteBoards(boards)

            let filtered = parsed.flags.contains("--favorites") ? boards.filter(\.isFavorite) : boards
            if parsed.flags.contains("--json") {
                let output = filtered.map(AgileBoardOutput.init)
                CLIOutput.printJSON(output)
            } else {
                CLIOutput.printAgileBoards(filtered)
            }
            return 0
        case "show":
            let parsed = try parseOptions(
                remaining,
                valueOptions: ["--base-url", "--token", "--id", "--name", "--sprint", "--top"],
                flagOptions: ["--backlog"]
            )
            if parsed.flags.contains("--help") {
                CLIOutput.printAgileBoardsHelp()
                return 0
            }

            let boardID = parsed.options["--id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let boardName = parsed.options["--name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if boardID == nil && (boardName == nil || boardName?.isEmpty == true) {
                throw CLIError.missingArgument("--id or --name")
            }

            if parsed.flags.contains("--backlog"), parsed.options["--sprint"] != nil {
                throw CLIError.invalidValue(option: "--sprint", value: "cannot be used with --backlog")
            }

            let topValue = parsed.options["--top"] ?? "200"
            guard let pageSize = Int(topValue), pageSize > 0 else {
                throw CLIError.invalidValue(option: "--top", value: topValue)
            }

            let connection = try resolveConnection(options: parsed)
            let boardRepository = YouTrackIssueBoardRepository(configuration: connection.configuration)
            let issueRepository = YouTrackIssueRepository(configuration: connection.configuration)

            let resolvedID: String
            if let boardID, !boardID.isEmpty {
                resolvedID = boardID
            } else if let name = boardName, !name.isEmpty {
                let summaries = try await boardRepository.fetchBoardSummaries()
                guard let match = summaries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw CLIError.invalidValue(option: "--name", value: name)
                }
                resolvedID = match.id
            } else {
                throw CLIError.missingArgument("--id or --name")
            }

            let board = try await boardRepository.fetchBoard(id: resolvedID)
            let sprintSelection = try resolveSprintSelection(parsed, board: board)
            let query = IssueQuery(
                rawQuery: IssueQuery.boardQuery(boardName: board.name, sprintName: nil),
                search: "",
                filters: [],
                sort: nil,
                page: IssueQuery.Page(size: pageSize, offset: 0)
            )
            let issues = try await issueRepository.fetchIssues(query: query)
            let visibleIssues: [IssueSummary]
            switch sprintSelection.filter {
            case .sprint(let sprintID):
                if let sprintIDs = try? await issueRepository.fetchSprintIssueIDs(
                    agileID: board.id,
                    sprintID: sprintID
                ), !sprintIDs.isEmpty {
                    let idSet = Set(sprintIDs)
                    visibleIssues = issues.filter { idSet.contains($0.readableID) }
                } else {
                    visibleIssues = board.filteredIssues(issues, sprintFilter: sprintSelection.filter)
                }
            case .backlog:
                visibleIssues = board.filteredIssues(issues, sprintFilter: sprintSelection.filter)
            }
            CLIOutput.printBoard(board, issues: visibleIssues, sprintLabel: sprintSelection.label)
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

    private struct CLISprintSelection {
        let filter: BoardSprintFilter
        let label: String
    }

    private static func resolveSprintSelection(
        _ parsed: CLIParsedOptions,
        board: IssueBoard
    ) throws -> CLISprintSelection {
        if parsed.flags.contains("--backlog") {
            return CLISprintSelection(filter: .backlog, label: "Backlog")
        }

        if let rawSprint = parsed.options["--sprint"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawSprint.isEmpty {
            guard let sprint = board.sprints.first(where: { $0.name.caseInsensitiveCompare(rawSprint) == .orderedSame }) else {
                throw CLIError.invalidValue(option: "--sprint", value: rawSprint)
            }
            return CLISprintSelection(filter: .sprint(id: sprint.id), label: sprint.name)
        }

        let fallback = board.defaultSprintFilter
        if fallback.isBacklog {
            return CLISprintSelection(filter: .backlog, label: "Backlog")
        }

        let name = board.sprintName(for: fallback)
        return CLISprintSelection(filter: fallback, label: name ?? "Sprint")
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

    private static func resolveProject(_ projects: [IssueProject], identifier: String) -> IssueProject? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let match = projects.first(where: { $0.id == trimmed }) {
            return match
        }
        if let match = projects.first(where: { $0.shortName?.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }
        if let match = projects.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }
        return nil
    }

    private static func findStatusField(in fields: [IssueField]) -> IssueField? {
        let namedMatches = fields.filter { field in
            let names = [field.name, field.localizedName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return names.contains("state") || names.contains("status")
        }

        if let stateMatch = namedMatches.first(where: { $0.kind == .state }) {
            return stateMatch
        }
        if let namedMatch = namedMatches.first {
            return namedMatch
        }
        return fields.first(where: { $0.kind == .state })
    }

    private static func statusBundlePath(kind: IssueFieldKind, bundleID: String) -> String {
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .state {
            return "admin/customFieldSettings/bundles/state/\(trimmedBundle)"
        }
        return "admin/customFieldSettings/bundles/enum/\(trimmedBundle)"
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
              issues comment --id <id> --text <text> [--json]
              issues statuses --project <id|shortName|name> [--fields <fields>]
              agile-boards list [--favorites] [--offline] [--json]
              agile-boards show --id <id> [--sprint <name> | --backlog] [--top <n>]
              agile-boards show --name <name> [--sprint <name> | --backlog] [--top <n>]
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
              youtrek issues comment --id <id> --text <text> [--json]
              youtrek issues statuses --project <id|shortName|name> [--fields <fields>]
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
              youtrek agile-boards list [--favorites] [--offline] [--json]
              youtrek agile-boards show --id <id> [--sprint <name> | --backlog] [--top <n>]
              youtrek agile-boards show --name <name> [--sprint <name> | --backlog] [--top <n>]
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

    static func printBoard(_ board: IssueBoard, issues: [IssueSummary], sprintLabel: String) {
        print("Board: \(board.name)")
        print("ID: \(board.id)")
        print("Sprint: \(sprintLabel)")
        print("")

        guard !issues.isEmpty else {
            print("No cards on this board.")
            return
        }

        let columns = makeBoardColumns(board, issues: issues)
        let groups = makeBoardGroups(board, issues: issues)

        for (index, group) in groups.enumerated() {
            print("\(group.title) (\(group.issues.count) cards)")
            for column in columns {
                let columnIssues = group.issues.filter(column.match)
                print("  \(column.title) (\(columnIssues.count))")
                for issue in columnIssues {
                    let title = truncate(issue.title, limit: 80)
                    print("    \(issue.readableID) \(title)")
                }
            }
            if index < groups.count - 1 {
                print("")
            }
        }
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

    private static func makeBoardColumns(_ board: IssueBoard, issues: [IssueSummary]) -> [BoardColumnDescriptor] {
        if let fieldName = board.columnFieldName, !board.columns.isEmpty {
            let normalizedField = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let columns = board.columns.sorted { (left, right) in
                let leftOrdinal = left.ordinal ?? Int.max
                let rightOrdinal = right.ordinal ?? Int.max
                if leftOrdinal != rightOrdinal { return leftOrdinal < rightOrdinal }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
            return columns.map { column in
                let matchValues = column.valueNames.map { $0.lowercased() }
                return BoardColumnDescriptor(
                    title: column.title,
                    match: { issue in
                        let values = issue.fieldValues(named: normalizedField).map { $0.lowercased() }
                        if matchValues.isEmpty {
                            let title = column.title.lowercased()
                            return values.contains(title)
                        }
                        return values.contains(where: { matchValues.contains($0) })
                    }
                )
            }
        }

        let resolved = IssueStatus.sortedUnique(issues.map(\.status))
        let fallback = resolved.isEmpty ? IssueStatus.fallbackCases : resolved
        return fallback.map { status in
            BoardColumnDescriptor(
                title: status.displayName,
                match: { issue in issue.status == status }
            )
        }
    }

    private static func makeBoardGroups(_ board: IssueBoard, issues: [IssueSummary]) -> [BoardGroup] {
        guard board.swimlaneSettings.isEnabled, let fieldName = board.swimlaneSettings.fieldName else {
            return [BoardGroup(title: "All cards", issues: issues, isUnassigned: false, sortIndex: 0)]
        }

        let normalizedField = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAssignee = normalizedField == "assignee"
        let explicitValues = board.swimlaneSettings.values
        let lookup = Dictionary(uniqueKeysWithValues: explicitValues.map { ($0.lowercased(), $0) })

        var buckets: [String: [IssueSummary]] = [:]
        var unassigned: [IssueSummary] = []
        var orderedKeys: [String] = []
        var orderedKeySet: Set<String> = []

        for issue in issues {
            let values = swimlaneValues(
                for: issue,
                fieldName: normalizedField,
                isAssignee: isAssignee,
                includeIdentifiers: !explicitValues.isEmpty
            )
            if values.isEmpty {
                unassigned.append(issue)
                continue
            }

            var matched = false
            for value in values {
                let key = value.lowercased()
                if let canonical = lookup[key] {
                    buckets[canonical, default: []].append(issue)
                    matched = true
                } else if explicitValues.isEmpty {
                    buckets[value, default: []].append(issue)
                    let normalized = value.lowercased()
                    if orderedKeySet.insert(normalized).inserted {
                        orderedKeys.append(value)
                    }
                    matched = true
                }
            }
            if !matched {
                unassigned.append(issue)
            }
        }

        var groups: [BoardGroup] = []
        if !explicitValues.isEmpty {
            for (index, value) in explicitValues.enumerated() {
                let groupIssues = buckets[value] ?? []
                groups.append(BoardGroup(title: value, issues: groupIssues, isUnassigned: false, sortIndex: index))
            }
        } else {
            for (index, key) in orderedKeys.enumerated() {
                groups.append(BoardGroup(title: key, issues: buckets[key] ?? [], isUnassigned: false, sortIndex: index))
            }
        }

        if !unassigned.isEmpty, !board.hideOrphansSwimlane {
            let title = isAssignee ? "Unassigned" : "Other"
            let sortIndex = board.orphansAtTheTop ? -1 : (groups.last?.sortIndex ?? 0) + 1
            let orphanGroup = BoardGroup(title: title, issues: unassigned, isUnassigned: true, sortIndex: sortIndex)
            if board.orphansAtTheTop {
                groups.insert(orphanGroup, at: 0)
            } else {
                groups.append(orphanGroup)
            }
        }

        if groups.isEmpty {
            return [BoardGroup(title: "All cards", issues: issues, isUnassigned: false, sortIndex: 0)]
        }

        return groups
    }

    private static func swimlaneValues(
        for issue: IssueSummary,
        fieldName: String,
        isAssignee: Bool,
        includeIdentifiers: Bool
    ) -> [String] {
        if isAssignee {
            var values: [String] = []
            if let assignee = issue.assignee {
                let displayName = assignee.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                appendUnique(displayName, to: &values)
                if includeIdentifiers {
                    let remoteID = assignee.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    appendUnique(remoteID, to: &values)
                    let login = assignee.login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    appendUnique(login, to: &values)
                }
            }
            if values.isEmpty {
                values = issue.fieldValues(named: fieldName)
            }
            return values
        }
        return issue.fieldValues(named: fieldName)
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        values.append(trimmed)
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

private struct IssueCommentOutput: Encodable {
    let id: String
    let issueID: String
    let text: String
    let createdAt: Date
    let author: String?

    init(comment: IssueComment, issueID: String) {
        self.id = comment.id
        self.issueID = issueID
        self.text = comment.text
        self.createdAt = comment.createdAt
        self.author = comment.author?.displayName
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

private struct BoardColumnDescriptor {
    let title: String
    let match: (IssueSummary) -> Bool
}

private struct BoardGroup {
    let title: String
    let issues: [IssueSummary]
    let isUnassigned: Bool
    let sortIndex: Int
}
