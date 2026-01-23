import Foundation

struct IssueProject: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let shortName: String?
    let isArchived: Bool

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !short.isEmpty, !trimmedName.isEmpty {
            return "\(short) — \(trimmedName)"
        }
        if !short.isEmpty {
            return short
        }
        return trimmedName.isEmpty ? "Untitled Project" : trimmedName
    }

    func matches(identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if id == trimmed { return true }
        if let shortName {
            return shortName.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return false
    }
}
