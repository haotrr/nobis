import Foundation
import FamilyDomain

/// Stored only on the source device. No private IDs or histories are copied to the destination.
public struct SharingPlan: Codable, Sendable, Identifiable {
    public let id: UUID
    public let rootRecordID: UUID
    public let sourceSpaceID: UUID
    public let targetSpaceID: UUID
    public let sources: [Revision]
    public let targetIDs: [UUID: UUID]
    public let operationIDs: [UUID: UUID]
    public let cleanupIDs: [UUID: UUID]
    public let bodies: [UUID: RecordBody]
}
public extension FamilyCore {
    func previewSharing(recordID: UUID, from sourceID: UUID, to targetID: UUID) throws -> SharingPlan {
        let source = try space(sourceID), target = try space(targetID)
        guard source.kind == .personal, source.ownerID == session.actorID(in: sourceID), target.kind == .family else { throw NobisError.forbidden }
        try repository.requireWrite(spaceID: targetID, actorID: session.actorID(in: targetID))
        let all = try records(spaceID: sourceID)
        guard let root = all.first(where: { $0.id == recordID }), root.body.sharedDestination == nil else { throw NobisError.notFound }
        guard root.body.kind != .comment else { throw NobisError.validation("评注留在原文档中，不单独分享。") }
        var ids: Set<UUID> = [recordID]
        var changed = true
        while changed {
            let before = ids
            for r in all where r.body.parentProjectID.map(ids.contains) == true || !ids.isDisjoint(with: r.body.projectIDs) || r.body.refundOfID.map(ids.contains) == true || r.body.subscriptionID.map(ids.contains) == true {
                ids.insert(r.id)
            }
            changed = ids != before
        }
        let selected = all.filter { ids.contains($0.id) }
        guard !selected.contains(where: { $0.conflicted || $0.body.sharedDestination != nil || $0.body.projectIDs.count > 1 }) else { throw NobisError.validation("请先处理冲突、已分享来源和多项目归属。") }
        func references(_ b: RecordBody) -> [UUID] { (b.referenceIDs ?? []) + b.projectIDs + [b.parentProjectID,b.refundOfID,b.subscriptionID,b.relatedRecordID].compactMap { $0 } }
        guard selected.allSatisfy({ Set(references($0.body)).isSubset(of: ids) }) else { throw NobisError.validation("存在项目外引用，请从完整的所属项目分享，或先处理引用。") }
        let map = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, UUID()) })
        let plans = Dictionary(uniqueKeysWithValues: selected.flatMap { $0.body.budget?.items ?? [] }.map { ($0.id, UUID()) })
        var bodies: [UUID: RecordBody] = [:]
        for r in selected {
            var b = r.body
            b.projectIDs = b.projectIDs.compactMap { map[$0] }; b.parentProjectID = b.parentProjectID.flatMap { map[$0] }
            b.refundOfID = b.refundOfID.flatMap { map[$0] }; b.subscriptionID = b.subscriptionID.flatMap { map[$0] }; b.relatedRecordID = b.relatedRecordID.flatMap { map[$0] }
            b.referenceIDs = b.referenceIDs?.compactMap { map[$0] }
            if b.memberID != nil { b.memberID = session.actorID(in: targetID) }
            if b.financialOwner?.kind == .member { b.financialOwner?.memberID = session.actorID(in: targetID) }
            b.splits = b.splits.map { ShareAmount(memberID: session.actorID(in: targetID), minor: $0.minor) }
            b.completedBy = b.completedBy == nil ? nil : session.actorID(in: targetID)
            b.importSource = nil; b.sharedDestination = nil; b.occurrenceKey = nil
            if let budget = b.budget { b.budget = ProjectBudget(limit: budget.limit, items: budget.items.map { BudgetItem(id: plans[$0.id]!, name: $0.name, amount: $0.amount) }) }
            let planItem = b.finance?.planItemID.flatMap { plans[$0] }; b.finance?.planItemID = planItem
            bodies[r.id] = b
        }
        return SharingPlan(id: UUID(), rootRecordID: recordID, sourceSpaceID: sourceID, targetSpaceID: targetID, sources: selected.map(\.latest), targetIDs: map,
                           operationIDs: Dictionary(uniqueKeysWithValues: ids.map { ($0,UUID()) }), cleanupIDs: Dictionary(uniqueKeysWithValues: ids.map { ($0,UUID()) }), bodies: bodies)
    }
    func commitSharing(_ plan: SharingPlan) throws {
        let source = try space(plan.sourceSpaceID), target = try space(plan.targetSpaceID)
        guard source.kind == .personal, source.ownerID == session.actorID(in: source.id), target.kind == .family else { throw NobisError.forbidden }
        try repository.requireWrite(spaceID: target.id, actorID: session.actorID(in: target.id))
        var snapshot = try repository.load()
        let saved = snapshot.revisions.filter { Set(plan.operationIDs.values).contains($0.operationID) }
        if saved.isEmpty {
            for r in plan.sources {
                let current = try record(r.recordID, spaceID: source.id)
                guard current.heads == [r], !current.deleted else { throw NobisError.validation("内容已变化，请重新预览分享。") }
            }
            // New descendants since preview also invalidate the complete-project preview.
            let fresh = try previewSharing(recordID: plan.rootRecordID, from: source.id, to: target.id)
            guard Set(fresh.sources.map(\.recordID)) == Set(plan.sources.map(\.recordID)) else { throw NobisError.validation("分享范围已变化，请重新预览。") }
            let staged = MemoryRepository(snapshot)
            let core = FamilyCore(repository: staged, session: session)
            var pending = plan.sources
            while !pending.isEmpty {
                var progressed = false
                for r in pending {
                    guard let b = plan.bodies[r.recordID], let id = plan.targetIDs[r.recordID], let op = plan.operationIDs[r.recordID] else { throw NobisError.corruptBackup }
                    let refs = (b.referenceIDs ?? []) + b.projectIDs + [b.parentProjectID,b.refundOfID,b.subscriptionID,b.relatedRecordID].compactMap { $0 }
                    if refs.allSatisfy({ reference in staged.snapshot.revisions.contains { $0.recordID == reference } }) {
                        try core.save(b, spaceID: target.id, recordID: id, operationID: op)
                        pending.removeAll { $0.recordID == r.recordID }; progressed = true
                    }
                }
                guard progressed else { throw NobisError.validation("引用无法完整发布，请核对循环关联。") }
            }
            try repository.save(staged.snapshot)
            snapshot = try repository.load()
        } else {
            guard saved.count == plan.sources.count, plan.sources.allSatisfy({ r in saved.contains { $0.operationID == plan.operationIDs[r.recordID] && $0.spaceID == target.id && $0.recordID == plan.targetIDs[r.recordID] && $0.body == plan.bodies[r.recordID] } }) else { throw NobisError.validation("分享写入状态不完整，原数据保留，请核对。") }
        }
        // Separate durable step. Source remains intact; only its active projection is retired.
        try repository.requireWrite(spaceID: source.id, actorID: session.actorID(in: source.id))
        let staged = MemoryRepository(snapshot), core = FamilyCore(repository: MemoryRepository(snapshot), session: session)
        for r in plan.sources {
            let current = try core.record(r.recordID, spaceID: source.id)
            let destination = SharedDestination(spaceID: target.id, recordID: plan.targetIDs[r.recordID]!)
            if current.body.sharedDestination == destination { continue }
            guard current.heads == [r] else { throw NobisError.validation("共同版本已保存，但来源发生变化；请保留分享回执并核对。") }
            var body = r.body; body.sharedDestination = destination
            let revision = Revision(recordID: r.recordID, spaceID: source.id, parents: [r.id], operationID: plan.cleanupIDs[r.recordID]!, actorID: session.actorID(in: source.id), body: body)
            staged.snapshot.revisions.append(revision); staged.snapshot.audits.append(AuditEvent(revision: revision, action: "share-source-retired"))
        }
        try repository.save(staged.snapshot)
    }
}
