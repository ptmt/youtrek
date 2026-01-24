import Foundation
import SwiftUI

struct IssueSummary: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let readableID: String
    let title: String
    let projectName: String
    let updatedAt: Date
    let assignee: Person?
    let reporter: Person?
    let priority: IssuePriority
    let status: IssueStatus
    let tags: [String]
    let customFieldValues: [String: [String]]

    init(
        id: UUID = UUID(),
        readableID: String,
        title: String,
        projectName: String,
        updatedAt: Date = .now,
        assignee: Person? = nil,
        reporter: Person? = nil,
        priority: IssuePriority = .normal,
        status: IssueStatus = .open,
        tags: [String] = [],
        customFieldValues: [String: [String]] = [:]
    ) {
        self.id = id
        self.readableID = readableID
        self.title = title
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.assignee = assignee
        self.reporter = reporter
        self.priority = priority
        self.status = status
        self.tags = tags
        self.customFieldValues = customFieldValues
    }

    var assigneeDisplayName: String {
        assignee?.displayName ?? "Unassigned"
    }

    var reporterDisplayName: String {
        reporter?.displayName ?? "Unknown"
    }

    func fieldValues(named fieldName: String) -> [String] {
        let key = fieldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return customFieldValues[key] ?? []
    }
}

extension IssueSummary {
    func updating(updatedAt date: Date) -> IssueSummary {
        IssueSummary(
            id: id,
            readableID: readableID,
            title: title,
            projectName: projectName,
            updatedAt: date,
            assignee: assignee,
            reporter: reporter,
            priority: priority,
            status: status,
            tags: tags,
            customFieldValues: customFieldValues
        )
    }
}

struct Person: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let displayName: String
    let avatarURL: URL?
    let login: String?
    let remoteID: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        avatarURL: URL? = nil,
        login: String? = nil,
        remoteID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.login = login
        self.remoteID = remoteID
    }
}

extension Person {
    static func stableID(for source: String) -> UUID {
        var hashBytes = [UInt8](repeating: 0, count: 16)
        let data = Array(source.utf8)
        for (index, byte) in data.enumerated() {
            hashBytes[index % 16] = hashBytes[index % 16] &+ byte &+ UInt8(index % 7)
        }
        return UUID(uuid: (
            hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
            hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
            hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
            hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
        ))
    }

    var issueFieldOption: IssueFieldOption? {
        let trimmedID = remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedID = trimmedID.isEmpty ? "" : trimmedID
        let name = login ?? displayName
        let identifier = resolvedID.isEmpty ? name : resolvedID
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return IssueFieldOption(
            id: resolvedID,
            name: name,
            displayName: displayName,
            login: login,
            avatarURL: avatarURL,
            ordinal: nil
        )
    }

    static func from(option: IssueFieldOption) -> Person {
        let seedParts = [option.id, option.login ?? "", option.displayName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let seed = seedParts.isEmpty ? option.displayName : seedParts.joined(separator: "|")
        let trimmedRemoteID = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteID = trimmedRemoteID.isEmpty ? nil : trimmedRemoteID
        return Person(
            id: Person.stableID(for: seed),
            displayName: option.displayName,
            avatarURL: option.avatarURL,
            login: option.login,
            remoteID: remoteID
        )
    }
}

enum IssuePriority: Hashable, Sendable, Codable, RawRepresentable {
    case critical
    case high
    case normal
    case low
    case custom(String)

    static var allCases: [IssuePriority] {
        [.critical, .high, .normal, .low]
    }

    static var fallbackCases: [IssuePriority] {
        allCases
    }

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = IssuePriority.normalizedKey(trimmed)
        if let exact = IssuePriority.exactCategory(for: key) {
            self = exact
        } else {
            self = .custom(trimmed)
        }
    }

    var rawValue: String {
        switch self {
        case .critical:
            return "critical"
        case .high:
            return "high"
        case .normal:
            return "normal"
        case .low:
            return "low"
        case .custom(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "custom" : trimmed
        }
    }

    static func from(apiName: String?) -> IssuePriority {
        guard let apiName, let priority = IssuePriority(rawValue: apiName) else {
            return .normal
        }
        return priority
    }

    var displayName: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        case .custom(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }
    }

    var iconName: String {
        switch semantic {
        case .critical: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.circle.fill"
        case .normal: return "circle"
        case .low: return "arrow.down.circle"
        case .custom: return "circle"
        }
    }

    var tint: Color {
        badgeColors.foreground
    }

    var normalizedKey: String {
        IssuePriority.normalizedKey(rawValue)
    }

    var sortRank: Int {
        switch semantic {
        case .critical: return 4
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        case .custom: return 0
        }
    }

    var isNormalSemantic: Bool {
        semantic == .normal
    }

    static func deduplicated(_ priorities: [IssuePriority]) -> [IssuePriority] {
        var seen = Set<String>()
        var unique: [IssuePriority] = []
        for priority in priorities {
            let key = priority.normalizedKey
            if seen.insert(key).inserted {
                unique.append(priority)
            }
        }
        return unique
    }

    static func sortedUnique(_ priorities: [IssuePriority]) -> [IssuePriority] {
        let unique = deduplicated(priorities)
        return unique.sorted { left, right in
            if left.sortRank != right.sortRank {
                return left.sortRank < right.sortRank
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    static func from(displayName: String) -> IssuePriority? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return IssuePriority(rawValue: trimmed) ?? .custom(trimmed)
    }

    init(option: IssueFieldOption) {
        let candidate = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = candidate.isEmpty ? fallback : candidate
        self = IssuePriority(rawValue: resolved) ?? .custom(resolved)
    }

    static func == (lhs: IssuePriority, rhs: IssuePriority) -> Bool {
        lhs.normalizedKey == rhs.normalizedKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedKey)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = IssuePriority(rawValue: raw) ?? .custom(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private extension IssuePriority {
    enum Semantic {
        case critical
        case high
        case normal
        case low
        case custom
    }

    static let exactCriticalKeys: Set<String> = ["critical"]
    static let exactHighKeys: Set<String> = ["high"]
    static let exactNormalKeys: Set<String> = ["normal"]
    static let exactLowKeys: Set<String> = ["low"]

    static func normalizedKey(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func exactCategory(for key: String) -> IssuePriority? {
        if exactCriticalKeys.contains(key) { return .critical }
        if exactHighKeys.contains(key) { return .high }
        if exactNormalKeys.contains(key) { return .normal }
        if exactLowKeys.contains(key) { return .low }
        return nil
    }

    static func heuristicCategory(for key: String) -> Semantic {
        if exactCriticalKeys.contains(key) || key.contains("critical") || key.contains("block") || key.contains("urgent") || key.contains("showstopper") {
            return .critical
        }
        if exactHighKeys.contains(key) || key.contains("high") || key.contains("major") || key.contains("important") {
            return .high
        }
        if exactLowKeys.contains(key) || key.contains("low") || key.contains("minor") || key.contains("trivial") {
            return .low
        }
        if exactNormalKeys.contains(key) || key.contains("normal") || key.contains("medium") || key.contains("default") {
            return .normal
        }
        return .custom
    }

    var semantic: Semantic {
        switch self {
        case .critical: return .critical
        case .high: return .high
        case .normal: return .normal
        case .low: return .low
        case .custom(let value):
            return IssuePriority.heuristicCategory(for: IssuePriority.normalizedKey(value))
        }
    }
}

extension IssueFieldColor {
    var backgroundColor: Color? {
        Color(hexString: backgroundHex)
    }

    var foregroundColor: Color? {
        Color(hexString: foregroundHex)
    }

    func readableForeground(for colorScheme: ColorScheme) -> Color? {
        let baseBackground: SRGBColor = (colorScheme == .dark) ? .black : .white
        guard var candidate = SRGBColor(hexString: foregroundHex ?? backgroundHex) else { return nil }
        if baseBackground.contrastRatio(with: candidate) >= 4.5 {
            return Color(candidate)
        }
        for _ in 0..<6 {
            candidate = candidate.blended(
                with: colorScheme == .dark ? SRGBColor.white : SRGBColor.black,
                amount: 0.15
            )
            if baseBackground.contrastRatio(with: candidate) >= 4.5 {
                return Color(candidate)
            }
        }
        return colorScheme == .dark ? Color.white : Color.black
    }

    func readableForegroundForBadge() -> Color? {
        guard let background = SRGBColor(hexString: backgroundHex) else {
            return foregroundColor
        }
        if let foreground = SRGBColor(hexString: foregroundHex),
           background.contrastRatio(with: foreground) >= 4.5 {
            return Color(foreground)
        }
        let black = SRGBColor.black
        let white = SRGBColor.white
        let blackContrast = background.contrastRatio(with: black)
        let whiteContrast = background.contrastRatio(with: white)
        return Color(blackContrast >= whiteContrast ? black : white)
    }
}

private struct SRGBColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let white = SRGBColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = SRGBColor(red: 0, green: 0, blue: 0, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

        if hex.count == 6 {
            self.red = Double((value & 0xFF0000) >> 16) / 255.0
            self.green = Double((value & 0x00FF00) >> 8) / 255.0
            self.blue = Double(value & 0x0000FF) / 255.0
            self.alpha = 1.0
        } else {
            self.red = Double((value & 0xFF000000) >> 24) / 255.0
            self.green = Double((value & 0x00FF0000) >> 16) / 255.0
            self.blue = Double((value & 0x0000FF00) >> 8) / 255.0
            self.alpha = Double(value & 0x000000FF) / 255.0
        }
    }

    func contrastRatio(with other: SRGBColor) -> Double {
        let l1 = max(relativeLuminance, other.relativeLuminance)
        let l2 = min(relativeLuminance, other.relativeLuminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }

    func blended(with other: SRGBColor, amount: Double) -> SRGBColor {
        let clamped = min(max(amount, 0), 1)
        return SRGBColor(
            red: red + (other.red - red) * clamped,
            green: green + (other.green - green) * clamped,
            blue: blue + (other.blue - blue) * clamped,
            alpha: alpha + (other.alpha - alpha) * clamped
        )
    }

    private var relativeLuminance: Double {
        let r = SRGBColor.linearize(red)
        let g = SRGBColor.linearize(green)
        let b = SRGBColor.linearize(blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func linearize(_ component: Double) -> Double {
        component <= 0.03928 ? (component / 12.92) : pow((component + 0.055) / 1.055, 2.4)
    }
}

private extension Color {
    init(_ components: SRGBColor) {
        self = Color(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
    }

    init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        if hex.count == 6 {
            red = Double((value & 0xFF0000) >> 16) / 255.0
            green = Double((value & 0x00FF00) >> 8) / 255.0
            blue = Double(value & 0x0000FF) / 255.0
            alpha = 1.0
        } else {
            red = Double((value & 0xFF000000) >> 24) / 255.0
            green = Double((value & 0x00FF0000) >> 16) / 255.0
            blue = Double((value & 0x0000FF00) >> 8) / 255.0
            alpha = Double(value & 0x000000FF) / 255.0
        }

        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct IssueBadgeColors {
    let background: Color
    let foreground: Color
    let border: Color
}

extension IssuePriority {
    var badgeColors: IssueBadgeColors {
        switch semantic {
        case .critical:
            return IssueBadgeColors(
                background: Color(hexString: "#FEE2E2") ?? .red.opacity(0.2),
                foreground: Color(hexString: "#991B1B") ?? .red,
                border: Color(hexString: "#FCA5A5") ?? .red.opacity(0.4)
            )
        case .high:
            return IssueBadgeColors(
                background: Color(hexString: "#FFEDD5") ?? .orange.opacity(0.2),
                foreground: Color(hexString: "#9A3412") ?? .orange,
                border: Color(hexString: "#FDBA74") ?? .orange.opacity(0.4)
            )
        case .normal:
            return IssueBadgeColors(
                background: Color(hexString: "#E5E7EB") ?? .gray.opacity(0.2),
                foreground: Color(hexString: "#374151") ?? .secondary,
                border: Color(hexString: "#D1D5DB") ?? .gray.opacity(0.4)
            )
        case .low:
            return IssueBadgeColors(
                background: Color(hexString: "#DBEAFE") ?? .blue.opacity(0.2),
                foreground: Color(hexString: "#1E40AF") ?? .blue,
                border: Color(hexString: "#93C5FD") ?? .blue.opacity(0.4)
            )
        case .custom:
            return IssueBadgeColors(
                background: Color(hexString: "#E5E7EB") ?? .gray.opacity(0.2),
                foreground: Color(hexString: "#374151") ?? .secondary,
                border: Color(hexString: "#D1D5DB") ?? .gray.opacity(0.4)
            )
        }
    }
}

enum IssueStatus: Hashable, Sendable, Codable, CaseIterable, RawRepresentable {
    case open
    case inProgress
    case inReview
    case blocked
    case done
    case custom(String)

    static var allCases: [IssueStatus] {
        [.open, .inProgress, .inReview, .blocked, .done]
    }

    static var fallbackCases: [IssueStatus] {
        allCases
    }

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = IssueStatus.normalizedKey(trimmed)
        if let exact = IssueStatus.exactCategory(for: key) {
            self = exact
        } else {
            self = .custom(trimmed)
        }
    }

    var rawValue: String {
        switch self {
        case .open:
            return "open"
        case .inProgress:
            return "inProgress"
        case .inReview:
            return "inReview"
        case .blocked:
            return "blocked"
        case .done:
            return "done"
        case .custom(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "custom" : trimmed
        }
    }

    static func from(apiName: String?) -> IssueStatus {
        guard let apiName, let status = IssueStatus(rawValue: apiName) else {
            return .open
        }
        return status
    }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .inReview: return "In Review"
        case .blocked: return "Blocked"
        case .done: return "Done"
        case .custom(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }
    }

    var iconName: String {
        switch semantic {
        case .open: return "bolt.circle"
        case .inProgress: return "clock.badge.checkmark"
        case .inReview: return "eye.circle"
        case .blocked: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .custom: return "circle"
        }
    }

    var tint: Color {
        badgeColors.foreground
    }

    var normalizedKey: String {
        IssueStatus.normalizedKey(rawValue)
    }

    var sortRank: Int {
        switch self {
        case .open: return 0
        case .inProgress: return 1
        case .inReview: return 2
        case .blocked: return 3
        case .done: return 4
        case .custom: return 10
        }
    }

    static func deduplicated(_ statuses: [IssueStatus]) -> [IssueStatus] {
        var seen = Set<String>()
        var unique: [IssueStatus] = []
        for status in statuses {
            let key = status.normalizedKey
            if seen.insert(key).inserted {
                unique.append(status)
            }
        }
        return unique
    }

    static func sortedUnique(_ statuses: [IssueStatus]) -> [IssueStatus] {
        let unique = deduplicated(statuses)
        return unique.sorted { left, right in
            if left.sortRank != right.sortRank {
                return left.sortRank < right.sortRank
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    static func == (lhs: IssueStatus, rhs: IssueStatus) -> Bool {
        lhs.normalizedKey == rhs.normalizedKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedKey)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = IssueStatus(rawValue: raw) ?? .custom(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension IssueStatus {
    var badgeColors: IssueBadgeColors {
        switch semantic {
        case .open:
            return IssueBadgeColors(
                background: Color(hexString: "#DBEAFE") ?? .blue.opacity(0.2),
                foreground: Color(hexString: "#1E40AF") ?? .blue,
                border: Color(hexString: "#93C5FD") ?? .blue.opacity(0.4)
            )
        case .inProgress:
            return IssueBadgeColors(
                background: Color(hexString: "#FEF3C7") ?? .orange.opacity(0.2),
                foreground: Color(hexString: "#92400E") ?? .orange,
                border: Color(hexString: "#FCD34D") ?? .orange.opacity(0.4)
            )
        case .inReview:
            return IssueBadgeColors(
                background: Color(hexString: "#CCFBF1") ?? .teal.opacity(0.2),
                foreground: Color(hexString: "#115E59") ?? .teal,
                border: Color(hexString: "#5EEAD4") ?? .teal.opacity(0.4)
            )
        case .blocked:
            return IssueBadgeColors(
                background: Color(hexString: "#FEE2E2") ?? .red.opacity(0.2),
                foreground: Color(hexString: "#991B1B") ?? .red,
                border: Color(hexString: "#FCA5A5") ?? .red.opacity(0.4)
            )
        case .done:
            return IssueBadgeColors(
                background: Color(hexString: "#DCFCE7") ?? .green.opacity(0.2),
                foreground: Color(hexString: "#166534") ?? .green,
                border: Color(hexString: "#86EFAC") ?? .green.opacity(0.4)
            )
        case .custom:
            return IssueBadgeColors(
                background: Color(hexString: "#E5E7EB") ?? .gray.opacity(0.2),
                foreground: Color(hexString: "#374151") ?? .secondary,
                border: Color(hexString: "#D1D5DB") ?? .gray.opacity(0.4)
            )
        }
    }
}

private extension IssueStatus {
    enum Semantic {
        case open
        case inProgress
        case inReview
        case blocked
        case done
        case custom
    }

    static let exactOpenKeys: Set<String> = ["open", "new", "todo", "backlog"]
    static let exactInProgressKeys: Set<String> = ["inprogress", "doing", "implementation"]
    static let exactInReviewKeys: Set<String> = ["inreview", "codereview", "qa", "testing"]
    static let exactBlockedKeys: Set<String> = ["blocked", "onhold", "stuck"]
    static let exactDoneKeys: Set<String> = ["done", "fixed", "resolved", "closed", "completed"]

    static func normalizedKey(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func exactCategory(for key: String) -> IssueStatus? {
        if exactOpenKeys.contains(key) { return .open }
        if exactInProgressKeys.contains(key) { return .inProgress }
        if exactInReviewKeys.contains(key) { return .inReview }
        if exactBlockedKeys.contains(key) { return .blocked }
        if exactDoneKeys.contains(key) { return .done }
        return nil
    }

    static func heuristicCategory(for key: String) -> Semantic {
        if exactOpenKeys.contains(key) { return .open }
        if exactInProgressKeys.contains(key) || key.contains("progress") { return .inProgress }
        if exactInReviewKeys.contains(key) || key.contains("review") || key.contains("qa") || key.contains("test") {
            return .inReview
        }
        if exactBlockedKeys.contains(key) || key.contains("block") || key.contains("hold") || key.contains("stuck") {
            return .blocked
        }
        if exactDoneKeys.contains(key) || key.contains("done") || key.contains("resolve") || key.contains("close") {
            return .done
        }
        return .custom
    }

    var semantic: Semantic {
        switch self {
        case .open: return .open
        case .inProgress: return .inProgress
        case .inReview: return .inReview
        case .blocked: return .blocked
        case .done: return .done
        case .custom(let value):
            return IssueStatus.heuristicCategory(for: IssueStatus.normalizedKey(value))
        }
    }
}

extension IssueStatus {
    init(option: IssueFieldOption) {
        let candidate = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = candidate.isEmpty ? fallback : candidate
        self = IssueStatus(rawValue: resolved) ?? .custom(resolved)
    }
}
