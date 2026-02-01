import SwiftUI
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
    let attachment: IssueAttachment
    let onOpen: () -> Void

    var body: some View {
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
            Button("Open", action: onOpen)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
