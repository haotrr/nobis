import Foundation
import FamilyDomain

/// A collection of independently authorized stores. A transaction may change only one store.
@MainActor public final class SpaceRepositoryRouter: Repository {
    private let stores: [any Repository]
    public init(stores: [any Repository]) { self.stores = stores }
    public func load() throws -> Snapshot {
        var result = Snapshot()
        for store in stores {
            let value = try store.load()
            guard Set(result.spaces.map(\.id)).isDisjoint(with: value.spaces.map(\.id)),
                  result.account == nil || value.account == nil else { throw NobisError.conflict }
            result.spaces += value.spaces; result.revisions += value.revisions; result.audits += value.audits
            if let account = value.account { result.account = account }
        }
        return result
    }
    public func loadSpaces() throws -> [Space] {
        let spaces = try stores.flatMap { try $0.loadSpaces() }
        guard Set(spaces.map(\.id)).count == spaces.count else { throw NobisError.conflict }
        return spaces
    }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws {
        let matches = try stores.filter { try $0.loadSpaces().contains { $0.id == spaceID } }
        guard matches.count == 1, let store = matches.first else { throw NobisError.forbidden }
        try store.requireWrite(spaceID: spaceID, actorID: actorID)
    }
    public func save(_ snapshot: Snapshot) throws {
        let current = try stores.map { try $0.load() }
        let known = Set(current.flatMap { $0.spaces.map(\.id) })
        guard snapshot.revisions.allSatisfy({ known.contains($0.spaceID) }),
              snapshot.audits.allSatisfy({ known.contains($0.spaceID) }),
              Set(snapshot.revisions.map(\.id)).count == snapshot.revisions.count,
              Set(snapshot.audits.map(\.id)).count == snapshot.audits.count else { throw NobisError.forbidden }
        guard Set(snapshot.spaces.map(\.id)) == Set(current.flatMap { $0.spaces.map(\.id) }),
              snapshot.account == current.compactMap(\.account).first else { throw NobisError.forbidden }
        var changes: [(any Repository, Snapshot)] = []
        for (store, old) in zip(stores, current) {
            let ids = Set(old.spaces.map(\.id))
            var next = Snapshot(spaces: snapshot.spaces.filter { ids.contains($0.id) }, revisions: snapshot.revisions.filter { ids.contains($0.spaceID) }, audits: snapshot.audits.filter { ids.contains($0.spaceID) })
            next.account = old.account
            guard next.spaces == old.spaces else { throw NobisError.forbidden }
            if try PrivateCloudSnapshot.data(next) != PrivateCloudSnapshot.data(old) { changes.append((store, next)) }
        }
        guard changes.count <= 1 else { throw NobisError.validation("不能跨空间存储执行同一笔写入。") }
        if let (store, next) = changes.first { try store.save(next) }
    }
}
