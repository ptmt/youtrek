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
                .toolbarFieldStyle()
                .frame(minWidth: 200)
                .submitLabel(.done)
                .onSubmit {
                    createDraft()
                }
                .help("Quickly capture a new issue from anywhere in the app")
            Button(action: createDraft) {
                Label("Create Issue", systemImage: "plus.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.accessoryBar)
            .help("Create a new issue")
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func createDraft() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        container.beginNewIssue(withTitle: trimmed)
        draftTitle = ""
    }
}

private enum ToolbarFieldStyleTokens {
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let strokeOpacity: Double = 0.6
}

private struct ToolbarFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, ToolbarFieldStyleTokens.horizontalPadding)
            .padding(.vertical, ToolbarFieldStyleTokens.verticalPadding)
//            .background(
//                .bar,
//                in: RoundedRectangle(cornerRadius: ToolbarFieldStyleTokens.cornerRadius, style: .continuous)
//            )
//            .overlay(
//                RoundedRectangle(cornerRadius: ToolbarFieldStyleTokens.cornerRadius, style: .continuous)
//                    .stroke(.separator.opacity(ToolbarFieldStyleTokens.strokeOpacity), lineWidth: 1)
//            )
    }
}

extension View {
    func toolbarFieldStyle() -> some View {
        modifier(ToolbarFieldStyle())
    }
}
