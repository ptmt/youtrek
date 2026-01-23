import Foundation

protocol PeopleRepository: Sendable {
    func fetchPeople(query: String?, projectID: String?) async throws -> [IssueFieldOption]
}
