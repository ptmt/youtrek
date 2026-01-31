import Foundation
import SQLite

actor SavedQueryLocalStore {
    private let db: Connection?

    private let savedQueries = Table("saved_queries")
    private let queryID = Expression<String>("id")
    private let name = Expression<String>("name")
    private let query = Expression<String>("query")
    private let updatedAt = Expression<Double?>("updated_at")

    init() {
        do {
            let dbURL = try Self.databaseURL()
            let db = try Connection(dbURL.path)
            db.busyTimeout = 5
            try Self.migrateIfNeeded(db)
            self.db = db
        } catch {
            print("SavedQueryLocalStore failed to open database: \(error.localizedDescription)")
            self.db = nil
        }
    }

    func loadSavedQueries() async -> [SavedQuery] {
        guard let db else { return [] }
        do {
            return try db.prepare(savedQueries.order(name.asc)).map(savedQueryFromRow(_:))
        } catch {
            return []
        }
    }

    func saveRemoteSavedQueries(_ remoteQueries: [SavedQuery]) async {
        guard let db else { return }
        do {
            try db.run("BEGIN IMMEDIATE TRANSACTION")
            try db.run(savedQueries.delete())
            let now = Date().timeIntervalSince1970
            for savedQuery in remoteQueries {
                let insert = savedQueries.insert(
                    queryID <- savedQuery.id,
                    name <- savedQuery.name,
                    query <- savedQuery.query,
                    updatedAt <- now
                )
                try db.run(insert)
            }
            try db.run("COMMIT")
        } catch {
            try? db.run("ROLLBACK")
            print("SavedQueryLocalStore failed to save saved queries: \(error.localizedDescription)")
        }
    }

    func clearCache() async {
        guard let db else { return }
        do {
            try db.run(savedQueries.delete())
        } catch {
            print("SavedQueryLocalStore failed to clear cache: \(error.localizedDescription)")
        }
    }

    private func savedQueryFromRow(_ row: Row) -> SavedQuery {
        SavedQuery(id: row[queryID], name: row[name], query: row[query])
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
        let savedQueriesTable = Table("saved_queries")
        let idColumn = Expression<String>("id")
        let nameColumn = Expression<String>("name")
        let queryColumn = Expression<String>("query")
        let updatedAtColumn = Expression<Double?>("updated_at")

        try db.run(savedQueriesTable.create(ifNotExists: true) { table in
            table.column(idColumn, primaryKey: true)
            table.column(nameColumn)
            table.column(queryColumn)
            table.column(updatedAtColumn)
        })

        try addColumnIfNeeded(db, table: "saved_queries", column: "updated_at", type: "DOUBLE")
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
