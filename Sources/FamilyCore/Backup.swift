import Foundation
import CryptoKit
import FamilyDomain

public struct BackupManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let spaceIDs: [UUID]
    public let revisionCount: Int
    public let sha256: String
}
public struct BackupEnvelope: Codable, Sendable {
    public let manifest: BackupManifest
    public let businessJSON: Data
}
public enum Backup {
    public static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
        let businessEncoder = JSONEncoder(); businessEncoder.outputFormatting = [.sortedKeys]
        // Preserve the full Date representation; ISO-8601 without fractions loses revision precision.
        let business = try businessEncoder.encode(snapshot)
        let manifest = BackupManifest(schemaVersion: 6, exportedAt: Date(), spaceIDs: snapshot.spaces.map(\.id), revisionCount: snapshot.revisions.count, sha256: digest(business))
        return try encoder.encode(BackupEnvelope(manifest: manifest, businessJSON: business))
    }
    public static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(BackupEnvelope.self, from: data)
        guard (1...6).contains(envelope.manifest.schemaVersion) else { throw NobisError.unsupportedVersion }
        guard digest(envelope.businessJSON) == envelope.manifest.sha256 else { throw NobisError.corruptBackup }
        let snapshot: Snapshot
        do { snapshot = try JSONDecoder().decode(Snapshot.self, from: envelope.businessJSON) }
        catch { snapshot = try decoder.decode(Snapshot.self, from: envelope.businessJSON) }
        guard snapshot.schemaVersion == 1 else { throw NobisError.unsupportedVersion }
        guard snapshot.revisions.count == envelope.manifest.revisionCount,
              Set(snapshot.spaces.map(\.id)) == Set(envelope.manifest.spaceIDs),
              Set(snapshot.spaces.map(\.id)).count == snapshot.spaces.count,
              Set(snapshot.revisions.map(\.id)).count == snapshot.revisions.count,
              Set(snapshot.revisions.map(\.operationID)).count == snapshot.revisions.count else { throw NobisError.corruptBackup }
        let spaces = Dictionary(uniqueKeysWithValues: snapshot.spaces.map { ($0.id, $0) })
        let revisions = Dictionary(uniqueKeysWithValues: snapshot.revisions.map { ($0.id, $0) })
        for space in snapshot.spaces {
            let members = Set(space.members.map(\.id))
            guard !space.name.isEmpty, members.count == space.members.count, members.contains(space.ownerID),
                  space.kind != .personal || members == [space.ownerID] else { throw NobisError.corruptBackup }
        }
        for versions in Dictionary(grouping: snapshot.revisions, by: \.recordID).values {
            guard Set(versions.map(\.spaceID)).count == 1, Set(versions.map { $0.body.kind }).count == 1 else { throw NobisError.corruptBackup }
        }
        for revision in snapshot.revisions {
            guard let space = spaces[revision.spaceID], space.members.contains(where: { $0.id == revision.actorID }),
                  revision.parents.allSatisfy({ revisions[$0]?.recordID == revision.recordID && revisions[$0]?.spaceID == revision.spaceID && $0 != revision.id }),
                  !revision.body.title.isEmpty else { throw NobisError.corruptBackup }
            var visited = Set<UUID>(), pending = revision.parents
            while let id = pending.popLast() {
                guard id != revision.id else { throw NobisError.corruptBackup }
                if visited.insert(id).inserted { pending += revisions[id]?.parents ?? [] }
            }
            for project in revision.body.projectIDs {
                guard snapshot.revisions.contains(where: { $0.recordID == project && $0.spaceID == revision.spaceID && $0.body.kind == .project }) else { throw NobisError.corruptBackup }
            }
            for related in ((revision.body.referenceIDs ?? []) + [revision.body.refundOfID, revision.body.subscriptionID, revision.body.relatedRecordID].compactMap({ $0 })) {
                guard snapshot.revisions.contains(where: { $0.recordID == related && $0.spaceID == revision.spaceID }) else { throw NobisError.corruptBackup }
            }
            for day in [revision.body.date, revision.body.endDate, revision.body.billingAnchor].compactMap({ $0 }) { _ = try LocalDay(day.year, day.month, day.day) }
            if let parent = revision.body.parentProjectID {
                guard parent != revision.recordID, snapshot.revisions.contains(where: { $0.recordID == parent && $0.spaceID == revision.spaceID && $0.body.kind == .project }) else { throw NobisError.corruptBackup }
            }
            if let plan = revision.body.finance?.planItemID {
                guard snapshot.revisions.contains(where: { revision.body.projectIDs.contains($0.recordID) && $0.spaceID == revision.spaceID && $0.body.budget?.items.contains(where: { $0.id == plan && $0.amount.currency == revision.body.money?.currency }) == true }) else { throw NobisError.corruptBackup }
            }
            try revision.body.validateFinance()
            try revision.body.validateStatement()
            if let member = revision.body.financialOwner?.memberID, !space.members.contains(where: { $0.id == member }) { throw NobisError.corruptBackup }
            if revision.body.sharedDestination != nil && space.kind != .personal { throw NobisError.corruptBackup }
            if revision.body.kind == .transaction {
                guard let money = revision.body.money, revision.body.hasValidTransactionAmount, revision.body.date != nil,
                      (revision.body.memberID.map({ id in space.members.contains { $0.id == id } }) ?? (revision.body.accountingMode == .ledgerOnly)),
                      Set(revision.body.splits.map(\.memberID)).count == revision.body.splits.count,
                      revision.body.splits.allSatisfy({ share in share.minor >= 0 && space.members.contains { $0.id == share.memberID } }) else { throw NobisError.corruptBackup }
                if revision.body.accountingMode == .sharedSettlement && revision.body.transactionKind != .income { guard try Money.sum(revision.body.splits.map(\.minor)) == money.minor else { throw NobisError.corruptBackup } }
            }
        }
        guard snapshot.audits.allSatisfy({ revisions[$0.revisionID]?.operationID == $0.operationID && revisions[$0.revisionID]?.spaceID == $0.spaceID }) else { throw NobisError.corruptBackup }
        return snapshot
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension FamilyCore {
    public func export(spaceID: UUID) throws -> Data {
        let space = try space(spaceID), snapshot = try repository.load()
        return try Backup.encode(Snapshot(spaces: [space], revisions: snapshot.revisions.filter { $0.spaceID == spaceID }, audits: snapshot.audits.filter { $0.spaceID == spaceID }))
    }
}
