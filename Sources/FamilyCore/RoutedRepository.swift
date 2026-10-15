import Foundation
import FamilyDomain

/// Compatibility adapter; routing is keyed by explicit space ownership, not by store count.
@MainActor public final class RoutedRepository: Repository {
    private let router: SpaceRepositoryRouter
    public init(local: any Repository, shared: any Repository) { router = SpaceRepositoryRouter(stores: [local, shared]) }
    public func load() throws -> Snapshot { try router.load() }
    public func loadSpaces() throws -> [Space] { try router.loadSpaces() }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws { try router.requireWrite(spaceID: spaceID, actorID: actorID) }
    public func save(_ snapshot: Snapshot) throws { try router.save(snapshot) }
}
