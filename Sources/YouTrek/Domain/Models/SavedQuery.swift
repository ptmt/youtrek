import Foundation

struct SavedQuery: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let query: String
}
