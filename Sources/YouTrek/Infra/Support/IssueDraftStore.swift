import Foundation

struct IssueDraftRecord: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case pending
        case submitted
        case failed
    }

    let id: UUID
    var draft: IssueDraft
    var status: Status
    let createdAt: Date
    var submittedAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        draft: IssueDraft,
        status: Status = .pending,
        createdAt: Date = Date(),
        submittedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.draft = draft
        self.status = status
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        self.lastError = lastError
    }
}

actor IssueDraftStore {
    private enum Keys {
        static let drafts = "com.potomushto.youtrek.issue-drafts"
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder
    }

    func saveDraft(_ draft: IssueDraft) -> IssueDraftRecord {
        var records = loadRecords()
        let record = IssueDraftRecord(draft: draft)
        records.append(record)
        persist(records)
        return record
    }

    func loadDraftRecords(statuses: [IssueDraftRecord.Status]? = nil) -> [IssueDraftRecord] {
        let records = loadRecords()
        guard let statuses else { return records }
        let allowed = Set(statuses)
        return records.filter { allowed.contains($0.status) }
    }

    @discardableResult
    func markDraftSubmitted(id: UUID) -> IssueDraftRecord? {
        updateRecord(id: id, status: .submitted, error: nil)
    }

    @discardableResult
    func markDraftFailed(id: UUID, errorDescription: String?) -> IssueDraftRecord? {
        updateRecord(id: id, status: .failed, error: errorDescription)
    }

    func latestSubmittedDraft() -> IssueDraft? {
        loadRecords()
            .filter { $0.status == .submitted }
            .sorted { ($0.submittedAt ?? .distantPast) > ($1.submittedAt ?? .distantPast) }
            .first?
            .draft
    }

    @discardableResult
    func updateDraft(id: UUID, draft: IssueDraft) -> IssueDraftRecord? {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        records[index].draft = draft
        persist(records)
        return records[index]
    }

    func deleteDraft(id: UUID) {
        var records = loadRecords()
        records.removeAll { $0.id == id }
        persist(records)
    }

    private func updateRecord(id: UUID, status: IssueDraftRecord.Status, error: String?) -> IssueDraftRecord? {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        records[index].status = status
        records[index].submittedAt = status == .submitted ? Date() : records[index].submittedAt
        records[index].lastError = error
        persist(records)
        return records[index]
    }

    private func loadRecords() -> [IssueDraftRecord] {
        guard let data = defaults.data(forKey: Keys.drafts) else { return [] }
        return (try? decoder.decode([IssueDraftRecord].self, from: data)) ?? []
    }

    private func persist(_ records: [IssueDraftRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: Keys.drafts)
    }
}
