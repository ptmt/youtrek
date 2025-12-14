import SwiftUI

struct SetupWindow: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to YouTrack")
                .font(.title2)
                .bold()

            Text("Enter your YouTrack site URL and a permanent token. The URL syncs via iCloud so reinstalling keeps your setup; the token is stored securely in your keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("https://your-company.youtrack.cloud", text: $baseURLString, prompt: Text("YouTrack base URL"))
                    .textContentType(.URL)

                SecureField("Permanent token", text: $token, prompt: Text("Paste your YouTrack token"))
                    .textContentType(.password)
            }
            .padding(.vertical, 4)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Continue") {
                    persist()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear(perform: preload)
    }

    private var canSubmit: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func preload() {
        let draft = container.storedConfigurationDraft()
        if let baseURL = draft.baseURL {
            baseURLString = baseURL.absoluteString
        }
        if let storedToken = draft.token {
            token = storedToken
        }
    }

    private func persist() {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "Enter a valid YouTrack URL including https://"
            return
        }

        guard !trimmedToken.isEmpty else {
            errorMessage = "Paste a valid YouTrack permanent token."
            return
        }

        errorMessage = nil
        Task { @MainActor in
            await container.completeManualSetup(baseURL: url, token: trimmedToken)
            dismissWindow(id: SceneID.setup.rawValue)
        }
    }
}
