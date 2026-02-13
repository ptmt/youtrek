import Foundation

struct TodoChecklistMarkdownRenderer {
    private static let markdownChecklistPattern = #"^(\s*)([-*+])\s+\[([ xX])\](.*)$"#
    private static let renderedChecklistPattern = #"^(\s*)([-*+])\s+([☐☑])(.*)$"#

    private let markdownChecklistRegex: NSRegularExpression?
    private let renderedChecklistRegex: NSRegularExpression?

    init() {
        markdownChecklistRegex = try? NSRegularExpression(pattern: Self.markdownChecklistPattern)
        renderedChecklistRegex = try? NSRegularExpression(pattern: Self.renderedChecklistPattern)
    }

    func displayText(fromMarkdown markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let converted = lines.map { displayLine(fromMarkdownLine: $0) }
        return converted.joined(separator: "\n")
    }

    func markdownText(fromDisplayText displayText: String) -> String {
        let lines = displayText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let converted = lines.map { markdownLine(fromDisplayLine: $0) }
        return converted.joined(separator: "\n")
    }

    private func displayLine(fromMarkdownLine line: String) -> String {
        guard
            let markdownChecklistRegex,
            let match = markdownChecklistRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ),
            match.numberOfRanges > 4
        else {
            return line
        }
        let nsLine = line as NSString
        let indentation = nsLine.substring(with: match.range(at: 1))
        let bullet = nsLine.substring(with: match.range(at: 2))
        let rawState = nsLine.substring(with: match.range(at: 3))
        let remainder = nsLine.substring(with: match.range(at: 4))
        let symbol = (rawState == "x" || rawState == "X") ? "☑" : "☐"
        if remainder.isEmpty {
            return "\(indentation)\(bullet) \(symbol)"
        }
        if remainder.first?.isWhitespace == true {
            return "\(indentation)\(bullet) \(symbol)\(remainder)"
        }
        return "\(indentation)\(bullet) \(symbol) \(remainder)"
    }

    private func markdownLine(fromDisplayLine line: String) -> String {
        guard
            let renderedChecklistRegex,
            let match = renderedChecklistRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ),
            match.numberOfRanges > 4
        else {
            return line
        }
        let nsLine = line as NSString
        let indentation = nsLine.substring(with: match.range(at: 1))
        let bullet = nsLine.substring(with: match.range(at: 2))
        let symbol = nsLine.substring(with: match.range(at: 3))
        let remainder = nsLine.substring(with: match.range(at: 4))
        let state = symbol == "☑" ? "x" : " "
        if remainder.isEmpty {
            return "\(indentation)\(bullet) [\(state)]"
        }
        if remainder.first?.isWhitespace == true {
            return "\(indentation)\(bullet) [\(state)]\(remainder)"
        }
        return "\(indentation)\(bullet) [\(state)] \(remainder)"
    }
}
