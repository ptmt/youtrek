import AppKit
import SwiftUI

struct ConflictResolutionDialog: View {
    let conflict: ConflictNotice
    @Environment(\.dismiss) private var dismiss
    @State private var localChanges: String

    init(conflict: ConflictNotice) {
        self.conflict = conflict
        _localChanges = State(initialValue: conflict.localChanges)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(conflict.title)
                .font(.title2.weight(.semibold))

            Text(conflict.message)
                .foregroundStyle(.secondary)

            Text("Your local changes")
                .font(.headline)

            TextEditor(text: $localChanges)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 1)
                )

            HStack {
                Button("Copy Changes") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(localChanges, forType: .string)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
    }
}
