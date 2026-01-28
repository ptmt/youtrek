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
    // TODO: Restore the OAuth vs Personal Token switch once browser sign-in is ready to ship.
    @State private var mode: SignInMode = .token
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    @State private var isValidatingToken = false
    @State private var hasStartedSignIn = false
    @FocusState private var focusedField: FocusField?
    private var isPreparingWorkspace: Bool {
        !container.requiresSetup && !container.appState.hasCompletedInitialSync
    }

    private enum FocusField: Hashable {
        case baseURL
        case token
    }

    private var primaryTextColor: Color { .white }
    private var secondaryTextColor: Color { .white.opacity(0.7) }
    private var tertiaryTextColor: Color { .white.opacity(0.5) }
    private var accentColor: Color { Color(red: 0.56, green: 0.84, blue: 1.0) }
    private var inputFillColor: Color { .white.opacity(0.08) }
    private var inputStrokeColor: Color { .white.opacity(0.18) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SetupWindowBackground()
            content
        }
        .frame(minWidth: 480, minHeight: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onAppear(perform: preload)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("YouTrekLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 44)
                .padding(.bottom, 8)
                .accessibilityLabel("YouTrek")

            if isPreparingWorkspace {
                preparingContent
            } else {
                // TODO: Bring back the OAuth vs Personal Token segmented control when browser sign-in is restored.
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://youtrack.jetbrains.com", text: $baseURLString, prompt: Text("YouTrack base URL"))
                        .textContentType(.URL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                        .tint(accentColor)
                        .accessibilityLabel("YouTrack base URL")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .modifier(SetupInputChrome(
                            isFocused: focusedField == .baseURL,
                            fill: inputFillColor,
                            stroke: inputStrokeColor,
                            focus: accentColor.opacity(0.9)
                        ))
                        .focused($focusedField, equals: .baseURL)

                    if mode == .token {
                        ZStack(alignment: .topLeading) {
                            if token.isEmpty {
                                Text("Paste your YouTrack token")
                                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                                    .foregroundStyle(tertiaryTextColor)
                                    .padding(.leading, 5)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $token)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .foregroundStyle(primaryTextColor)
                                .tint(accentColor)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel("YouTrack token")
                                .focused($focusedField, equals: .token)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .frame(minHeight: 72, maxHeight: 100)
                        .modifier(SetupInputChrome(
                            isFocused: focusedField == .token,
                            fill: inputFillColor,
                            stroke: inputStrokeColor,
                            focus: accentColor.opacity(0.9)
                        ))
                        if let tokenPortalURL {
                            Link("How to create a personal token", destination: tokenPortalURL)
                                .font(.callout)
                                .foregroundStyle(accentColor)
                                .underline()
                        }
                    } else {
                        Label(browserHintText, systemImage: container.browserAuthAvailable ? "globe" : "exclamationmark.triangle.fill")
                            .foregroundStyle(container.browserAuthAvailable ? secondaryTextColor : .orange)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)

                Button(action: submit) {
                    Text(actionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(accentColor)
                .padding(.top, 4)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSubmit || isValidatingToken)

                // Status area with fixed height to prevent layout jumps
                VStack(alignment: .leading, spacing: 4) {
                    if shouldShowSetupProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(setupProgressText)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(secondaryTextColor)
                        .accessibilityLabel("Setup progress")
                        SetupNetworkStatusView(monitor: container.networkMonitor)
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .textSelection(.enabled)
                    } else if let warningMessage {
                        Label(warningMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .frame(height: 44, alignment: .top)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 64)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(primaryTextColor)
    }

    private var preparingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preparingTitle)
                .font(.callout).bold()
            Text("YouTrek downloads as much as possible to minimize waiting time for most common tasks.")
                .font(.callout)
                .foregroundStyle(secondaryTextColor)
            if let warningMessage {
                Label(warningMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                initialSyncProgressView
                VStack(alignment: .leading, spacing: 4) {
                    Text(syncStatusText)
                        .font(.callout)
                        .foregroundStyle(secondaryTextColor)
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

        guard let label = baseSyncLabel else {
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

    private var baseSyncLabel: String? {
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

    private struct SyncStepInfo {
        let current: Int
        let completed: Int
        let total: Int
        let isActive: Bool
    }

    private var syncStepInfo: SyncStepInfo {
        let total = 3
        let completed = (container.appState.hasCompletedIssueSync ? 1 : 0)
            + (container.appState.hasCompletedBoardSync ? 1 : 0)
            + (container.appState.hasCompletedSavedSearchSync ? 1 : 0)
        let isActive = isPreparingWorkspace || container.appState.isSyncing || hasStartedSignIn
        let labelStep: Int? = {
            switch baseSyncLabel {
            case "Sync issues": return 1
            case "Sync agile boards": return 2
            case "Sync saved searches": return 3
            default: return nil
            }
        }()

        var current = max(completed, labelStep ?? completed)
        if current == 0, isActive {
            current = 1
        } else if isPreparingWorkspace, completed < total, current == completed {
            current = min(total, completed + 1)
        }
        return SyncStepInfo(current: current, completed: completed, total: total, isActive: isActive)
    }

    private var syncStepSuffix: String? {
        let info = syncStepInfo
        guard info.isActive else { return nil }
        return "(\(info.current)/\(info.total))"
    }

    private var initialSyncProgressView: some View {
        let info = syncStepInfo
        let progress = info.isActive ? Double(info.current) / Double(info.total) : container.appState.initialSyncProgress
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
                    let outcome = await container.completeManualSetup(
                        baseURL: url,
                        token: trimmedToken,
                        userDisplayName: displayName,
                        allowKeychainInteraction: true
                    )
                    if !outcome.saved {
                        let warning = tokenSaveWarningMessage(error: outcome.errorMessage)
                        warningMessage = warning
                        LoggingService.sync.error("Keychain warning: \(warning, privacy: .public)")
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

    private func tokenSaveWarningMessage(error: String?) -> String {
        let detail = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty {
            return "Could not save token to keychain: \(detail). You may need to sign in again after relaunching."
        }
        return "Could not save token to keychain. You may need to sign in again after relaunching."
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
                .foregroundStyle(.white.opacity(0.55))
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

private struct SetupWindowBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.12),
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                    Color(red: 0.02, green: 0.02, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color(red: 0.58, green: 0.82, blue: 1.0).opacity(0.18),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 320
            )
            .blendMode(.screen)
            RadialGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 260
            )
            .blendMode(.screen)
        }
    }
}

private struct SetupInputChrome: ViewModifier {
    let isFocused: Bool
    let fill: Color
    let stroke: Color
    let focus: Color

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? focus : stroke, lineWidth: 1)
            )
    }
}
