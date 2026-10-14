import Foundation
import FamilyDomain

/// Device-only drafts retain their revision baseline; only independent management changes can be reconciled.
public struct DocumentDraft: Codable, Equatable, Sendable {
    public var body: RecordBody
    public var spaceID: UUID
    public var recordID: UUID?
    public var expected: Set<UUID>
    public var updatedAt: Date
    public init(body: RecordBody, spaceID: UUID, recordID: UUID?, expected: Set<UUID>, updatedAt: Date = Date()) {
        self.body = body; self.spaceID = spaceID; self.recordID = recordID; self.expected = expected; self.updatedAt = updatedAt
    }
}

public struct DocumentDraftStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func url(_ key: UUID) -> URL { directory.appendingPathComponent("\(key).json") }
    // All draft access shares one FIFO, including permission cleanup and explicit removal.
    private static let io = DispatchQueue(label: "Nobis.document-drafts", qos: .utility)
    public func read(_ key: UUID) throws -> DocumentDraft? {
        try Self.io.sync {
            guard FileManager.default.fileExists(atPath: url(key).path) else { return nil }
            return try JSONDecoder().decode(DocumentDraft.self, from: LocalMetadataFile.read(from: url(key)))
        }
    }
    private func write(_ draft: DocumentDraft, key: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url(key), options: LocalMetadataFile.writingOptions)
    }
    public func save(_ draft: DocumentDraft, key: UUID) throws {
        try Self.io.sync { try write(draft, key: key) }
    }
    public func saveInBackground(_ draft: DocumentDraft, key: UUID,
                                 completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        Self.io.async { completion(Result { try write(draft, key: key) }) }
    }
    public func remove(spaceID: UUID) throws {
        try Self.io.sync {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let draft = try JSONDecoder().decode(DocumentDraft.self, from: LocalMetadataFile.read(from: file))
                if draft.spaceID == spaceID { try FileManager.default.removeItem(at: file) }
            }
        }
    }
    public func remove(_ key: UUID) throws {
        try Self.io.sync {
            if FileManager.default.fileExists(atPath: url(key).path) { try FileManager.default.removeItem(at: url(key)) }
        }
    }
}

extension FamilyCore {
    /// Reconcile only independent management changes; body edits still require review.
    public func reconcilingManagementChanges(in draft: DocumentDraft) throws -> DocumentDraft {
        guard let id = draft.recordID, !draft.expected.isEmpty else { return draft }
        let current = try record(id, spaceID: draft.spaceID)
        guard !current.deleted, !current.conflicted else { throw NobisError.conflict }
        guard draft.expected != Set(current.heads.map(\.id)) else { return draft }
        guard draft.expected.count == 1,
              let base = try history(id, spaceID: draft.spaceID).first(where: { draft.expected.contains($0.id) }),
              !base.deleted, base.body.kind == .document, current.body.kind == .document else { throw NobisError.conflict }
        var unchanged = current.body
        unchanged.title = base.body.title
        unchanged.noteGroup = base.body.noteGroup
        unchanged.projectIDs = base.body.projectIDs
        unchanged.isPinned = base.body.isPinned
        unchanged.status = base.body.status
        guard unchanged == base.body else { throw NobisError.conflict }
        func merge<T: Equatable>(_ local: T, _ old: T, _ remote: T) throws -> T {
            guard local == old || remote == old || local == remote else { throw NobisError.conflict }
            return local == old ? remote : local
        }
        var result = draft
        result.body.title = try merge(draft.body.title, base.body.title, current.body.title)
        result.body.noteGroup = try merge(draft.body.noteGroup, base.body.noteGroup, current.body.noteGroup)
        result.body.projectIDs = try merge(draft.body.projectIDs, base.body.projectIDs, current.body.projectIDs)
        result.body.isPinned = try merge(draft.body.isPinned, base.body.isPinned, current.body.isPinned)
        result.body.status = try merge(draft.body.status, base.body.status, current.body.status)
        result.expected = Set(current.heads.map(\.id))
        return result
    }
}
