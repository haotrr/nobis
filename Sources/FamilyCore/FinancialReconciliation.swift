import Foundation
import FamilyDomain

public struct AssetReconciliation: Sendable {
    public let baseline: Record
    public let breakdown: [Record]
    public let currency: Currency
    /// Selected breakdown minus the old whole-space snapshot, component by component.
    public let differences: [AssetComponent: Int64]
    public let totals: AssetPosition
    public var matches: Bool { differences.values.allSatisfy { $0 == 0 } }
}

public struct MemberMappingPreview: Codable, Sendable {
    public let sourceSpaceID: UUID
    public let targetSpaceID: UUID
    public let mapping: [UUID: UUID]
    public let sourceHeads: [UUID]
    public let referencedRecords: Int
    public let responsibilityOrPayerCount: Int
    public let splitCount: Int
    public let financialOwnerCount: Int
    public let completionCount: Int
    public let createdAt: Date
}

public extension FamilyCore {
    /// Produces optimistic changes for an explicit user selection; it never infers identity.
    func ownershipChanges(_ selected: [Record], owner: FinancialOwner, spaceID: UUID) throws -> [RecordChange] {
        let space = try space(spaceID)
        guard !selected.isEmpty, Set(selected.map(\.id)).count == selected.count,
              (owner.kind == .joint ? owner.memberID == nil : space.members.contains(where: { $0.id == owner.memberID })) else {
            throw NobisError.validation("请选择记录和此范围内的有效归属。")
        }
        let all = try records(spaceID: spaceID)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var changes: [RecordChange] = []
        for record in selected {
            guard record.latest.spaceID == spaceID, !record.deleted, !record.conflicted,
                  record.body.sharedDestination == nil, record.body.status == .active,
                  [.monthlyIncome, .assetSnapshot].contains(record.body.kind) else { throw NobisError.validation("仅可确认本范围内有效、无冲突的收入或资产记录。") }
            guard let current = byID[record.id], Set(current.heads.map(\.id)) == Set(record.heads.map(\.id)) else { throw NobisError.conflict }
            guard current.body.kind != .monthlyIncome || owner.kind == .member else { throw NobisError.validation("收入须选择具体成员。") }
            if current.body.financialOwner == owner { continue }
            var body = current.body; body.financialOwner = owner
            changes.append(RecordChange(id: record.id, expected: Set(record.heads.map(\.id)), body: body))
        }
        // Do not silently turn two old snapshots into an ambiguous same-owner/date balance.
        let changedIDs = Set(changes.map(\.id))
        let remaining = all.filter { !changedIDs.contains($0.id) && $0.body.sharedDestination == nil }
        for change in changes where change.body.kind == .assetSnapshot {
            func matches(_ body: RecordBody) -> Bool {
                body.kind == .assetSnapshot && body.status == .active && body.financialOwner == owner &&
                body.date == change.body.date && body.assetPosition?.currency == change.body.assetPosition?.currency
            }
            guard !remaining.contains(where: { $0.heads.contains { matches($0.body) } }),
                  !changes.contains(where: { $0.id != change.id && matches($0.body) }) else {
                throw NobisError.validation("同一持有人、日期和币种已有快照，请先逐份核对，不能批量合并。")
            }
        }
        return changes
    }

    func reconcileAssets(baselineID: UUID, breakdownIDs: Set<UUID>, spaceID: UUID) throws -> AssetReconciliation {
        guard !breakdownIDs.isEmpty, !breakdownIDs.contains(baselineID) else { throw NobisError.validation("请选择旧整体快照及独立的分项快照。") }
        let space = try space(spaceID)
        let baseline = try record(baselineID, spaceID: spaceID)
        func valid(_ record: Record) -> Bool {
            !record.deleted && !record.conflicted && record.body.kind == .assetSnapshot &&
            record.body.status == .active && record.body.sharedDestination == nil
        }
        guard valid(baseline), baseline.body.financialOwner == nil, let original = baseline.body.assetPosition else {
            throw NobisError.validation("对照须为有效且尚未指定持有人的旧整体快照。")
        }
        try original.validate()
        let breakdown = try breakdownIDs.sorted { $0.uuidString < $1.uuidString }.map { try record($0, spaceID: spaceID) }
        let all = try records(spaceID: spaceID).filter { $0.body.sharedDestination == nil }
        var owners = Set<String>(), totals = Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, Int64(0)) })
        for item in breakdown {
            guard valid(item), let owner = item.body.financialOwner,
                  owner.kind == .joint || space.members.contains(where: { $0.id == owner.memberID }),
                  item.body.date == baseline.body.date, let position = item.body.assetPosition,
                  position.currency == original.currency, owners.insert(owner.key).inserted else {
                throw NobisError.validation("分项须为同日期、同币种、归属已确认且每个持有范围仅一份的有效快照。")
            }
            let sameRange = all.filter { record in record.heads.contains {
                $0.body.kind == .assetSnapshot && $0.body.status == .active && $0.body.financialOwner == owner &&
                $0.body.date == baseline.body.date && $0.body.assetPosition?.currency == original.currency
            } }
            guard sameRange.count == 1, !sameRange.contains(where: \.conflicted) else {
                throw NobisError.validation("所选持有范围存在同日重复或冲突快照，请先在详情中核对。")
            }
            try position.validate()
            for component in AssetComponent.allCases { totals[component] = try Money.sum([totals[component]!, position.amounts[component]!]) }
        }
        let position = AssetPosition(currency: original.currency, amounts: totals)
        try position.validate()
        let differences = try Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, try Money.sum([totals[$0]!, -original.amounts[$0]!])) })
        return AssetReconciliation(baseline: baseline, breakdown: breakdown, currency: original.currency, differences: differences, totals: position)
    }

    /// Mapping is a review artifact only: historical authors, access grants and source records stay intact.
    func previewMemberMapping(from sourceID: UUID, to targetID: UUID, mapping: [UUID: UUID]) throws -> MemberMappingPreview {
        let source = try space(sourceID), target = try space(targetID)
        guard sourceID != targetID, source.kind == .family, target.kind == .family else { throw NobisError.validation("请选择两个不同的家庭范围。") }
        let records = try records(spaceID: sourceID).filter { $0.body.sharedDestination == nil }
        guard !records.contains(where: \.conflicted) else { throw NobisError.conflict }
        let used = Set(records.flatMap { [$0.body.memberID, $0.body.financialOwner?.memberID, $0.body.completedBy].compactMap { $0 } + $0.body.splits.map(\.memberID) })
        let sourceMembers = Set(source.members.map(\.id)), targetMembers = Set(target.members.map(\.id))
        guard used.isSubset(of: Set(mapping.keys)), Set(mapping.keys).isSubset(of: sourceMembers.union(used)),
              Set(mapping.values).isSubset(of: targetMembers), Set(mapping.values).count == mapping.count else {
            throw NobisError.validation("请明确映射每个被引用的旧成员；目标须为该家庭成员，不能把不同旧成员合并成一个人。")
        }
        return MemberMappingPreview(sourceSpaceID: sourceID, targetSpaceID: targetID, mapping: mapping,
            sourceHeads: records.flatMap { $0.heads.map(\.id) }.sorted { $0.uuidString < $1.uuidString },
            referencedRecords: records.filter { $0.body.memberID != nil || $0.body.financialOwner?.memberID != nil || $0.body.completedBy != nil || !$0.body.splits.isEmpty }.count,
            responsibilityOrPayerCount: records.filter { $0.body.memberID != nil }.count,
            splitCount: records.filter { !$0.body.splits.isEmpty }.count,
            financialOwnerCount: records.filter { $0.body.financialOwner?.memberID != nil }.count,
            completionCount: records.filter { $0.body.completedBy != nil }.count, createdAt: Date())
    }
}
