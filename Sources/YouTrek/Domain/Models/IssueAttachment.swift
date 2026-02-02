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
        let originalValues = try? url.resourceValues(forKeys: [.nameKey])
        let originalName = originalValues?.name ?? url.lastPathComponent
        let staging = AttachmentStaging.prepareCopy(from: url)
        let resolvedURL = staging?.url ?? url
        let values = staging?.values ?? (try? resolvedURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey]))
        let fileSize = values?.fileSize
        let contentType = values?.contentType
        return IssueAttachmentDraft(
            fileURL: resolvedURL,
            fileName: originalName,
            fileSize: fileSize,
            mimeType: contentType?.preferredMIMEType,
            isImage: contentType?.conforms(to: .image)
        )
    }
}

private enum AttachmentStaging {
    static func prepareCopy(from url: URL) -> (url: URL, values: URLResourceValues?)? {
        guard let stagingDirectory = stagingDirectory() else { return nil }
        if url.deletingLastPathComponent() == stagingDirectory {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
            return (url, values)
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension
        let fileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = stagingDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
            return (destination, values)
        } catch {
            return nil
        }
    }

    private static func stagingDirectory() -> URL? {
        do {
            let baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = baseURL
                .appendingPathComponent("YouTrek", isDirectory: true)
                .appendingPathComponent("Attachments", isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return directory
        } catch {
            return nil
        }
    }
}
