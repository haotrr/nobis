import CoreData
import CloudKit
import FamilyDomain

/// Separate development-only container. Not used by the local v0.1 store.
/// Never enable production sharing until the two-device gates in docs/verification.md pass.
@MainActor public final class CloudSharingSpike {
    public let container: NSPersistentCloudKitContainer
    public private(set) var sharedStore: NSPersistentStore?
    public init(directory: URL, containerIdentifier: String) {
        container = NSPersistentCloudKitContainer(name: "NobisSharingSpike", managedObjectModel: CoreDataRepository.model())
        let privateDescription = NSPersistentStoreDescription(url: directory.appendingPathComponent("private.sqlite"))
        let sharedDescription = NSPersistentStoreDescription(url: directory.appendingPathComponent("shared.sqlite"))
        for (description, scope) in [(privateDescription, CKDatabase.Scope.private), (sharedDescription, CKDatabase.Scope.shared)] {
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier); options.databaseScope = scope
            description.cloudKitContainerOptions = options
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        container.persistentStoreDescriptions = [privateDescription, sharedDescription]
    }
    public func load() async throws {
        for description in container.persistentStoreDescriptions {
            if let url = description.url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        }
        // NSPersistentContainer calls its completion once per store; use a serial context to collect results.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = StoreLoadCounter(count: container.persistentStoreDescriptions.count, continuation: continuation)
            container.loadPersistentStores { _, error in result.finished(error) }
        }
        sharedStore = container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "shared.sqlite" }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
    public func shareFamilyRoot(_ root: NSManagedObject) async throws -> CKShare {
        guard root.entity.name == "SpaceRoot", let data = root.value(forKey: "payload") as? Data,
              let space = try? JSONDecoder().decode(Space.self, from: data), space.kind == .family else { throw NobisError.forbidden }
        let (_, share, _) = try await container.share([root], to: nil)
        share[CKShare.SystemFieldKey.title] = space.name as CKRecordValue
        share.publicPermission = .none
        return share
    }
    public func accept(_ metadata: CKShare.Metadata) async throws {
        guard let store = sharedStore else { throw NobisError.validation("共享存储尚未就绪。") }
        try await container.acceptShareInvitations(from: [metadata], into: store)
        // Invitation acceptance is NOT identity mapping or a joined/ready state.
    }
}

private final class StoreLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var failure: Error?
    private let continuation: CheckedContinuation<Void, Error>
    init(count: Int, continuation: CheckedContinuation<Void, Error>) { remaining = count; self.continuation = continuation }
    func finished(_ error: Error?) {
        lock.lock(); if let error { failure = error }; remaining -= 1
        let complete = remaining == 0; let failure = failure; lock.unlock()
        if complete { if let failure { continuation.resume(throwing: failure) } else { continuation.resume() } }
    }
}
