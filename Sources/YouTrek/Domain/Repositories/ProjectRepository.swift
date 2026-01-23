import Foundation

protocol ProjectRepository: Sendable {
    func fetchProjects() async throws -> [IssueProject]
}
