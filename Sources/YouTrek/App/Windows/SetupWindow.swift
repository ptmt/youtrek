import AppKit
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
    @State private var mode: SignInMode = .token
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    @State private var isValidatingToken = false
    @State private var hasStartedSignIn = false
    private var isPreparingWorkspace: Bool {
        !container.requiresSetup && !container.appState.hasCompletedInitialSync
    }

    var body: some View {
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
            }

            if isPreparingWorkspace {
                preparingContent
            } else {
                Picker("", selection: $mode) {
                    ForEach(SignInMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://youtrack.jetbrains.com", text: $baseURLString, prompt: Text("YouTrack base URL"))
                        .textContentType(.URL)
                        .textFieldStyle(.roundedBorder)

                    if mode == .token {
                        TextField("Permanent token", text: $token, prompt: Text("Paste your YouTrack token"))
                            .textFieldStyle(.roundedBorder)
                        if let tokenPortalURL {
                            Link("How to create a personal token", destination: tokenPortalURL)
                                .font(.callout)
                                .underline()
                        }
                    } else {
                        Label(browserHintText, systemImage: container.browserAuthAvailable ? "globe" : "exclamationmark.triangle.fill")
                            .foregroundColor(container.browserAuthAvailable ? .secondary : .orange)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)

                if shouldShowSetupProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(setupProgressText)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Setup progress")
                        SetupNetworkStatusView(monitor: container.networkMonitor)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                if let warningMessage {
                    Label(warningMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button(action: submit) {
                        Text(actionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit || isValidatingToken)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassBackgroundModifier())
        .ignoresSafeArea()
        .onAppear(perform: preload)
    }

    private var preparingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preparingTitle)
                .font(.system(size: 24, weight: .semibold))
            Text("YouTrek downloads as much as possible to minimize waiting time for most common tasks.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let warningMessage {
                Label(warningMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                initialSyncProgressView
                VStack(alignment: .leading, spacing: 4) {
                    Text(syncStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SetupNetworkStatusView(monitor: container.networkMonitor)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancelInitialSync)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var shouldShowSetupProgress: Bool {
        isValidatingToken || hasStartedSignIn || container.appState.isSyncing
    }

    private var setupProgressText: String {
        if isValidatingToken {
            return "Validating token..."
        }
        return syncStatusText
    }

    private var actionTitle: String {
        switch mode {
        case .browser: "Sign in with Browser"
        case .token: "Sign In"
        }
    }

    private var preparingTitle: String {
        if let name = container.appState.currentUserDisplayName {
            return "Hey \(name), we are preparing your workspace"
        }
        return "Hey there, we are preparing your workspace"
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
            // Strip /api suffix for display
            var displayURL = baseURL
            if displayURL.lastPathComponent.lowercased() == "api" {
                displayURL.deleteLastPathComponent()
            }
            baseURLString = displayURL.absoluteString
        }
        if let storedToken = draft.token {
            token = storedToken
        }
    }

    private var syncStatusText: String {
        if container.requiresSetup {
            if hasStartedSignIn {
                if mode == .browser {
                    return "Waiting for browser sign-in..."
                }
                return "Signing in..."
            }
            return "Connecting to YouTrack..."
        }

        guard let label = resolvedSyncLabel else {
            return "Preparing your workspace..."
        }
        let base: String
        switch label {
        case "Sync issues":
            base = "Fetching issues..."
        case "Sync agile boards":
            base = "Fetching issue boards..."
        case "Sync saved searches":
            base = "Fetching saved searches..."
        case "Sync issue details":
            base = "Fetching issue details..."
        default:
            if label.lowercased().hasPrefix("sync ") {
                let trimmed = label.dropFirst(5).lowercased()
                base = "Fetching \(trimmed)..."
            } else {
                base = label
            }
        }
        if let suffix = syncStepSuffix {
            return "\(base) \(suffix)"
        }
        return base
    }

    private var resolvedSyncLabel: String? {
        if let label = container.appState.syncStatusMessage {
            if isPreparingWorkspace {
                switch label {
                case "Sync issues" where container.appState.hasCompletedIssueSync:
                    break
                case "Sync agile boards" where container.appState.hasCompletedBoardSync:
                    break
                case "Sync saved searches" where container.appState.hasCompletedSavedSearchSync:
                    break
                default:
                    return label
                }
            } else {
                return label
            }
        }
        if AppDebugSettings.disableSyncing {
            return "Syncing disabled"
        }
        guard isPreparingWorkspace || hasStartedSignIn || container.appState.isSyncing else {
            return nil
        }
        if !container.appState.hasCompletedIssueSync {
            return "Sync issues"
        }
        if !container.appState.hasCompletedBoardSync {
            return "Sync agile boards"
        }
        if !container.appState.hasCompletedSavedSearchSync {
            return "Sync saved searches"
        }
        return nil
    }

    private var syncStepSuffix: String? {
        guard isPreparingWorkspace || container.appState.isSyncing else { return nil }
        let total = 3
        let completed = (container.appState.hasCompletedIssueSync ? 1 : 0)
            + (container.appState.hasCompletedBoardSync ? 1 : 0)
            + (container.appState.hasCompletedSavedSearchSync ? 1 : 0)
        return "(\(completed)/\(total))"
    }

    private var initialSyncProgressView: some View {
        let progress = container.appState.initialSyncProgress
        let view = Group {
            if progress > 0 {
                ProgressView(value: progress)
            } else {
                ProgressView()
            }
        }
        return view
            .progressViewStyle(.linear)
            .animation(.easeInOut(duration: 0.35), value: progress)
    }

    private func submit() {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "Enter a valid YouTrack URL including https://"
            hasStartedSignIn = false
            return
        }

        errorMessage = nil
        warningMessage = nil

        switch mode {
        case .browser:
            guard container.browserAuthAvailable else {
                errorMessage = "Browser sign-in needs YOUTRACK_CLIENT_ID in the environment."
                hasStartedSignIn = false
                return
            }
            hasStartedSignIn = true
            container.setBaseURL(url)
            container.beginSignIn()
        case .token:
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else {
                errorMessage = "Paste a valid YouTrack permanent token."
                hasStartedSignIn = false
                return
            }
            hasStartedSignIn = true
            Task { @MainActor in
                isValidatingToken = true
                defer { isValidatingToken = false }
                do {
                    let displayName = try await container.validateManualToken(baseURL: url, token: trimmedToken)
                    let tokenSaved = await container.completeManualSetup(
                        baseURL: url,
                        token: trimmedToken,
                        userDisplayName: displayName
                    )
                    if !tokenSaved {
                        warningMessage = "We couldn’t save your token to the keychain. You’ll need to sign in again after relaunching."
                    }
                } catch {
                    errorMessage = validationErrorMessage(for: error)
                    hasStartedSignIn = false
                }
            }
        }
    }

    private func validationErrorMessage(for error: Error) -> String {
        if let apiError = error as? YouTrackAPIError {
            switch apiError {
            case .http(let statusCode, _):
                if statusCode == 401 || statusCode == 403 {
                    return "Token was rejected by YouTrack. Make sure it is a permanent token with access to this instance."
                }
            default:
                break
            }
            return apiError.localizedDescription
        }
        return "Token validation failed: \(error.localizedDescription)"
    }

    private func cancelInitialSync() {
        Task { @MainActor in
            await container.cancelInitialSync()
            hasStartedSignIn = false
        }
    }
}

private struct SetupNetworkStatusView: View {
    @ObservedObject var monitor: NetworkRequestMonitor

    var body: some View {
        if let text = statusText {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var statusText: String? {
        guard let entry = monitor.entries.first else { return nil }
        let verb = entry.method
        let endpoint = entry.endpoint
        if entry.isPending {
            return "Request: \(verb) \(endpoint)"
        }
        return "Last request: \(verb) \(endpoint)"
    }
}

private struct GlassBackgroundModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffectBackground())
                .clipShape(shape)
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
