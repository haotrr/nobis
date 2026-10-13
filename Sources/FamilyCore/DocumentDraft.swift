import Foundation
import FamilyDomain

/// Device-only drafts retain the original heads; recovery never rebases a stale edit silently.
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
    public func read(_ key: UUID) throws -> DocumentDraft? {
        guard FileManager.default.fileExists(atPath: url(key).path) else { return nil }
        return try JSONDecoder().decode(DocumentDraft.self, from: LocalMetadataFile.read(from: url(key)))
    }
    public func save(_ draft: DocumentDraft, key: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url(key), options: LocalMetadataFile.writingOptions)
    }
    public func remove(spaceID: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let draft = try JSONDecoder().decode(DocumentDraft.self, from: LocalMetadataFile.read(from: file))
            if draft.spaceID == spaceID { try FileManager.default.removeItem(at: file) }
        }
    }
    public func remove(_ key: UUID) throws {
        if FileManager.default.fileExists(atPath: url(key).path) { try FileManager.default.removeItem(at: url(key)) }
    }
}
