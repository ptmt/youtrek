import Foundation

protocol SavedQueryRepository: Sendable {
    func fetchSavedQueries() async throws -> [SavedQuery]
}
