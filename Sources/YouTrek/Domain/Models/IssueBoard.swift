import Foundation

struct IssueBoard: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFavorite: Bool
    let projectNames: [String]
}
