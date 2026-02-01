import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum AttachmentSizeFormatter {
    static func string(for size: Int?) -> String? {
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

struct DraftAttachmentPicker: View {
    @Binding var attachments: [IssueAttachmentDraft]
    var showEmptyState: Bool = true
    @State private var isPickingFiles = false
    @State private var isPickingImages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Attachments")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    isPickingFiles = true
                } label: {
                    Label("Add file", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Attach file")

                Button {
                    isPickingImages = true
                } label: {
                    Label("Add image", systemImage: "photo")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Attach image")
            }

            if attachments.isEmpty {
                if showEmptyState {
                    Text("No attachments yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        DraftAttachmentRow(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .fileImporter(
            isPresented: $isPickingImages,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            appendAttachments(urls)
        case .failure:
            break
        }
    }

    private func appendAttachments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let existing = Set(attachments.map { $0.fileURL.standardizedFileURL.path })
        let newAttachments = urls
            .filter { !existing.contains($0.standardizedFileURL.path) }
            .map { IssueAttachmentDraft.fromFileURL($0) }
        attachments.append(contentsOf: newAttachments)
    }
}

struct DraftAttachmentRow: View {
    let attachment: IssueAttachmentDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.callout)
                if let size = AttachmentSizeFormatter.string(for: attachment.fileSize) {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove attachment")
        }
        .padding(.vertical, 4)
    }
}

struct IssueAttachmentRow: View {
    @EnvironmentObject private var container: AppContainer
    let attachment: IssueAttachment
    let onOpen: () -> Void
    @State private var isExpanded: Bool
    @StateObject private var loader = AttachmentPreviewLoader()

    init(attachment: IssueAttachment, onOpen: @escaping () -> Void) {
        self.attachment = attachment
        self.onOpen = onOpen
        _isExpanded = State(initialValue: attachment.prefersInlinePreview)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if isExpanded {
                previewContent
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            if isExpanded {
                loader.load(attachment: attachment, using: container)
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            if newValue {
                loader.load(attachment: attachment, using: container)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment \(attachment.name)")
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.callout)
                HStack(spacing: 8) {
                    if let size = AttachmentSizeFormatter.string(for: attachment.size) {
                        Text(size)
                    }
                    if let createdAt = attachment.createdAt {
                        Text(createdAt.formatted(.dateTime.year().month().day()))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if attachment.url != nil {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Hide preview" : "Preview", systemImage: isExpanded ? "eye.slash" : "eye")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide preview" : "Show preview")
            }
            Button {
                openAttachment()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Open attachment")
            .disabled(attachment.url == nil && loader.cachedFileURL == nil)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch loader.state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading preview...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .failure(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview unavailable.")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    loader.load(attachment: attachment, using: container, force: true)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        case .success(let payload):
            AttachmentPreviewContent(payload: payload)
        }
    }

    private func openAttachment() {
        if let cachedURL = loader.cachedFileURL {
            NSWorkspace.shared.open(cachedURL)
            return
        }
        onOpen()
    }
}

private struct AttachmentPreviewContent: View {
    let payload: AttachmentPreviewPayload

    var body: some View {
        Group {
            switch payload.kind {
            case .image:
                if let image = NSImage(data: payload.data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                } else {
                    AttachmentPreviewPlaceholder(message: "Unable to render image preview.")
                }
            case .markdown:
                if let text = payload.decodedText {
                    ScrollView {
                        MarkdownTextView(text: text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                } else {
                    AttachmentPreviewPlaceholder(message: "Unable to read markdown content.")
                }
            case .text:
                if let text = payload.decodedText {
                    ScrollView {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                } else {
                    AttachmentPreviewPlaceholder(message: "Unable to read text content.")
                }
            case .pdf:
                if let document = PDFDocument(data: payload.data) {
                    AttachmentPDFView(document: document)
                        .frame(maxHeight: 320)
                } else {
                    AttachmentPreviewPlaceholder(message: "Unable to render PDF preview.")
                }
            case .unknown:
                AttachmentPreviewPlaceholder(message: "Preview not available. Open the attachment to view it.")
            }
        }
        .padding(8)
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AttachmentPreviewPlaceholder: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct AttachmentPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = document
    }
}

private enum AttachmentPreviewKind {
    case image
    case markdown
    case text
    case pdf
    case unknown
}

private struct AttachmentPreviewPayload {
    let data: Data
    let fileURL: URL
    let kind: AttachmentPreviewKind

    var decodedText: String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        return nil
    }
}

@MainActor
private final class AttachmentPreviewLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case success(AttachmentPreviewPayload)
        case failure(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var cachedFileURL: URL?
    private var task: Task<Void, Never>?

    func load(attachment: IssueAttachment, using container: AppContainer, force: Bool = false) {
        if case .loading = state { return }
        if case .success = state, !force { return }
        task?.cancel()
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let fileURL = try AttachmentPreviewCache.fileURL(for: attachment) else {
                    throw AttachmentPreviewError.missingURL
                }
                let data: Data
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    data = try await Self.readData(from: fileURL)
                } else {
                    data = try await container.fetchAttachmentData(for: attachment)
                    try await Self.writeData(data, to: fileURL)
                }
                let payload = AttachmentPreviewPayload(data: data, fileURL: fileURL, kind: attachment.previewKind)
                cachedFileURL = fileURL
                state = .success(payload)
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }

    private static func readData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }

    private static func writeData(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: [.atomic])
        }.value
    }
}

private enum AttachmentPreviewError: LocalizedError {
    case missingURL

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Missing attachment URL."
        }
    }
}

private enum AttachmentPreviewCache {
    private static let directoryName = "youtrek-attachments"

    static func fileURL(for attachment: IssueAttachment) throws -> URL? {
        guard attachment.url != nil else { return nil }
        let directory = try cacheDirectory()
        let filename = attachment.previewFileName
        let fileNameWithID = "\(attachment.id)-\(filename)"
        return directory.appendingPathComponent(fileNameWithID)
    }

    private static func cacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

private extension IssueAttachment {
    var previewKind: AttachmentPreviewKind {
        if isImage { return .image }
        if isMarkdown { return .markdown }
        if isPDF { return .pdf }
        if isPlainText { return .text }
        return .unknown
    }

    var prefersInlinePreview: Bool {
        switch previewKind {
        case .image, .markdown:
            return true
        default:
            return false
        }
    }

    var previewFileName: String {
        var candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            candidate = "Attachment"
        }
        candidate = candidate.sanitizedFileName
        if (candidate as NSString).pathExtension.isEmpty, let ext = preferredFileExtension {
            candidate = "\(candidate).\(ext)"
        }
        return candidate
    }

    var preferredFileExtension: String? {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            return ext
        }
        guard let mimeType else { return nil }
        return UTType(mimeType: mimeType)?.preferredFilenameExtension?.lowercased()
    }

    var isMarkdown: Bool {
        if let mimeType = mimeType?.lowercased(), mimeType == "text/markdown" {
            return true
        }
        guard let ext = preferredFileExtension else { return false }
        return ["md", "markdown", "mdown", "mkd", "mkdn", "mdtxt"].contains(ext)
    }

    var isPlainText: Bool {
        if let mimeType = mimeType?.lowercased(), mimeType.hasPrefix("text/") {
            return !isMarkdown
        }
        guard let ext = preferredFileExtension, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .text) && !isMarkdown
    }

    var isPDF: Bool {
        if let mimeType = mimeType?.lowercased(), mimeType == "application/pdf" {
            return true
        }
        return preferredFileExtension == "pdf"
    }
}

private extension String {
    var sanitizedFileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = components(separatedBy: invalidCharacters).joined(separator: "-")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
