import SwiftUI

struct SidebarView: View {
    let sections: [SidebarSection]
    @Binding var selection: SidebarItem?
    let onDeleteSavedSearch: ((String) -> Void)?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section(section.title) {
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
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        // .toolbar { EditButton() }
    }
}
