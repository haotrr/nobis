import Foundation
import FamilyDomain

/// The local store remains untouched by cloud account changes. Cross-route writes are forbidden.
@MainActor public final class RoutedRepository: Repository {
    private let local: any Repository
    private let shared: any Repository
    public init(local: any Repository, shared: any Repository) { self.local = local; self.shared = shared }
    public func load() throws -> Snapshot {
        let a = try local.load(), b = try shared.load()
        guard Set(a.spaces.map(\.id)).isDisjoint(with: b.spaces.map(\.id)) else { throw NobisError.conflict }
        return Snapshot(spaces: a.spaces + b.spaces, revisions: a.revisions + b.revisions, audits: a.audits + b.audits)
    }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws {
        if try local.load().spaces.contains(where: { $0.id == spaceID }) { try local.requireWrite(spaceID: spaceID, actorID: actorID) }
        else { try shared.requireWrite(spaceID: spaceID, actorID: actorID) }
    }
    public func save(_ snapshot: Snapshot) throws {
        let a = try local.load(), b = try shared.load()
        let aIDs = Set(a.spaces.map(\.id)), bIDs = Set(b.spaces.map(\.id))
        guard Set(snapshot.spaces.map(\.id)) == aIDs.union(bIDs) else { throw NobisError.forbidden }
        func subset(_ ids: Set<UUID>) -> Snapshot { Snapshot(spaces: snapshot.spaces.filter { ids.contains($0.id) }, revisions: snapshot.revisions.filter { ids.contains($0.spaceID) }, audits: snapshot.audits.filter { ids.contains($0.spaceID) }) }
        let newA = subset(aIDs), newB = subset(bIDs)
        let changesA = Set(newA.revisions.map(\.id)) != Set(a.revisions.map(\.id)) || Set(newA.audits.map(\.id)) != Set(a.audits.map(\.id))
        let changesB = Set(newB.revisions.map(\.id)) != Set(b.revisions.map(\.id)) || Set(newB.audits.map(\.id)) != Set(b.audits.map(\.id))
        guard !(changesA && changesB) else { throw NobisError.validation("不能跨本地和共享存储执行同一笔写入。") }
        if changesA { try local.save(newA) } else if changesB { try shared.save(newB) }
    }
}
