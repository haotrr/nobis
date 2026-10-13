import SwiftUI
import FamilyCore
import FamilyDomain
import FamilyPersistence

struct StartupRecoveryView: View {
    let model: AppModel
    @State private var importing = false
    @State private var report: String?
    var body: some View {
        ContentUnavailableView {
            Label("暂时无法打开空间", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(model.error ?? "原有数据未更改，请重试。")
            Text(model.startupDiagnostic).font(.caption).textSelection(.enabled)
            if let report { Text(report).font(.caption).textSelection(.enabled) }
        } actions: {
            Button("重新打开") { model.retryOpening() }
            Button("校验备份并隔离恢复…") { importing = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url), snapshot = try Backup.decode(data)
                let target = model.directory.appendingPathComponent("Recovery/\(UUID().uuidString)")
                let repository = try CoreDataRepository(directory: target, initialSpaces: snapshot.spaces)
                for space in snapshot.spaces {
                    var isolated = try repository.load()
                    isolated.revisions += snapshot.revisions.filter { $0.spaceID == space.id }
                    isolated.audits += snapshot.audits.filter { $0.spaceID == space.id }
                    try repository.save(isolated)
                }
                let verified = try repository.load()
                guard Set(verified.revisions.map(\.id)) == Set(snapshot.revisions.map(\.id)), Set(verified.audits.map(\.id)) == Set(snapshot.audits.map(\.id)) else { throw NobisError.corruptBackup }
                report = "已校验并恢复到隔离目录，当前库未改变。\n\(target.path)\n\(verified.revisions.count) 个修订；核对后可另行迁移。"
            } catch { report = "恢复未完成：" + error.localizedDescription }
        }
    }
}
