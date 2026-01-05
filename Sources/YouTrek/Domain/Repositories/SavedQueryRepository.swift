import Foundation

protocol SavedQueryRepository: Sendable {
    func fetchSavedQueries() async throws -> [SavedQuery]
    func deleteSavedQuery(id: String) async throws
}
