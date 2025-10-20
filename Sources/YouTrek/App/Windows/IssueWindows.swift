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
            TextField("Title", text: draftTitleBinding)
            TextField("Description", text: draftDescriptionBinding, axis: .vertical)
                .lineLimit(5...10)
            Button("Submit Issue") {
                submit()
            }
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
    }

    private var draftTitleBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftTitle },
            set: { container.issueComposer.draftTitle = $0 }
        )
    }

    private var draftDescriptionBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftDescription },
            set: { container.issueComposer.draftDescription = $0 }
        )
    }

    private func submit() {
        guard !container.issueComposer.draftTitle.isEmpty else { return }
        Task { @MainActor in
            container.issueComposer.submitDraft()
            dismissWindow(id: SceneID.newIssue.rawValue)
        }
    }
}
