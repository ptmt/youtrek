import SwiftUI
import AppKit

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
            VisualEffectBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Text("YOU")
                            .font(.system(size: 36, weight: .black))
                            .italic()
                        Text(" ")
                        Text("TREK")
                            .font(.system(size: 36, weight: .black))
                            .italic()
                    }
                    .tracking(2)
                    Text("Sign in to your YouTrack or paste a personal token. Your URL syncs via iCloud; tokens stay in your keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Picker("", selection: $mode) {
                    ForEach(SignInMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://youtrack.jetbrains.com/api", text: $baseURLString, prompt: Text("YouTrack base URL"))
                        .textContentType(.URL)
                        .textFieldStyle(.roundedBorder)

                    if mode == .token {
                        SecureField("Permanent token", text: $token, prompt: Text("Paste your YouTrack token"))
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder)
                        if let tokenPortalURL {
                            Link("Create a personal token", destination: tokenPortalURL)
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .underline()
                        }
                    } else {
                        Label(browserHintText, systemImage: container.browserAuthAvailable ? "globe" : "exclamationmark.triangle.fill")
                            .foregroundStyle(container.browserAuthAvailable ? .secondary : Color.yellow)
                            .font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
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
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit)
                }
            }
            .padding(24)
            .frame(width: 480, height: 340)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        case .token: "Sign In"
        }
    }

    private var browserHintText: String {
        if container.browserAuthAvailable {
            return "We’ll open your default browser to sign in with YouTrack Hub."
        } else {
            return "To enable browser sign-in, set YOUTRACK_CLIENT_ID (and YOUTRACK_BASE_URL if you are not using the default YouTrack instance). Register youtrek://oauth_callback in Hub, or set YOUTRACK_REDIRECT_URI to your custom redirect."
        }
    }

    private var tokenPortalURL: URL? {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiURL = URL(string: trimmedURL), apiURL.scheme?.hasPrefix("http") == true else {
            return nil
        }
        var uiBase = apiURL
        if uiBase.lastPathComponent.lowercased() == "api" {
            uiBase.deleteLastPathComponent()
        }
        uiBase.appendPathComponent("users")
        uiBase.appendPathComponent("me")
        var components = URLComponents(url: uiBase, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "tab", value: "account-security")]
        return components?.url
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
                errorMessage = "Browser sign-in needs YOUTRACK_CLIENT_ID in the environment."
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

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
