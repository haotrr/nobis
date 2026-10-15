import Foundation
import FamilyDomain

/// A private cloud payload can contain exactly one personal space owned by the verified Apple ID.
public enum PrivateCloudSnapshot {
    public static func validate(_ snapshot: Snapshot, owner: UUID, spaceID: UUID) throws {
        guard snapshot.spaces.count == 1, let space = snapshot.spaces.first,
              space.id == spaceID, space.kind == .personal, space.ownerID == owner,
              space.members.count == 1, space.members.first?.id == owner,
              snapshot.revisions.allSatisfy({ $0.spaceID == spaceID && $0.actorID == owner }),
              snapshot.audits.allSatisfy({ $0.spaceID == spaceID && $0.actorID == owner }) else { throw NobisError.forbidden }
        let auditByRevision = Dictionary(grouping: snapshot.audits, by: \.revisionID)
        guard snapshot.revisions.allSatisfy({ revision in
            auditByRevision[revision.id]?.contains(where: {
                $0.operationID == revision.operationID && $0.actorID == revision.actorID && $0.targetID == revision.recordID
            }) == true
        }) else { throw NobisError.corruptBackup }
        _ = try Backup.decode(Backup.encode(snapshot))
    }
    public static func merge(local: Snapshot, remote: Snapshot, owner: UUID, spaceID: UUID) throws -> Snapshot {
        try validate(local, owner: owner, spaceID: spaceID)
        try validate(remote, owner: owner, spaceID: spaceID)
        var revisions = Dictionary(uniqueKeysWithValues: remote.revisions.map { ($0.id, $0) })
        var audits = Dictionary(uniqueKeysWithValues: remote.audits.map { ($0.id, $0) })
        for value in local.revisions {
            if let previous = revisions[value.id], previous != value { throw NobisError.conflict }
            revisions[value.id] = value
        }
        for value in local.audits {
            if let previous = audits[value.id], previous != value { throw NobisError.conflict }
            audits[value.id] = value
        }
        let merged = Snapshot(spaces: remote.spaces, revisions: Array(revisions.values), audits: Array(audits.values))
        try validate(merged, owner: owner, spaceID: spaceID)
        return merged
    }
    public static func data(_ snapshot: Snapshot) throws -> Data {
        var value = snapshot
        value.revisions.sort { $0.id.uuidString < $1.id.uuidString }
        value.audits.sort { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
