import Foundation

protocol TodoIssueIDParsing {
    func issueIDs(in markdown: String) -> Set<String>
}

struct RegexTodoIssueIDParser: TodoIssueIDParsing {
    private static let issueIDPattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
    private let regex: NSRegularExpression?

    init() {
        regex = try? NSRegularExpression(pattern: Self.issueIDPattern)
    }

    func issueIDs(in markdown: String) -> Set<String> {
        guard let regex else { return [] }
        let nsText = markdown as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: markdown, range: range)
        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let raw = nsText.substring(with: match.range(at: 1))
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return normalized.isEmpty ? nil : normalized
        })
    }
}
