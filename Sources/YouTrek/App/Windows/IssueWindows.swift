import SwiftUI

struct IssueDetailWindow: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        if let issue = container.appState.selectedIssue {
            IssueDetailView(issue: issue)
        } else {
            ContentUnavailableView(
                "No issue selected",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("Select an issue to open its dedicated window.")
            )
            .frame(minWidth: 480, minHeight: 400)
        }
    }
}

struct NewIssueWindow: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Form {
            TextField("Title", text: $container.issueComposer.draftTitle)
            TextField("Description", text: $container.issueComposer.draftDescription, axis: .vertical)
                .lineLimit(5...10)
            Button("Submit Issue") {
                submit()
            }
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
    }

    private func submit() {
        guard !container.issueComposer.draftTitle.isEmpty else { return }
        Task { @MainActor in
            container.issueComposer.submitDraft()
            dismissWindow(id: SceneID.newIssue.rawValue)
        }
    }
}
