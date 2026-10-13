import Foundation
import Testing
import FamilyDomain
import FamilyCore

@Suite("资源组织与笔记清单") @MainActor struct ResourceOrganizationTests {
    @Test func checklistIsOneSourceAndRejectsStaleLineAfterReorder() throws {
        let f = Fixture()
        var body = RecordBody(kind: .document, title: "行程")
        body.notes = "- [ ] 订票\n- [ ] 订票\n1. [X] 护照\n```\n- [ ] 示例\n```"
        let first = try f.core.save(body, spaceID: f.family.id)
        let rows = NoteChecklistItem.items(in: try f.core.records(spaceID: f.family.id), includeCompleted: true)
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        try f.core.toggleChecklist(rows[1])
        let updated = try f.core.record(first.recordID, spaceID: f.family.id)
        #expect(updated.body.notes.hasPrefix("- [ ] 订票\n- [x] 订票"))
        #expect(try f.core.records(spaceID: f.family.id).count == 1)
        #expect(NoteChecklistItem.items(in: [updated]).count == 1)
        #expect(throws: NobisError.conflict) { try f.core.toggleChecklist(rows[0]) }
        body = updated.body; body.notes = "新段落\n" + body.notes
        try f.core.save(body, spaceID: f.family.id, recordID: updated.id, expected: Set(updated.heads.map(\.id)))
        #expect(throws: NobisError.conflict) { try f.core.toggleChecklist(NoteChecklistItem.items(in: [updated])[0]) }
        let current = try f.core.record(updated.id, spaceID: f.family.id)
        let reopened = NoteChecklistItem.items(in: [current], includeCompleted: true)[1]
        try f.core.toggleChecklist(reopened)
        #expect(NoteChecklistItem.items(in: try f.core.records(spaceID: f.family.id)).count == 2)
    }
    @Test func removalArchiveAndAccessControlFollowTheNote() throws {
        let f = Fixture()
        var body = RecordBody(kind: .document, title: "清单"); body.notes = "- [ ] 内容"
        let first = try f.core.save(body, spaceID: f.family.id)
        let row = try #require(NoteChecklistItem.items(in: try f.core.records(spaceID: f.family.id)).first)
        let denied = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.a.id, allowedSpaceIDs: []))
        #expect(throws: NobisError.forbidden) { try denied.toggleChecklist(row) }
        body.status = .archived
        let archived = try f.core.save(body, spaceID: f.family.id, recordID: first.recordID, expected: [first.id])
        #expect(NoteChecklistItem.items(in: try f.core.records(spaceID: f.family.id)).isEmpty)
        #expect(throws: NobisError.conflict) { try f.core.toggleChecklist(row) }
        body.status = .active; body.notes = "已移除清单"
        try f.core.save(body, spaceID: f.family.id, recordID: first.recordID, expected: [archived.id])
        #expect(NoteChecklistItem.items(in: try f.core.records(spaceID: f.family.id)).isEmpty)
    }
    @Test func organizationMetadataRoundTripsAndReferencesStayInScope() throws {
        let f = Fixture()
        let target = try f.core.save(RecordBody(kind: .task, title: "订票"), spaceID: f.family.id)
        var note = RecordBody(kind: .document, title: "旅行"); note.noteGroup = "资料"; note.isPinned = true; note.referenceIDs = [target.recordID]
        let saved = try f.core.save(note, spaceID: f.family.id)
        let decoded = try Backup.decode(Backup.encode(f.repository.load()))
        #expect(decoded.revisions.first { $0.id == saved.id }?.body == note)
        #expect(WorkspaceQuery.search("旅行 资料", in: try f.core.records(spaceID: f.family.id)).count == 1)
        let basic = RecordBody(kind: .document, title: "旧笔记")
        #expect(try JSONDecoder().decode(RecordBody.self, from: JSONEncoder().encode(basic)).noteGroup == nil)
        note.referenceIDs = [UUID()]
        #expect(throws: (any Error).self) { try f.core.save(note, spaceID: f.family.id) }
    }
    @Test func calendarHonorsAllDayRangeAndTimedEndBoundary() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let f = Fixture()
        var event = RecordBody(kind: .event, title: "跨天")
        event.allDay = false
        event.startAt = try LocalDay(2026, 10, 12).date(timeZone: zone)
        event.endAt = try LocalDay(2026, 10, 13).date(timeZone: zone).addingTimeInterval(-12 * 3600)
        let revision = try f.core.save(event, spaceID: f.family.id)
        let record = try f.core.record(revision.recordID, spaceID: f.family.id)
        #expect(WorkspaceQuery.occurs(record, on: try LocalDay(2026, 10, 12), timeZone: zone))
        #expect(!WorkspaceQuery.occurs(record, on: try LocalDay(2026, 10, 13), timeZone: zone))
        event.allDay = true; event.date = try LocalDay(2026, 10, 12); event.endDate = try LocalDay(2026, 10, 14)
        let multi = try f.core.save(event, spaceID: f.family.id)
        #expect(WorkspaceQuery.occurs(try f.core.record(multi.recordID, spaceID: f.family.id), on: try LocalDay(2026, 10, 14)))
    }
}

extension ResourceOrganizationTests {
    @Test func sharingRemapsReferencesAndRejectsOutsideScope() throws {
        let f = Fixture()
        let project = try f.core.save(RecordBody(kind: .project, title: "旅行"), spaceID: f.personal.id)
        var task = RecordBody(kind: .task, title: "订票"); task.projectIDs = [project.recordID]
        let target = try f.core.save(task, spaceID: f.personal.id)
        var note = RecordBody(kind: .document, title: "行程"); note.notes = "- [ ] 订酒店"; note.projectIDs = [project.recordID]; note.referenceIDs = [target.recordID]; note.noteGroup = "旅行资料"
        let saved = try f.core.save(note, spaceID: f.personal.id)
        note.projectIDs = []
        #expect(throws: (any Error).self) { try f.core.save(note, spaceID: f.family.id) }
        let plan = try f.core.previewSharing(recordID: project.recordID, from: f.personal.id, to: f.family.id)
        try f.core.commitSharing(plan)
        let shared = try f.core.record(try #require(plan.targetIDs[saved.recordID]), spaceID: f.family.id)
        #expect(shared.body.referenceIDs == [plan.targetIDs[target.recordID]!])
        #expect(shared.body.noteGroup == "旅行资料")
        #expect(NoteChecklistItem.items(in: try f.core.records(spaceID: f.family.id)).count == 1)
        #expect(NoteChecklistItem.items(in: try f.core.records(spaceID: f.personal.id)).isEmpty)
        _ = try Backup.decode(Backup.encode(f.repository.load()))
    }
}
