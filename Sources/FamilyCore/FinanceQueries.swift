import Foundation
import FamilyDomain

public struct LedgerFilter: Sendable {
    public var search = ""
    public var from: LocalDay?
    public var through: LocalDay?
    public var category: String?
    public var projectID: UUID?
    public var currency: Currency?
    public var minimum: Int64?
    public var maximum: Int64?
    public var consumption: ConsumptionKind?
    public var consumer: String?
    public init() {}
    public func matches(_ record: Record) -> Bool {
        // Conflicting branches must remain visible when any branch matches.
        record.heads.contains { revision in
            let b = revision.body
            return b.kind == .transaction && (search.isEmpty || [b.title, b.notes, b.category, b.finance?.originalRecorder ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }) &&
                (from == nil || b.date.map { $0 >= from! } == true) && (through == nil || b.date.map { $0 <= through! } == true) &&
                (category == nil || b.category == category) && (projectID == nil || b.projectIDs.contains(projectID!)) &&
                (currency == nil || b.money?.currency == currency) && (minimum == nil || (b.money?.minor ?? 0) >= minimum!) &&
                (maximum == nil || (b.money?.minor ?? 0) <= maximum!) &&
                (consumption == nil || (b.finance?.consumption ?? .unassigned) == consumption) && (consumer == nil || b.finance?.consumer == consumer)
        }
    }
}
public struct ProjectSpending: Sendable {
    public let actual: [Currency: Int64]
    public let itemActual: [UUID: Int64]
    public let unresolvedCount: Int
}
public struct RecordChange: Sendable {
    public let id: UUID
    public let expected: Set<UUID>
    public let body: RecordBody
    public init(id: UUID = UUID(), expected: Set<UUID> = [], body: RecordBody) { self.id = id; self.expected = expected; self.body = body }
}
public extension FamilyCore {
    /// Validate the complete ordered batch in isolation, then commit revisions and audits once.
    func saveBatch(_ changes: [RecordChange], spaceID: UUID) throws {
        _ = try space(spaceID)
        try repository.requireWrite(spaceID: spaceID, actorID: session.actorID(in: spaceID))
        let staging = MemoryRepository(try repository.load())
        let core = FamilyCore(repository: staging, session: session)
        for change in changes { try core.save(change.body, spaceID: spaceID, recordID: change.id, expected: change.expected) }
        try repository.save(staging.snapshot)
    }
    func projectSpending(_ id: UUID, spaceID: UUID) throws -> ProjectSpending {
        let all = try records(spaceID: spaceID).filter { $0.body.sharedDestination == nil }
        guard all.contains(where: { $0.id == id && $0.body.kind == .project }) else { throw NobisError.notFound }
        let ids = Set([id] + all.filter { $0.body.parentProjectID == id }.map(\.id))
        var totals: [Currency: Int64] = [:], items: [UUID: Int64] = [:], unresolved = 0
        for record in all where record.body.kind == .transaction && record.heads.contains(where: { !ids.isDisjoint(with: $0.body.projectIDs) }) {
            if record.conflicted || record.body.status == .draft { unresolved += 1; continue }
            guard record.body.status == .confirmed, [.expense, .refund].contains(record.body.transactionKind), let money = record.body.money else { continue }
            let value = record.body.transactionKind == .refund ? -money.minor : money.minor
            totals[money.currency] = try Money.sum([totals[money.currency] ?? 0, value])
            if let item = record.body.finance?.planItemID { items[item] = try Money.sum([items[item] ?? 0, value]) }
        }
        return ProjectSpending(actual: totals, itemActual: items, unresolvedCount: unresolved)
    }
    func reassignProjects(recordIDs: Set<UUID>, to target: UUID, spaceID: UUID) throws {
        let project = try record(target, spaceID: spaceID)
        guard project.body.kind == .project, !project.deleted, !project.conflicted else { throw NobisError.validation("目标项目不可用。") }
        let changes = try recordIDs.map { id -> RecordChange in
            let record = try record(id, spaceID: spaceID)
            guard record.body.kind == .transaction, !record.deleted, !record.conflicted else { throw NobisError.conflict }
            var b = record.body; b.projectIDs = [target]; b.finance?.planItemID = nil
            return RecordChange(id: id, expected: Set(record.heads.map(\.id)), body: b)
        }
        try saveBatch(changes, spaceID: spaceID)
    }
    func mergeProject(_ sourceID: UUID, into targetID: UUID, spaceID: UUID) throws {
        let source = try record(sourceID, spaceID: spaceID), target = try record(targetID, spaceID: spaceID)
        let all = try records(spaceID: spaceID).filter { $0.body.sharedDestination == nil }
        guard sourceID != targetID, source.body.kind == .project, target.body.kind == .project,
              !source.deleted, !target.deleted, !source.conflicted, !target.conflicted,
              !all.contains(where: { $0.body.parentProjectID == sourceID || $0.body.parentProjectID == targetID }) else { throw NobisError.validation("请先分别处理子项目，再合并项目。") }
        var targetBody = target.body
        if let budget = source.body.budget {
            if var existing = targetBody.budget {
                guard existing.limit.currency == budget.limit.currency else { throw NobisError.validation("不同预算币种的项目不能合并。") }
                existing.limit.minor = try Money.sum([existing.limit.minor, budget.limit.minor]); existing.items += budget.items; targetBody.budget = existing
            } else { targetBody.budget = budget }
        }
        var changes = [RecordChange(id: targetID, expected: Set(target.heads.map(\.id)), body: targetBody)]
        for r in all where r.body.projectIDs.contains(sourceID) {
            guard !r.conflicted else { throw NobisError.conflict }
            var b = r.body; b.projectIDs = Array(Set(b.projectIDs.map { $0 == sourceID ? targetID : $0 })).sorted { $0.uuidString < $1.uuidString }
            changes.append(RecordChange(id: r.id, expected: Set(r.heads.map(\.id)), body: b))
        }
        var old = source.body; old.status = .archived; old.budget = nil
        changes.append(RecordChange(id: sourceID, expected: Set(source.heads.map(\.id)), body: old))
        try saveBatch(changes, spaceID: spaceID)
    }
}
