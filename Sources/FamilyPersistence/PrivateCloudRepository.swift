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
    public var profile: Member? { authorized ? snapshot.account?.profile : nil }
    public func updateProfile(_ member: Member, expected: Member?) throws {
        try requireWrite(spaceID: spaceID, actorID: member.id)
        guard profile == expected else { throw NobisError.conflict }
        if profile == member { return }
        var value = snapshot
        if value.account == nil { value.account = AccountState(ownerID: ownerID) }
        let previous = value.account?.profiles.map(\.updatedAt).max() ?? .distantPast
        value.account?.profiles.append(AccountProfileVersion(member: member, updatedAt: max(Date(), previous.addingTimeInterval(0.001))))
        value.spaces[0].members = [member]
        try PrivateCloudSnapshot.validate(value, owner: ownerID, spaceID: spaceID)
        try persist(value); onSave?()
    }
    public func updateDrafts(deviceID: UUID, drafts: [AccountDraft]) throws {
        try requireWrite(spaceID: spaceID, actorID: ownerID)
        guard drafts.allSatisfy({ $0.deviceID == deviceID }), snapshot.account != nil else { throw NobisError.forbidden }
        var existing = Dictionary(uniqueKeysWithValues: (snapshot.account?.drafts ?? []).map { ($0.id, $0) })
        let incoming = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        var changed = false
        for draft in drafts {
            let old = existing[draft.id]
            if old?.payload == draft.payload { continue }
            existing[draft.id] = AccountDraft(deviceID: deviceID, key: draft.key, kind: draft.kind, payload: draft.payload,
                updatedAt: max(Date(), (old?.updatedAt ?? .distantPast).addingTimeInterval(0.001)))
            changed = true
        }
        for old in existing.values where old.deviceID == deviceID && old.payload != nil && incoming[old.id] == nil {
            existing[old.id] = AccountDraft(deviceID: deviceID, key: old.key, kind: old.kind, payload: nil,
                updatedAt: max(Date(), old.updatedAt.addingTimeInterval(0.001)))
            changed = true
        }
        guard changed else { return }
        var value = snapshot; value.account?.drafts = Array(existing.values)
        try PrivateCloudSnapshot.validate(value, owner: ownerID, spaceID: spaceID)
        try persist(value); onSave?()
    }
    public func block() { authorized = false }
    public func load() throws -> Snapshot { guard authorized else { throw NobisError.forbidden }; return snapshot }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws {
        guard authorized, spaceID == self.spaceID, actorID == ownerID else { throw NobisError.forbidden }
    }
    public func save(_ value: Snapshot) throws {
        try requireWrite(spaceID: spaceID, actorID: ownerID)
        try PrivateCloudSnapshot.validate(value, owner: ownerID, spaceID: spaceID)
        guard value.spaces == snapshot.spaces, value.account == snapshot.account,
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
