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
            TextField("Project", text: draftProjectBinding, prompt: Text("Project ID or short name"))
            TextField("Module", text: draftModuleBinding, prompt: Text("Subsystem or component"))
            TextField("Assignee", text: draftAssigneeBinding, prompt: Text("Username or user ID"))
            Picker("Priority", selection: draftPriorityBinding) {
                ForEach(IssuePriority.allCases, id: \.self) { priority in
                    Text(priority.displayName).tag(priority)
                }
            }
            TextField("Description", text: draftDescriptionBinding, axis: .vertical)
                .lineLimit(5...10)
            Button("Create") {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!container.issueComposer.canSubmit)
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

    private var draftProjectBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftProjectID },
            set: { container.issueComposer.draftProjectID = $0 }
        )
    }

    private var draftModuleBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftModule },
            set: { container.issueComposer.draftModule = $0 }
        )
    }

    private var draftAssigneeBinding: Binding<String> {
        Binding(
            get: { container.issueComposer.draftAssigneeID },
            set: { container.issueComposer.draftAssigneeID = $0 }
        )
    }

    private var draftPriorityBinding: Binding<IssuePriority> {
        Binding(
            get: { container.issueComposer.draftPriority },
            set: { container.issueComposer.draftPriority = $0 }
        )
    }

    private func submit() {
        Task { @MainActor in
            container.submitIssueDraft()
            dismissWindow(id: SceneID.newIssue.rawValue)
        }
    }
}
