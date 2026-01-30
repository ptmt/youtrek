import SwiftUI

struct NewIssueToolbar: View {
    @ObservedObject private var container: AppContainer
    @State private var draftTitle: String = ""

    init(container: AppContainer) {
        self._container = ObservedObject(initialValue: container)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("New issue title", text: $draftTitle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: 200)
                .submitLabel(.done)
                .onSubmit {
                    openDialog()
                }
            Button(action: openDialog) {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("n", modifiers: [.command])
        }
        .help("Create a new issue (Cmd+N)")
    }

    private func openDialog() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        container.presentNewIssueDialog(title: trimmed)
        draftTitle = ""
    }
}
