import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

@Suite("统一入口路由") @MainActor struct WorkspaceUITests {
    @Test func taskDatesSeparateFinishedWorkAndSortUpcomingTasks() throws {
        let today = try LocalDay(2026, 10, 12)
        func task(_ title: String, date: LocalDay?, status: RecordStatus = .active) -> Record {
            var body = RecordBody(kind: .task, title: title)
            body.date = date; body.status = status
            return Record.project([Revision(spaceID: UUID(), actorID: UUID(), body: body)])[0]
        }
        let overdue = task("逾期", date: today.addingDays(-1))
        let due = task("今天", date: today)
        let next = task("明天", date: today.addingDays(1))
        let later = task("下周", date: today.addingDays(7))
        let undated = task("未定", date: nil)
        let finished = task("完成", date: today.addingDays(-2), status: .completed)
        let cancelled = task("取消", date: today, status: .cancelled)
        let records = [later, finished, due, undated, overdue, next, cancelled]
        #expect(TaskDateGroup.overdue.records(in: records, today: today).map(\.id) == [overdue.id])
        #expect(TaskDateGroup.today.records(in: records, today: today).map(\.id) == [due.id])
        #expect(TaskDateGroup.upcoming.records(in: records, today: today).map(\.id) == [next.id, later.id])
        #expect(TaskDateGroup.undated.records(in: records, today: today).map(\.id) == [undated.id])
        #expect(Set(TaskDateGroup.finished.records(in: records, today: today).map(\.id)) == [finished.id, cancelled.id])
        #expect(TaskDateGroup.group(for: due, today: today.addingDays(1)) == .overdue)
    }
    @Test func defaultSharedPrivateCreateEditAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "A", familyName: "我们", partnerName: "B")
        let common = try #require(model.workspace.commonID), personal = try #require(model.workspace.personalID)
        #expect(model.selectedSpaceID == common)
        let p = RecordBody(kind: .project, title: "私密项目")
        try model.save(p, spaceID: personal)
        let original = try #require(model.records.first { $0.body.title == p.title })
        var edited = original.body; edited.notes = "私密修改"
        try model.save(edited, spaceID: original.latest.spaceID, existing: original)
        #expect(model.records(in: .shared).isEmpty)
        #expect(model.records(in: .personal).count == 1)
        try model.save(RecordBody(kind: .task, title: "共同任务"), spaceID: common)
        #expect(model.records(in: .all).count == 2)
        let reopened = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(reopened.selectedSpaceID == common)
        #expect(reopened.records(in: .personal).first?.body.notes == "私密修改")
        #expect(reopened.records(in: .shared).first?.body.title == "共同任务")
    }
    @Test func browsingScopeDoesNotChangeWriteDestinationOrOverview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "A", familyName: "我们", partnerName: "B")
        let common = try #require(model.workspace.commonID)
        let personal = try #require(model.workspace.personalID)
        try model.save(RecordBody(kind: .task, title: "共同任务"), spaceID: common)
        try model.save(RecordBody(kind: .task, title: "私密任务"), spaceID: personal)
        let overviewIDs = Set(model.activeRecords.map(\.id))
        for scope in LifeScope.allCases {
            model.browsingScope = scope
            model.refresh()
            #expect(model.browsingScope == scope)
            #expect(model.selectedSpaceID == common)
            #expect(Set(model.activeRecords.map(\.id)) == overviewIDs)
            #expect(model.records(in: model.browsingScope).count == (scope == .all ? 2 : 1))
        }
        model.browsingScope = .personal
        try model.save(RecordBody(kind: .task, title: "默认仍共享"), spaceID: try #require(model.selectedSpaceID))
        #expect(model.records(in: .shared).contains { $0.body.title == "默认仍共享" })
        #expect(!model.records(in: .personal).contains { $0.body.title == "默认仍共享" })
    }

    @Test func durableSharingReceiptAndNoDoubleCounting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "A", familyName: "我们", partnerName: "B")
        let core = try #require(model.core), personal = try #require(model.workspace.personalID), common = try #require(model.workspace.commonID)
        let r = try core.save(RecordBody(kind: .project, title: "将要分享"), spaceID: personal)
        let plan = try core.previewSharing(recordID: r.recordID, from: personal, to: common)
        try model.share(plan)
        #expect(model.pendingShares.isEmpty)
        #expect(model.records(in: .all).count == 1)
        #expect(model.records(in: .shared).count == 1)
        #expect(model.records.contains { $0.body.sharedDestination != nil })
        let reopened = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(reopened.records(in: .all).count == 1)
        #expect(reopened.pendingShares.isEmpty)
    }
}
