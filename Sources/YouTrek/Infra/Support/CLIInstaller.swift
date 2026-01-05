import Foundation

enum CLIInstaller {
    static let defaultInstallPath = "/usr/local/bin/youtrek"

    static func installSymlink(at path: URL, force: Bool) throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw CLIInstallerError.missingExecutable
        }

        let fileManager = FileManager.default
        let destinationPath = path.path

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
    }
}

enum CLIInstallerError: LocalizedError {
    case missingExecutable
    case pathExists(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Unable to locate the app executable."
        case .pathExists(let path):
            return "\(path) already exists. Re-run with --force to replace it."
        }
    }
}
