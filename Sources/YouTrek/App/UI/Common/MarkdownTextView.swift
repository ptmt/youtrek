import SwiftUI

struct MarkdownTextView: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        let renderedText = Self.preprocess(text)
        if let attributed = try? AttributedString(
            markdown: renderedText,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .font(font)
                .textSelection(.enabled)
        } else {
            Text(renderedText)
                .font(font)
                .textSelection(.enabled)
        }
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
