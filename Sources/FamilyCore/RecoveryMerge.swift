import Foundation
import FamilyDomain

public enum RecoveryDisposition: String, Sendable { case addition, identical, kept, difference, conflict, omitted }
public struct RecoveryItem: Identifiable, Sendable {
    public let id: UUID
    public let source: Record
    public let target: Record?
    public let disposition: RecoveryDisposition
    public let detail: String
}
public struct RecoveryMergePlan: Sendable {
    public let sourceSpace: Space
    public let targetSpace: Space
    public let items: [RecoveryItem]
    public var additions: Int { items.filter { $0.disposition == .addition }.count }
    public var conflicts: Int { items.filter { $0.disposition == .conflict || $0.disposition == .difference }.count }
    public var canCommit: Bool { conflicts == 0 && additions > 0 }
    fileprivate let actorID: UUID
    fileprivate let targetBefore: Snapshot
    fileprivate let staged: Snapshot
}

public extension FamilyCore {
    /// Restore current copies, never overwrite a target revision. Full original history stays in the source backup.
    func previewRecovery(_ data: Data, sourceSpaceID: UUID, targetSpaceID: UUID,
                         members: [UUID: UUID], keepingTarget: Set<UUID> = []) throws -> RecoveryMergePlan {
        let sourceSnapshot = try Backup.decode(data)
        guard let source = sourceSnapshot.spaces.first(where: { $0.id == sourceSpaceID }) else { throw NobisError.corruptBackup }
        let target = try space(targetSpaceID)
        guard source.kind == target.kind else { throw NobisError.validation("恢复合并不能改变共同／私密范围，请使用专门的分享流程。") }
        let sourceRecords = Record.project(sourceSnapshot.revisions.filter { $0.spaceID == sourceSpaceID })
        let used = Set(sourceRecords.filter { !$0.deleted && $0.body.sharedDestination == nil }.flatMap {
            [$0.body.memberID, $0.body.financialOwner?.memberID, $0.body.completedBy].compactMap { $0 } + $0.body.splits.map(\.memberID)
        })
        guard used.isSubset(of: Set(members.keys)), Set(members.keys).isSubset(of: Set(source.members.map(\.id)).union(used)),
              Set(members.values).isSubset(of: Set(target.members.map(\.id))), Set(members.values).count == members.count else {
            throw NobisError.validation("请映射所有被引用的旧成员，不能将不同成员合并或选择范围外成员。")
        }
        if source.kind == .personal {
            guard members[source.ownerID] == target.ownerID else { throw NobisError.validation("请明确确认私密备份拥有者对应当前私密空间拥有者。") }
        }
        let before = try repository.load()
        let existing = Record.project(before.revisions.filter { $0.spaceID == targetSpaceID })
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id,$0) })
        let bySource = Dictionary(grouping: existing.filter { $0.body.importSource != nil }, by: { $0.body.importSource!.key })
        var ids: [UUID: UUID] = [:], ambiguous = Set<UUID>()
        for r in sourceRecords {
            let stable = sourceSpaceID == targetSpaceID ? r.id : LedgerImport.stableID("recovery:\(sourceSpaceID):\(targetSpaceID):\(r.id)")
            var candidates = r.body.importSource.flatMap { bySource[$0.key] } ?? []
            if candidates.isEmpty, r.body.kind == .category {
                candidates = existing.filter { !$0.deleted && $0.body.kind == .category && $0.body.title == r.body.title && $0.body.status == .active }
            }
            if candidates.isEmpty, r.body.kind == .assetSnapshot {
                var owner = r.body.financialOwner
                let member = owner?.memberID.flatMap { members[$0] }; owner?.memberID = member
                candidates = existing.filter { !$0.deleted && $0.heads.contains {
                    $0.body.kind == .assetSnapshot && $0.body.status == .active && $0.body.financialOwner == owner &&
                    $0.body.date == r.body.date && $0.body.assetPosition?.currency == r.body.assetPosition?.currency
                } }
            }
            if candidates.count > 1 { ambiguous.insert(r.id) }
            if let direct = byID[stable] {
                ids[r.id] = direct.id
                if candidates.contains(where: { $0.id != direct.id }) { ambiguous.insert(r.id) }
            } else { ids[r.id] = candidates.first?.id ?? stable }
        }
        for group in Dictionary(grouping: sourceRecords, by: { ids[$0.id]! }).values where group.count > 1 { ambiguous.formUnion(group.map(\.id)) }
        let liveIDs = Set(sourceRecords.filter { !$0.deleted && $0.body.sharedDestination == nil }.map(\.id))
        func refs(_ b: RecordBody) -> [UUID] { b.projectIDs + (b.referenceIDs ?? []) + [b.parentProjectID,b.subscriptionID,b.refundOfID,b.relatedRecordID].compactMap { $0 } }
        var pending: [(Record, RecordBody)] = [], items: [RecoveryItem] = []
        for r in sourceRecords {
            let old = byID[ids[r.id]!]
            func item(_ status: RecoveryDisposition, _ reason: String) -> RecoveryItem { RecoveryItem(id: r.id, source: r, target: old, disposition: status, detail: reason) }
            if r.deleted || r.body.sharedDestination != nil { items.append(item(.omitted, "源记录已删除或已发布共同副本，不迁入，也不删除目标。")); continue }
            if r.conflicted || ambiguous.contains(r.id) { items.append(item(.conflict, "来源有未解决修订或来源对应关系不唯一，请先核对。")); continue }
            guard Set(refs(r.body)).isSubset(of: liveIDs) else { items.append(item(.conflict, "关联记录已删除或未包含在迁入范围，不能形成完整关系。")); continue }
            var b = r.body
            b.memberID = b.memberID.flatMap { members[$0] }
            let mappedOwner = b.financialOwner?.memberID.flatMap { members[$0] }
            b.financialOwner?.memberID = mappedOwner
            b.completedBy = b.completedBy.flatMap { members[$0] }
            b.splits = b.splits.map { ShareAmount(memberID: members[$0.memberID]!, minor: $0.minor) }
            b.projectIDs = b.projectIDs.map { ids[$0]! }; b.referenceIDs = b.referenceIDs?.map { ids[$0]! }
            b.parentProjectID = b.parentProjectID.flatMap { ids[$0] }; b.subscriptionID = b.subscriptionID.flatMap { ids[$0] }
            b.refundOfID = b.refundOfID.flatMap { ids[$0] }; b.relatedRecordID = b.relatedRecordID.flatMap { ids[$0] }
            if let old {
                if old.deleted || old.conflicted { items.append(item(.conflict, "目标已删除或存在冲突，不自动复活或选择版本。")) }
                else if old.body == b { items.append(item(.identical, "映射后内容一致，跳过。")) }
                else if keepingTarget.contains(r.id) { items.append(item(.kept, "已选择保留目标内容，来源差异仅留在源备份。")) }
                else { items.append(item(.difference, Self.recoveryDifference(b, old.body))) }
            } else { pending.append((r,b)) }
        }
        let staged = MemoryRepository(before)
        // One staging repository ensures later records see earlier linked records.
        let validator = FamilyCore(repository: staged, session: session)
        try validator.prepareBatchProjection(spaceID: targetSpaceID)
        while !pending.isEmpty {
            var progressed = false
            let available = Set(staged.snapshot.revisions.filter { $0.spaceID == targetSpaceID }.map(\.recordID))
            for (r,b) in pending where Set(refs(b)).isSubset(of: available) {
                do {
                    var initial = b
                    if b.kind == .comment && b.status == .completed { initial.status = .active }
                    var revision = try validator.save(initial, spaceID: targetSpaceID, recordID: ids[r.id]!)
                    if initial != b { revision = try validator.save(b, spaceID: targetSpaceID, recordID: ids[r.id]!, expected: [revision.id]) }
                    if b.kind == .task && b.status == .completed {
                        let preserved = Revision(id: revision.id, recordID: revision.recordID, spaceID: revision.spaceID, parents: revision.parents, operationID: revision.operationID, actorID: revision.actorID, createdAt: revision.createdAt, body: b)
                        staged.snapshot.revisions[staged.snapshot.revisions.count - 1] = preserved
                    }
                    items.append(RecoveryItem(id: r.id, source: r, target: nil, disposition: .addition, detail: "新增当前版本；源修订和审计保留在完整备份。"))
                } catch { items.append(RecoveryItem(id: r.id, source: r, target: nil, disposition: .conflict, detail: error.localizedDescription)) }
                pending.removeAll { $0.0.id == r.id }; progressed = true
            }
            if !progressed {
                items += pending.map { RecoveryItem(id: $0.0.id, source: $0.0, target: nil, disposition: .conflict, detail: "依赖缺失、被阻断或存在循环引用，请先处理关联记录。") }
                pending = []
            }
        }
        return RecoveryMergePlan(sourceSpace: source, targetSpace: target, items: items.sorted { $0.source.body.title < $1.source.body.title }, actorID: session.actorID(in: targetSpaceID), targetBefore: before, staged: staged.snapshot)
    }
    func commitRecovery(_ plan: RecoveryMergePlan) throws -> Int {
        guard plan.canCommit else { throw NobisError.validation("请先解决全部冲突，并确认存在新增记录。") }
        _ = try space(plan.targetSpace.id)
        guard plan.actorID == session.actorID(in: plan.targetSpace.id) else { throw NobisError.forbidden }
        try repository.requireWrite(spaceID: plan.targetSpace.id, actorID: session.actorID(in: plan.targetSpace.id))
        guard try repository.load() == plan.targetBefore else { throw NobisError.validation("预览后目标数据发生变化，请重新预览。") }
        try repository.save(plan.staged)
        return plan.additions
    }
    private static func recoveryDifference(_ source: RecordBody, _ target: RecordBody) -> String {
        var fields: [String] = []
        if source.title != target.title { fields.append("标题") }
        if source.notes != target.notes { fields.append("正文／备注") }
        if source.status != target.status { fields.append("状态") }
        if source.money != target.money || source.incomeMonth != target.incomeMonth || source.assetPosition != target.assetPosition { fields.append("金额／财务明细") }
        if source.memberID != target.memberID || source.splits != target.splits || source.financialOwner != target.financialOwner { fields.append("成员归属／分摊") }
        if source.date != target.date || source.endDate != target.endDate { fields.append("日期") }
        if source.projectIDs != target.projectIDs || source.budget != target.budget { fields.append("项目／预算") }
        return "内容不同：" + (fields.isEmpty ? "其他属性或关联" : fields.joined(separator: "、")) + "。可明确保留目标；不会覆盖。"
    }
}
