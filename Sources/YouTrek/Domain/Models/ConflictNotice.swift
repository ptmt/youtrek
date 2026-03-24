import Foundation

struct ConflictNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let localChanges: String

    init(id: UUID = UUID(), title: String, message: String, localChanges: String) {
        self.id = id
        self.title = title
        self.message = message
        self.localChanges = localChanges
    }
}
