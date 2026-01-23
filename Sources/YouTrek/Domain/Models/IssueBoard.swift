import Foundation

struct IssueBoard: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFavorite: Bool
    let projectNames: [String]
    let sprints: [IssueBoardSprint]
    let currentSprintID: String?
    let sprintFieldName: String?
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
        sprints: [IssueBoardSprint] = [],
        currentSprintID: String? = nil,
        sprintFieldName: String? = nil,
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
        self.sprints = sprints
        self.currentSprintID = currentSprintID
        self.sprintFieldName = sprintFieldName
        self.columnFieldName = columnFieldName
        self.columns = columns
        self.swimlaneSettings = swimlaneSettings
        self.orphansAtTheTop = orphansAtTheTop
        self.hideOrphansSwimlane = hideOrphansSwimlane
    }
}

struct IssueBoardSprint: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let start: Date?
    let finish: Date?
    let isArchived: Bool
    let isDefault: Bool

    init(
        id: String,
        name: String,
        start: Date? = nil,
        finish: Date? = nil,
        isArchived: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.finish = finish
        self.isArchived = isArchived
        self.isDefault = isDefault
    }
}

enum BoardSprintFilter: Hashable, Sendable {
    case backlog
    case sprint(id: String)

    var sprintID: String? {
        switch self {
        case .backlog:
            return nil
        case .sprint(let id):
            return id
        }
    }

    var isBacklog: Bool {
        if case .backlog = self { return true }
        return false
    }
}

extension IssueBoard {
    var activeSprints: [IssueBoardSprint] {
        sprints.filter { !$0.isArchived }
    }

    var displaySprints: [IssueBoardSprint] {
        let active = activeSprints
        guard let currentSprintID,
              let current = active.first(where: { $0.id == currentSprintID })
        else {
            return active
        }
        let remaining = active.filter { $0.id != current.id }
        return [current] + remaining
    }

    var defaultSprintFilter: BoardSprintFilter {
        if let currentSprintID,
           let current = activeSprints.first(where: { $0.id == currentSprintID }),
           !current.isArchived {
            return .sprint(id: currentSprintID)
        }
        if let defaultSprint = activeSprints.first(where: { $0.isDefault }) {
            return .sprint(id: defaultSprint.id)
        }
        if let first = activeSprints.first {
            return .sprint(id: first.id)
        }
        return .backlog
    }

    func sprintName(for filter: BoardSprintFilter) -> String? {
        guard let id = filter.sprintID else { return nil }
        return sprints.first(where: { $0.id == id })?.name
    }

    func resolveSprintFilter(_ filter: BoardSprintFilter) -> BoardSprintFilter {
        switch filter {
        case .backlog:
            return .backlog
        case .sprint(let id):
            return sprints.contains(where: { $0.id == id }) ? filter : defaultSprintFilter
        }
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
