import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence

@Suite("文档与协作评注") @MainActor struct DocumentTests {
    func document(_ f: Fixture, spaceID: UUID? = nil) throws -> Revision {
        var body = RecordBody(kind: .document, title: "旅行计划")
        body.notes = "# 周末\n一起去海边 **散步**"
        return try f.core.save(body, spaceID: spaceID ?? f.family.id)
    }
    func comment(_ target: UUID, text: String = "带上相机") -> RecordBody {
        var body = RecordBody(kind: .comment, title: "评注")
        body.relatedRecordID = target; body.notes = text
        return body
    }
    @Test func independentCommentsRepliesAndResolution() throws {
        let f = Fixture(), doc = try document(f)
        let partner = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.b.id, allowedSpaceIDs: [f.family.id]))
        var body = comment(doc.recordID); body.documentQuote = "海边"
        let first = try f.core.save(body, spaceID: f.family.id)
        let second = try partner.save(comment(doc.recordID, text: "好呀"), spaceID: f.family.id)
        try partner.save(comment(first.recordID, text: "我来准备"), spaceID: f.family.id)
        #expect(try f.core.documentComments(doc.recordID, spaceID: f.family.id).count == 3)
        #expect(try f.core.record(doc.recordID, spaceID: f.family.id).heads == [doc])
        var revised = doc.body; revised.notes = "目的地待定"
        try f.core.save(revised, spaceID: f.family.id, recordID: doc.recordID, expected: [doc.id])
        body.status = .completed
        let resolved = try partner.save(body, spaceID: f.family.id, recordID: first.recordID, expected: [first.id])
        #expect(resolved.actorID == f.b.id)
        #expect(try f.core.history(first.recordID, spaceID: f.family.id).last?.actorID == f.a.id)
        #expect(throws: NobisError.self) { try partner.save(comment(first.recordID), spaceID: f.family.id) }
        body.notes = "改写对方的留言"
        #expect(throws: NobisError.self) { try partner.save(body, spaceID: f.family.id, recordID: first.recordID, expected: [resolved.id]) }
        #expect(try f.core.record(second.recordID, spaceID: f.family.id).body.notes == "好呀")
        let restored = try Backup.decode(f.core.export(spaceID: f.family.id))
        #expect(restored.revisions.contains { $0.id == first.id && $0.body.documentQuote == "海边" })
    }
    @Test func isolationDeletedTargetsAndStaleEdits() throws {
        let f = Fixture(), personal = try document(f, spaceID: f.personal.id), shared = try document(f)
        #expect(throws: NobisError.self) { try f.core.save(comment(personal.recordID), spaceID: f.family.id) }
        let partner = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.b.id, allowedSpaceIDs: [f.personal.id, f.family.id]))
        #expect(throws: NobisError.self) { try partner.documentComments(personal.recordID, spaceID: f.personal.id) }
        var changed = shared.body; changed.notes = "新正文"
        let revision = try partner.save(changed, spaceID: f.family.id, recordID: shared.recordID, expected: [shared.id])
        #expect(throws: NobisError.conflict) { try f.core.save(shared.body, spaceID: f.family.id, recordID: shared.recordID, expected: [shared.id]) }
        var quote = comment(shared.recordID); quote.documentQuote = "不存在的原文"
        #expect(throws: NobisError.self) { try f.core.save(quote, spaceID: f.family.id) }
        try f.core.save(changed, spaceID: f.family.id, recordID: shared.recordID, expected: [revision.id], deleted: true)
        #expect(throws: NobisError.self) { try f.core.save(comment(shared.recordID), spaceID: f.family.id) }
    }
    @Test func persistenceAndReadOnlyGrant() throws {
        let f = Fixture(), doc = try document(f)
        try f.core.save(comment(doc.recordID), spaceID: f.family.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try CoreDataRepository(directory: url, initialSpaces: [f.family, f.personal])
        try repository.save(f.repository.snapshot)
        let reopened = try CoreDataRepository(directory: url)
        let restored = FamilyCore(repository: reopened, session: f.core.session)
        #expect(try restored.documentComments(doc.recordID, spaceID: f.family.id).count == 1)
        let readOnly = FamilyCore(repository: ReadOnlyDocumentRepository(snapshot: f.repository.snapshot), session: f.core.session)
        #expect(try readOnly.documentComments(doc.recordID, spaceID: f.family.id).count == 1)
        #expect(throws: NobisError.forbidden) { try readOnly.save(comment(doc.recordID), spaceID: f.family.id) }
        #expect(throws: NobisError.forbidden) { try readOnly.save(doc.body, spaceID: f.family.id, recordID: doc.recordID, expected: [doc.id]) }
    }
    @Test func markdownBlocksAndOldPayloadDecode() throws {
        #expect(MarkdownBlock.parse("# 标题\n\n- [ ] 待办\n- [x] 完成\n> 引用\n1. 一\n```swift\nlet a = 1\n```\n---") == [
            .heading(1, "标题"), .task(2, false, "待办"), .task(3, true, "完成"), .quote("引用"), .list("1.", "一"), .code("let a = 1"), .divider
        ])
        #expect(MarkdownBlock.parse("```\n# 原样") == [.code("# 原样")])
        let data = try JSONEncoder().encode(RecordBody(kind: .task, title: "旧记录"))
        #expect(try JSONDecoder().decode(RecordBody.self, from: data).documentQuote == nil)
    }
}

@MainActor private final class ReadOnlyDocumentRepository: Repository {
    let snapshot: Snapshot
    init(snapshot: Snapshot) { self.snapshot = snapshot }
    func load() throws -> Snapshot { snapshot }
    func save(_ snapshot: Snapshot) throws { throw NobisError.forbidden }
    func requireWrite(spaceID: UUID, actorID: UUID) throws { throw NobisError.forbidden }
}
