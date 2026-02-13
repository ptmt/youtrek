import Foundation

struct TodoInlineMarkdownMatch: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case bold
        case italic
        case code
        case strikethrough
        case link(URL)
    }

    let kind: Kind
    let wholeRange: NSRange
    let contentRange: NSRange
}

struct RegexTodoInlineMarkdownParser {
    private static let linkPattern = #"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#
    private static let codePattern = #"`([^`\n]+)`"#
    private static let boldPattern = #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#
    private static let italicStarPattern = #"(?<!\*)\*(?!\*)([^*\n]+)\*(?!\*)"#
    private static let italicUnderscorePattern = #"(?<!_)_(?!_)([^_\n]+)_(?!_)"#
    private static let strikePattern = #"~~([^~\n]+)~~"#

    private let linkRegex: NSRegularExpression?
    private let codeRegex: NSRegularExpression?
    private let boldRegex: NSRegularExpression?
    private let italicStarRegex: NSRegularExpression?
    private let italicUnderscoreRegex: NSRegularExpression?
    private let strikeRegex: NSRegularExpression?

    init() {
        linkRegex = try? NSRegularExpression(pattern: Self.linkPattern)
        codeRegex = try? NSRegularExpression(pattern: Self.codePattern)
        boldRegex = try? NSRegularExpression(pattern: Self.boldPattern)
        italicStarRegex = try? NSRegularExpression(pattern: Self.italicStarPattern)
        italicUnderscoreRegex = try? NSRegularExpression(pattern: Self.italicUnderscorePattern)
        strikeRegex = try? NSRegularExpression(pattern: Self.strikePattern)
    }

    func matches(in text: String) -> [TodoInlineMarkdownMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var candidates: [(priority: Int, match: TodoInlineMarkdownMatch)] = []

        if let linkRegex {
            linkRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 2 else { return }
                let wholeRange = match.range(at: 0)
                let labelRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                guard wholeRange.location != NSNotFound, labelRange.location != NSNotFound, urlRange.location != NSNotFound else { return }
                guard NSMaxRange(urlRange) <= nsText.length else { return }
                let rawURL = nsText.substring(with: urlRange)
                guard let url = URL(string: rawURL) else { return }
                candidates.append((0, TodoInlineMarkdownMatch(kind: .link(url), wholeRange: wholeRange, contentRange: labelRange)))
            }
        }

        if let codeRegex {
            codeRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let wholeRange = match.range(at: 0)
                let contentRange = match.range(at: 1)
                guard wholeRange.location != NSNotFound, contentRange.location != NSNotFound else { return }
                candidates.append((1, TodoInlineMarkdownMatch(kind: .code, wholeRange: wholeRange, contentRange: contentRange)))
            }
        }

        if let boldRegex {
            boldRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 2 else { return }
                let wholeRange = match.range(at: 0)
                let contentRange = match.range(at: 2)
                guard wholeRange.location != NSNotFound, contentRange.location != NSNotFound else { return }
                candidates.append((2, TodoInlineMarkdownMatch(kind: .bold, wholeRange: wholeRange, contentRange: contentRange)))
            }
        }

        if let strikeRegex {
            strikeRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let wholeRange = match.range(at: 0)
                let contentRange = match.range(at: 1)
                guard wholeRange.location != NSNotFound, contentRange.location != NSNotFound else { return }
                candidates.append((3, TodoInlineMarkdownMatch(kind: .strikethrough, wholeRange: wholeRange, contentRange: contentRange)))
            }
        }

        if let italicStarRegex {
            italicStarRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let wholeRange = match.range(at: 0)
                let contentRange = match.range(at: 1)
                guard wholeRange.location != NSNotFound, contentRange.location != NSNotFound else { return }
                candidates.append((4, TodoInlineMarkdownMatch(kind: .italic, wholeRange: wholeRange, contentRange: contentRange)))
            }
        }

        if let italicUnderscoreRegex {
            italicUnderscoreRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let wholeRange = match.range(at: 0)
                let contentRange = match.range(at: 1)
                guard wholeRange.location != NSNotFound, contentRange.location != NSNotFound else { return }
                candidates.append((4, TodoInlineMarkdownMatch(kind: .italic, wholeRange: wholeRange, contentRange: contentRange)))
            }
        }

        let sorted = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.match.wholeRange.location < $1.match.wholeRange.location
        }

        var accepted: [TodoInlineMarkdownMatch] = []
        var occupied: [NSRange] = []
        for candidate in sorted.map(\.match) {
            let hasOverlap = occupied.contains { NSIntersectionRange($0, candidate.contentRange).length > 0 }
            guard !hasOverlap else { continue }
            accepted.append(candidate)
            occupied.append(candidate.contentRange)
        }
        return accepted
    }
}
