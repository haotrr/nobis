import Foundation
import FamilyDomain
import FamilyCore

extension AppModel {
    public var cloudDrafts: [AccountDraft] {
        ((try? privateCloud.repository?.load().account?.drafts) ?? []).filter { value in
            guard let payload = value.payload, let draft = try? JSONDecoder().decode(DocumentDraft.self, from: payload) else { return false }
            return spaces.contains { $0.id == draft.spaceID }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func syncDraftCopies() {
        guard let repository = privateCloud.repository, repository.profile != nil, let memberID else { return }
        do {
            var drafts: [AccountDraft] = []
            for kind in ["DocumentDrafts", "CommentDrafts"] {
                let path = directory.appendingPathComponent(kind)
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                let store = DocumentDraftStore(directory: path)
                for file in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                    guard let key = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let draft = try store.read(key) else { continue }
                    guard spaces.contains(where: { $0.id == draft.spaceID }) else { continue }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    drafts.append(AccountDraft(deviceID: memberID, key: key, kind: kind, payload: try encoder.encode(draft)))
                }
            }
            try repository.updateDrafts(deviceID: memberID, drafts: drafts)
        } catch { notice = "草稿已留在本机，私密同步待重试：" + error.localizedDescription }
    }
    public func restoreCloudDraft(_ value: AccountDraft) throws {
        guard let current = cloudDrafts.first(where: { $0.id == value.id }), current == value,
              let payload = value.payload else { throw NobisError.forbidden }
        let draft = try JSONDecoder().decode(DocumentDraft.self, from: payload)
        guard spaces.contains(where: { $0.id == draft.spaceID }) else { throw NobisError.forbidden }
        let store = DocumentDraftStore(directory: directory.appendingPathComponent(value.kind))
        if let existing = try store.read(value.key), existing != draft {
            throw NobisError.validation("此设备已有不同草稿，请先处理本机草稿；不会覆盖。")
        }
        try store.save(draft, key: value.key)
        notice = "已恢复到此设备，请打开对应笔记或评注继续编辑。"
    }
}
