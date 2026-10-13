import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence

@Suite("共同生活与私密边界") @MainActor struct LifeWorkspaceTests {
    func expense(_ f: Fixture, _ amount: Int64) throws -> RecordBody {
        var b = try f.expense(amount); b.finance = FinanceDetails(); b.splits = []; return b
    }
    @Test func unifiedScopeAndReportsAreReadOnly() throws {
        let f = Fixture(), otherFamily = Space(name: "待迁入", kind: .family, ownerID: UUID(), members: [])
        let view = LifeWorkspace(spaces: [f.personal, otherFamily, f.family], cloudID: f.family.id)
        #expect(view.commonID == f.family.id); #expect(view.pendingSpaces.map(\.id) == [otherFamily.id])
        #expect(view.ids(.all) == [f.family.id, f.personal.id])
        try f.core.save(expense(f,100), spaceID: f.personal.id)
        try f.core.save(expense(f,200), spaceID: f.family.id)
        let shared = try f.core.reportView(spaceIDs: view.ids(.shared)), all = try f.core.reportView(spaceIDs: view.ids(.all))
        #expect(try shared.core.financialReport(spaceID: shared.spaceID, year: 2026).totals.first?.expense == 200)
        #expect(try all.core.financialReport(spaceID: all.spaceID, year: 2026).totals.first?.expense == 300)
        #expect(throws: NobisError.self) { try all.core.save(RecordBody(kind: .task, title: "不能写投影"), spaceID: all.spaceID) }
        let partner = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.b.id, allowedSpaceIDs: [f.family.id,f.personal.id]))
        #expect(throws: NobisError.self) { try partner.reportView(spaceIDs: [f.personal.id]) }
        #expect(try partner.spaces().map(\.id) == [f.family.id])
    }
    @Test func inheritedStorageAndLegacyMultiProject() throws {
        let f = Fixture()
        let p = try f.core.save(RecordBody(kind: .project, title: "惊喜"), spaceID: f.personal.id)
        var task = RecordBody(kind: .task, title: "准备"); task.projectIDs = [p.recordID]
        #expect(throws: NobisError.self) { try f.core.save(task, spaceID: f.family.id) }
        try f.core.save(task, spaceID: f.personal.id)
        let p2 = try f.core.save(RecordBody(kind: .project, title: "另一个"), spaceID: f.personal.id)
        task.projectIDs.append(p2.recordID)
        #expect(throws: NobisError.self) { try f.core.save(task, spaceID: f.personal.id) }
        let legacy = Revision(spaceID: f.personal.id, actorID: f.a.id, body: task)
        f.repository.snapshot.revisions.append(legacy); f.repository.snapshot.audits.append(AuditEvent(revision: legacy, action: "legacy"))
        task.notes = "保留原关联"
        try f.core.save(task, spaceID: f.personal.id, recordID: legacy.recordID, expected: [legacy.id])
    }
    @Test func sharingPublishesCurrentGraphOnlyAndIsIdempotent() throws {
        let f = Fixture()
        var p = RecordBody(kind: .project, title: "惊喜旧标题"); p.notes = "不公开的旧备注"
        let old = try f.core.save(p, spaceID: f.personal.id)
        p.title = "旅行"; p.notes = "当前备注"
        let project = try f.core.save(p, spaceID: f.personal.id, recordID: old.recordID, expected: [old.id])
        var b = try expense(f, 1234); b.projectIDs = [project.recordID]
        try f.core.save(b, spaceID: f.personal.id)
        let plan = try f.core.previewSharing(recordID: project.recordID, from: f.personal.id, to: f.family.id)
        try f.core.commitSharing(plan); try f.core.commitSharing(plan)
        let shared = try f.core.records(spaceID: f.family.id)
        #expect(shared.count == 2)
        #expect(shared.allSatisfy { $0.heads.count == 1 && $0.body.notes != "不公开的旧备注" && $0.body.importSource == nil })
        #expect(try f.core.history(plan.targetIDs[project.recordID]!, spaceID: f.family.id).count == 1)
        let all = try f.core.reportView(spaceIDs: [f.personal.id,f.family.id])
        #expect(try all.core.financialReport(spaceID: all.spaceID, year: 2026).totals.first?.expense == 1234)
        #expect(try f.core.ledger(spaceID: f.personal.id).isEmpty)
        #expect(try Backup.decode(f.core.export(spaceID: f.personal.id)).revisions.count == 5)
    }
    @Test func stalePreviewAndExternalReferencesNeverPartiallyPublish() throws {
        let f = Fixture()
        let p = try f.core.save(RecordBody(kind: .project, title: "惊喜"), spaceID: f.personal.id)
        let plan = try f.core.previewSharing(recordID: p.recordID, from: f.personal.id, to: f.family.id)
        var task = RecordBody(kind: .task, title: "新增子项"); task.projectIDs = [p.recordID]
        let t = try f.core.save(task, spaceID: f.personal.id)
        #expect(throws: NobisError.self) { try f.core.commitSharing(plan) }
        #expect(try f.core.records(spaceID: f.family.id).isEmpty)
        #expect(throws: NobisError.self) { try f.core.previewSharing(recordID: t.recordID, from: f.personal.id, to: f.family.id) }
    }
    @Test func ownershipSnapshotsRemainSeparateAndBackupPreservesThem() throws {
        let f = Fixture()
        var b = try FinancialReportTests().asset()
        try f.core.save(b, spaceID: f.family.id)
        b.financialOwner = FinancialOwner(kind: .member, memberID: f.a.id)
        try f.core.save(b, spaceID: f.family.id)
        b.financialOwner = FinancialOwner(kind: .joint)
        try f.core.save(b, spaceID: f.family.id)
        let observations = try f.core.positions(spaceID: f.family.id, through: LocalDay(2026,10,31))
        #expect(observations.count == 3); #expect(observations.allSatisfy { !$0.ambiguous })
        let backup = try Backup.decode(f.core.export(spaceID: f.family.id))
        #expect(backup.revisions.filter { $0.body.financialOwner != nil }.count == 2)
        b.financialOwner = FinancialOwner(kind: .member, memberID: UUID())
        #expect(throws: NobisError.self) { try f.core.save(b, spaceID: f.family.id) }
    }
    @Test func sharingSurvivesFailureBetweenStores() throws {
        let f = Fixture()
        let p = try f.core.save(RecordBody(kind: .project, title: "可重试"), spaceID: f.personal.id)
        let repository = FailSecondSave(snapshot: f.repository.snapshot)
        let core = FamilyCore(repository: repository, session: f.core.session)
        let plan = try core.previewSharing(recordID: p.recordID, from: f.personal.id, to: f.family.id)
        #expect(throws: NobisError.self) { try core.commitSharing(plan) }
        #expect(try core.records(spaceID: f.family.id).count == 1)
        try core.commitSharing(plan)
        #expect(try core.records(spaceID: f.family.id).count == 1)
        #expect(try core.record(p.recordID, spaceID: f.personal.id).body.sharedDestination != nil)
    }
}
@MainActor private final class FailSecondSave: Repository {
    var snapshot: Snapshot; var calls = 0
    init(snapshot: Snapshot) { self.snapshot = snapshot }
    func load() throws -> Snapshot { snapshot }
    func save(_ snapshot: Snapshot) throws { calls += 1; if calls == 2 { throw NobisError.validation("模拟来源落盘失败") }; self.snapshot = snapshot }
}
