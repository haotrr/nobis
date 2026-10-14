import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

@Suite("笔记管理与草稿") @MainActor struct DocumentManagementDraftTests {
    @Test func managementChangesPreserveDraftAndMergeOnSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "A", familyName: "我们", partnerName: "B")
        let space = try #require(model.workspace.commonID)
        try model.save(RecordBody(kind: .project, title: "项目"), spaceID: space)
        let project = try #require(model.activeRecords.first { $0.body.kind == .project })
        var body = RecordBody(kind: .document, title: "原名"); body.notes = "已保存正文"
        try model.save(body, spaceID: space)
        let original = try #require(model.activeRecords.first { $0.body.kind == .document })
        var local = body; local.notes = "未保存中文草稿\n- [ ] 保留清单"
        let draft = DocumentDraft(body: local, spaceID: space, recordID: original.id, expected: Set(original.heads.map(\.id)))
        try model.draftStore.save(draft, key: original.id)
        var managed = body
        managed.title = "新名"; managed.noteGroup = "旅行"; managed.isPinned = true
        managed.projectIDs = [project.id]; managed.status = .archived
        try model.save(managed, spaceID: space, existing: original)
        #expect(try model.draftStore.read(original.id) == draft)
        let core = try #require(model.core)
        #expect(try core.record(original.id, spaceID: space).body.notes == "已保存正文")
        let merged = try core.reconcilingManagementChanges(in: draft)
        #expect(merged.body.notes == local.notes)
        #expect(merged.body.title == "新名")
        #expect(merged.body.noteGroup == "旅行")
        #expect(merged.body.projectIDs == [project.id])
        #expect(merged.body.isPinned == true)
        #expect(merged.body.status == .archived)
        try model.save(merged.body, spaceID: space, existing: original, expected: merged.expected)
        #expect(try core.record(original.id, spaceID: space).body == merged.body)
        // A write after reconciliation still triggers the normal concurrency check.
        #expect(throws: (any Error).self) {
            try model.save(merged.body, spaceID: space, existing: original, expected: merged.expected)
        }
    }

    @Test(arguments: ["正文", "同字段", "删除"])
    func conflictsKeepStoredDraftUnchanged(_ scenario: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "A", familyName: "我们", partnerName: "B")
        let space = try #require(model.workspace.commonID)
        let body = RecordBody(kind: .document, title: "原名")
        try model.save(body, spaceID: space)
        let original = try #require(model.activeRecords.first { $0.body.kind == .document })
        var local = body; local.notes = "必须保留的草稿"
        if scenario == "同字段" { local.title = "草稿新名" }
        let draft = DocumentDraft(body: local, spaceID: space, recordID: original.id, expected: Set(original.heads.map(\.id)))
        try model.draftStore.save(draft, key: original.id)
        var remote = body
        if scenario == "正文" { remote.notes = "另一份已保存正文" }
        if scenario == "同字段" { remote.title = "列表新名" }
        try model.save(remote, spaceID: space, existing: original, deleted: scenario == "删除")
        let core = try #require(model.core)
        #expect(throws: (any Error).self) { try core.reconcilingManagementChanges(in: draft) }
        #expect(try model.draftStore.read(original.id) == draft)
        #expect(try core.record(original.id, spaceID: space).body == remote)
    }
}
