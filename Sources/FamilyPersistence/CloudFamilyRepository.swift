import Foundation
import CoreData
import CloudKit
import FamilyDomain
import FamilyCore

@MainActor public final class CloudFamilyRepository: Repository {
    public let container: NSPersistentCloudKitContainer
    public private(set) var policy = FamilyAccessPolicy()
    public private(set) var root: NSManagedObject?
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(directory: URL, identifier: String?) {
        self.directory = directory
        container = NSPersistentCloudKitContainer(name: "NobisFamily", managedObjectModel: CoreDataRepository.model())
        container.persistentStoreDescriptions = [("family-private.sqlite", CKDatabase.Scope.private), ("family-shared.sqlite", .shared)].map { filename, scope in
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent(filename))
            if let identifier {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier); options.databaseScope = scope
                description.cloudKitContainerOptions = options
            }
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            return description
        }
        container.viewContext.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
    public func open() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let counter = CloudStoreLoad(count: 2, continuation: continuation)
            container.loadPersistentStores { _, error in counter.finish(error) }
        }
    }
    public var privateStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "family-private.sqlite" } }
    public var sharedStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "family-shared.sqlite" } }
    public func roots() throws -> [NSManagedObject] { try container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "SpaceRoot")) }
    public func space(of root: NSManagedObject) throws -> Space {
        guard let data = root.value(forKey: "payload") as? Data else { throw NobisError.validation("正在准备家庭数据：共享根尚未完整导入。") }
        let space = try decoder.decode(Space.self, from: data)
        guard space.kind == .family else { throw NobisError.forbidden }; return space
    }
    public func identify(_ accountID: UUID) { policy.identify(accountID) }
    public func authorize(_ grant: FamilyGrant, root: NSManagedObject, generation: UUID) throws {
        let space = try space(of: root)
        guard space.id == grant.spaceID, space.ownerID == grant.ownerID else { throw NobisError.forbidden }
        try policy.authorize(grant, generation: generation); self.root = root
    }
    public func block() { policy.revoke(); root = nil }
    @discardableResult public func createFamily(name: String, member: Member) throws -> NSManagedObject {
        guard policy.accountID == member.id, let store = privateStore else { throw NobisError.forbidden }
        guard try roots().isEmpty else { throw NobisError.validation("已有家庭数据，请等待导入或恢复连接。") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NobisError.validation("请填写家庭名称。") }
        let context = container.viewContext
        let object = NSEntityDescription.insertNewObject(forEntityName: "SpaceRoot", into: context)
        do {
            let space = Space(name: name, kind: .family, ownerID: member.id, members: [member])
            context.assign(object, to: store); object.setValue(space.id.uuidString, forKey: "logicalID"); object.setValue(try encoder.encode(space), forKey: "payload")
            try context.save(); return object
        } catch { context.rollback(); throw error }
    }
    public func load() throws -> Snapshot {
        guard let grant = policy.grant, let root, !root.isDeleted else { return Snapshot() }
        var space = try space(of: root)
        guard space.id == grant.spaceID, space.ownerID == grant.ownerID else { throw NobisError.forbidden }
        var snapshot = Snapshot()
        let context = container.viewContext
        for entity in ["RecordRevision", "AuditEvent"] {
            let incomplete = NSFetchRequest<NSManagedObject>(entityName: entity)
            incomplete.affectedStores = root.objectID.persistentStore.map { [$0] }
            incomplete.predicate = NSPredicate(format: "root == nil")
            guard try context.count(for: incomplete) == 0 else { throw self.incomplete() }
        }
        func children(_ entity: String) throws -> [NSManagedObject] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity); request.predicate = NSPredicate(format: "root == %@", root)
            return try context.fetch(request)
        }
        var revisionIDs: [UUID: Revision] = [:], operations: [UUID: UUID] = [:]
        for object in try children("RecordRevision") {
            guard let data = object.value(forKey: "payload") as? Data else { throw incomplete() }
            let revision = try decoder.decode(Revision.self, from: data)
            guard revision.spaceID == space.id, object.objectID.persistentStore == root.objectID.persistentStore else { throw NobisError.forbidden }
            if let old = revisionIDs[revision.id], old != revision { throw NobisError.conflict }
            if let oldID = operations[revision.operationID], oldID != revision.id { throw NobisError.conflict }
            revisionIDs[revision.id] = revision; operations[revision.operationID] = revision.id
        }
        snapshot.revisions = Array(revisionIDs.values)
        let recordIDs = Set(snapshot.revisions.map(\.recordID))
        for revision in snapshot.revisions {
            guard revision.parents.allSatisfy({ revisionIDs[$0]?.recordID == revision.recordID }),
                  revision.body.projectIDs.allSatisfy({ id in snapshot.revisions.contains { $0.recordID == id && $0.body.kind == .project } }),
                  ((revision.body.referenceIDs ?? []) + [revision.body.refundOfID, revision.body.subscriptionID, revision.body.relatedRecordID].compactMap({ $0 })).allSatisfy({ recordIDs.contains($0) }) else { throw incomplete() }
        }
        var audits: [UUID: AuditEvent] = [:]
        for object in try children("AuditEvent") {
            guard let data = object.value(forKey: "payload") as? Data else { throw incomplete() }
            let audit = try decoder.decode(AuditEvent.self, from: data)
            guard audit.spaceID == space.id else { throw NobisError.forbidden }
            if let previous = audits[audit.id], previous != audit { throw NobisError.conflict }
            audits[audit.id] = audit
        }
        snapshot.audits = Array(audits.values)
        guard snapshot.revisions.allSatisfy({ revision in snapshot.audits.contains {
            $0.revisionID == revision.id && $0.operationID == revision.operationID && $0.actorID == revision.actorID && $0.targetID == revision.recordID
        } }), snapshot.audits.allSatisfy({ revisionIDs[$0.revisionID] != nil }) else { throw incomplete() }
        // Retain departed IDs for historical accounting, but do not grant them access.
        let historicalIDs = Set(snapshot.revisions.flatMap { [$0.actorID] + [$0.body.memberID].compactMap { $0 } + $0.body.splits.map(\.memberID) })
        let displayMembers = space.members
        space.members = grant.members.map { authorized in displayMembers.first { $0.id == authorized.id } ?? authorized } + historicalIDs.subtracting(grant.members.map(\.id)).sorted { $0.uuidString < $1.uuidString }.map { Member(id: $0, name: "已退出成员") }
        snapshot.spaces = [space]
        // Use the same structural/amount validation as recovery before exposing a cloud projection.
        _ = try Backup.decode(Backup.encode(snapshot))
        return snapshot
    }
    public func updateDisplay(name: String, member: Member, expected: Space? = nil) throws {
        guard let grant = policy.grant, let root else { throw NobisError.forbidden }
        try requireWrite(spaceID: grant.spaceID, actorID: grant.accountID)
        if let expected, try load().spaces.first != expected { throw NobisError.conflict }
        var space = try space(of: root)
        guard member.id == grant.accountID, name == space.name || grant.accountID == space.ownerID else { throw NobisError.forbidden }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, member.name.count <= 80,
              (member.avatarData?.count ?? 0) <= 100_000 else { throw NobisError.validation("名称或头像超出限制。") }
        space.name = name
        space.members.removeAll { $0.id == member.id }; space.members.append(member)
        let context = container.viewContext
        do { root.setValue(try encoder.encode(space), forKey: "payload"); try context.save() }
        catch { context.rollback(); throw error }
    }
    private func incomplete() -> NobisError { .validation("家庭内容正在同步，引用尚未到齐；暂不展示不完整的账务合计。") }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws { try policy.requireWrite(spaceID: spaceID, actorID: actorID) }
    public func save(_ snapshot: Snapshot) throws {
        guard let root, let grant = policy.grant else { throw NobisError.forbidden }
        try requireWrite(spaceID: grant.spaceID, actorID: grant.accountID)
        let current = try load()
        guard snapshot.schemaVersion == 1, snapshot.spaces == current.spaces,
              current.revisions.allSatisfy({ snapshot.revisions.contains($0) }), current.audits.allSatisfy({ snapshot.audits.contains($0) }) else { throw NobisError.conflict }
        let oldIDs = Set(current.revisions.map(\.id)), oldAudits = Set(current.audits.map(\.id))
        let additions = snapshot.revisions.filter { !oldIDs.contains($0.id) }, audits = snapshot.audits.filter { !oldAudits.contains($0.id) }
        guard additions.allSatisfy({ $0.spaceID == grant.spaceID && $0.actorID == grant.accountID }), audits.allSatisfy({ $0.spaceID == grant.spaceID && $0.actorID == grant.accountID }) else { throw NobisError.forbidden }
        let context = container.viewContext
        guard let store = root.objectID.persistentStore else { throw NobisError.forbidden }
        do {
            func insert<T: Encodable>(_ value: T, id: UUID, entity: String) throws {
                let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
                context.assign(object, to: store); object.setValue(root, forKey: "root"); object.setValue(id.uuidString, forKey: "logicalID"); object.setValue(try encoder.encode(value), forKey: "payload")
            }
            for revision in additions { try insert(revision, id: revision.id, entity: "RecordRevision") }
            for audit in audits { try insert(audit, id: audit.id, entity: "AuditEvent") }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    /// Local-only destruction. Never call purgeObjectsAndRecordsInZone here: that also deletes server records.
    public func closeAndClearLocalCache() throws {
        block(); policy.invalidate(); container.viewContext.reset()
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            guard let url = store.url, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { throw NobisError.forbidden }
            try coordinator.remove(store)
            try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
        }
        try Self.clearDetachedCache(directory: directory)
    }
    public static func clearDetachedCache(directory: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataRepository.model())
        for name in ["family-private.sqlite", "family-shared.sqlite"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil) }
        }
        // SQLite may leave an empty file/sidecars after destroy. This directory belongs solely to this cloud stack.
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
private final class CloudStoreLoad: @unchecked Sendable {
    private let lock = NSLock(); private var remaining: Int; private var failure: Error?
    private let continuation: CheckedContinuation<Void, Error>
    init(count: Int, continuation: CheckedContinuation<Void, Error>) { remaining = count; self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); if let error { failure = error }; remaining -= 1; let done = remaining == 0, failure = failure; lock.unlock()
        if done { if let failure { continuation.resume(throwing: failure) } else { continuation.resume() } }
    }
}
