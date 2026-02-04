import SwiftUI

struct MarkdownTextView: View {
    let text: String
    var font: Font = .callout
    var codeFont: Font = .system(.callout, design: .monospaced)

    var body: some View {
        let segments = Self.segments(from: text)
        if segments.count == 1, case let .markdown(value) = segments[0] {
            markdownText(value)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments.indices, id: \.self) { index in
                    switch segments[index] {
                    case .markdown(let value):
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            markdownText(value)
                        }
                    case .codeBlock(let code, let language):
                        MarkdownCodeBlockView(code: code, language: language, font: codeFont)
                    }
                }
            }
        }
    }

    private func markdownText(_ value: String) -> some View {
        let renderedText = Self.preprocess(value)
        if let attributed = try? AttributedString(
            markdown: renderedText,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attributed)
                .font(font)
                .textSelection(.enabled)
        }
        return Text(renderedText)
            .font(font)
            .textSelection(.enabled)
    }

    private static func segments(from text: String) -> [MarkdownSegment] {
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let lines = rawLines.map(String.init)
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

    private static func preprocess(_ text: String) -> String {
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var lines = rawLines.map(String.init)
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

private enum MarkdownSegment {
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
