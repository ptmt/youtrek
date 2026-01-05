import SwiftUI

struct SidebarView: View {
    let sections: [SidebarSection]
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        NavigationLink(value: item) {
                            Label(item.displayTitle, systemImage: item.iconName)
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
