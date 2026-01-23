import Foundation

protocol IssueFieldRepository: Sendable {
    func fetchFields(projectID: String) async throws -> [IssueField]
    func fetchBundleOptions(bundleID: String, kind: IssueFieldKind) async throws -> [IssueFieldOption]
}
