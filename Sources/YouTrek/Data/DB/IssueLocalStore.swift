import Foundation
import SQLite

actor IssueLocalStore {
    private let db: Connection?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let issues = Table("issues")
    private let issueID = Expression<String>("id")
    private let readableID = Expression<String>("readable_id")
    private let title = Expression<String>("title")
    private let projectName = Expression<String>("project_name")
    private let updatedAt = Expression<Double>("updated_at")
    private let lastSeenUpdatedAt = Expression<Double?>("last_seen_updated_at")
    private let assigneeID = Expression<String?>("assignee_id")
    private let assigneeName = Expression<String?>("assignee_name")
    private let assigneeAvatarURL = Expression<String?>("assignee_avatar_url")
    private let assigneeLogin = Expression<String?>("assignee_login")
    private let assigneeRemoteID = Expression<String?>("assignee_remote_id")
    private let reporterID = Expression<String?>("reporter_id")
    private let reporterName = Expression<String?>("reporter_name")
    private let reporterAvatarURL = Expression<String?>("reporter_avatar_url")
    private let priority = Expression<String>("priority")
    private let priorityRank = Expression<Int>("priority_rank")
    private let status = Expression<String>("status")
    private let tagsJSON = Expression<String>("tags_json")
    private let customFieldsJSON = Expression<String?>("custom_fields_json")
    private let isDirty = Expression<Bool>("is_dirty")
    private let localUpdatedAt = Expression<Double?>("local_updated_at")

    private let issueQueries = Table("issue_queries")
    private let queryKey = Expression<String>("query_key")
    private let issueQueryIssueID = Expression<String>("issue_id")
    private let lastSeenAt = Expression<Double>("last_seen_at")

    private let mutations = Table("issue_mutations")
    private let mutationID = Expression<String>("id")
    private let mutationIssueID = Expression<String>("issue_id")
    private let mutationKind = Expression<String>("kind")
    private let mutationPayload = Expression<String>("payload_json")
    private let mutationLocalChanges = Expression<String>("local_changes")
    private let mutationCreatedAt = Expression<Double>("created_at")
    private let mutationLastAttemptAt = Expression<Double?>("last_attempt_at")
    private let mutationRetryCount = Expression<Int>("retry_count")
    private let mutationLastError = Expression<String?>("last_error")

    init() {
        do {
            let dbURL = try Self.databaseURL()
            let db = try Connection(dbURL.path)
            db.busyTimeout = 5
            try Self.migrateIfNeeded(db)
            self.db = db
        } catch {
            print("IssueLocalStore failed to open database: \(error.localizedDescription)")
            self.db = nil
        }
    }

    func loadIssues(for query: IssueQuery) async -> [IssueSummary] {
        guard let db else { return [] }
        let key = queryKey(for: query)
        let joined = issues.join(issueQueries, on: issues[issueID] == issueQueries[issueQueryIssueID])
            .filter(issueQueries[queryKey] == key)

        do {
            var results = try db.prepare(joined).compactMap { row in
                issueFromRow(row)
            }
            results = applySearchAndSort(results, query: query)
            return applyPaging(results, page: query.page)
        } catch {
            return []
        }
    }

    func saveRemoteIssues(_ remoteIssues: [IssueSummary], for query: IssueQuery) async {
        guard let db else { return }
        let key = queryKey(for: query)
        do {
            try db.run("BEGIN IMMEDIATE TRANSACTION")
            let existing = issueQueries.filter(queryKey == key)
            try db.run(existing.delete())

            for issue in remoteIssues {
                let idString = issue.id.uuidString
                let existingRow = try db.pluck(issues.filter(issueID == idString))
                let isLocalDirty = existingRow?[isDirty] ?? false
                if !isLocalDirty {
                    try upsert(issue: issue, db: db, existingRow: existingRow, markDirty: false)
                }
                let seenAt = Date().timeIntervalSince1970
                let insert = issueQueries.insert(or: .replace,
                                                 queryKey <- key,
                                                 issueQueryIssueID <- idString,
                                                 lastSeenAt <- seenAt)
                try db.run(insert)
            }

            try db.run("COMMIT")
        } catch {
            try? db.run("ROLLBACK")
            print("IssueLocalStore failed to save remote issues: \(error.localizedDescription)")
        }
    }

    func clearCache() async {
        guard let db else { return }
        do {
            try db.run("BEGIN IMMEDIATE TRANSACTION")
            try db.run(issueQueries.delete())
            try db.run(issues.delete())
            try db.run("COMMIT")
        } catch {
            try? db.run("ROLLBACK")
            print("IssueLocalStore failed to clear cache: \(error.localizedDescription)")
        }
    }

    func loadIssueSeenUpdates(for issueIDs: [IssueSummary.ID]) async -> [IssueSummary.ID: Date] {
        guard let db else { return [:] }
        var results: [IssueSummary.ID: Date] = [:]
        for id in Set(issueIDs) {
            guard let row = try? db.pluck(issues.filter(issueID == id.uuidString)),
                  let seenAt = row[lastSeenUpdatedAt]
            else { continue }
            results[id] = Date(timeIntervalSince1970: seenAt)
        }
        return results
    }

    func markIssueSeen(_ issue: IssueSummary) async {
        guard let db else { return }
        do {
            let seenAt = issue.updatedAt.timeIntervalSince1970
            let row = issues.filter(issueID == issue.id.uuidString)
            try db.run(row.update(lastSeenUpdatedAt <- seenAt))
        } catch {
            return
        }
    }

    func applyPatch(id: IssueSummary.ID, patch: IssuePatch) async -> IssueSummary? {
        guard let db else { return nil }
        do {
            guard let row = try db.pluck(issues.filter(issueID == id.uuidString)) else {
                return nil
            }
            var issue = issueFromRow(row)
            issue = applyPatch(patch, to: issue)
            let now = Date().timeIntervalSince1970
            let seenAt = row[lastSeenUpdatedAt]
            let setters = issueSetters(for: issue, markDirty: true, lastSeenUpdatedAt: seenAt)
                + [localUpdatedAt <- now, isDirty <- true]
            try db.run(issues.filter(issueID == id.uuidString).update(setters))
            return issue
        } catch {
            return nil
        }
    }

    func enqueueUpdate(issueID: IssueSummary.ID, patch: IssuePatch) async -> PendingIssueMutation? {
        guard let db else { return nil }
        let mutation = PendingIssueMutation(
            id: UUID(),
            issueID: issueID,
            kind: .update,
            patch: patch,
            localChanges: patch.localChangesDescription
        )
        do {
            let payloadData = try encoder.encode(patch)
            let payloadString = String(decoding: payloadData, as: UTF8.self)
            let insert = mutations.insert(
                mutationID <- mutation.id.uuidString,
                mutationIssueID <- mutation.issueID.uuidString,
                mutationKind <- mutation.kind.rawValue,
                mutationPayload <- payloadString,
                mutationLocalChanges <- mutation.localChanges,
                mutationCreatedAt <- mutation.createdAt.timeIntervalSince1970,
                mutationLastAttemptAt <- nil,
                mutationRetryCount <- 0,
                mutationLastError <- nil
            )
            try db.run(insert)
            return mutation
        } catch {
            return nil
        }
    }

    func pendingMutations() async -> [PendingIssueMutation] {
        guard let db else { return [] }
        do {
            return try db.prepare(mutations.order(mutationCreatedAt.asc)).compactMap { row in
                mutationFromRow(row)
            }
        } catch {
            return []
        }
    }

    func markMutationAttempted(id: UUID, errorDescription: String?) async {
        guard let db else { return }
        do {
            let row = mutations.filter(mutationID == id.uuidString)
            let updatedRetry = (try db.pluck(row))?[mutationRetryCount].advanced(by: 1) ?? 1
            try db.run(row.update(
                mutationLastAttemptAt <- Date().timeIntervalSince1970,
                mutationRetryCount <- updatedRetry,
                mutationLastError <- errorDescription
            ))
        } catch {
            return
        }
    }

    func markMutationApplied(_ mutation: PendingIssueMutation, updatedIssue: IssueSummary?) async {
        guard let db else { return }
        do {
            if let updatedIssue {
                try upsert(issue: updatedIssue, db: db, markDirty: false)
            } else {
                try db.run(issues.filter(issueID == mutation.issueID.uuidString).update(isDirty <- false))
            }
            try db.run(mutations.filter(mutationID == mutation.id.uuidString).delete())
        } catch {
            return
        }
    }

    private func upsert(issue: IssueSummary, db: Connection, markDirty: Bool) throws {
        let existingRow = try? db.pluck(issues.filter(issueID == issue.id.uuidString))
        try upsert(issue: issue, db: db, existingRow: existingRow, markDirty: markDirty)
    }

    private func upsert(issue: IssueSummary, db: Connection, existingRow: Row?, markDirty: Bool) throws {
        let seenAt = existingRow?[lastSeenUpdatedAt]
        let setters = issueSetters(for: issue, markDirty: markDirty, lastSeenUpdatedAt: seenAt)
        let insert = issues.insert(or: .replace, setters)
        try db.run(insert)
    }

    private func issueSetters(
        for issue: IssueSummary,
        markDirty: Bool,
        lastSeenUpdatedAt: Double?
    ) -> [Setter] {
        [
            issueID <- issue.id.uuidString,
            readableID <- issue.readableID,
            title <- issue.title,
            projectName <- issue.projectName,
            updatedAt <- issue.updatedAt.timeIntervalSince1970,
            self.lastSeenUpdatedAt <- lastSeenUpdatedAt,
            assigneeID <- issue.assignee?.id.uuidString,
            assigneeName <- issue.assignee?.displayName,
            assigneeAvatarURL <- issue.assignee?.avatarURL?.absoluteString,
            assigneeLogin <- issue.assignee?.login,
            assigneeRemoteID <- issue.assignee?.remoteID,
            reporterID <- issue.reporter?.id.uuidString,
            reporterName <- issue.reporter?.displayName,
            reporterAvatarURL <- issue.reporter?.avatarURL?.absoluteString,
            priority <- issue.priority.rawValue,
            priorityRank <- issue.priority.sortRank,
            status <- issue.status.rawValue,
            tagsJSON <- encodeTags(issue.tags),
            customFieldsJSON <- encodeCustomFields(issue.customFieldValues),
            isDirty <- markDirty
        ]
    }

    private func issueFromRow(_ row: Row) -> IssueSummary {
        let idValue = UUID(uuidString: row[issueID]) ?? UUID()
        let assignee: Person?
        if let name = row[assigneeName] {
            let assigneeUUID = UUID(uuidString: row[assigneeID] ?? "") ?? UUID()
            let avatar = row[assigneeAvatarURL].flatMap(URL.init(string:))
            let login = row[assigneeLogin]
            let remoteID = row[assigneeRemoteID]
            assignee = Person(id: assigneeUUID, displayName: name, avatarURL: avatar, login: login, remoteID: remoteID)
        } else {
            assignee = nil
        }
        let reporter: Person?
        if let name = row[reporterName] {
            let reporterUUID = UUID(uuidString: row[reporterID] ?? "") ?? UUID()
            let avatar = row[reporterAvatarURL].flatMap(URL.init(string:))
            reporter = Person(id: reporterUUID, displayName: name, avatarURL: avatar)
        } else {
            reporter = nil
        }
        let priorityValue = IssuePriority(rawValue: row[priority]) ?? .normal
        let statusValue = IssueStatus(rawValue: row[status]) ?? .open
        let tags = decodeTags(row[tagsJSON])
        let customFields = decodeCustomFields(row[customFieldsJSON])
        return IssueSummary(
            id: idValue,
            readableID: row[readableID],
            title: row[title],
            projectName: row[projectName],
            updatedAt: Date(timeIntervalSince1970: row[updatedAt]),
            assignee: assignee,
            reporter: reporter,
            priority: priorityValue,
            status: statusValue,
            tags: tags,
            customFieldValues: customFields
        )
    }

    private func mutationFromRow(_ row: Row) -> PendingIssueMutation? {
        guard let id = UUID(uuidString: row[mutationID]),
              let issueID = UUID(uuidString: row[mutationIssueID]),
              let kind = PendingIssueMutation.Kind(rawValue: row[mutationKind])
        else { return nil }

        guard let payloadData = row[mutationPayload].data(using: .utf8),
              let patch = try? decoder.decode(IssuePatch.self, from: payloadData)
        else { return nil }

        return PendingIssueMutation(
            id: id,
            issueID: issueID,
            kind: kind,
            patch: patch,
            localChanges: row[mutationLocalChanges],
            createdAt: Date(timeIntervalSince1970: row[mutationCreatedAt]),
            lastAttemptAt: row[mutationLastAttemptAt].map { Date(timeIntervalSince1970: $0) },
            retryCount: row[mutationRetryCount]
        )
    }

    private func applyPatch(_ patch: IssuePatch, to issue: IssueSummary) -> IssueSummary {
        let resolvedAssignee: Person?
        switch patch.assignee {
        case .clear:
            resolvedAssignee = nil
        case .set(let option):
            resolvedAssignee = Person.from(option: option)
        case .none:
            resolvedAssignee = issue.assignee
        }

        return IssueSummary(
            id: issue.id,
            readableID: issue.readableID,
            title: patch.title ?? issue.title,
            projectName: issue.projectName,
            updatedAt: Date(),
            assignee: resolvedAssignee,
            reporter: issue.reporter,
            priority: patch.priority ?? issue.priority,
            status: patch.status ?? issue.status,
            tags: issue.tags
        )
    }

    private func applySearchAndSort(_ issues: [IssueSummary], query: IssueQuery) -> [IssueSummary] {
        let filtered: [IssueSummary]
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty {
            filtered = issues
        } else {
            let lowercased = search.lowercased()
            filtered = issues.filter { issue in
                issue.title.lowercased().contains(lowercased) ||
                issue.readableID.lowercased().contains(lowercased) ||
                issue.projectName.lowercased().contains(lowercased)
            }
        }

        switch query.sort {
        case .updated(let descending):
            return filtered.sorted { descending ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt }
        case .priority(let descending):
            return filtered.sorted { descending ? $0.priority.sortRank > $1.priority.sortRank : $0.priority.sortRank < $1.priority.sortRank }
        case .none:
            return filtered
        }
    }

    private func applyPaging(_ issues: [IssueSummary], page: IssueQuery.Page) -> [IssueSummary] {
        guard page.offset < issues.count else { return [] }
        let start = max(0, page.offset)
        let end = min(issues.count, start + page.size)
        return Array(issues[start..<end])
    }

    private func encodeTags(_ tags: [String]) -> String {
        guard let data = try? encoder.encode(tags) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeTags(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let tags = try? decoder.decode([String].self, from: data)
        else { return [] }
        return tags
    }

    private func encodeCustomFields(_ fields: [String: [String]]) -> String? {
        guard !fields.isEmpty, let data = try? encoder.encode(fields) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeCustomFields(_ json: String?) -> [String: [String]] {
        guard let json,
              let data = json.data(using: .utf8),
              let fields = try? decoder.decode([String: [String]].self, from: data)
        else { return [:] }
        return fields
    }

    private func queryKey(for query: IssueQuery) -> String {
        let rawQuery = query.rawQuery ?? ""
        let filters = query.filters.joined(separator: "|")
        let sortKey: String
        switch query.sort {
        case .updated(let descending):
            sortKey = "updated:\(descending)"
        case .priority(let descending):
            sortKey = "priority:\(descending)"
        case .none:
            sortKey = "none"
        }
        return [
            rawQuery,
            query.search,
            filters,
            sortKey,
            "page:\(query.page.size):\(query.page.offset)"
        ].joined(separator: "||")
    }

    private static func databaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("YouTrek", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        return directoryURL.appendingPathComponent("YouTrek.sqlite")
    }

    private static func migrateIfNeeded(_ db: Connection) throws {
        let issuesTable = Table("issues")
        let issueIDColumn = Expression<String>("id")
        let readableIDColumn = Expression<String>("readable_id")
        let titleColumn = Expression<String>("title")
        let projectNameColumn = Expression<String>("project_name")
        let updatedAtColumn = Expression<Double>("updated_at")
        let lastSeenUpdatedAtColumn = Expression<Double?>("last_seen_updated_at")
        let assigneeIDColumn = Expression<String?>("assignee_id")
        let assigneeNameColumn = Expression<String?>("assignee_name")
        let assigneeAvatarURLColumn = Expression<String?>("assignee_avatar_url")
        let assigneeLoginColumn = Expression<String?>("assignee_login")
        let assigneeRemoteIDColumn = Expression<String?>("assignee_remote_id")
        let reporterIDColumn = Expression<String?>("reporter_id")
        let reporterNameColumn = Expression<String?>("reporter_name")
        let reporterAvatarURLColumn = Expression<String?>("reporter_avatar_url")
        let priorityColumn = Expression<String>("priority")
        let priorityRankColumn = Expression<Int>("priority_rank")
        let statusColumn = Expression<String>("status")
        let tagsJSONColumn = Expression<String>("tags_json")
        let customFieldsJSONColumn = Expression<String?>("custom_fields_json")
        let isDirtyColumn = Expression<Bool>("is_dirty")
        let localUpdatedAtColumn = Expression<Double?>("local_updated_at")

        let issueQueriesTable = Table("issue_queries")
        let queryKeyColumn = Expression<String>("query_key")
        let issueQueryIssueIDColumn = Expression<String>("issue_id")
        let lastSeenAtColumn = Expression<Double>("last_seen_at")

        let mutationsTable = Table("issue_mutations")
        let mutationIDColumn = Expression<String>("id")
        let mutationIssueIDColumn = Expression<String>("issue_id")
        let mutationKindColumn = Expression<String>("kind")
        let mutationPayloadColumn = Expression<String>("payload_json")
        let mutationLocalChangesColumn = Expression<String>("local_changes")
        let mutationCreatedAtColumn = Expression<Double>("created_at")
        let mutationLastAttemptAtColumn = Expression<Double?>("last_attempt_at")
        let mutationRetryCountColumn = Expression<Int>("retry_count")
        let mutationLastErrorColumn = Expression<String?>("last_error")

        try db.run(issuesTable.create(ifNotExists: true) { table in
            table.column(issueIDColumn, primaryKey: true)
            table.column(readableIDColumn)
            table.column(titleColumn)
            table.column(projectNameColumn)
            table.column(updatedAtColumn)
            table.column(lastSeenUpdatedAtColumn)
            table.column(assigneeIDColumn)
            table.column(assigneeNameColumn)
            table.column(assigneeAvatarURLColumn)
            table.column(assigneeLoginColumn)
            table.column(assigneeRemoteIDColumn)
            table.column(reporterIDColumn)
            table.column(reporterNameColumn)
            table.column(reporterAvatarURLColumn)
            table.column(priorityColumn)
            table.column(priorityRankColumn)
            table.column(statusColumn)
            table.column(tagsJSONColumn)
            table.column(customFieldsJSONColumn)
            table.column(isDirtyColumn, defaultValue: false)
            table.column(localUpdatedAtColumn)
        })

        try addColumnIfNeeded(db, table: "issues", column: "custom_fields_json", type: "TEXT")
        try addColumnIfNeeded(db, table: "issues", column: "last_seen_updated_at", type: "DOUBLE")
        try addColumnIfNeeded(db, table: "issues", column: "reporter_id", type: "TEXT")
        try addColumnIfNeeded(db, table: "issues", column: "reporter_name", type: "TEXT")
        try addColumnIfNeeded(db, table: "issues", column: "reporter_avatar_url", type: "TEXT")
        try addColumnIfNeeded(db, table: "issues", column: "assignee_login", type: "TEXT")
        try addColumnIfNeeded(db, table: "issues", column: "assignee_remote_id", type: "TEXT")

        try db.run(issueQueriesTable.create(ifNotExists: true) { table in
            table.column(queryKeyColumn)
            table.column(issueQueryIssueIDColumn)
            table.column(lastSeenAtColumn)
            table.primaryKey(queryKeyColumn, issueQueryIssueIDColumn)
        })

        try db.run(mutationsTable.create(ifNotExists: true) { table in
            table.column(mutationIDColumn, primaryKey: true)
            table.column(mutationIssueIDColumn)
            table.column(mutationKindColumn)
            table.column(mutationPayloadColumn)
            table.column(mutationLocalChangesColumn)
            table.column(mutationCreatedAtColumn)
            table.column(mutationLastAttemptAtColumn)
            table.column(mutationRetryCountColumn, defaultValue: 0)
            table.column(mutationLastErrorColumn)
        })
    }

    private static func addColumnIfNeeded(_ db: Connection, table: String, column: String, type: String) throws {
        let existing = try existingColumns(in: table, db: db)
        guard !existing.contains(column) else { return }
        try db.run("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
    }

    private static func existingColumns(in table: String, db: Connection) throws -> Set<String> {
        let rows = try db.prepare("PRAGMA table_info(\(table))")
        var columns = Set<String>()
        for row in rows {
            if let name = row[1] as? String {
                columns.insert(name)
            }
        }
        return columns
    }
}

struct PendingIssueMutation: Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case update
    }

    let id: UUID
    let issueID: UUID
    let kind: Kind
    let patch: IssuePatch
    let localChanges: String
    let createdAt: Date
    let lastAttemptAt: Date?
    let retryCount: Int

    init(
        id: UUID,
        issueID: UUID,
        kind: Kind,
        patch: IssuePatch,
        localChanges: String,
        createdAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.issueID = issueID
        self.kind = kind
        self.patch = patch
        self.localChanges = localChanges
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.retryCount = retryCount
    }
}

private extension IssuePriority {
    var sortRank: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        }
    }
}
