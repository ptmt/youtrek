import Foundation

enum CLIInstaller {
    static let defaultInstallPath = "/usr/local/bin/youtrek"
    static let fallbackInstallPaths = [
        "~/.local/bin/youtrek",
        "~/bin/youtrek"
    ]

    static func installSymlink(at path: URL, force: Bool) throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw CLIInstallerError.missingExecutable
        }

        let fileManager = FileManager.default
        let destinationPath = path.path

        do {
            if fileManager.fileExists(atPath: destinationPath) {
                if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: destinationPath),
                   existingDestination == executableURL.path {
                    return "CLI alias already installed at \(destinationPath)"
                }
                if !force {
                    throw CLIInstallerError.pathExists(destinationPath)
                }
                try fileManager.removeItem(atPath: destinationPath)
            }

            let parent = path.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            try fileManager.createSymbolicLink(atPath: destinationPath, withDestinationPath: executableURL.path)
            return "Installed CLI alias at \(destinationPath) -> \(executableURL.path)"
        } catch {
            throw mapPermissionError(error, path: destinationPath)
        }
    }

    static func installDefault(force: Bool) throws -> String {
        do {
            return try installSymlink(at: resolveInstallURL(defaultInstallPath), force: force)
        } catch {
            if isPermissionDenied(error) {
                return try installFallback(force: force)
            }
            throw error
        }
    }

    static func resolveInstallURL(_ path: String) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath)
    }

    private static func installFallback(force: Bool) throws -> String {
        var lastError: Error?
        for fallback in fallbackInstallPaths {
            do {
                let url = resolveInstallURL(fallback)
                let message = try installSymlink(at: url, force: force)
                let directory = url.deletingLastPathComponent().path
                return "\(message)\nNote: ensure \(directory) is on your PATH."
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CLIInstallerError.permissionDenied(defaultInstallPath)
    }

    private static func mapPermissionError(_ error: Error, path: String) -> Error {
        if isPermissionDenied(error) {
            return CLIInstallerError.permissionDenied(path)
        }
        return error
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        if case CLIInstallerError.permissionDenied = error {
            return true
        }
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileWriteNoPermission {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)),
           code == .EACCES || code == .EPERM {
            return true
        }
        return false
    }
}

enum CLIInstallerError: LocalizedError {
    case missingExecutable
    case pathExists(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Unable to locate the app executable."
        case .pathExists(let path):
            return "\(path) already exists. Re-run with --force to replace it."
        case .permissionDenied(let path):
            return "Not allowed to write to \(path).\nTry: youtrek install-cli --path ~/.local/bin/youtrek"
        }
    }
}
