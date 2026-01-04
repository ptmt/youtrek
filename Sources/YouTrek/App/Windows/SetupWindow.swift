import SwiftUI

struct SetupWindow: View {
    @EnvironmentObject private var container: AppContainer

    private enum SignInMode: String, CaseIterable {
        case browser
        case token

        var title: String {
            switch self {
            case .browser: "Sign in with Browser"
            case .token: "Use Personal Token"
            }
        }
    }

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    @State private var mode: SignInMode = .browser
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.accentColor.opacity(0.35), .teal.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360)
                .opacity(0.08)
                .padding()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to YouTrek")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("Sign in to your YouTrack or paste a personal token. Your URL syncs via iCloud; tokens stay in your keychain.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Picker("Sign-in method", selection: $mode) {
                    ForEach(SignInMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://youtrack.jetbrains.com/api", text: $baseURLString, prompt: Text("YouTrack base URL"))
                        .textContentType(.URL)
                        .textFieldStyle(.roundedBorder)

                    if mode == .token {
                        SecureField("Permanent token", text: $token, prompt: Text("Paste your YouTrack token"))
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Label(browserHintText, systemImage: container.browserAuthAvailable ? "globe" : "exclamationmark.triangle.fill")
                            .foregroundStyle(container.browserAuthAvailable ? .secondary : Color.yellow)
                            .font(.callout)
                    }
                }
                .padding()
                .frame(maxWidth: 520)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                }

                HStack {
                    Spacer()
                    Button(action: submit) {
                        Text(actionTitle)
                            .frame(maxWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, maxHeight: 520)
        }
        .onAppear(perform: preload)
    }

    private var canSubmit: Bool {
        let hasURL = !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case .browser:
            return hasURL
        case .token:
            return hasURL && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var actionTitle: String {
        switch mode {
        case .browser: "Sign in with Browser"
        case .token: "Save Token"
        }
    }

    private var browserHintText: String {
        if container.browserAuthAvailable {
            return "We’ll open your default browser to sign in with YouTrack Hub."
        } else {
            return "To enable browser sign-in, set Hub OAuth environment values (YOUTRACK_BASE_URL, YOUTRACK_HUB_AUTHORIZE_URL, YOUTRACK_HUB_TOKEN_URL, YOUTRACK_CLIENT_ID, YOUTRACK_REDIRECT_URI)."
        }
    }

    private func preload() {
        let draft = container.storedConfigurationDraft()
        if let baseURL = draft.baseURL {
            baseURLString = baseURL.absoluteString
        } else if baseURLString.isEmpty {
            baseURLString = "https://youtrack.jetbrains.com/api"
        }
        if let storedToken = draft.token {
            token = storedToken
        }
    }

    private func submit() {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "Enter a valid YouTrack URL including https://"
            return
        }

        errorMessage = nil

        switch mode {
        case .browser:
            guard container.browserAuthAvailable else {
                errorMessage = "Browser sign-in needs Hub OAuth config (YOUTRACK_* environment variables)."
                return
            }
            container.setBaseURL(url)
            container.beginSignIn()
        case .token:
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else {
                errorMessage = "Paste a valid YouTrack permanent token."
                return
            }
            Task { @MainActor in
                await container.completeManualSetup(baseURL: url, token: trimmedToken)
            }
        }
    }
}
