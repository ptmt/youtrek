import SwiftUI

struct NewIssueToolbar: View {
    @ObservedObject private var container: AppContainer
    @State private var draftTitle: String = ""

    init(container: AppContainer) {
        self._container = ObservedObject(initialValue: container)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("New issue...", text: $draftTitle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.separator.opacity(0.6), lineWidth: 1)
                )
                .frame(minWidth: 200)
                .submitLabel(.done)
                .onSubmit {
                    createDraft()
                }
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
