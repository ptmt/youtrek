import Foundation

struct IssueDetail: Identifiable, Hashable, Sendable {
    let id: IssueSummary.ID
    let readableID: String
    let title: String
    let description: String?
    let reporter: Person?
    let createdAt: Date?
    let updatedAt: Date
    let comments: [IssueComment]

    init(
        id: IssueSummary.ID,
        readableID: String,
        title: String,
        description: String? = nil,
        reporter: Person? = nil,
        createdAt: Date? = nil,
        updatedAt: Date,
        comments: [IssueComment] = []
    ) {
        self.id = id
        self.readableID = readableID
        self.title = title
        self.description = description
        self.reporter = reporter
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.comments = comments
    }
}

struct IssueComment: Identifiable, Hashable, Sendable {
    let id: String
    let author: Person?
    let createdAt: Date
    let text: String

    init(id: String, author: Person? = nil, createdAt: Date, text: String) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.text = text
    }
}
