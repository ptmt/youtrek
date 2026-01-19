import Foundation
import SwiftUI

struct SidebarItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case inbox
        case assignedToMe
        case createdByMe
        case board
        case savedSearch
    }

    let id: String
    let kind: Kind
    let title: String
    let iconName: String
    let query: IssueQuery

    var displayTitle: LocalizedStringKey { LocalizedStringKey(title) }

    var isInbox: Bool { kind == .inbox }
    var isBoard: Bool { kind == .board }
    var isSavedSearch: Bool { kind == .savedSearch }
    var savedQueryID: String? {
        guard isSavedSearch, id.hasPrefix("saved:") else { return nil }
        return String(id.dropFirst("saved:".count))
    }
    var boardID: String? {
        guard isBoard, id.hasPrefix("board:") else { return nil }
        return String(id.dropFirst("board:".count))
    }
}

struct SidebarSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [SidebarItem]
    let emptyMessage: String?

    init(id: String, title: String, items: [SidebarItem], emptyMessage: String? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.emptyMessage = emptyMessage
    }
}

extension SidebarItem {
    static func inbox(page: IssueQuery.Page) -> SidebarItem {
        SidebarItem(
            id: "smart:inbox",
            kind: .inbox,
            title: "Inbox",
            iconName: "tray.fill",
            query: IssueQuery(
                rawQuery: nil,
                search: "",
                filters: ["for: me", "#Unresolved"],
                sort: .updated(descending: true),
                page: page
            )
        )
    }

    static func assignedToMe(page: IssueQuery.Page) -> SidebarItem {
        SidebarItem(
            id: "smart:assigned",
            kind: .assignedToMe,
            title: "Assigned to Me",
            iconName: "person.crop.circle.fill.badge.checkmark",
            query: IssueQuery(
                rawQuery: nil,
                search: "",
                filters: ["assignee: me"],
                sort: .updated(descending: true),
                page: page
            )
        )
    }

    static func createdByMe(page: IssueQuery.Page) -> SidebarItem {
        SidebarItem(
            id: "smart:created",
            kind: .createdByMe,
            title: "Created by Me",
            iconName: "person.crop.circle.badge.plus",
            query: IssueQuery(
                rawQuery: nil,
                search: "",
                filters: ["reporter: me"],
                sort: .updated(descending: true),
                page: page
            )
        )
    }

    static func savedSearch(_ savedQuery: SavedQuery, page: IssueQuery.Page) -> SidebarItem {
        SidebarItem(
            id: "saved:\(savedQuery.id)",
            kind: .savedSearch,
            title: savedQuery.name,
            iconName: "sparkle.magnifyingglass",
            query: IssueQuery.saved(savedQuery.query, page: page)
        )
    }

    static func board(_ board: IssueBoard, page: IssueQuery.Page) -> SidebarItem {
        SidebarItem(
            id: "board:\(board.id)",
            kind: .board,
            title: board.name,
            iconName: "rectangle.3.group.fill",
            query: IssueQuery(
                rawQuery: boardQuery(for: board.name),
                search: "",
                filters: [],
                sort: .updated(descending: true),
                page: page
            )
        )
    }

    private static func boardQuery(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        return "Board: \"\(escaped)\""
    }
}
