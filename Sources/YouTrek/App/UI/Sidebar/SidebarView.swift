import SwiftUI
import AppKit

struct SidebarView: View {
    let sections: [SidebarSection]
    @Binding var selection: SidebarItem?
    let isSyncing: Bool
    let syncStatusMessage: String?
    let onDeleteSavedSearch: ((String) -> Void)?
    let onRefreshBoard: ((SidebarItem) -> Void)?
    let onOpenBoardInWeb: ((SidebarItem) -> Void)?
    let boardSyncStatus: ((SidebarItem) -> String?)?
    let onCreateTodoList: (() -> Void)?
    let onRenameTodoList: ((SidebarItem) -> Void)?
    let onDeleteTodoList: ((SidebarItem) -> Void)?
    let onToggleSidebar: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(.container, edges: .top)
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section {
                        if section.items.isEmpty {
                            if let emptyMessage = section.emptyMessage {
                                if section.id == "todo" {
                                    Button(action: { onCreateTodoList?() }) {
                                        Label(emptyMessage, systemImage: "plus.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text(emptyMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .disabled(true)
                                }
                            }
                        } else {
                            ForEach(section.items) { item in
                                if let savedQueryID = item.savedQueryID {
                                    NavigationLink(value: item) {
                                        Label(item.displayTitle, systemImage: item.iconName)
                                    }
                                    .contextMenu {
                                        Button("Delete Saved Search", role: .destructive) {
                                            onDeleteSavedSearch?(savedQueryID)
                                        }
                                    }
                                } else if item.isBoard {
                                    NavigationLink(value: item) {
                                        Label(item.displayTitle, systemImage: item.iconName)
                                    }
                                    .contextMenu {
                                        Button("Refresh") {
                                            onRefreshBoard?(item)
                                        }
                                        Button("Open in Web") {
                                            onOpenBoardInWeb?(item)
                                        }
                                        if let status = boardSyncStatus?(item) {
                                            Divider()
                                            Text("Last synced: \(status)")
                                                .disabled(true)
                                        }
                                    }
                                } else if item.isTodoList {
                                    NavigationLink(value: item) {
                                        Label(item.displayTitle, systemImage: item.iconName)
                                    }
                                    .contextMenu {
                                        Button("Rename") {
                                            onRenameTodoList?(item)
                                        }
                                        Button("Delete", role: .destructive) {
                                            onDeleteTodoList?(item)
                                        }
                                    }
                                } else {
                                    NavigationLink(value: item) {
                                        Label(item.displayTitle, systemImage: item.iconName)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(section.title)
                            Spacer()
                            if section.id == "todo" {
                                Button(action: { onCreateTodoList?() }) {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.plain)
                                .help("Create todo list")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220, maxHeight: .infinity)
        .padding(.bottom, 28)
        .overlay(alignment: .bottomLeading) {
            if isSyncing {
                SyncStatusIndicator(label: syncStatusMessage)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Sync status")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { onToggleSidebar?() }) {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.accessoryBar)
                .help("Toggle sidebar")
            }
        }
        // .toolbar { EditButton() }
    }
}
