import Foundation

protocol IssueBoardRepository: Sendable {
    func fetchBoards() async throws -> [IssueBoard]
    func fetchBoard(id: String) async throws -> IssueBoard
}
