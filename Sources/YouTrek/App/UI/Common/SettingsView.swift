import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .dark

    var body: some View {
        Form {
            Section("Account") {
                Button("Sign in to YouTrack") {
                    container.beginSignIn()
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

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
