import Foundation
import Testing
import FamilyDomain
import FamilyCore

@Suite("恢复合并") @MainActor struct RecoveryMergeTests {
    func destination(_ f: Fixture) -> (Space, MemoryRepository, FamilyCore, [UUID: UUID]) {
        let a = Member(name: "甲"), b = Member(name: "乙")
        let space = Space(name: "迁入目标副本", kind: .family, ownerID: a.id, members: [a,b])
        let repository = MemoryRepository(Snapshot(spaces: [space]))
        return (space, repository, FamilyCore(repository: repository, session: AccessSession(memberID: a.id, allowedSpaceIDs: [space.id])), [f.a.id:a.id,f.b.id:b.id])
    }
    @Test func mappedImportKeepsLinksAmountsAndCompletionAndIsIdempotent() throws {
        let f = Fixture()
        let project = try f.core.save(RecordBody(kind: .project, title: "原项目"), spaceID: f.family.id)
        var expense = try f.expense(); expense.projectIDs = [project.recordID]
        try f.core.save(expense, spaceID: f.family.id)
        var task = RecordBody(kind: .task, title: "已完成事项", status: .completed); task.memberID = f.b.id; task.projectIDs = [project.recordID]
        let completed = try f.core.save(task, spaceID: f.family.id)
        let before = f.repository.snapshot, data = try f.core.export(spaceID: f.family.id)
        let (space, repository, core, mapping) = destination(f)
        let plan = try core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping)
        #expect(plan.canCommit && plan.additions == 3)
        #expect(repository.snapshot.revisions.isEmpty)
        #expect(try core.commitRecovery(plan) == 3)
        let records = try core.records(spaceID: space.id)
        let movedProject = try #require(records.first { $0.body.kind == .project })
        let movedExpense = try #require(records.first { $0.body.kind == .transaction })
        let movedTask = try #require(records.first { $0.body.kind == .task })
        #expect(movedExpense.body.projectIDs == [movedProject.id])
        #expect(movedExpense.body.memberID == mapping[f.a.id])
        #expect(Set(movedExpense.body.splits.map(\.memberID)) == Set(mapping.values))
        #expect(movedTask.body.memberID == mapping[f.b.id])
        #expect(movedTask.body.completedAt == completed.body.completedAt)
        #expect(movedTask.body.completedBy == mapping[completed.body.completedBy!])
        #expect(try core.ledger(spaceID: space.id).first?.netExpense == 10001)
        #expect(f.repository.snapshot == before)
        let again = try core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping)
        #expect(again.additions == 0 && again.conflicts == 0 && again.items.allSatisfy { $0.disposition == .identical })
        _ = try Backup.decode(core.export(spaceID: space.id))
    }
    @Test func differencesRequireKeepAndNeverOverwriteTarget() throws {
        let f = Fixture(); let first = try f.core.save(RecordBody(kind: .task, title: "旧标题"), spaceID: f.family.id)
        let (space, repository, core, mapping) = destination(f)
        let data = try f.core.export(spaceID: f.family.id)
        try core.commitRecovery(core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping))
        let old = try #require(core.records(spaceID: space.id).first)
        var edit = old.body; edit.title = "目标已编辑"
        try core.save(edit, spaceID: space.id, recordID: old.id, expected: Set(old.heads.map(\.id)))
        try f.core.save(RecordBody(kind: .task, title: "新任务"), spaceID: f.family.id)
        let next = try f.core.export(spaceID: f.family.id), before = repository.snapshot
        let blocked = try core.previewRecovery(next, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping)
        #expect(blocked.conflicts == 1 && blocked.additions == 1)
        #expect(throws: NobisError.self) { try core.commitRecovery(blocked) }
        #expect(repository.snapshot == before)
        let kept = try core.previewRecovery(next, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping, keepingTarget: [first.recordID])
        #expect(kept.conflicts == 0)
        try core.commitRecovery(kept)
        #expect(try core.record(old.id, spaceID: space.id).body.title == "目标已编辑")
        #expect(try core.history(old.id, spaceID: space.id).count == 2)
    }
    @Test func stalePlanAndPrivacyAndIncompleteMappingAreRejected() throws {
        let f = Fixture(); try f.core.save(f.expense(), spaceID: f.family.id)
        let (space, repository, core, mapping) = destination(f)
        let data = try f.core.export(spaceID: f.family.id)
        #expect(throws: NobisError.self) { try core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: [:]) }
        let plan = try core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping)
        try core.save(RecordBody(kind: .task, title: "预览后新增"), spaceID: space.id)
        let before = repository.snapshot
        #expect(throws: NobisError.self) { try core.commitRecovery(plan) }
        #expect(repository.snapshot == before)
        #expect(throws: NobisError.self) { try core.previewRecovery(f.core.export(spaceID: f.personal.id), sourceSpaceID: f.personal.id, targetSpaceID: space.id, members: [f.a.id:space.ownerID]) }
    }
    @Test func incrementalMintyImportUsesRecoveredProjectIDs() throws {
        let f = Fixture(), (space, _, core, mapping) = destination(f)
        var expense: [String: Any] = ["id": 1, "item": "项目支出", "date": "2026-10-01", "amount": "10", "category": "其他", "project_id": 1]
        func package(_ expenses: [[String: Any]]) throws -> ImportPreview {
            try MintyMigration.preview(JSONSerialization.data(withJSONObject: ["format":"minty-nobis", "version":1, "source":"copy", "tables":[
                "projects":[["id":1,"name":"项目","status":"active","budget_amount":"100"]], "expenses":expenses
            ]]))
        }
        let first = try package([expense]); try f.core.commitImport(first, spaceID: f.family.id)
        let source = try f.core.export(spaceID: f.family.id)
        try core.commitRecovery(core.previewRecovery(source, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping))
        let project = try #require(core.records(spaceID: space.id).first { $0.body.kind == .project })
        let original = expense; expense["id"] = 2
        #expect(try core.commitImport(package([original, expense]), spaceID: space.id) == 1)
        let transactions = try core.records(spaceID: space.id).filter { $0.body.kind == .transaction }
        #expect(transactions.count == 2 && transactions.allSatisfy { $0.body.projectIDs == [project.id] })
    }
    @Test func deletedTargetDoesNotReviveAndResolvedCommentsMigrate() throws {
        let f = Fixture(); var document = RecordBody(kind: .document, title: "正文"); document.notes = "原文"
        let doc = try f.core.save(document, spaceID: f.family.id)
        var comment = RecordBody(kind: .comment, title: "评注"); comment.notes = "核对"; comment.relatedRecordID = doc.recordID
        let root = try f.core.save(comment, spaceID: f.family.id)
        comment.status = .completed
        try f.core.save(comment, spaceID: f.family.id, recordID: root.recordID, expected: [root.id])
        let (space, _, core, mapping) = destination(f), data = try f.core.export(spaceID: f.family.id)
        let plan = try core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping)
        #expect(plan.conflicts == 0)
        try core.commitRecovery(plan)
        let moved = try #require(core.records(spaceID: space.id).first { $0.body.kind == .document })
        #expect(try core.documentComments(moved.id, spaceID: space.id).first?.body.status == .completed)
        try core.save(moved.body, spaceID: space.id, recordID: moved.id, expected: Set(moved.heads.map(\.id)), deleted: true)
        #expect(try core.previewRecovery(data, sourceSpaceID: f.family.id, targetSpaceID: space.id, members: mapping, keepingTarget: [doc.recordID]).conflicts == 1)
    }
}
