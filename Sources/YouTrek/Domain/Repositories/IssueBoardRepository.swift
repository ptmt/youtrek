import Foundation

protocol IssueBoardRepository: Sendable {
    func fetchBoards() async throws -> [IssueBoard]
}
