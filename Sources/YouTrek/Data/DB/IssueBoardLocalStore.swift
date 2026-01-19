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

    private func boardFromRow(_ row: Row) -> IssueBoard {
        IssueBoard(
            id: row[boardID],
            name: row[name],
            isFavorite: row[isFavorite],
            projectNames: decodeProjects(row[projectNamesJSON])
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
        let updatedAtColumn = Expression<Double?>("updated_at")

        try db.run(boardsTable.create(ifNotExists: true) { table in
            table.column(boardIDColumn, primaryKey: true)
            table.column(nameColumn)
            table.column(isFavoriteColumn, defaultValue: false)
            table.column(projectNamesJSONColumn)
            table.column(updatedAtColumn)
        })
    }
}
