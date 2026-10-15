import Foundation
import Testing
import FamilyDomain
import FamilyCore

@Suite("安排查询") struct WorkspaceQueryTests {
    private func record(_ body: RecordBody, deleted: Bool = false) -> Record {
        Record.project([Revision(spaceID: UUID(), actorID: UUID(), body: body, deleted: deleted)])[0]
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test(arguments: [RecordStatus.paused, .cancelled, .archived])
    func inactiveSubscriptionsDoNotAppearOnCalendar(_ status: RecordStatus) throws {
        var body = RecordBody(kind: .subscription, title: "订阅", status: status)
        body.date = try LocalDay(2026, 10, 15)
        #expect(!WorkspaceQuery.occurs(record(body), on: try LocalDay(2026, 10, 15)))
        body.status = .active
        #expect(WorkspaceQuery.occurs(record(body), on: try LocalDay(2026, 10, 15)))
        #expect(!WorkspaceQuery.occurs(record(body, deleted: true), on: try LocalDay(2026, 10, 15)))
    }

    @Test func timedEventsUseExclusiveEndAndDeviceDayAcrossDST() throws {
        var body = RecordBody(kind: .event, title: "跨天日程")
        body.allDay = false
        body.startAt = date("2026-03-08T04:30:00Z")
        body.endAt = date("2026-03-09T04:00:00Z")
        let zone = TimeZone(identifier: "America/New_York")!
        #expect(WorkspaceQuery.occurs(record(body), on: try LocalDay(2026, 3, 7), timeZone: zone))
        #expect(WorkspaceQuery.occurs(record(body), on: try LocalDay(2026, 3, 8), timeZone: zone))
        #expect(!WorkspaceQuery.occurs(record(body), on: try LocalDay(2026, 3, 9), timeZone: zone))
        body.allDay = true; body.date = try LocalDay(2026, 3, 7); body.endDate = try LocalDay(2026, 3, 9)
        #expect(WorkspaceQuery.occurs(record(body), on: try LocalDay(2026, 3, 9), timeZone: zone))
    }

    @Test func checklistSearchMatchesAllTermsAcrossNoteAndItemOnly() {
        var body = RecordBody(kind: .document, title: "旅行准备")
        body.notes = "- [ ] 预订 HOTEL\n- [ ] 买车票\n- [x] 收拾行李\n普通正文：护照"
        let items = NoteChecklistItem.items(in: [record(body)])
        #expect(NoteChecklistItem.search("  旅行\n hotel  ", in: items).map(\.title) == ["预订 HOTEL"])
        #expect(NoteChecklistItem.search("HOTEL 旅行", in: items).map(\.id) == NoteChecklistItem.search("旅行 hotel", in: items).map(\.id))
        #expect(NoteChecklistItem.search("旅行 护照", in: items).isEmpty)
        #expect(NoteChecklistItem.search("HOTEL 车票", in: items).isEmpty)
        #expect(NoteChecklistItem.search(" \n\t", in: items).map(\.id) == items.map(\.id))
        #expect(NoteChecklistItem.search("行李", in: items).isEmpty)
        let completed = NoteChecklistItem.items(in: [record(body)], includeCompleted: true)
        #expect(NoteChecklistItem.search("旅行 行李", in: completed).first?.completed == true)
        body.status = .archived
        #expect(NoteChecklistItem.search("旅行", in: NoteChecklistItem.items(in: [record(body)], includeCompleted: true)).isEmpty)
    }
}
