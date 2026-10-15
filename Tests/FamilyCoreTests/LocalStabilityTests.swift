import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

@MainActor private final class IntermittentRepository: Repository {
    var snapshot: Snapshot
    var failure: Error?
    init(_ snapshot: Snapshot) { self.snapshot = snapshot }
    func load() throws -> Snapshot { if let failure { throw failure }; return snapshot }
    func save(_ snapshot: Snapshot) throws { self.snapshot = snapshot }
}

@Suite("本地稳定性收尾") @MainActor struct LocalStabilityTests {
    @Test(arguments: ["{\"year\":2026,\"month\":2,\"day\":30}", "{\"year\":0,\"month\":1,\"day\":1}", "{\"year\":2026,\"month\":13,\"day\":1}", "{\"year\":9223372036854775807,\"month\":1,\"day\":1}"])
    func invalidDecodedDatesAreRejected(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalDay.self, from: Data(json.utf8)) }
    }
    @Test func datesRoundTripAndArithmeticRemainCalendarBased() throws {
        for day in [try LocalDay(2024, 2, 29), try LocalDay(2011, 12, 30), try LocalDay(2026, 12, 31)] {
            #expect(try JSONDecoder().decode(LocalDay.self, from: JSONEncoder().encode(day)) == day)
            #expect(day.addingDays(1).addingDays(-1) == day)
        }
        #expect(try LocalDay(2026, 12, 31).addingDays(1) == LocalDay(2027, 1, 1))
    }
    @Test func refreshPublishesRecordsAndTotalsTogetherAndCanRecover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "测试", familyName: "测试家庭", partnerName: "另一位")
        let originalCore = try #require(model.core), id = try #require(model.selectedSpaceID)
        let repository = IntermittentRepository(try originalCore.repository.load())
        let core = FamilyCore(repository: repository, session: originalCore.session)
        model.core = core
        var body = RecordBody(kind: .transaction, title: "测试支出", status: .confirmed)
        body.date = try LocalDay(2026, 10, 15); body.money = Money(minor: 100, currency: .CNY)
        body.finance = FinanceDetails()
        try core.save(body, spaceID: id)
        model.refresh()
        let before = model.records.map(\.id)
        #expect(model.summaries.first?.netExpense == 100)
        repository.failure = CocoaError(.fileReadNoPermission)
        model.refresh()
        #expect(model.records.map(\.id) == before)
        #expect(model.summaries.first?.netExpense == 100)
        #expect(model.error?.contains("上次成功") == true)
        repository.failure = nil
        let goodSnapshot = repository.snapshot
        // A load succeeds but totals overflow: neither the new records nor partial totals publish.
        body.money = Money(minor: Int64.max, currency: .CNY)
        let overflowing = Revision(spaceID: id, actorID: core.session.actorID(in: id), body: body)
        repository.snapshot.revisions.append(overflowing)
        model.refresh()
        #expect(model.records.map(\.id) == before)
        #expect(model.summaries.first?.netExpense == 100)
        repository.snapshot = goodSnapshot
        body.money = Money(minor: 200, currency: .CNY); body.title = "第二笔"
        try core.save(body, spaceID: id)
        model.error = nil; model.refresh()
        #expect(model.records.count == 2)
        #expect(model.summaries.first?.netExpense == 300)
        #expect(model.error == nil)
        repository.snapshot.spaces.removeAll { $0.id == id }
        model.refresh()
        #expect(model.records.isEmpty && model.summaries.isEmpty)
        #expect(model.error == NobisError.forbidden.localizedDescription)
    }
    @Test func reminderUpdateRetainsDesiredRequestsDuringPartialFailure() throws {
        let f = Fixture()
        var task = RecordBody(kind: .task, title: "提醒")
        task.date = try LocalDay(2030, 1, 1); task.timeZone = "UTC"
        try f.core.save(task, spaceID: f.family.id)
        let plan = try ReminderPlanning.plan(records: f.core.records(spaceID: f.family.id), preferences: ReminderPreferences(), now: .distantPast)
        let id = try #require(plan.first?.id)
        let pending = [id, "nobis:obsolete", "unrelated"]
        let update = ReminderScheduleUpdate(planned: plan, pendingIDs: pending)
        #expect(update.scheduling.map(\.id) == [id])
        #expect(update.removingIDs == ["nobis:obsolete"])
        // Removing obsolete requests followed by a failed add must retain the prior valid request.
        #expect(Set(pending).subtracting(update.removingIDs) == [id, "unrelated"])
        #expect(ReminderScheduleUpdate(planned: [], pendingIDs: pending).removingIDs == [id, "nobis:obsolete"])
        #expect(ReminderScheduleUpdate(planned: plan, pendingIDs: pending, limit: 0).scheduling.isEmpty)
    }
    @Test func backupLongHistoryAndLinkedRecordsRoundTrip() throws {
        let f = Fixture()
        let project = Revision(spaceID: f.family.id, actorID: f.a.id, body: RecordBody(kind: .project, title: "项目"))
        var revisions = [project]
        let recordID = UUID()
        var parents: [UUID] = []
        var body = RecordBody(kind: .document, title: "长期笔记")
        body.projectIDs = [project.recordID]
        body.notes = String(repeating: "正文与清单\n", count: 30)
        for _ in 0..<6000 {
            let r = Revision(recordID: recordID, spaceID: f.family.id, parents: parents, actorID: f.a.id, body: body)
            revisions.append(r); parents = [r.id]
        }
        for _ in 0..<2000 {
            var task = RecordBody(kind: .task, title: "关联事项")
            task.projectIDs = [project.recordID]; task.referenceIDs = [recordID]
            revisions.append(Revision(spaceID: f.family.id, actorID: f.a.id, body: task))
        }
        let snapshot = Snapshot(spaces: [f.family], revisions: revisions, audits: revisions.map { AuditEvent(revision: $0, action: "test") })
        let data = try Backup.encode(snapshot)
        let start = Date()
        #expect(try Backup.decode(data) == snapshot)
        print("Synthetic backup: \(revisions.count) revisions, \(data.count) bytes, validation \(Date().timeIntervalSince(start))s")
    }
    @Test func backupRejectsCyclesMissingParentsAndCrossSpaceReferences() throws {
        let f = Fixture(), a = UUID(), b = UUID(), recordID = UUID()
        let body = RecordBody(kind: .task, title: "循环")
        let first = Revision(id: a, recordID: recordID, spaceID: f.family.id, parents: [b], actorID: f.a.id, body: body)
        let second = Revision(id: b, recordID: recordID, spaceID: f.family.id, parents: [a], actorID: f.a.id, body: body)
        for revisions in [[first, second], [first]] {
            #expect(throws: NobisError.corruptBackup) { try Backup.decode(Backup.encode(Snapshot(spaces: [f.family], revisions: revisions))) }
        }
        let privateProject = Revision(spaceID: f.personal.id, actorID: f.a.id, body: RecordBody(kind: .project, title: "私密项目"))
        var linked = body; linked.projectIDs = [privateProject.recordID]
        let task = Revision(spaceID: f.family.id, actorID: f.a.id, body: linked)
        #expect(throws: NobisError.corruptBackup) { try Backup.decode(Backup.encode(Snapshot(spaces: [f.family, f.personal], revisions: [privateProject, task]))) }
    }
}
