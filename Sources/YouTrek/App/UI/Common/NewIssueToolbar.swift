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
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
            Button(action: createDraft) {
                Label("Create Issue", systemImage: "plus.circle.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .help("Quickly capture a new issue from anywhere in the app")
    }

    private func createDraft() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        container.issueComposer.beginNewIssue(withTitle: trimmed)
        draftTitle = ""
    }
}
