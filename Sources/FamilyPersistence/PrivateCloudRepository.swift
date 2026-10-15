import Foundation
import FamilyDomain
import FamilyCore

/// Account-scoped local cache. It is never registered with the family CloudKit container.
@MainActor public final class PrivateCloudRepository: Repository {
    public let ownerID: UUID
    public let spaceID: UUID
    public var onSave: (() -> Void)?
    private var snapshot: Snapshot
    private let file: URL
    private var authorized = true
    public init(directory: URL, space: Space) throws {
        ownerID = space.ownerID; spaceID = space.id
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("snapshot.json")
        snapshot = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Snapshot.self, from: LocalMetadataFile.read(from: file)) : Snapshot(spaces: [space])
        try PrivateCloudSnapshot.validate(snapshot, owner: ownerID, spaceID: spaceID)
    }
    public func block() { authorized = false }
    public func load() throws -> Snapshot { guard authorized else { throw NobisError.forbidden }; return snapshot }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws {
        guard authorized, spaceID == self.spaceID, actorID == ownerID else { throw NobisError.forbidden }
    }
    public func save(_ value: Snapshot) throws {
        try requireWrite(spaceID: spaceID, actorID: ownerID)
        try PrivateCloudSnapshot.validate(value, owner: ownerID, spaceID: spaceID)
        guard value.spaces == snapshot.spaces,
              snapshot.revisions.allSatisfy(value.revisions.contains), snapshot.audits.allSatisfy(value.audits.contains) else { throw NobisError.conflict }
        try persist(value); onSave?()
    }
    public func receive(_ remote: Snapshot) throws {
        let merged = try PrivateCloudSnapshot.merge(local: load(), remote: remote, owner: ownerID, spaceID: spaceID)
        try persist(merged)
    }
    private func persist(_ value: Snapshot) throws {
        try PrivateCloudSnapshot.data(value).write(to: file, options: LocalMetadataFile.writingOptions)
        snapshot = value
    }
}
