import AppKit
import SwiftUI

struct TodoListContentView: View {
    @StateObject private var viewModel: TodoListEditorViewModel
    private let urlOpener: any TodoURLOpening

    init(
        listID: UUID,
        title: String,
        markdownStore: TodoListMarkdownStoring,
        issueLinkHandler: TodoIssueLinkHandling,
        todoListManager: (any TodoListManaging)? = nil,
        urlOpener: any TodoURLOpening = WorkspaceTodoURLOpener(),
        issueIDParser: any TodoIssueIDParsing = RegexTodoIssueIDParser(),
        saveDebounceNanoseconds: UInt64 = 600_000_000
    ) {
        _viewModel = StateObject(
            wrappedValue: TodoListEditorViewModel(
                listID: listID,
                title: title,
                markdownStore: markdownStore,
                issueLinkHandler: issueLinkHandler,
                todoListManager: todoListManager,
                issueIDParser: issueIDParser,
                saveDebounceNanoseconds: saveDebounceNanoseconds
            )
        )
        self.urlOpener = urlOpener
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: promptRename) {
                    Label("Rename", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Rename todo list")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            TodoMarkdownTextView(
                text: $viewModel.markdown,
                issueStyles: viewModel.issueStyles,
                onOpenIssueID: { issueID in
                    Task {
                        await viewModel.openIssue(issueID)
                    }
                },
                onOpenURL: { url in
                    urlOpener.openURL(url)
                }
            )
        }
        .task(id: viewModel.listID) {
            await viewModel.load()
        }
        .onChange(of: viewModel.markdown) { _, newValue in
            viewModel.handleMarkdownChange(newValue)
        }
        .onDisappear {
            Task {
                await viewModel.cleanup()
            }
        }
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename Todo List"
        alert.informativeText = "Set a new name for this todo list."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(string: viewModel.title)
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        Task {
            await viewModel.rename(to: newName)
        }
    }
}

private struct TodoMarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let issueStyles: [String: TodoIssueInlineStyle]
    let onOpenIssueID: (String) -> Void
    let onOpenURL: (URL) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.applyInlineMarkup(textView: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.onOpenIssueID = onOpenIssueID
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.issueStyles = issueStyles
        if textView.string != text {
            context.coordinator.isSyncingFromModel = true
            textView.string = text
            context.coordinator.applyInlineMarkup(textView: textView)
            context.coordinator.isSyncingFromModel = false
        } else {
            context.coordinator.applyInlineMarkup(textView: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, issueStyles: issueStyles, onOpenIssueID: onOpenIssueID, onOpenURL: onOpenURL)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var issueStyles: [String: TodoIssueInlineStyle]
        var onOpenIssueID: (String) -> Void
        var onOpenURL: (URL) -> Void
        var isSyncingFromModel = false

        private static let issueIDPattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
        private static let urlPattern = #"\bhttps?://[^\s<>()]+"#
        private lazy var issueIDRegex = try? NSRegularExpression(pattern: Self.issueIDPattern)
        private lazy var urlRegex = try? NSRegularExpression(pattern: Self.urlPattern, options: [.caseInsensitive])

        init(
            text: Binding<String>,
            issueStyles: [String: TodoIssueInlineStyle],
            onOpenIssueID: @escaping (String) -> Void,
            onOpenURL: @escaping (URL) -> Void
        ) {
            _text = text
            self.issueStyles = issueStyles
            self.onOpenIssueID = onOpenIssueID
            self.onOpenURL = onOpenURL
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isSyncingFromModel else { return }
            isSyncingFromModel = true
            text = textView.string
            applyInlineMarkup(textView: textView)
            isSyncingFromModel = false
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let linkValue: String
            if let value = link as? String {
                linkValue = value
            } else if let url = link as? URL {
                linkValue = url.absoluteString
            } else {
                return false
            }
            if linkValue.hasPrefix("youtrek-issue:") {
                let issueID = String(linkValue.dropFirst("youtrek-issue:".count))
                guard !issueID.isEmpty else { return false }
                onOpenIssueID(issueID)
                return true
            }
            guard let url = URL(string: linkValue) else { return false }
            onOpenURL(url)
            return true
        }

        func applyInlineMarkup(textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let text = textView.string
            let range = NSRange(location: 0, length: (text as NSString).length)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]

            textStorage.beginEditing()
            textStorage.setAttributes(baseAttributes, range: range)
            urlRegex?.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match else { return }
                let linkRange = match.range
                guard linkRange.location != NSNotFound else { return }
                let urlValue = (text as NSString).substring(with: linkRange)
                guard URL(string: urlValue) != nil else { return }
                textStorage.addAttributes(
                    [
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: urlValue
                    ],
                    range: linkRange
                )
            }
            issueIDRegex?.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let issueRange = match.range(at: 1)
                guard issueRange.location != NSNotFound else { return }
                let issueID = (text as NSString).substring(with: issueRange).uppercased()
                let style = issueStyles[issueID]
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: statusColor(for: style?.status) ?? NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: "youtrek-issue:\(issueID)"
                ]
                if style?.isClosed == true {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
                }
                if let status = style?.status.displayName {
                    attributes[.toolTip] = "\(issueID) • \(status)"
                }
                textStorage.addAttributes(attributes, range: issueRange)
            }
            textStorage.endEditing()
        }

        private func statusColor(for status: IssueStatus?) -> NSColor? {
            guard let status else { return nil }
            switch status {
            case .open:
                return NSColor.systemBlue
            case .inProgress:
                return NSColor.systemOrange
            case .inReview:
                return NSColor.systemTeal
            case .blocked:
                return NSColor.systemRed
            case .done:
                return NSColor.systemGreen
            case .custom:
                return NSColor.linkColor
            }
        }
    }
}
