import Foundation
import FamilyDomain

public enum LifeScope: String, CaseIterable, Sendable {
    case shared, personal, all
    public var title: String { switch self { case .shared: "共同"; case .personal: "仅自己"; case .all: "我可见的全部" } }
}

/// UI aggregation never changes the storage or authorization of an existing record.
public struct LifeWorkspace: Sendable {
    public let spaces: [Space]
    public let commonID: UUID?
    public init(spaces: [Space], cloudID: UUID?) {
        self.spaces = spaces
        commonID = spaces.first { $0.id == cloudID && $0.kind == .family }?.id
            ?? spaces.filter { $0.kind == .family }.sorted { $0.id.uuidString < $1.id.uuidString }.first?.id
    }
    public var personalID: UUID? { spaces.first { $0.kind == .personal }?.id }
    public var pendingSpaces: [Space] { spaces.filter { $0.kind == .family && $0.id != commonID } }
    public func ids(_ scope: LifeScope) -> Set<UUID> {
        switch scope {
        case .shared: Set([commonID].compactMap { $0 })
        case .personal: Set(spaces.filter { $0.kind == .personal }.map(\.id))
        case .all: ids(.shared).union(ids(.personal))
        }
    }
}

/// Reports run against an ephemeral authorized projection. This repository cannot persist mutations.
@MainActor private final class ReportRepository: Repository {
    let snapshot: Snapshot
    init(_ snapshot: Snapshot) { self.snapshot = snapshot }
    func load() throws -> Snapshot { snapshot }
    func save(_ snapshot: Snapshot) throws { throw NobisError.forbidden }
    func requireWrite(spaceID: UUID, actorID: UUID) throws { throw NobisError.forbidden }
}
public extension FamilyCore {
    func reportView(spaceIDs: Set<UUID>) throws -> (core: FamilyCore, spaceID: UUID) {
        let snapshot = try repository.load()
        let allowed = Dictionary(uniqueKeysWithValues: authorizedSpaces(in: snapshot).map { ($0.id, $0) })
        let selected = try spaceIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            guard let space = allowed[id] else { throw NobisError.forbidden }; return space
        }
        guard let first = selected.first else { throw NobisError.validation("没有可用的记录范围。") }
        let id = UUID()
        let members = Dictionary(grouping: selected.flatMap(\.members), by: \.id).values.compactMap(\.first)
        let projectedSpace = Space(id: id, name: "报告", kind: .family, ownerID: first.ownerID, members: members)
        let published = Set(Record.project(snapshot.revisions.filter { spaceIDs.contains($0.spaceID) }).filter { $0.body.sharedDestination != nil }.map(\.id))
        let revisions = snapshot.revisions.filter { spaceIDs.contains($0.spaceID) && !published.contains($0.recordID) }.map { r in
            Revision(id: r.id, recordID: r.recordID, spaceID: id, parents: r.parents, operationID: r.operationID, actorID: r.actorID, createdAt: r.createdAt, body: r.body, deleted: r.deleted)
        }
        let projected = Snapshot(spaces: [projectedSpace], revisions: revisions)
        return (FamilyCore(repository: ReportRepository(projected), session: AccessSession(memberID: first.ownerID, allowedSpaceIDs: [id])), id)
    }
}

public extension CSV {
    static func scoped(_ data: Data, scope: String) throws -> Data {
        let rows = try parse(decode(data))
        return encode(rows.enumerated().map { index, row in [index == 0 ? "visibility_scope" : scope] + row })
    }
}
