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
    let attachments: [IssueAttachment]

    init(
        id: IssueSummary.ID,
        readableID: String,
        title: String,
        description: String? = nil,
        reporter: Person? = nil,
        createdAt: Date? = nil,
        updatedAt: Date,
        comments: [IssueComment] = [],
        attachments: [IssueAttachment] = []
    ) {
        self.id = id
        self.readableID = readableID
        self.title = title
        self.description = description
        self.reporter = reporter
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.comments = comments
        self.attachments = attachments
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

extension IssueDetail {
    func appending(comment: IssueComment) -> IssueDetail {
        var updatedComments = comments
        updatedComments.append(comment)
        let updatedAt = max(self.updatedAt, comment.createdAt)
        return IssueDetail(
            id: id,
            readableID: readableID,
            title: title,
            description: description,
            reporter: reporter,
            createdAt: createdAt,
            updatedAt: updatedAt,
            comments: updatedComments,
            attachments: attachments
        )
    }

    func appending(attachments newAttachments: [IssueAttachment]) -> IssueDetail {
        guard !newAttachments.isEmpty else { return self }
        var merged = attachments
        for attachment in newAttachments where !merged.contains(attachment) {
            merged.append(attachment)
        }
        let latestAttachmentDate = newAttachments.compactMap(\.createdAt).max() ?? updatedAt
        let resolvedUpdatedAt = max(updatedAt, latestAttachmentDate)
        return IssueDetail(
            id: id,
            readableID: readableID,
            title: title,
            description: description,
            reporter: reporter,
            createdAt: createdAt,
            updatedAt: resolvedUpdatedAt,
            comments: comments,
            attachments: merged
        )
    }
}
