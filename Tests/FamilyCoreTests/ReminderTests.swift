import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

@Suite("日常提醒") @MainActor struct ReminderTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    @Test func quietBoundariesAndOvernight() throws {
        var p = ReminderPreferences(); p.quietEnabled = true
        let zone = TimeZone(secondsFromGMT: 0)!
        #expect(p.adjusted(date("2026-10-13T21:59:00Z"), deviceTimeZone: zone) == date("2026-10-13T21:59:00Z"))
        #expect(p.adjusted(date("2026-10-13T22:00:00Z"), deviceTimeZone: zone) == date("2026-10-14T08:00:00Z"))
        #expect(p.adjusted(date("2026-10-14T07:59:00Z"), deviceTimeZone: zone) == date("2026-10-14T08:00:00Z"))
        #expect(p.adjusted(date("2026-10-14T08:00:00Z"), deviceTimeZone: zone) == date("2026-10-14T08:00:00Z"))
        p.quietStart = 8 * 60; p.quietEnd = 10 * 60
        #expect(p.adjusted(date("2026-10-14T09:00:00Z"), deviceTimeZone: zone) == date("2026-10-14T10:00:00Z"))
        p.quietEnd = p.quietStart
        #expect(throws: NobisError.self) { try p.validate() }
    }
    @Test func daylightSavingMissingAndRepeatedEnd() {
        var p = ReminderPreferences(); p.quietEnabled = true; p.quietEnd = 150
        let zone = TimeZone(identifier: "America/New_York")!
        #expect(p.adjusted(date("2026-03-08T06:00:00Z"), deviceTimeZone: zone) == date("2026-03-08T07:00:00Z"))
        p.quietEnd = 90
        #expect(p.adjusted(date("2026-11-01T04:30:00Z"), deviceTimeZone: zone) == date("2026-11-01T05:30:00Z"))
        #expect(p.adjusted(date("2026-11-01T06:15:00Z"), deviceTimeZone: zone) == date("2026-11-01T06:30:00Z"))
    }
    @Test func recordZoneAndDeviceQuietZoneAreIndependent() throws {
        let f = Fixture(); var body = RecordBody(kind: .task, title: "提醒测试")
        body.date = try LocalDay(2026, 10, 14); body.timeZone = "Asia/Shanghai"
        try f.core.save(body, spaceID: f.family.id)
        var p = ReminderPreferences(); p.quietEnabled = true
        let records = try f.core.records(spaceID: f.family.id)
        let plan = try ReminderPlanning.plan(records: records, preferences: p, now: date("2026-10-14T02:00:00Z"), deviceTimeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(plan.count == 1)
        #expect(plan.first?.originalDate == date("2026-10-14T01:00:00Z"))
        #expect(plan.first?.fireDate == date("2026-10-14T08:00:00Z"))
        p.enabled = false
        #expect(try ReminderPlanning.plan(records: records, preferences: p, now: date("2026-10-13T00:00:00Z")).isEmpty)
        p.enabled = true
        #expect(try ReminderPlanning.plan(records: records, preferences: p, now: date("2026-10-14T09:00:00Z"), deviceTimeZone: TimeZone(secondsFromGMT: 0)!).isEmpty)
    }
    @Test func subscriptionOffsetsAndCompletedRecords() throws {
        let f = Fixture(); var body = RecordBody(kind: .subscription, title: "订阅")
        body.date = try LocalDay(2026, 10, 20); body.money = Money(minor: 100, currency: .CNY)
        body.billingAnchor = body.date; body.memberID = f.family.ownerID; body.timeZone = "UTC"; body.reminderDays = [7, 1, 1]
        try f.core.save(body, spaceID: f.family.id)
        var done = RecordBody(kind: .task, title: "已完成", status: .completed); done.date = body.date
        try f.core.save(done, spaceID: f.family.id)
        let plan = try ReminderPlanning.plan(records: f.core.records(spaceID: f.family.id), preferences: ReminderPreferences(), now: date("2026-10-12T00:00:00Z"))
        #expect(plan.count == 2 && Set(plan.map(\.id)).count == 2)
        #expect(plan.first?.fireDate == date("2026-10-13T09:00:00Z"))
        #expect(plan.last?.fireDate == date("2026-10-19T09:00:00Z"))
    }
    @Test @MainActor func preferencesPersistOnlyInIsolatedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nobis-reminder-test-\(UUID())")
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "测试", familyName: "测试", partnerName: "另一位")
        let core = try #require(model.core), id = try #require(model.workspace.commonID)
        let before = try Backup.decode(core.export(spaceID: id))
        var p = ReminderPreferences(); p.enabled = false; p.quietEnabled = true; p.quietEnd = 600
        try model.saveReminderPreferences(p)
        await model.updateNotifications(requestPermission: true)
        #expect(model.notificationStatus.contains("仅预览"))
        let reopened = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(reopened.reminderPreferences == p)
        #expect(try Backup.decode(core.export(spaceID: id)) == before)
        #expect(try reopened.reminderPreview().isEmpty)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("ReminderPreferences.json"))
        let broken = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(!broken.reminderPreferences.enabled && broken.reminderSettingsError != nil)
    }
}
