import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence
import NobisUI

@Suite("文档完善与资料恢复") @MainActor struct DocumentCompletionTests {
    @Test func taskOffsetsIgnoreFencesAndPreserveOtherText() {
        let source = "😀\n```\n- [ ] code\n```\n  - [X] 中文\n- [ ] next\n"
        #expect(MarkdownBlock.togglingTask(in: source, line: 2) == nil)
        #expect(MarkdownBlock.togglingTask(in: source, line: 4) == source.replacingOccurrences(of: "[X] 中文", with: "[ ] 中文"))
        #expect(MarkdownBlock.togglingTask(in: source, line: 99) == nil)
        #expect(MarkdownBlock.parse("| 名称 | 金额 |\n| :--- | ---: |\n| **餐费** | 20 |\n\n![海](https://example.com/a.png)") == [.table([["名称", "金额"], ["**餐费**", "20"]]), .image("海", "https://example.com/a.png")])
    }
    @Test func recoveredDraftKeepsStaleHeadsAndCannotOverwritePartner() throws {
        let f = Fixture()
        var body = RecordBody(kind: .document, title: "协作")
        body.notes = "初稿"
        let first = try f.core.save(body, spaceID: f.family.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentDraftStore(directory: directory)
        body.notes = "未发布草稿"
        let draft = DocumentDraft(body: body, spaceID: f.family.id, recordID: first.recordID, expected: [first.id])
        try store.save(draft, key: first.recordID)
        body.notes = "对方的新版本"
        try f.core.save(body, spaceID: f.family.id, recordID: first.recordID, expected: [first.id])
        let recovered = try #require(try DocumentDraftStore(directory: directory).read(first.recordID))
        #expect(recovered == draft)
        #expect(throws: NobisError.conflict) { try f.core.save(recovered.body, spaceID: recovered.spaceID, recordID: first.recordID, expected: recovered.expected) }
        try store.remove(first.recordID)
        #expect(try store.read(first.recordID) == nil)
    }
    @Test func draftRevocationIsScopedAndUnreadTracksRevisions() throws {
        let f = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentDraftStore(directory: directory.appendingPathComponent("drafts"))
        let privateID = UUID(), firstKey = UUID(), secondKey = UUID()
        let body = RecordBody(kind: .document, title: "草稿")
        try store.save(DocumentDraft(body: body, spaceID: f.family.id, recordID: nil, expected: []), key: firstKey)
        try store.save(DocumentDraft(body: body, spaceID: privateID, recordID: nil, expected: []), key: secondKey)
        try store.remove(spaceID: f.family.id)
        #expect(try store.read(firstKey) == nil)
        #expect(try store.read(secondKey) != nil)
        let doc = try f.core.save(body, spaceID: f.family.id)
        let partner = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.b.id, allowedSpaceIDs: [f.family.id]))
        var comment = RecordBody(kind: .comment, title: "评注"); comment.notes = "另一个人"; comment.relatedRecordID = doc.recordID
        let revision = try partner.save(comment, spaceID: f.family.id)
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.core = f.core; model.records = try f.core.records(spaceID: f.family.id)
        #expect(model.unreadComments(for: doc.recordID) == 1)
        model.markCommentsRead(model.records.filter { $0.body.kind == .comment })
        #expect(model.unreadComments(for: doc.recordID) == 0)
        let reopened = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(reopened.readComments.contains(revision.id))
        comment.status = .completed
        try partner.save(comment, spaceID: f.family.id, recordID: revision.recordID, expected: [revision.id])
        model.records = try f.core.records(spaceID: f.family.id)
        #expect(model.unreadComments(for: doc.recordID) == 1)
    }
    @Test func failedReadReceiptWritePreservesUnreadAndCanRetry() throws {
        let f = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receipt = directory.appendingPathComponent("CommentReads.json")
        let previousID = UUID()
        let original = try JSONEncoder().encode(Set([previousID]))
        try original.write(to: receipt)
        let doc = try f.core.save(RecordBody(kind: .document, title: "笔记"), spaceID: f.family.id)
        let partner = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.b.id, allowedSpaceIDs: [f.family.id]))
        var body = RecordBody(kind: .comment, title: "评注")
        body.notes = "待阅读"; body.relatedRecordID = doc.recordID
        let revision = try partner.save(body, spaceID: f.family.id)
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.core = f.core; model.records = try f.core.records(spaceID: f.family.id)
        let comments = model.records.filter { $0.body.kind == .comment }
        let before = f.repository.snapshot
        let savedReceipt = directory.appendingPathComponent("previous.json")
        try FileManager.default.moveItem(at: receipt, to: savedReceipt)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false)
        try Data("obstacle".utf8).write(to: receipt.appendingPathComponent("keep"))
        model.markCommentsRead(comments)
        #expect(model.error != nil)
        #expect(model.readComments == [previousID])
        #expect(model.unreadComments(for: doc.recordID) == 1)
        #expect(try Data(contentsOf: savedReceipt) == original)
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.moveItem(at: savedReceipt, to: receipt)
        model.error = nil
        model.markCommentsRead(comments)
        #expect(model.error == nil)
        #expect(model.unreadComments(for: doc.recordID) == 0)
        let reopened = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(reopened.readComments == [previousID, revision.id])
        #expect(f.repository.snapshot == before)
    }
    @Test func localDisplayChangesPreserveIdentityAndSurviveRestart() throws {
        let f = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try CoreDataRepository(directory: directory, initialSpaces: [f.family])
        var member = f.a; member.name = "新的称呼"; member.avatarData = Data([1,2,3])
        #expect(throws: NobisError.forbidden) { try repository.updateDisplay(spaceID: f.family.id, actorID: f.b.id, name: "修改", member: member) }
        try repository.updateDisplay(spaceID: f.family.id, actorID: f.a.id, name: "我们的家", member: member)
        #expect(throws: NobisError.conflict) { try repository.updateDisplay(spaceID: f.family.id, actorID: f.a.id, name: "旧窗口修改", member: member, expected: f.family) }
        let reopened = try CoreDataRepository(directory: directory)
        let space = try #require(try reopened.load().spaces.first)
        #expect(space.ownerID == f.family.ownerID)
        #expect(space.name == "我们的家")
        #expect(space.members.first { $0.id == member.id } == member)
        let backup = try Backup.decode(Backup.encode(reopened.load()))
        #expect(backup.spaces == [space])
        let old = Data("{\"id\":\"\(member.id)\",\"name\":\"旧称呼\"}".utf8)
        #expect(try JSONDecoder().decode(Member.self, from: old).avatarData == nil)
    }
}
