import Foundation
import FamilyDomain
import FamilyCore

extension AppModel {
    /// Explicit, backed-up migration. No source deletion and no Minty access occurs here.
    public func migrateLegacyData() throws {
        guard cloudOnly, let core, let memberID,
              let personal = privateCloud.repository else { throw NobisError.validation("请先连接个人 iCloud，再核对旧数据。") }
        guard let source = localRepository else { legacyMigrationStatus = "没有旧本地库，个人与 Studio 内容均使用云端存储。"; return }
        let snapshot = try source.load()
        let backup = try Backup.encode(snapshot)
        let folder = directory.appendingPathComponent("LegacyMigration/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try backup.write(to: folder.appendingPathComponent("source.json"), options: LocalMetadataFile.writingOptions)
        try Backup.encode(core.repository.load()).write(to: folder.appendingPathComponent("target-before.json"), options: LocalMetadataFile.writingOptions)
        for name in ["DocumentDrafts", "CommentDrafts"] {
            let path = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.copyItem(at: path, to: folder.appendingPathComponent(name)) }
        }
        var targets: [(Space, UUID)] = []
        for space in snapshot.spaces {
            guard space.ownerID == memberID else { throw NobisError.validation("旧空间拥有者与本机原身份不一致，请先核对。") }
            let hasRecords = snapshot.revisions.contains { $0.spaceID == space.id }
            if !hasRecords { continue }
            guard let targetID = space.kind == .personal ? personal.spaceID : cloud.grant?.spaceID else {
                throw NobisError.validation("请连接 Studio 后迁移家庭内容。源备份已保存。")
            }
            let target = try core.space(targetID)
            let plan = try core.previewRecovery(backup, sourceSpaceID: space.id, targetSpaceID: targetID, members: [space.ownerID: core.session.actorID(in: target.id)])
            guard plan.conflicts == 0 else { throw NobisError.validation("旧数据有 \(plan.conflicts) 项差异或身份待核对，尚未迁入。请使用备份恢复预览核对，不能重复导入。") }
            targets.append((space, targetID))
        }
        // Drafts need a separate recovery path; never silently discard or publish them as saved records.
        for name in ["DocumentDrafts", "CommentDrafts"] {
            let path = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                for file in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                    let draft = try JSONDecoder().decode(DocumentDraft.self, from: LocalMetadataFile.read(from: file))
                    if snapshot.spaces.contains(where: { $0.id == draft.spaceID }) {
                        throw NobisError.validation("发现旧空间草稿，完整副本已备份；请先通过草稿核对恢复，暂不标记迁移完成。")
                    }
                }
            }
        }
        guard try source.load() == snapshot else { throw NobisError.conflict }
        var added = 0
        for (space, targetID) in targets {
            let target = try core.space(targetID)
            let plan = try core.previewRecovery(backup, sourceSpaceID: space.id, targetSpaceID: targetID, members: [space.ownerID: core.session.actorID(in: target.id)])
            guard plan.conflicts == 0 else { throw NobisError.conflict }
            if plan.canCommit { added += try core.commitRecovery(plan) }
        }
        let message = "旧本地数据已备份核对：新增 \(added) 条；源库只读保留，不参与日常展示或统计。"
        try Data(message.utf8).write(to: folder.appendingPathComponent("receipt.txt"), options: LocalMetadataFile.writingOptions)
        legacyMigrationStatus = message
        rebind()
    }
}
