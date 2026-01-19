import SwiftUI

struct SidebarView: View {
    let sections: [SidebarSection]
    @Binding var selection: SidebarItem?
    let isSyncing: Bool
    let syncStatusMessage: String?
    let onDeleteSavedSearch: ((String) -> Void)?

    var body: some View {
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
        .frame(minWidth: 220)
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
        // .toolbar { EditButton() }
    }
}
