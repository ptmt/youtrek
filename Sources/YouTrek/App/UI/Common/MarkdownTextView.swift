import AppKit
import SwiftUI

enum MarkdownDisplayTextRenderer {
    private static let markdownParsingOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func segments(from text: String) -> [MarkdownSegment] {
        let normalizedText = normalizeLineEndings(in: text)
        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [MarkdownSegment] = []
        var markdownLines: [String] = []
        var codeLines: [String] = []
        var currentLanguage: String?
        var inCodeBlock = false

        func flushMarkdown() {
            guard !markdownLines.isEmpty else { return }
            segments.append(.markdown(markdownLines.joined(separator: "\n")))
            markdownLines.removeAll(keepingCapacity: true)
        }

        func flushCodeBlock() {
            segments.append(.codeBlock(codeLines.joined(separator: "\n"), language: currentLanguage))
            codeLines.removeAll(keepingCapacity: true)
            currentLanguage = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    flushCodeBlock()
                    inCodeBlock = false
                } else {
                    flushMarkdown()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    currentLanguage = language.isEmpty ? nil : String(language)
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
            } else {
                markdownLines.append(line)
            }
        }

        if inCodeBlock {
            flushCodeBlock()
        } else {
            flushMarkdown()
        }

        return segments
    }

    static func preparedMarkdown(for text: String) -> String {
        let normalizedText = normalizeLineEndings(in: text)
        var lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inCodeBlock = false
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            guard !inCodeBlock else { continue }

            var updated = replacingChecklistMarker(in: line)
            let isCurrentEmpty = trimmed.isEmpty
            let nextIsEmpty: Bool
            if index + 1 < lines.count {
                nextIsEmpty = lines[index + 1].trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
            } else {
                nextIsEmpty = true
            }
            if !isCurrentEmpty && !nextIsEmpty {
                updated += "  "
            }
            lines[index] = updated
        }
        return lines.joined(separator: "\n")
    }

    private final class CachedAttributedMarkdown {
        let value: AttributedString?
        init(value: AttributedString?) { self.value = value }
    }

    // Parsing is deterministic per input and expensive (worst case one
    // AttributedString(markdown:) call per line); SwiftUI re-evaluates the
    // detail panel on every AppState change, so cache by source text.
    nonisolated(unsafe) private static let attributedMarkdownCache: NSCache<NSString, CachedAttributedMarkdown> = {
        let cache = NSCache<NSString, CachedAttributedMarkdown>()
        cache.countLimit = 256
        return cache
    }()

    static func attributedMarkdown(for text: String) -> AttributedString? {
        let key = text as NSString
        if let cached = attributedMarkdownCache.object(forKey: key) {
            return cached.value
        }
        let parsed = parseAttributedMarkdown(for: text)
        attributedMarkdownCache.setObject(CachedAttributedMarkdown(value: parsed), forKey: key)
        return parsed
    }

    private static func parseAttributedMarkdown(for text: String) -> AttributedString? {
        let prepared = preparedMarkdown(for: text)
        guard let attributed = try? AttributedString(
            markdown: prepared,
            options: markdownParsingOptions
        ) else {
            return nil
        }

        guard renderedLineBreakCount(in: attributed) < sourceLineBreakCount(in: prepared) else {
            return attributed
        }
        return linePreservingAttributedMarkdown(for: prepared) ?? attributed
    }

    static func normalizeLineEndings(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func linePreservingAttributedMarkdown(for preparedMarkdown: String) -> AttributedString? {
        let lines = normalizeLineEndings(in: preparedMarkdown)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return AttributedString("") }

        var result = AttributedString("")
        for index in lines.indices {
            if !lines[index].isEmpty {
                let line = (try? AttributedString(
                    markdown: lines[index],
                    options: markdownParsingOptions
                )) ?? AttributedString(lines[index])
                result.append(line)
            }
            if index < lines.index(before: lines.endIndex) {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private static func sourceLineBreakCount(in text: String) -> Int {
        text.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private static func renderedLineBreakCount(in attributed: AttributedString) -> Int {
        attributed.characters.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private static func replacingChecklistMarker(in line: String) -> String {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return line }
        let bulletIndex = index
        let bullet = line[bulletIndex]
        guard bullet == "-" || bullet == "*" || bullet == "+" else { return line }

        var cursor = line.index(after: bulletIndex)
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == "[" else { return line }
        let stateIndex = line.index(after: cursor)
        guard stateIndex < line.endIndex else { return line }
        let stateChar = line[stateIndex]
        let closeIndex = line.index(after: stateIndex)
        guard closeIndex < line.endIndex, line[closeIndex] == "]" else { return line }

        let symbol = (stateChar == "x" || stateChar == "X") ? "☑" : "☐"
        var contentStart = line.index(after: closeIndex)
        while contentStart < line.endIndex, line[contentStart].isWhitespace {
            contentStart = line.index(after: contentStart)
        }

        let prefix = line[..<bulletIndex]
        if contentStart < line.endIndex {
            let rest = line[contentStart...]
            return "\(prefix)\(symbol) \(rest)"
        }
        return "\(prefix)\(symbol)"
    }
}

struct MarkdownTextView: View {
    let text: String
    var font: Font = .callout
    var codeFont: Font = .system(.callout, design: .monospaced)
    var baseURL: URL?
    var attachments: [IssueAttachment] = []
    var remoteImageDataLoader: ((URL) async throws -> Data)?

    var body: some View {
        let segments = MarkdownDisplayTextRenderer.segments(from: text)
        if segments.count == 1, case let .markdown(value) = segments[0] {
            markdownSegment(value)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments.indices, id: \.self) { index in
                    switch segments[index] {
                    case .markdown(let value):
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            markdownSegment(value)
                        }
                    case .codeBlock(let code, let language):
                        MarkdownCodeBlockView(code: code, language: language, font: codeFont)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownSegment(_ value: String) -> some View {
        let fragments = MarkdownImageMarkdownParser.fragments(in: value)
        if fragments.count == 1, case let .text(singleText) = fragments[0] {
            markdownText(singleText)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(fragments.enumerated()), id: \.offset) { _, fragment in
                    switch fragment {
                    case .text(let text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            markdownText(text)
                        }
                    case .image(let match):
                        MarkdownImageView(
                            match: match,
                            baseURL: baseURL,
                            attachments: attachments,
                            remoteImageDataLoader: remoteImageDataLoader
                        )
                    }
                }
            }
        }
    }

    private func markdownText(_ value: String) -> some View {
        if let attributed = MarkdownDisplayTextRenderer.attributedMarkdown(for: value) {
            return Text(attributed)
                .font(font)
                .textSelection(.enabled)
        }
        let renderedText = MarkdownDisplayTextRenderer.preparedMarkdown(for: value)
        return Text(renderedText)
            .font(font)
            .textSelection(.enabled)
    }
}

enum MarkdownImageFragment: Equatable {
    case text(String)
    case image(MarkdownImageMatch)
}

struct MarkdownImageMatch: Equatable {
    let altText: String
    let source: String
    let displayOptions: MarkdownImageDisplayOptions

    init(
        altText: String,
        source: String,
        displayOptions: MarkdownImageDisplayOptions = MarkdownImageDisplayOptions()
    ) {
        self.altText = altText
        self.source = source
        self.displayOptions = displayOptions
    }
}

struct MarkdownImageDisplayOptions: Equatable {
    var width: MarkdownImageDimension?
    var height: CGFloat?
}

enum MarkdownImageDimension: Equatable {
    case percent(CGFloat)
    case points(CGFloat)
}

enum MarkdownImageMarkdownParser {
    private static let imagePattern = #"!\[([^\]\n]*)\]\(([^)\n]+)\)(?:[ \t]*\{([^}\n]+)\})?"#
    private static let regex = try? NSRegularExpression(pattern: imagePattern)

    static func fragments(in markdown: String) -> [MarkdownImageFragment] {
        guard let regex else { return [.text(markdown)] }
        let nsText = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: markdown, range: fullRange)
        guard !matches.isEmpty else { return [.text(markdown)] }

        var fragments: [MarkdownImageFragment] = []
        var cursor = 0
        for match in matches {
            guard match.numberOfRanges > 2 else { continue }
            let wholeRange = match.range(at: 0)
            let altRange = match.range(at: 1)
            let sourceRange = match.range(at: 2)
            let attributesRange = match.numberOfRanges > 3 ? match.range(at: 3) : NSRange(location: NSNotFound, length: 0)
            guard wholeRange.location != NSNotFound,
                  altRange.location != NSNotFound,
                  sourceRange.location != NSNotFound,
                  NSMaxRange(wholeRange) <= nsText.length,
                  NSMaxRange(altRange) <= nsText.length,
                  NSMaxRange(sourceRange) <= nsText.length
            else {
                continue
            }

            if wholeRange.location > cursor {
                let textRange = NSRange(location: cursor, length: wholeRange.location - cursor)
                fragments.append(.text(nsText.substring(with: textRange)))
            }

            let alt = nsText.substring(with: altRange)
            let source = nsText.substring(with: sourceRange)
            let attributes: String?
            if attributesRange.location != NSNotFound,
               NSMaxRange(attributesRange) <= nsText.length {
                attributes = nsText.substring(with: attributesRange)
            } else {
                attributes = nil
            }
            fragments.append(.image(MarkdownImageMatch(
                altText: alt,
                source: source,
                displayOptions: displayOptions(from: attributes)
            )))

            cursor = NSMaxRange(wholeRange)
        }

        if cursor < nsText.length {
            let tailRange = NSRange(location: cursor, length: nsText.length - cursor)
            fragments.append(.text(nsText.substring(with: tailRange)))
        }

        return fragments.isEmpty ? [.text(markdown)] : fragments
    }

    private static func displayOptions(from attributes: String?) -> MarkdownImageDisplayOptions {
        guard let attributes else { return MarkdownImageDisplayOptions() }
        var options = MarkdownImageDisplayOptions()
        let pairs = attributes
            .split { character in
                character == "," || character == ";" || character.isWhitespace
            }
            .map(String.init)

        for pair in pairs {
            let separator = pair.firstIndex(of: "=") ?? pair.firstIndex(of: ":")
            guard let separator else { continue }
            let key = pair[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = pair[pair.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "width":
                options.width = dimension(from: rawValue)
            case "height":
                if case .points(let points) = dimension(from: rawValue) {
                    options.height = points
                }
            default:
                continue
            }
        }
        return options
    }

    private static func dimension(from value: String) -> MarkdownImageDimension? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("%") {
            trimmed.removeLast()
            guard let percent = Double(trimmed), percent > 0 else { return nil }
            return .percent(CGFloat(min(percent, 100)) / 100.0)
        }
        if trimmed.lowercased().hasSuffix("px") {
            trimmed.removeLast(2)
        }
        guard let points = Double(trimmed), points > 0 else { return nil }
        return .points(CGFloat(points))
    }
}

enum MarkdownImageSource: Equatable {
    case inlineData(Data)
    case remote(URL)
    case file(URL)
    case unsupported
}

enum MarkdownImageSourceResolver {
    static func resolve(source raw: String, baseURL: URL?, attachments: [IssueAttachment] = []) -> MarkdownImageSource {
        let trimmed = normalizeSource(raw)
        guard !trimmed.isEmpty else { return .unsupported }

        if trimmed.lowercased().hasPrefix("data:image/"), let data = decodeDataURL(trimmed) {
            return .inlineData(data)
        }

        if let attachmentURL = matchingAttachmentURL(for: trimmed, attachments: attachments) {
            return imageSource(for: attachmentURL)
        }

        let candidateBases = candidateURLs(from: baseURL)
        for candidateBase in candidateBases {
            if let resolvedURL = resolveURL(trimmed, relativeTo: candidateBase) {
                return imageSource(for: resolvedURL)
            }
        }
        return .unsupported
    }

    private static func normalizeSource(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return trimmed
        }

        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.hasPrefix("'") && trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let hasWhitespace = trimmed.contains { $0.isWhitespace }
        if hasWhitespace, let firstSpace = trimmed.firstIndex(where: { $0.isWhitespace }) {
            trimmed = String(trimmed[..<firstSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private static func matchingAttachmentURL(for source: String, attachments: [IssueAttachment]) -> URL? {
        let normalized = normalizedComparableSource(source)
        guard !normalized.isEmpty else { return nil }
        for attachment in attachments where attachment.isImage {
            guard let url = attachment.url else { continue }
            let candidates = [
                attachment.name,
                url.lastPathComponent,
                url.deletingPathExtension().lastPathComponent,
                url.absoluteString
            ]
            if candidates.contains(where: { normalizedComparableSource($0) == normalized }) {
                return url
            }
        }
        return nil
    }

    private static func normalizedComparableSource(_ value: String) -> String {
        let decoded = value.removingPercentEncoding ?? value
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return lastPathComponent.lowercased()
    }

    private static func resolveURL(_ value: String, relativeTo baseURL: URL?) -> URL? {
        if let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL, isHTTPOrFile(resolved) {
            return resolved
        }

        let urlAllowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed)
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: urlAllowed),
           let resolved = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
           isHTTPOrFile(resolved) {
            return resolved
        }

        return nil
    }

    private static func isHTTPOrFile(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private static func imageSource(for url: URL) -> MarkdownImageSource {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .remote(url)
        case "file":
            return .file(url)
        default:
            return .unsupported
        }
    }

    private static func candidateURLs(from baseURL: URL?) -> [URL?] {
        guard let baseURL else { return [nil] }
        var candidates: [URL] = [baseURL]
        let parent = baseURL.deletingLastPathComponent()
        if parent != baseURL {
            candidates.append(parent)
        }
        let grandparent = parent.deletingLastPathComponent()
        if grandparent != parent {
            candidates.append(grandparent)
        }
        return candidates.map { $0 as URL? }
    }

    private static func decodeDataURL(_ value: String) -> Data? {
        guard let separatorRange = value.range(of: ",") else { return nil }
        let metadata = value[..<separatorRange.lowerBound].lowercased()
        guard metadata.hasPrefix("data:image/"), metadata.contains(";base64") else { return nil }

        let payload = String(value[separatorRange.upperBound...])
        let decodedPayload = payload.removingPercentEncoding ?? payload
        return Data(base64Encoded: decodedPayload, options: [.ignoreUnknownCharacters])
    }
}

private struct MarkdownImageView: View {
    let match: MarkdownImageMatch
    let baseURL: URL?
    let attachments: [IssueAttachment]
    let remoteImageDataLoader: ((URL) async throws -> Data)?

    @ViewBuilder
    var body: some View {
        switch MarkdownImageSourceResolver.resolve(source: match.source, baseURL: baseURL, attachments: attachments) {
        case .inlineData(let data):
            if let image = NSImage(data: data) {
                rendered(nsImage: image)
            } else {
                placeholder
            }
        case .remote(let url):
            if let remoteImageDataLoader {
                MarkdownRemoteImageLoaderView(
                    url: url,
                    displayOptions: match.displayOptions,
                    remoteImageDataLoader: remoteImageDataLoader
                )
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading image…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    case .success(let image):
                        MarkdownRenderedImageView(image: image, displayOptions: match.displayOptions)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            }
        case .file(let url):
            if let image = NSImage(contentsOf: url) {
                rendered(nsImage: image)
            } else {
                placeholder
            }
        case .unsupported:
            placeholder
        }
    }

    private func rendered(nsImage: NSImage) -> some View {
        MarkdownRenderedImageView(image: Image(nsImage: nsImage), displayOptions: match.displayOptions)
    }

    private var placeholder: some View {
        let label = match.altText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(label.isEmpty ? "Image unavailable" : label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct MarkdownRemoteImageLoaderView: View {
    let url: URL
    let displayOptions: MarkdownImageDisplayOptions
    let remoteImageDataLoader: (URL) async throws -> Data

    @State private var state: MarkdownRemoteImageLoadState = .loading

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading image…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .task(id: url) {
                await loadImage()
            }
        case .loaded(let image):
            MarkdownRenderedImageView(image: Image(nsImage: image), displayOptions: displayOptions)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text("Image unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func loadImage() async {
        state = .loading
        do {
            let data = try await remoteImageDataLoader(url)
            guard let image = NSImage(data: data) else {
                state = .failed
                return
            }
            state = .loaded(image)
        } catch {
            state = .failed
        }
    }
}

private struct MarkdownRenderedImageView: View {
    let image: Image
    let displayOptions: MarkdownImageDisplayOptions

    var body: some View {
        sizedImage
            .frame(maxHeight: displayOptions.height ?? 320)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sizedImage: some View {
        switch displayOptions.width {
        case .percent(let fraction):
            image
                .resizable()
                .scaledToFit()
                .containerRelativeFrame(.horizontal) { length, _ in
                    max(1, length * min(max(fraction, 0), 1))
                }
        case .points(let points):
            image
                .resizable()
                .scaledToFit()
                .frame(width: points)
        case nil:
            image
                .resizable()
                .scaledToFit()
        }
    }
}

private enum MarkdownRemoteImageLoadState {
    case loading
    case loaded(NSImage)
    case failed
}

enum MarkdownSegment: Equatable {
    case markdown(String)
    case codeBlock(String, language: String?)
}

private struct MarkdownCodeBlockView: View {
    let code: String
    let language: String?
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(font)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ClipboardImageMarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = ClipboardImagePasteTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.imagePasteDelegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, ClipboardImagePasteHandling {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func handleImagePaste(in textView: NSTextView) -> Bool {
            let pasteboard = NSPasteboard.general
            guard let image = NSImage(pasteboard: pasteboard),
                  let pngData = image.markdownImagePNGData()
            else {
                return false
            }

            let insertionRange = textView.selectedRange()
            guard insertionRange.location != NSNotFound else { return false }

            let markdown = MarkdownClipboardImageEncoder.markdownSnippet(forPNGData: pngData)
            textView.insertText(markdown, replacementRange: insertionRange)
            text = textView.string
            return true
        }
    }
}

enum MarkdownClipboardImageEncoder {
    static func markdownSnippet(forPNGData data: Data) -> String {
        let base64 = data.base64EncodedString()
        return "![Pasted image](data:image/png;base64,\(base64))"
    }
}

@MainActor
private protocol ClipboardImagePasteHandling: AnyObject {
    func handleImagePaste(in textView: NSTextView) -> Bool
}

private final class ClipboardImagePasteTextView: NSTextView {
    weak var imagePasteDelegate: ClipboardImagePasteHandling?

    override func paste(_ sender: Any?) {
        if imagePasteDelegate?.handleImagePaste(in: self) == true {
            return
        }
        super.paste(sender)
    }
}

private extension NSImage {
    func markdownImagePNGData() -> Data? {
        guard let tiffData = tiffRepresentation else { return nil }
        guard let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
