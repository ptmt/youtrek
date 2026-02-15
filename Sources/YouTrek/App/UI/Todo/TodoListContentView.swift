import AppKit
import QuartzCore
import SwiftUI

private enum TodoEditorLayout {
    static let baseFontSize: CGFloat = 13
    static let fontScale: CGFloat = 1.5
    static let textScale: CGFloat = 0.75
    static let fontSize: CGFloat = baseFontSize * fontScale * textScale
    static let lineHeightMultiple: CGFloat = 1.3
    static let textInset = NSSize(width: 36, height: 12)
    static let checkboxSize = NSSize(width: 20, height: 20)
    static let checkboxGutterTrailing: CGFloat = 6
    static let checkboxVerticalOffset: CGFloat = 0
    static let inlineImageSize = NSSize(width: 22, height: 22)
    static let checkedLineOpacity: CGFloat = 0.46
    static let checklistFadeDuration: CFTimeInterval = 0.2
    static let checklistFrameIntervalNanoseconds: UInt64 = 16_000_000

    static let checkboxBaselineScaleFromLine: CGFloat = 0.68
}

struct TodoListContentView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: TodoListEditorViewModel
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var isTitleEditorFocused: Bool
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
                if isEditingTitle {
                    TextField("Todo list name", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isTitleEditorFocused)
                        .onSubmit {
                            commitInlineRename()
                        }
                } else {
                    Text(viewModel.title)
                        .font(.title3.weight(.semibold))
                        .onTapGesture(count: 2) {
                            beginInlineRename()
                        }
                }
                Spacer()
                if isEditingTitle {
                    Button {
                        commitInlineRename()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Save name")

                    Button {
                        cancelInlineRename()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel rename")
                } else {
                    Button(action: beginInlineRename) {
                        Label("Rename", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Rename todo list")
                }
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
                },
                onSetIssueClosed: { issueID, isClosed in
                    Task {
                        await viewModel.setIssueClosed(fromChecklist: issueID, isClosed: isClosed)
                    }
                },
                onSavePastedImage: { data, fileExtension in
                    await viewModel.saveImageAttachment(data: data, preferredFileExtension: fileExtension)
                },
                onLoadImageAttachment: { reference in
                    await viewModel.loadImageAttachment(reference: reference)
                }
            )
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(uncommittedChangesHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if container.isCommittingTodoUncommittedChanges {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(commitButtonTitle) {
                        commitQueuedChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(container.todoUncommittedChanges.isEmpty || container.isCommittingTodoUncommittedChanges)
                }
                Text("Shortcuts: Cmd+Shift+N convert selection to issue, Space toggle done/undone, Cmd+Return commit changes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task(id: viewModel.listID) {
            await viewModel.load()
        }
        .task {
            titleDraft = viewModel.title
        }
        .onChange(of: viewModel.markdown) { _, newValue in
            viewModel.handleMarkdownChange(newValue)
        }
        .onChange(of: viewModel.title) { _, newValue in
            if !isEditingTitle {
                titleDraft = newValue
            }
        }
        .onChange(of: isTitleEditorFocused) { _, isFocused in
            if isEditingTitle, !isFocused {
                commitInlineRename()
            }
        }
        .onDisappear {
            Task {
                await viewModel.cleanup()
            }
        }
    }

    private var uncommittedChangesHint: String {
        let count = container.todoUncommittedChanges.count
        guard count > 0 else { return "No uncommitted YouTrack changes." }
        if count == 1, let summary = container.todoUncommittedChanges.first?.summary {
            return "1 uncommitted change queued: \(summary)"
        }
        return "\(count) uncommitted YouTrack changes queued."
    }

    private var commitButtonTitle: String {
        container.isCommittingTodoUncommittedChanges ? "Committing..." : "Commit Changes"
    }

    private func beginInlineRename() {
        guard !isEditingTitle else { return }
        titleDraft = viewModel.title
        isEditingTitle = true
        DispatchQueue.main.async {
            isTitleEditorFocused = true
        }
    }

    private func cancelInlineRename() {
        isEditingTitle = false
        isTitleEditorFocused = false
        titleDraft = viewModel.title
    }

    private func commitInlineRename() {
        guard isEditingTitle else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingTitle = false
        isTitleEditorFocused = false
        guard !trimmed.isEmpty, trimmed != viewModel.title else {
            titleDraft = viewModel.title
            return
        }
        Task {
            await viewModel.rename(to: trimmed)
        }
    }

    private func commitQueuedChanges() {
        Task {
            await container.commitTodoUncommittedChanges()
            viewModel.refreshIssueStylesNow()
        }
    }
}

private struct TodoMarkdownImageMatch: Equatable {
    let wholeRange: NSRange
    let reference: String
}

private struct RegexTodoImageMarkdownParser {
    private static let imagePattern = #"!\[[^\]\n]*\]\(([^)\n]+)\)"#
    private let regex: NSRegularExpression?

    init() {
        regex = try? NSRegularExpression(pattern: Self.imagePattern)
    }

    func matches(in markdown: String) -> [TodoMarkdownImageMatch] {
        guard let regex else { return [] }
        let nsText = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: markdown, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let wholeRange = match.range(at: 0)
            let referenceRange = match.range(at: 1)
            guard wholeRange.location != NSNotFound, referenceRange.location != NSNotFound else { return nil }
            guard NSMaxRange(referenceRange) <= nsText.length else { return nil }
            let rawReference = nsText.substring(with: referenceRange)
            let normalizedReference = normalizedAttachmentReference(from: rawReference)
            guard !normalizedReference.isEmpty else { return nil }
            return TodoMarkdownImageMatch(wholeRange: wholeRange, reference: normalizedReference)
        }
    }

    private func normalizedAttachmentReference(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "todo-attachment" {
            let hostPart = url.host ?? ""
            let pathPart = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !hostPart.isEmpty, !pathPart.isEmpty {
                return "\(hostPart)/\(pathPart)".split(separator: "/").last.map(String.init) ?? hostPart
            }
            if !hostPart.isEmpty {
                return hostPart
            }
            if !pathPart.isEmpty {
                return pathPart.split(separator: "/").last.map(String.init) ?? pathPart
            }
        }
        if trimmed.hasPrefix("todo-attachment://") {
            return String(trimmed.dropFirst("todo-attachment://".count)).split(separator: "/").last.map(String.init) ?? ""
        }
        if trimmed.hasPrefix("todo-attachment:") {
            return String(trimmed.dropFirst("todo-attachment:".count)).split(separator: "/").last.map(String.init) ?? ""
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? ""
    }
}

private struct TodoMarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let issueStyles: [String: TodoIssueInlineStyle]
    let onOpenIssueID: (String) -> Void
    let onOpenURL: (URL) -> Void
    let onSetIssueClosed: (String, Bool) -> Void
    let onSavePastedImage: (Data, String) async -> String?
    let onLoadImageAttachment: (String) async -> Data?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = TodoChecklistTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = TodoEditorLayout.textInset
        textView.font = NSFont.monospacedSystemFont(ofSize: TodoEditorLayout.fontSize, weight: .regular)
        textView.checklistKeyDelegate = context.coordinator
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
        context.coordinator.onSetIssueClosed = onSetIssueClosed
        context.coordinator.onSavePastedImage = onSavePastedImage
        context.coordinator.onLoadImageAttachment = onLoadImageAttachment
        context.coordinator.issueStyles = issueStyles
        if textView.string != text {
            context.coordinator.isSyncingFromModel = true
            context.coordinator.resetChecklistVisualState()
            textView.string = text
            context.coordinator.applyInlineMarkup(textView: textView)
            context.coordinator.isSyncingFromModel = false
        } else {
            context.coordinator.applyInlineMarkup(textView: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            issueStyles: issueStyles,
            onOpenIssueID: onOpenIssueID,
            onOpenURL: onOpenURL,
            onSetIssueClosed: onSetIssueClosed,
            onSavePastedImage: onSavePastedImage,
            onLoadImageAttachment: onLoadImageAttachment
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, TodoChecklistKeyHandling {
        @Binding var text: String
        var issueStyles: [String: TodoIssueInlineStyle]
        var onOpenIssueID: (String) -> Void
        var onOpenURL: (URL) -> Void
        var onSetIssueClosed: (String, Bool) -> Void
        var onSavePastedImage: (Data, String) async -> String?
        var onLoadImageAttachment: (String) async -> Data?
        var isSyncingFromModel = false

        private static let issueIDPattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
        private static let urlPattern = #"\bhttps?://[^\s<>()]+"#
        private lazy var issueIDRegex = try? NSRegularExpression(pattern: Self.issueIDPattern)
        private lazy var urlRegex = try? NSRegularExpression(pattern: Self.urlPattern, options: [.caseInsensitive])
        private let checklistParser = RegexTodoChecklistMarkerParser()
        private let listContinuationDetector = RegexTodoDashListContinuationDetector()
        private let inlineMarkdownParser = RegexTodoInlineMarkdownParser()
        private let imageMarkdownParser = RegexTodoImageMarkdownParser()
        private var checklistMarkers: [TodoChecklistMarkerMatch] = []
        private var transientChecklistStates: [Int: Bool] = [:]
        private var checklistButtonsByLocation: [Int: NSButton] = [:]
        private var focusedChecklistLocation: Int?
        private var imageMarkdownMatches: [TodoMarkdownImageMatch] = []
        private var imageViewsByLocation: [Int: NSImageView] = [:]
        private var imageCache: [String: NSImage] = [:]
        private var imageLoadTasks: [String: Task<Void, Never>] = [:]
        private var lineFadeAnimations: [Int: ChecklistLineFadeAnimation] = [:]
        private var checklistFadeTask: Task<Void, Never>?

        private struct ChecklistLineFadeAnimation {
            let fromOpacity: CGFloat
            let toOpacity: CGFloat
            let startedAt: CFTimeInterval
            let duration: CFTimeInterval
        }

        init(
            text: Binding<String>,
            issueStyles: [String: TodoIssueInlineStyle],
            onOpenIssueID: @escaping (String) -> Void,
            onOpenURL: @escaping (URL) -> Void,
            onSetIssueClosed: @escaping (String, Bool) -> Void,
            onSavePastedImage: @escaping (Data, String) async -> String?,
            onLoadImageAttachment: @escaping (String) async -> Data?
        ) {
            _text = text
            self.issueStyles = issueStyles
            self.onOpenIssueID = onOpenIssueID
            self.onOpenURL = onOpenURL
            self.onSetIssueClosed = onSetIssueClosed
            self.onSavePastedImage = onSavePastedImage
            self.onLoadImageAttachment = onLoadImageAttachment
        }

        deinit {
            checklistFadeTask?.cancel()
        }

        func resetChecklistVisualState() {
            checklistFadeTask?.cancel()
            checklistFadeTask = nil
            lineFadeAnimations.removeAll()
            transientChecklistStates.removeAll()
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
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineHeightMultiple = TodoEditorLayout.lineHeightMultiple
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: TodoEditorLayout.fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraphStyle
            ]
            let parsedChecklistMarkers = checklistParser.checklistMarkers(in: text)
            let activeTransientLocations = Set(
                parsedChecklistMarkers
                    .filter { !$0.hasExplicitCheckbox && $0.markerRange.location != NSNotFound }
                    .map(\.markerRange.location)
            )
            transientChecklistStates = transientChecklistStates.filter { activeTransientLocations.contains($0.key) }
            checklistMarkers = parsedChecklistMarkers.map { marker in
                guard !marker.hasExplicitCheckbox else { return marker }
                let resolvedState = transientChecklistStates[marker.markerRange.location] ?? false
                return TodoChecklistMarkerMatch(
                    markerRange: marker.markerRange,
                    stateRange: marker.stateRange,
                    lineRange: marker.lineRange,
                    isChecked: resolvedState,
                    issueID: marker.issueID,
                    hasExplicitCheckbox: false
                )
            }
            imageMarkdownMatches = imageMarkdownParser.matches(in: text)

            textStorage.beginEditing()
            textStorage.setAttributes(baseAttributes, range: range)
            applyInlineMarkdownStyles(to: textStorage, text: text)
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
                if let status = style?.status.displayName {
                    attributes[.toolTip] = "\(issueID) • \(status)"
                }
                textStorage.addAttributes(attributes, range: issueRange)
            }
            let nsText = text as NSString
            for marker in checklistMarkers {
                guard let lineDisplayRange = normalizedLineDisplayRange(marker.lineRange, in: nsText) else { continue }
                let contentRange = checklistContentRange(for: marker, lineDisplayRange: lineDisplayRange)
                let lineOpacity = resolvedLineOpacity(for: marker)

                if contentRange.length > 0 {
                    textStorage.addAttributes(
                        [.foregroundColor: NSColor.textColor.withAlphaComponent(lineOpacity)],
                        range: contentRange
                    )
                    if marker.isChecked {
                        textStorage.addAttributes(
                            [
                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .strikethroughColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.8)
                            ],
                            range: contentRange
                        )
                    }
                }

                if marker.hasExplicitCheckbox,
                   marker.markerRange.location != NSNotFound,
                   NSMaxRange(marker.markerRange) <= nsText.length {
                    textStorage.addAttributes([.foregroundColor: NSColor.clear], range: marker.markerRange)
                }
            }
            for match in imageMarkdownMatches where match.wholeRange.location != NSNotFound {
                textStorage.addAttributes(
                    [
                        .foregroundColor: NSColor.clear,
                        .toolTip: "Image attachment"
                    ],
                    range: match.wholeRange
                )
            }
            textStorage.endEditing()
            textView.typingAttributes = baseAttributes
            syncChecklistButtons(in: textView)
            syncInlineImageViews(in: textView)
        }

        private func applyInlineMarkdownStyles(to textStorage: NSTextStorage, text: String) {
            let baseFont = NSFont.monospacedSystemFont(ofSize: TodoEditorLayout.fontSize, weight: .regular)
            let boldFont = NSFont.monospacedSystemFont(ofSize: TodoEditorLayout.fontSize, weight: .semibold)
            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            let codeFont = NSFont.monospacedSystemFont(ofSize: TodoEditorLayout.fontSize * 0.95, weight: .regular)

            for inlineMatch in inlineMarkdownParser.matches(in: text) {
                textStorage.addAttributes(
                    [.foregroundColor: NSColor.secondaryLabelColor],
                    range: inlineMatch.wholeRange
                )

                switch inlineMatch.kind {
                case .bold:
                    textStorage.addAttributes(
                        [
                            .font: boldFont,
                            .foregroundColor: NSColor.textColor
                        ],
                        range: inlineMatch.contentRange
                    )
                case .italic:
                    textStorage.addAttributes(
                        [
                            .font: italicFont,
                            .foregroundColor: NSColor.textColor
                        ],
                        range: inlineMatch.contentRange
                    )
                case .code:
                    textStorage.addAttributes(
                        [
                            .font: codeFont,
                            .foregroundColor: NSColor.systemIndigo
                        ],
                        range: inlineMatch.contentRange
                    )
                case .strikethrough:
                    textStorage.addAttributes(
                        [
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: NSColor.secondaryLabelColor
                        ],
                        range: inlineMatch.contentRange
                    )
                case .link(let url):
                    textStorage.addAttributes(
                        [
                            .foregroundColor: NSColor.linkColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .link: url.absoluteString
                        ],
                        range: inlineMatch.contentRange
                    )
                }
            }
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

        private func normalizedLineDisplayRange(_ lineRange: NSRange, in nsText: NSString) -> NSRange? {
            guard lineRange.location != NSNotFound else { return nil }
            guard NSMaxRange(lineRange) <= nsText.length else { return nil }
            var range = lineRange
            while range.length > 0 {
                let lastIndex = NSMaxRange(range) - 1
                let scalar = nsText.character(at: lastIndex)
                if scalar == 10 || scalar == 13 {
                    range.length -= 1
                } else {
                    break
                }
            }
            return range.length > 0 ? range : nil
        }

        private func checklistContentRange(for marker: TodoChecklistMarkerMatch, lineDisplayRange: NSRange) -> NSRange {
            let lineEnd = NSMaxRange(lineDisplayRange)
            if marker.markerRange.location != NSNotFound {
                let markerEnd = min(lineEnd, NSMaxRange(marker.markerRange))
                if markerEnd < lineEnd {
                    return NSRange(location: markerEnd, length: lineEnd - markerEnd)
                }
            }
            return lineDisplayRange
        }

        private func resolvedLineOpacity(for marker: TodoChecklistMarkerMatch) -> CGFloat {
            resolvedLineOpacity(
                forLineLocation: marker.lineRange.location,
                fallback: marker.isChecked ? TodoEditorLayout.checkedLineOpacity : 1
            )
        }

        private func resolvedLineOpacity(forLineLocation lineLocation: Int, fallback: CGFloat) -> CGFloat {
            guard lineLocation != NSNotFound else { return fallback }
            guard let animation = lineFadeAnimations[lineLocation] else { return fallback }
            let elapsed = CACurrentMediaTime() - animation.startedAt
            if elapsed >= animation.duration {
                lineFadeAnimations.removeValue(forKey: lineLocation)
                return animation.toOpacity
            }
            let progress = max(0, min(1, elapsed / animation.duration))
            return animation.fromOpacity + ((animation.toOpacity - animation.fromOpacity) * CGFloat(progress))
        }

        private func startChecklistFadeAnimation(
            for marker: TodoChecklistMarkerMatch,
            targetIsChecked: Bool,
            in textView: NSTextView
        ) {
            let lineLocation = marker.lineRange.location
            guard lineLocation != NSNotFound else { return }
            let currentOpacity = resolvedLineOpacity(
                forLineLocation: lineLocation,
                fallback: marker.isChecked ? TodoEditorLayout.checkedLineOpacity : 1
            )
            let targetOpacity = targetIsChecked ? TodoEditorLayout.checkedLineOpacity : 1
            guard abs(currentOpacity - targetOpacity) > 0.001 else { return }

            lineFadeAnimations[lineLocation] = ChecklistLineFadeAnimation(
                fromOpacity: currentOpacity,
                toOpacity: targetOpacity,
                startedAt: CACurrentMediaTime(),
                duration: TodoEditorLayout.checklistFadeDuration
            )
            ensureChecklistFadeAnimation(in: textView)
        }

        private func ensureChecklistFadeAnimation(in textView: NSTextView) {
            guard checklistFadeTask == nil else { return }
            checklistFadeTask = Task { [weak self, weak textView] in
                guard let self else { return }
                while !Task.isCancelled {
                    guard let textView else { break }
                    if self.lineFadeAnimations.isEmpty {
                        break
                    }
                    self.applyInlineMarkup(textView: textView)
                    try? await Task.sleep(nanoseconds: TodoEditorLayout.checklistFrameIntervalNanoseconds)
                }
                self.checklistFadeTask = nil
            }
        }

        private func checklistButtonOpacity(for marker: TodoChecklistMarkerMatch) -> CGFloat {
            let lineOpacity = resolvedLineOpacity(for: marker)
            return max(0.58, min(1, lineOpacity + 0.18))
        }

        private func syncChecklistButtons(in textView: NSTextView) {
            let activeLocations = Set(checklistMarkers.map(\.markerRange.location).filter { $0 != NSNotFound })
            for (location, button) in checklistButtonsByLocation where !activeLocations.contains(location) {
                button.removeFromSuperview()
                checklistButtonsByLocation.removeValue(forKey: location)
            }

            guard
                !checklistMarkers.isEmpty,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let orderedMarkers = checklistMarkers.sorted { $0.markerRange.location < $1.markerRange.location }
            var orderedLocations: [Int] = []
            for marker in orderedMarkers {
                let location = marker.markerRange.location
                guard location != NSNotFound else { continue }
                let button = checklistButtonsByLocation[location] ?? {
                    let created = TodoChecklistButton(checkboxWithTitle: "", target: self, action: #selector(checklistButtonToggled(_:)))
                    textView.addSubview(created)
                    checklistButtonsByLocation[location] = created
                    return created
                }()
                button.state = marker.isChecked ? .on : .off
                button.alphaValue = checklistButtonOpacity(for: marker)
                button.tag = location
                button.toolTip = marker.issueID.map { "Toggle \($0) completion" } ?? "Toggle todo completion"
                button.frame = checkboxFrame(
                    for: marker,
                    textView: textView,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
                orderedLocations.append(location)
            }

            configureKeyViewChain(textView: textView, orderedLocations: orderedLocations)
            if let focusedChecklistLocation, checklistButtonsByLocation[focusedChecklistLocation] == nil {
                self.focusedChecklistLocation = nil
            }
        }

        private func syncInlineImageViews(in textView: NSTextView) {
            let activeLocations = Set(imageMarkdownMatches.map(\.wholeRange.location).filter { $0 != NSNotFound })

            for (location, imageView) in imageViewsByLocation where !activeLocations.contains(location) {
                imageView.removeFromSuperview()
                imageViewsByLocation.removeValue(forKey: location)
            }

            guard
                !imageMarkdownMatches.isEmpty,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            for match in imageMarkdownMatches {
                let location = match.wholeRange.location
                guard location != NSNotFound else { continue }

                let imageView = imageViewsByLocation[location] ?? {
                    let view = NSImageView(frame: .zero)
                    view.imageScaling = .scaleProportionallyUpOrDown
                    view.wantsLayer = true
                    view.layer?.cornerRadius = 4
                    view.layer?.masksToBounds = true
                    view.toolTip = match.reference
                    textView.addSubview(view)
                    imageViewsByLocation[location] = view
                    return view
                }()

                imageView.frame = inlineImageFrame(
                    for: match,
                    textView: textView,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )

                if let cached = imageCache[match.reference] {
                    imageView.image = cached
                    imageView.layer?.backgroundColor = NSColor.clear.cgColor
                } else {
                    imageView.image = nil
                    imageView.layer?.backgroundColor = NSColor.clear.cgColor
                    scheduleAttachmentImageLoad(reference: match.reference, in: textView)
                }
            }
        }

        private func inlineImageFrame(
            for match: TodoMarkdownImageMatch,
            textView: NSTextView,
            layoutManager: NSLayoutManager,
            textContainer: NSTextContainer
        ) -> NSRect {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: match.wholeRange, actualCharacterRange: nil)
            var matchRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let containerOrigin = textView.textContainerOrigin
            matchRect.origin.x += containerOrigin.x
            matchRect.origin.y += containerOrigin.y
            let imageSize = TodoEditorLayout.inlineImageSize
            let x = matchRect.minX
            let y = round(matchRect.midY - (imageSize.height * 0.5))
            return NSRect(origin: NSPoint(x: x, y: y), size: imageSize)
        }

        private func scheduleAttachmentImageLoad(reference: String, in textView: NSTextView) {
            guard imageLoadTasks[reference] == nil else { return }
            imageLoadTasks[reference] = Task { [weak self, weak textView] in
                guard let self else { return }
                defer { self.imageLoadTasks[reference] = nil }
                guard let data = await self.onLoadImageAttachment(reference) else { return }
                guard let image = NSImage(data: data) else { return }
                self.imageCache[reference] = image
                guard let textView else { return }
                self.syncInlineImageViews(in: textView)
            }
        }

        private func checkboxFrame(
            for marker: TodoChecklistMarkerMatch,
            textView: NSTextView,
            layoutManager: NSLayoutManager,
            textContainer: NSTextContainer
        ) -> NSRect {
            let markerGlyphRange = layoutManager.glyphRange(
                forCharacterRange: marker.markerRange,
                actualCharacterRange: nil
            )
            var markerRect = layoutManager.boundingRect(forGlyphRange: markerGlyphRange, in: textContainer)
            let containerOrigin = textView.textContainerOrigin
            markerRect.origin.x += containerOrigin.x
            markerRect.origin.y += containerOrigin.y
            let checkboxSize = TodoEditorLayout.checkboxSize
            let checkboxX = max(
                2,
                markerRect.minX - checkboxSize.width - TodoEditorLayout.checkboxGutterTrailing
            )

            let anchorCharacterLocation = marker.markerRange.location
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: anchorCharacterLocation)
            let lineFragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let baselineOffset = layoutManager.defaultBaselineOffset(
                for: textView.font ?? NSFont.monospacedSystemFont(ofSize: TodoEditorLayout.fontSize, weight: .regular)
            )
            let baselineY = containerOrigin.y + lineFragmentRect.minY + baselineOffset
            let checkboxY = baselineY - (TodoEditorLayout.checkboxSize.height * TodoEditorLayout.checkboxBaselineScaleFromLine)
            let clampedY = min(
                max(checkboxY, 0),
                max(0, textView.bounds.maxY - TodoEditorLayout.checkboxSize.height - 2)
            )
            let clampedX = min(
                max(checkboxX, textView.bounds.minX + 2),
                max(0, textView.bounds.maxX - TodoEditorLayout.checkboxSize.width - 2)
            )
            return NSRect(
                origin: NSPoint(x: clampedX, y: clampedY + TodoEditorLayout.checkboxVerticalOffset),
                size: checkboxSize
            )
        }

        private func configureKeyViewChain(textView: NSTextView, orderedLocations: [Int]) {
            let orderedButtons = orderedLocations.compactMap { checklistButtonsByLocation[$0] }
            guard !orderedButtons.isEmpty else { return }
            for index in orderedButtons.indices {
                let next = index + 1 < orderedButtons.count ? orderedButtons[index + 1] : textView
                orderedButtons[index].nextKeyView = next
            }
        }

        @objc
        private func checklistButtonToggled(_ sender: NSButton) {
            guard let marker = checklistMarkers.first(where: { $0.markerRange.location == sender.tag }) else { return }
            guard let textView = sender.superview as? NSTextView else { return }
            focusedChecklistLocation = marker.markerRange.location
            applyChecklistToggle(
                marker: marker,
                isChecked: sender.state == .on,
                in: textView,
                shouldUpdateIssue: true
            )
            textView.window?.makeFirstResponder(textView)
        }

        private func applyChecklistToggle(
            marker: TodoChecklistMarkerMatch,
            isChecked: Bool,
            in textView: NSTextView,
            shouldUpdateIssue: Bool
        ) {
            if !marker.hasExplicitCheckbox {
                transientChecklistStates[marker.markerRange.location] = isChecked
                startChecklistFadeAnimation(for: marker, targetIsChecked: isChecked, in: textView)
                applyInlineMarkup(textView: textView)
                if shouldUpdateIssue, let issueID = marker.issueID {
                    onSetIssueClosed(issueID, isChecked)
                }
                return
            }

            let updatedMarkdown = checklistParser.applyingCheckState(isChecked, to: textView.string, marker: marker)
            guard updatedMarkdown != textView.string else { return }
            startChecklistFadeAnimation(for: marker, targetIsChecked: isChecked, in: textView)

            let selectedRange = textView.selectedRange()
            isSyncingFromModel = true
            textView.string = updatedMarkdown
            text = updatedMarkdown
            applyInlineMarkup(textView: textView)
            if selectedRange.location != NSNotFound {
                let updatedLength = (updatedMarkdown as NSString).length
                let clampedLocation = max(0, min(updatedLength, selectedRange.location))
                let clampedLength = max(0, min(selectedRange.length, updatedLength - clampedLocation))
                textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            }
            isSyncingFromModel = false

            if shouldUpdateIssue, let issueID = marker.issueID {
                onSetIssueClosed(issueID, isChecked)
            }
        }

        func handleChecklistPaste(in textView: NSTextView) -> Bool {
            let pasteboard = NSPasteboard.general
            guard let image = NSImage(pasteboard: pasteboard) else { return false }
            guard let pngData = image.todoPNGData() else { return false }
            let insertionRange = textView.selectedRange()
            guard insertionRange.location != NSNotFound else { return false }

            Task { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard let reference = await onSavePastedImage(pngData, "png") else { return }
                let markdown = "![Pasted image](todo-attachment://\(reference))"
                let nextSelection = NSRange(location: insertionRange.location + markdown.count, length: 0)
                replaceText(in: textView, range: insertionRange, replacement: markdown, selectedRange: nextSelection)
            }
            return true
        }

        func handleChecklistKeyDown(_ event: NSEvent, in textView: NSTextView) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasUnsupportedModifiers =
                flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
            if hasUnsupportedModifiers { return false }

            if event.keyCode == 48 {
                return handleTabIndentation(in: textView, outdent: flags.contains(.shift))
            }
            if (event.keyCode == 36 || event.keyCode == 76), !flags.contains(.shift) {
                return handleListContinuationOnReturn(in: textView)
            }
            if event.keyCode == 49, !flags.contains(.shift) {
                return toggleChecklistFromKeyboard(in: textView)
            }
            return false
        }

        private func handleTabIndentation(in textView: NSTextView, outdent: Bool) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return false }
            let nsText = textView.string as NSString

            if selectedRange.length == 0, !outdent {
                let insertionRange = selectedRange
                replaceText(in: textView, range: insertionRange, replacement: "\t", selectedRange: NSRange(location: insertionRange.location + 1, length: 0))
                return true
            }

            let lineRange = nsText.lineRange(for: selectedRange)
            guard lineRange.location != NSNotFound else { return false }
            let selectedLines = nsText.substring(with: lineRange)
            let transformed = transformLines(selectedLines, outdent: outdent)
            guard transformed.text != selectedLines else { return true }

            let nextSelection: NSRange
            if selectedRange.length == 0 {
                let caretLocation = max(lineRange.location, selectedRange.location + transformed.firstLineDelta)
                nextSelection = NSRange(location: caretLocation, length: 0)
            } else {
                nextSelection = NSRange(location: lineRange.location, length: (transformed.text as NSString).length)
            }
            replaceText(in: textView, range: lineRange, replacement: transformed.text, selectedRange: nextSelection)
            return true
        }

        private func toggleChecklistFromKeyboard(in textView: NSTextView) -> Bool {
            if let responder = textView.window?.firstResponder as? NSButton,
               let marker = checklistMarkers.first(where: { $0.markerRange.location == responder.tag }) {
                applyChecklistToggle(
                    marker: marker,
                    isChecked: !marker.isChecked,
                    in: textView,
                    shouldUpdateIssue: true
                )
                return true
            }

            let caretLocation = textView.selectedRange().location
            guard let marker = checklistMarkers.first(where: { NSLocationInRange(caretLocation, $0.lineRange) }) else {
                return false
            }
            applyChecklistToggle(
                marker: marker,
                isChecked: !marker.isChecked,
                in: textView,
                shouldUpdateIssue: true
            )
            return true
        }

        private func handleListContinuationOnReturn(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound, selectedRange.length == 0 else { return false }
            let nsText = textView.string as NSString
            let safeLocation = max(0, min(selectedRange.location, nsText.length))
            guard safeLocation <= nsText.length else { return false }

            let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
            guard lineRange.location != NSNotFound else { return false }

            var contentLineRange = lineRange
            while contentLineRange.length > 0 {
                let lastIndex = NSMaxRange(contentLineRange) - 1
                let scalar = nsText.character(at: lastIndex)
                if scalar == 10 || scalar == 13 {
                    contentLineRange.length -= 1
                } else {
                    break
                }
            }
            guard contentLineRange.length > 0 else { return false }

            let line = nsText.substring(with: contentLineRange)
            guard let indentation = listContinuationDetector.continuationIndentation(in: line) else {
                return false
            }

            let insertion = "\n\(indentation)- "
            let insertionLength = (insertion as NSString).length
            let nextSelection = NSRange(location: selectedRange.location + insertionLength, length: 0)
            replaceText(in: textView, range: selectedRange, replacement: insertion, selectedRange: nextSelection)
            return true
        }

        private func replaceText(in textView: NSTextView, range: NSRange, replacement: String, selectedRange: NSRange) {
            let mutable = NSMutableString(string: textView.string)
            mutable.replaceCharacters(in: range, with: replacement)
            let updatedText = mutable as String
            let updatedLength = (updatedText as NSString).length
            let clampedLocation = max(0, min(updatedLength, selectedRange.location))
            let clampedLength = max(0, min(selectedRange.length, updatedLength - clampedLocation))

            isSyncingFromModel = true
            textView.string = updatedText
            text = updatedText
            applyInlineMarkup(textView: textView)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            isSyncingFromModel = false
        }

        private func transformLines(_ value: String, outdent: Bool) -> (text: String, firstLineDelta: Int) {
            var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var firstLineDelta = 0

            for index in lines.indices {
                if outdent {
                    if lines[index].hasPrefix("\t") {
                        lines[index].removeFirst()
                        if index == 0 { firstLineDelta = -1 }
                        continue
                    }
                    let leadingSpaces = min(4, lines[index].prefix { $0 == " " }.count)
                    if leadingSpaces > 0 {
                        lines[index].removeFirst(leadingSpaces)
                        if index == 0 { firstLineDelta = -leadingSpaces }
                    }
                } else {
                    lines[index] = "\t\(lines[index])"
                    if index == 0 { firstLineDelta = 1 }
                }
            }

            return (lines.joined(separator: "\n"), firstLineDelta)
        }
    }
}

@MainActor
private protocol TodoChecklistKeyHandling: AnyObject {
    func handleChecklistKeyDown(_ event: NSEvent, in textView: NSTextView) -> Bool
    func handleChecklistPaste(in textView: NSTextView) -> Bool
}

private final class TodoChecklistTextView: NSTextView {
    weak var checklistKeyDelegate: TodoChecklistKeyHandling?

    override func keyDown(with event: NSEvent) {
        if checklistKeyDelegate?.handleChecklistKeyDown(event, in: self) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if checklistKeyDelegate?.handleChecklistPaste(in: self) == true {
            return
        }
        super.paste(sender)
    }
}

private final class CheckboxAttachmentCell: NSButtonCell {
    override init(textCell: String) {
        super.init(textCell: textCell)
        configure()
    }

    init(checked: Bool) {
        super.init(textCell: "")
        configure()
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        title = ""
        setButtonType(.switch)
        controlSize = .regular
        imagePosition = .imageOnly
        isBordered = false
    }

}

private final class TodoChecklistButton: NSButton {
    private func configureCell() {
        controlSize = .regular
        isBordered = false
        setButtonType(.switch)
        imagePosition = .imageOnly
        cell = CheckboxAttachmentCell(textCell: title)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCell()
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

private extension NSImage {
    func todoPNGData() -> Data? {
        guard let tiffData = tiffRepresentation else { return nil }
        guard let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
