import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.iconName)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        // .toolbar { EditButton() }
    }
}
