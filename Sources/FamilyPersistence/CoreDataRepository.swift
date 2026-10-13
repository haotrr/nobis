import Foundation
import CoreData
import FamilyDomain
import FamilyCore

@MainActor public final class CoreDataRepository: Repository {
    public let container: NSPersistentContainer
    private let directory: URL
    private var stores: [UUID: NSPersistentStore] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL, initialSpaces: [Space] = []) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = NSPersistentContainer(name: "Nobis", managedObjectModel: Self.model())
        let catalogURL = directory.appendingPathComponent("spaces.json")
        let spaces = FileManager.default.fileExists(atPath: catalogURL.path) ? try decoder.decode([Space].self, from: LocalMetadataFile.read(from: catalogURL)) : initialSpaces
        guard !spaces.isEmpty else { throw NobisError.validation("尚未创建个人空间。") }
        for space in spaces {
            // Separate physical SQLite files. No private objects can enter a family relationship graph.
            let store = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: directory.appendingPathComponent("\(space.id).sqlite"), options: [NSPersistentHistoryTrackingKey: true, NSPersistentStoreRemoteChangeNotificationPostOptionKey: true])
            stores[space.id] = store
        }
        container.viewContext.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
        if !FileManager.default.fileExists(atPath: catalogURL.path) {
            for space in spaces {
                let root = NSEntityDescription.insertNewObject(forEntityName: "SpaceRoot", into: container.viewContext)
                root.setValue(space.id.uuidString, forKey: "logicalID"); root.setValue(try encoder.encode(space), forKey: "payload")
                container.viewContext.assign(root, to: stores[space.id]!)
            }
            try container.viewContext.save()
            try encoder.encode(spaces).write(to: catalogURL, options: LocalMetadataFile.writingOptions)
        }
    }
    public func load() throws -> Snapshot {
        let context = container.viewContext
        var snapshot = Snapshot()
        let roots = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SpaceRoot"))
        for root in roots {
            guard let data = root.value(forKey: "payload") as? Data else { throw NobisError.corruptBackup }
            let space = try decoder.decode(Space.self, from: data)
            guard stores[space.id] == root.objectID.persistentStore else { throw NobisError.corruptBackup }
            snapshot.spaces.append(space)
        }
        for entity in ["RecordRevision", "AuditEvent"] {
            for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) {
                guard let data = object.value(forKey: "payload") as? Data else { throw NobisError.corruptBackup }
                if entity == "RecordRevision" {
                    let revision = try decoder.decode(Revision.self, from: data)
                    guard stores[revision.spaceID] == object.objectID.persistentStore else { throw NobisError.corruptBackup }
                    snapshot.revisions.append(revision)
                } else { snapshot.audits.append(try decoder.decode(AuditEvent.self, from: data)) }
            }
        }
        return snapshot
    }
    public func save(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw NobisError.unsupportedVersion }
        let current = try load()
        guard Set(current.spaces.map(\.id)) == Set(snapshot.spaces.map(\.id)), current.spaces.allSatisfy({ snapshot.spaces.contains($0) }) else { throw NobisError.validation("空间配置不可通过记录写入修改。") }
        let oldRevisions = Dictionary(uniqueKeysWithValues: current.revisions.map { ($0.id, $0) })
        let oldAudits = Dictionary(uniqueKeysWithValues: current.audits.map { ($0.id, $0) })
        guard current.revisions.allSatisfy({ snapshot.revisions.contains($0) }), current.audits.allSatisfy({ snapshot.audits.contains($0) }) else { throw NobisError.validation("历史记录不能覆盖或物理删除。") }
        let additions = snapshot.revisions.filter { oldRevisions[$0.id] == nil }
        let audits = snapshot.audits.filter { oldAudits[$0.id] == nil }
        guard Set(additions.map(\.spaceID) + audits.map(\.spaceID)).count <= 1 else { throw NobisError.validation("单次写入只能属于一个物理空间。") }
        let context = container.viewContext
        do {
            let roots = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SpaceRoot"))
            for revision in additions {
                guard let store = stores[revision.spaceID], let root = roots.first(where: { $0.value(forKey: "logicalID") as? String == revision.spaceID.uuidString }) else { throw NobisError.forbidden }
                let object = NSEntityDescription.insertNewObject(forEntityName: "RecordRevision", into: context)
                context.assign(object, to: store); object.setValue(revision.id.uuidString, forKey: "logicalID"); object.setValue(try encoder.encode(revision), forKey: "payload"); object.setValue(root, forKey: "root")
            }
            for audit in audits {
                guard let store = stores[audit.spaceID], let root = roots.first(where: { $0.value(forKey: "logicalID") as? String == audit.spaceID.uuidString }) else { throw NobisError.forbidden }
                let object = NSEntityDescription.insertNewObject(forEntityName: "AuditEvent", into: context)
                context.assign(object, to: store); object.setValue(audit.id.uuidString, forKey: "logicalID"); object.setValue(try encoder.encode(audit), forKey: "payload"); object.setValue(root, forKey: "root")
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    /// Local catalog membership is immutable; only the owner's display metadata can change here.
    public func updateDisplay(spaceID: UUID, actorID: UUID, name: String, member: Member, expected: Space? = nil) throws {
        let context = container.viewContext
        let roots = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SpaceRoot"))
        guard let root = roots.first(where: { $0.value(forKey: "logicalID") as? String == spaceID.uuidString }),
              let data = root.value(forKey: "payload") as? Data else { throw NobisError.forbidden }
        var space = try decoder.decode(Space.self, from: data)
        if let expected, expected != space { throw NobisError.conflict }
        guard space.ownerID == actorID, let index = space.members.firstIndex(where: { $0.id == member.id }) else { throw NobisError.forbidden }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, member.name.count <= 80,
              (member.avatarData?.count ?? 0) <= 100_000 else { throw NobisError.validation("名称或头像超出限制。") }
        space.name = name; space.members[index] = member
        do { root.setValue(try encoder.encode(space), forKey: "payload"); try context.save() }
        catch { context.rollback(); throw error }
        // spaces.json is the stable store inventory; display metadata is read from SpaceRoot.
    }
    public static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        func entity(_ name: String) -> NSEntityDescription {
            let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"
            let id = NSAttributeDescription(); id.name = "logicalID"; id.attributeType = .stringAttributeType; id.isOptional = true
            let payload = NSAttributeDescription(); payload.name = "payload"; payload.attributeType = .binaryDataAttributeType; payload.isOptional = true
            e.properties = [id, payload]; return e
        }
        let root = entity("SpaceRoot"), revision = entity("RecordRevision"), audit = entity("AuditEvent")
        for (child, name) in [(revision, "revisions"), (audit, "audits")] {
            let children = NSRelationshipDescription(); children.name = name; children.destinationEntity = child; children.minCount = 0; children.maxCount = 0; children.isOptional = true; children.deleteRule = .nullifyDeleteRule
            let parent = NSRelationshipDescription(); parent.name = "root"; parent.destinationEntity = root; parent.minCount = 0; parent.maxCount = 1; parent.isOptional = true; parent.deleteRule = .nullifyDeleteRule
            children.inverseRelationship = parent; parent.inverseRelationship = children
            root.properties.append(children); child.properties.append(parent)
        }
        model.entities = [root, revision, audit]; return model
    }
}
