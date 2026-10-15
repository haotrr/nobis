import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

@Suite("跨日刷新") @MainActor struct DailyRefreshTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func midnightRefreshUpdatesGroupsAndPreservesEditing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "测试", familyName: "测试家庭", partnerName: "另一位")
        let spaceID = try #require(model.workspace.commonID)
        var body = RecordBody(kind: .task, title: "跨日待办")
        body.date = try LocalDay(2026, 10, 15)
        try model.save(body, spaceID: spaceID)
        let record = try #require(model.records.first { $0.body.title == body.title })
        model.recordPanel.open(record.id)
        model.recordPanel.edit(record)
        model.recordPanel.updateChanges(true, recordID: record.id)
        let epoch = model.accessEpoch
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        model.refresh(now: date("2026-10-15T15:59:59Z"), timeZone: zone)
        #expect(model.today == body.date)
        #expect(TaskDateGroup.overdue.records(in: model.activeRecords, today: model.today).isEmpty)
        model.refresh(now: date("2026-10-15T16:00:00Z"), timeZone: zone)
        #expect(model.today == (try LocalDay(2026, 10, 16)))
        #expect(TaskDateGroup.overdue.records(in: model.activeRecords, today: model.today).map(\.id) == [record.id])
        #expect(model.recordPanel.editingRecord?.id == record.id)
        #expect(model.recordPanel.hasChanges)
        #expect(model.accessEpoch == epoch)
        #expect(try model.core?.history(record.id, spaceID: spaceID).count == 1)
        model.refresh(now: date("2026-10-15T16:00:00Z"), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(model.today == body.date)
        #expect(TaskDateGroup.overdue.records(in: model.activeRecords, today: model.today).isEmpty)
    }

    @Test func crossingRenewalWindowCreatesOneTaskInSubscriptionTimeZone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "测试", familyName: "测试家庭", partnerName: "另一位")
        let core = try #require(model.core), spaceID = try #require(model.workspace.commonID)
        var body = RecordBody(kind: .subscription, title: "跨日续费")
        body.date = try LocalDay(2026, 10, 23); body.billingAnchor = body.date
        body.memberID = try core.space(spaceID).ownerID
        body.timeZone = "Pacific/Honolulu"; body.reminderDays = [7, 0]
        try core.save(body, spaceID: spaceID)
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        model.refresh(now: date("2026-10-15T15:59:59Z"), timeZone: zone)
        #expect(model.records.filter { $0.body.kind == .task }.isEmpty)
        for _ in 0..<2 { model.refresh(now: date("2026-10-15T16:00:00Z"), timeZone: zone) }
        let tasks = model.records.filter { $0.body.kind == .task }
        #expect(tasks.count == 1)
        #expect(tasks.first?.body.timeZone == body.timeZone)
        let plan = try ReminderPlanning.plan(records: tasks, preferences: ReminderPreferences(), now: date("2026-10-16T00:00:00Z"))
        #expect(plan.first?.fireDate == date("2026-10-23T19:00:00Z"))
        #expect(try core.ledger(spaceID: spaceID).isEmpty)
    }
}
