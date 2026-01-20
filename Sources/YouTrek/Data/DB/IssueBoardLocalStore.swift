import Foundation
import SQLite

actor IssueBoardLocalStore {
    private let db: Connection?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let boards = Table("issue_boards")
    private let boardID = Expression<String>("id")
    private let name = Expression<String>("name")
    private let isFavorite = Expression<Bool>("is_favorite")
    private let projectNamesJSON = Expression<String>("project_names_json")
    private let sprintsJSON = Expression<String?>("sprints_json")
    private let currentSprintID = Expression<String?>("current_sprint_id")
    private let columnFieldName = Expression<String?>("column_field_name")
    private let columnsJSON = Expression<String?>("columns_json")
    private let swimlaneJSON = Expression<String?>("swimlane_json")
    private let orphansAtTop = Expression<Bool?>("orphans_at_top")
    private let hideOrphansSwimlane = Expression<Bool?>("hide_orphans_swimlane")
    private let updatedAt = Expression<Double?>("updated_at")

    init() {
        do {
            let dbURL = try Self.databaseURL()
            let db = try Connection(dbURL.path)
            db.busyTimeout = 5
            try Self.migrateIfNeeded(db)
            self.db = db
        } catch {
            print("IssueBoardLocalStore failed to open database: \(error.localizedDescription)")
            self.db = nil
        }
    }

    func loadBoards() async -> [IssueBoard] {
        guard let db else { return [] }
        do {
            return try db.prepare(boards.order(name.asc)).compactMap { row in
                boardFromRow(row)
            }
        } catch {
            return []
        }
    }

    func loadFavoriteBoards() async -> [IssueBoard] {
        guard let db else { return [] }
        do {
            return try db.prepare(boards.filter(isFavorite == true).order(name.asc)).compactMap { row in
                boardFromRow(row)
            }
        } catch {
            return []
        }
    }

    func saveRemoteBoards(_ remoteBoards: [IssueBoard]) async {
        guard let db else { return }
        do {
            try db.run("BEGIN IMMEDIATE TRANSACTION")
            try db.run(boards.delete())
            let now = Date().timeIntervalSince1970
            for board in remoteBoards {
                let insert = boards.insert(
                    boardID <- board.id,
                    name <- board.name,
                    isFavorite <- board.isFavorite,
                    projectNamesJSON <- encodeProjects(board.projectNames),
                    sprintsJSON <- encodeSprints(board.sprints),
                    currentSprintID <- board.currentSprintID,
                    columnFieldName <- board.columnFieldName,
                    columnsJSON <- encodeColumns(board.columns),
                    swimlaneJSON <- encodeSwimlane(board.swimlaneSettings),
                    orphansAtTop <- board.orphansAtTheTop,
                    hideOrphansSwimlane <- board.hideOrphansSwimlane,
                    updatedAt <- now
                )
                try db.run(insert)
            }
            try db.run("COMMIT")
        } catch {
            try? db.run("ROLLBACK")
            print("IssueBoardLocalStore failed to save remote boards: \(error.localizedDescription)")
        }
    }

    func clearCache() async {
        guard let db else { return }
        do {
            try db.run(boards.delete())
        } catch {
            print("IssueBoardLocalStore failed to clear cache: \(error.localizedDescription)")
        }
    }

    private func boardFromRow(_ row: Row) -> IssueBoard {
        IssueBoard(
            id: row[boardID],
            name: row[name],
            isFavorite: row[isFavorite],
            projectNames: decodeProjects(row[projectNamesJSON]),
            sprints: decodeSprints(row[sprintsJSON]),
            currentSprintID: row[currentSprintID],
            columnFieldName: row[columnFieldName],
            columns: decodeColumns(row[columnsJSON]),
            swimlaneSettings: decodeSwimlane(row[swimlaneJSON]),
            orphansAtTheTop: row[orphansAtTop] ?? false,
            hideOrphansSwimlane: row[hideOrphansSwimlane] ?? false
        )
    }

    private func encodeProjects(_ projects: [String]) -> String {
        guard let data = try? encoder.encode(projects) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeProjects(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let projects = try? decoder.decode([String].self, from: data)
        else { return [] }
        return projects
    }

    private func encodeColumns(_ columns: [IssueBoardColumn]) -> String? {
        guard !columns.isEmpty, let data = try? encoder.encode(columns) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeColumns(_ json: String?) -> [IssueBoardColumn] {
        guard let json,
              let data = json.data(using: .utf8),
              let columns = try? decoder.decode([IssueBoardColumn].self, from: data)
        else { return [] }
        return columns
    }

    private func encodeSprints(_ sprints: [IssueBoardSprint]) -> String? {
        guard !sprints.isEmpty, let data = try? encoder.encode(sprints) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeSprints(_ json: String?) -> [IssueBoardSprint] {
        guard let json,
              let data = json.data(using: .utf8),
              let sprints = try? decoder.decode([IssueBoardSprint].self, from: data)
        else { return [] }
        return sprints
    }

    private func encodeSwimlane(_ settings: IssueBoardSwimlaneSettings) -> String? {
        guard let data = try? encoder.encode(settings) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeSwimlane(_ json: String?) -> IssueBoardSwimlaneSettings {
        guard let json,
              let data = json.data(using: .utf8),
              let settings = try? decoder.decode(IssueBoardSwimlaneSettings.self, from: data)
        else { return .disabled }
        return settings
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
        let boardsTable = Table("issue_boards")
        let boardIDColumn = Expression<String>("id")
        let nameColumn = Expression<String>("name")
        let isFavoriteColumn = Expression<Bool>("is_favorite")
        let projectNamesJSONColumn = Expression<String>("project_names_json")
        let sprintsJSONColumn = Expression<String?>("sprints_json")
        let currentSprintIDColumn = Expression<String?>("current_sprint_id")
        let columnFieldNameColumn = Expression<String?>("column_field_name")
        let columnsJSONColumn = Expression<String?>("columns_json")
        let swimlaneJSONColumn = Expression<String?>("swimlane_json")
        let orphansAtTopColumn = Expression<Bool?>("orphans_at_top")
        let hideOrphansSwimlaneColumn = Expression<Bool?>("hide_orphans_swimlane")
        let updatedAtColumn = Expression<Double?>("updated_at")

        try db.run(boardsTable.create(ifNotExists: true) { table in
            table.column(boardIDColumn, primaryKey: true)
            table.column(nameColumn)
            table.column(isFavoriteColumn, defaultValue: false)
            table.column(projectNamesJSONColumn)
            table.column(sprintsJSONColumn)
            table.column(currentSprintIDColumn)
            table.column(columnFieldNameColumn)
            table.column(columnsJSONColumn)
            table.column(swimlaneJSONColumn)
            table.column(orphansAtTopColumn)
            table.column(hideOrphansSwimlaneColumn)
            table.column(updatedAtColumn)
        })

        try addColumnIfNeeded(db, table: "issue_boards", column: "column_field_name", type: "TEXT")
        try addColumnIfNeeded(db, table: "issue_boards", column: "columns_json", type: "TEXT")
        try addColumnIfNeeded(db, table: "issue_boards", column: "swimlane_json", type: "TEXT")
        try addColumnIfNeeded(db, table: "issue_boards", column: "orphans_at_top", type: "INTEGER")
        try addColumnIfNeeded(db, table: "issue_boards", column: "hide_orphans_swimlane", type: "INTEGER")
        try addColumnIfNeeded(db, table: "issue_boards", column: "sprints_json", type: "TEXT")
        try addColumnIfNeeded(db, table: "issue_boards", column: "current_sprint_id", type: "TEXT")
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
