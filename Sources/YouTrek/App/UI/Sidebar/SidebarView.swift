import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject private var container: AppContainer
    let sections: [SidebarSection]
    @Binding var selection: SidebarItem?
    let isSyncing: Bool
    let syncStatusMessage: String?
    let onDeleteSavedSearch: ((String) -> Void)?
    let onRefreshBoard: ((SidebarItem) -> Void)?
    let onOpenBoardInWeb: ((SidebarItem) -> Void)?
    let boardSyncStatus: ((SidebarItem) -> String?)?
    let onToggleSidebar: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(.container, edges: .top)
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        if section.items.isEmpty {
                            if let emptyMessage = section.emptyMessage {
                                Text(emptyMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .disabled(true)
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
                                } else {
                                    NavigationLink(value: item) {
                                        Label(item.displayTitle, systemImage: item.iconName)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                accountHeader
            }
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

    private var accountHeader: some View {
        VStack(spacing: 0) {
            accountSwitcher
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
        }
        .background(.ultraThinMaterial)
    }

    private var accountSwitcher: some View {
        Menu {
            if container.accounts.isEmpty {
                Text("No accounts")
                    .foregroundStyle(.secondary)
                    .disabled(true)
            } else {
                ForEach(container.accounts) { account in
                    Button {
                        Task { await container.switchAccount(to: account.id) }
                    } label: {
                        HStack {
                            Text(account.displayTitle)
                            Spacer(minLength: 0)
                            if account.id == container.activeAccountID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Add Account…") {
                container.startAddingAccount()
            }
        } label: {
            HStack(spacing: 8) {
                UserAvatarView(person: activePerson, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle = activeSubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityLabel("Account menu")
    }

    private var activeTitle: String {
        container.activeAccount?.displayTitle ?? "Add account"
    }

    private var activeSubtitle: String? {
        container.activeAccount?.subtitle
    }

    private var activePerson: Person? {
        guard let account = container.activeAccount else { return nil }
        return Person(
            id: Person.stableID(for: account.id.uuidString),
            displayName: account.displayTitle,
            avatarURL: nil,
            login: account.login,
            remoteID: account.userID
        )
    }
}
