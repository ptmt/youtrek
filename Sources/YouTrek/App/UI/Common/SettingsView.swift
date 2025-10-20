import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Form {
            Section("Account") {
                Button("Sign in to YouTrack") {
                    // Placeholder until auth module is wired.
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            Section("Appearance") {
                Toggle("Use vibrancy", isOn: .constant(true))
                    .disabled(true)
                Toggle("High contrast", isOn: .constant(false))
                    .disabled(true)
            }

            Section("Data") {
                Button("Refresh now") {
                    // placeholder for future sync trigger
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
    }
}
