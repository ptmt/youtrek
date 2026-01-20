import Foundation

struct IssueBoard: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFavorite: Bool
    let projectNames: [String]
    let columnFieldName: String?
    let columns: [IssueBoardColumn]
    let swimlaneSettings: IssueBoardSwimlaneSettings
    let orphansAtTheTop: Bool
    let hideOrphansSwimlane: Bool

    init(
        id: String,
        name: String,
        isFavorite: Bool,
        projectNames: [String],
        columnFieldName: String? = nil,
        columns: [IssueBoardColumn] = [],
        swimlaneSettings: IssueBoardSwimlaneSettings = .disabled,
        orphansAtTheTop: Bool = false,
        hideOrphansSwimlane: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isFavorite = isFavorite
        self.projectNames = projectNames
        self.columnFieldName = columnFieldName
        self.columns = columns
        self.swimlaneSettings = swimlaneSettings
        self.orphansAtTheTop = orphansAtTheTop
        self.hideOrphansSwimlane = hideOrphansSwimlane
    }
}

struct IssueBoardColumn: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let valueNames: [String]
    let isResolved: Bool
    let ordinal: Int?
    let parentID: String?

    init(
        id: String,
        title: String,
        valueNames: [String],
        isResolved: Bool = false,
        ordinal: Int? = nil,
        parentID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.valueNames = valueNames
        self.isResolved = isResolved
        self.ordinal = ordinal
        self.parentID = parentID
    }
}

struct IssueBoardSwimlaneSettings: Hashable, Sendable, Codable {
    enum Kind: String, Codable, Hashable, Sendable {
        case none
        case attribute
        case issue
    }

    let kind: Kind
    let isEnabled: Bool
    let fieldName: String?
    let values: [String]

    static let disabled = IssueBoardSwimlaneSettings(kind: .none, isEnabled: false, fieldName: nil, values: [])
}

extension IssueBoardSwimlaneSettings.Kind {
    init(from typeName: String?) {
        guard let typeName else {
            self = .none
            return
        }
        let normalized = typeName.lowercased()
        if normalized.contains("attributebased") {
            self = .attribute
        } else if normalized.contains("issuebased") {
            self = .issue
        } else {
            self = .none
        }
    }
}
