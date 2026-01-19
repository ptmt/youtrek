import SwiftUI

struct NewIssueToolbar: View {
    @ObservedObject private var container: AppContainer
    @State private var draftTitle: String = ""

    init(container: AppContainer) {
        self._container = ObservedObject(initialValue: container)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("New issue title", text: $draftTitle, onCommit: createDraft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: 200)
            Button(action: createDraft) {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .help("Quickly capture a new issue from anywhere in the app")
    }

    private func createDraft() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        container.beginNewIssue(withTitle: trimmed)
        draftTitle = ""
    }
}
