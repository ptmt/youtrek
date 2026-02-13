import Foundation

struct TodoChecklistLineMatch: Equatable, Sendable {
    let lineIndex: Int
    let issueID: String?
    let isChecked: Bool
}

struct TodoChecklistMarkerMatch: Equatable, Sendable {
    let markerRange: NSRange
    let stateRange: NSRange
    let lineRange: NSRange
    let isChecked: Bool
    let issueID: String?
    let hasExplicitCheckbox: Bool
}

struct RegexTodoChecklistMarkerParser {
    private static let explicitChecklistPattern = #"^([ \t]*)(-|\d+\.)[ \t]+\[([ xX])\]"#
    private static let listItemPattern = #"^([ \t]*)(-|\d+\.)[ \t]+"#
    private static let issueIDPattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#

    private let explicitChecklistRegex: NSRegularExpression?
    private let listItemRegex: NSRegularExpression?
    private let issueIDRegex: NSRegularExpression?

    init() {
        explicitChecklistRegex = try? NSRegularExpression(pattern: Self.explicitChecklistPattern)
        listItemRegex = try? NSRegularExpression(pattern: Self.listItemPattern)
        issueIDRegex = try? NSRegularExpression(pattern: Self.issueIDPattern)
    }

    func checklistMarkers(in markdown: String) -> [TodoChecklistMarkerMatch] {
        guard explicitChecklistRegex != nil || listItemRegex != nil else { return [] }
        let nsText = markdown as NSString
        guard nsText.length > 0 else { return [] }

        var markers: [TodoChecklistMarkerMatch] = []
        var searchLocation = 0
        var inCodeFence = false

        while searchLocation < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: searchLocation, length: 0))
            guard lineRange.location != NSNotFound, lineRange.length > 0 else { break }

            let line = nsText.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                inCodeFence.toggle()
                searchLocation = NSMaxRange(lineRange)
                continue
            }

            if !inCodeFence {
                let nsLine = line as NSString
                let localLineRange = NSRange(location: 0, length: nsLine.length)
                if let match = explicitChecklistRegex?.firstMatch(in: line, range: localLineRange),
                   match.numberOfRanges > 3 {
                    let localMarkerRange = match.range(at: 0)
                    let localStateRange = match.range(at: 3)
                    if localMarkerRange.location != NSNotFound,
                       localStateRange.location != NSNotFound,
                       NSMaxRange(localMarkerRange) <= nsLine.length,
                       NSMaxRange(localStateRange) <= nsLine.length {
                        let markerRange = NSRange(
                            location: lineRange.location + localMarkerRange.location,
                            length: localMarkerRange.length
                        )
                        let stateRange = NSRange(
                            location: lineRange.location + localStateRange.location,
                            length: localStateRange.length
                        )
                        let stateToken = nsLine.substring(with: localStateRange)
                        let isChecked = stateToken == "x" || stateToken == "X"
                        let issueID = resolvedIssueID(inLine: line)
                        markers.append(
                            TodoChecklistMarkerMatch(
                                markerRange: markerRange,
                                stateRange: stateRange,
                                lineRange: lineRange,
                                isChecked: isChecked,
                                issueID: issueID,
                                hasExplicitCheckbox: true
                            )
                        )
                    }
                } else if let match = listItemRegex?.firstMatch(in: line, range: localLineRange),
                          match.numberOfRanges > 2 {
                    let localMarkerRange = match.range(at: 0)
                    if localMarkerRange.location != NSNotFound,
                       NSMaxRange(localMarkerRange) <= nsLine.length {
                        let markerRange = NSRange(
                            location: lineRange.location + localMarkerRange.location,
                            length: localMarkerRange.length
                        )
                        let issueID = resolvedIssueID(inLine: line)
                        markers.append(
                            TodoChecklistMarkerMatch(
                                markerRange: markerRange,
                                stateRange: NSRange(location: NSNotFound, length: 0),
                                lineRange: lineRange,
                                isChecked: false,
                                issueID: issueID,
                                hasExplicitCheckbox: false
                            )
                        )
                    }
                }
            }

            searchLocation = NSMaxRange(lineRange)
        }

        return markers
    }

    func applyingCheckState(_ isChecked: Bool, to markdown: String, marker: TodoChecklistMarkerMatch) -> String {
        let nsText = markdown as NSString
        let mutable = NSMutableString(string: markdown)

        if marker.stateRange.location != NSNotFound {
            guard NSMaxRange(marker.stateRange) <= nsText.length else { return markdown }
            let replacement = isChecked ? "x" : " "
            mutable.replaceCharacters(in: marker.stateRange, with: replacement)
            return mutable as String
        }

        return markdown
    }

    private func resolvedIssueID(inLine line: String) -> String? {
        guard let issueIDRegex else { return nil }
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)
        var matches: [String] = []
        issueIDRegex.enumerateMatches(in: line, range: lineRange) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let range = match.range(at: 1)
            guard range.location != NSNotFound, NSMaxRange(range) <= nsLine.length else { return }
            let value = nsLine.substring(with: range).uppercased()
            matches.append(value)
        }
        let unique = Array(Set(matches))
        guard unique.count == 1 else { return nil }
        return unique[0]
    }
}

struct RegexTodoChecklistDetector {
    private static let listItemPattern = #"^[ \t]*(?:-|\d+\.)[ \t]+"#
    private static let markdownChecklistPattern = #"^[ \t]*(?:-|\d+\.)[ \t]+\[([ xX])\]"#

    private let listItemRegex: NSRegularExpression?
    private let markdownChecklistRegex: NSRegularExpression?

    init() {
        listItemRegex = try? NSRegularExpression(pattern: Self.listItemPattern)
        markdownChecklistRegex = try? NSRegularExpression(pattern: Self.markdownChecklistPattern)
    }

    func checklistLines(in markdown: String) -> [TodoChecklistLineMatch] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.enumerated().compactMap { index, line in
            checklistMatch(in: line, lineIndex: index)
        }
    }

    private func checklistMatch(in line: String, lineIndex: Int) -> TodoChecklistLineMatch? {
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)

        if
            let markdownChecklistRegex,
            let match = markdownChecklistRegex.firstMatch(in: line, range: lineRange),
            match.numberOfRanges > 1,
            match.range(at: 1).location != NSNotFound
        {
            let rawState = nsLine.substring(with: match.range(at: 1))
            let isChecked = rawState == "x" || rawState == "X"
            return TodoChecklistLineMatch(lineIndex: lineIndex, issueID: nil, isChecked: isChecked)
        }

        guard
            let listItemRegex,
            listItemRegex.firstMatch(in: line, range: lineRange) != nil
        else {
            return nil
        }

        return TodoChecklistLineMatch(lineIndex: lineIndex, issueID: nil, isChecked: false)
    }
}

struct RegexTodoDashListContinuationDetector {
    private static let listPattern = #"^([ \t]*)-\s+"#
    private let listRegex: NSRegularExpression?

    init() {
        listRegex = try? NSRegularExpression(pattern: Self.listPattern)
    }

    func continuationIndentation(in line: String) -> String? {
        guard let listRegex else { return nil }
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)
        guard
            let match = listRegex.firstMatch(in: line, range: lineRange),
            match.numberOfRanges > 1,
            match.range(at: 1).location != NSNotFound
        else {
            return nil
        }
        return nsLine.substring(with: match.range(at: 1))
    }
}
