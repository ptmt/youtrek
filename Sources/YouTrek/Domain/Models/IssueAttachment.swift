import Foundation
import UniformTypeIdentifiers

struct IssueAttachment: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let size: Int?
    let mimeType: String?
    let url: URL?
    let createdAt: Date?
    let author: Person?

    var isImage: Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("image/") {
            return true
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }
}

struct IssueAttachmentDraft: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let fileSize: Int?
    let mimeType: String?
    let isImage: Bool

    init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String? = nil,
        fileSize: Int? = nil,
        mimeType: String? = nil,
        isImage: Bool? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName ?? fileURL.lastPathComponent
        self.fileSize = fileSize
        if let mimeType {
            self.mimeType = mimeType
        } else {
            let ext = fileURL.pathExtension
            self.mimeType = UTType(filenameExtension: ext)?.preferredMIMEType
        }
        if let isImage {
            self.isImage = isImage
        } else {
            let ext = fileURL.pathExtension
            self.isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
        }
    }
}

extension IssueAttachmentDraft {
    static func fromFileURL(_ url: URL) -> IssueAttachmentDraft {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        let fileSize = values?.fileSize
        let contentType = values?.contentType
        return IssueAttachmentDraft(
            fileURL: url,
            fileName: values?.name ?? url.lastPathComponent,
            fileSize: fileSize,
            mimeType: contentType?.preferredMIMEType,
            isImage: contentType?.conforms(to: .image)
        )
    }
}
