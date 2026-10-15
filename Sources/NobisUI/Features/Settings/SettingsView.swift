import SwiftUI
import UniformTypeIdentifiers
import FamilyDomain
import FamilyCore
import FamilyPersistence

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SettingsView: View {
    let model: AppModel
    @State private var backupSpaceID: UUID?
    @State private var exporting = false
    @State private var importing = false
    @State private var exportConfirmation = false
    @State private var document = BackupDocument(data: Data())
    @State private var recoveredData: Data?
    @State private var restoreData: Data?
    @State private var restoreSnapshot: Snapshot?
    @State private var restoreReport: String?
    @State private var exportFilename = "Nobis-backup"
    var body: some View {
        LifePage {
            LifeSection(title: "我们的生活", icon: "person.2") {
                if let id = model.selectedSpaceID { ResourceOwnership(model: model, spaceID: id, detailed: true) }
                ForEach(model.selectedSpace?.members ?? []) { member in MemberIdentityBadge(member: member, showsAvatar: true) }
                if model.selectedSpace?.kind == .family && model.selectedSpaceID != model.cloud.grant?.spaceID { Text("这些是本地成员标识，用于分工和账单分摊。尚未发出 iCloud 邀请，也没有对方已收到数据的回执。").font(.caption).foregroundStyle(.secondary) }
            }
            ProfileSettingsSection(model: model)
            FamilySharingSection(model: model)
            LifeSection(title: "此设备与提醒", icon: "bell") {
                LabeledContent("保存与同步", value: model.saveStatus)
                LabeledContent("提醒", value: model.notificationStatus)
                NavigationLink("日常提醒：设备与静默时段") { ReminderSettingsView(model: model) }
                Text("通知按发生日期去重，前台补算待办。休眠、系统权限和后台限制可能影响提醒送达。").font(.caption).foregroundStyle(.secondary)
                if let notice = model.notice { Text(notice).font(.caption) }
            }
            LifeSection(title: "账务与导入", icon: "creditcard") {
                NavigationLink { LedgerWorkspace(model: model) } label: { SettingsEntry(title: "收支工作台", detail: "查看收支、筛选账单和导出明细", icon: "list.bullet.rectangle") }.buttonStyle(.plain)
                Divider().opacity(0.35)
                NavigationLink { RecordsView(model: model, fixedKind: .category) } label: { SettingsEntry(title: "分类管理", detail: "整理记账时使用的分类", icon: "tag") }.buttonStyle(.plain)
                Divider().opacity(0.35)
                NavigationLink { LedgerImportView(model: model) } label: { SettingsEntry(title: "导入账单", detail: "支持 CSV 与 Minty 迁移包，导入前可预览", icon: "square.and.arrow.down") }.buttonStyle(.plain)
            }
            NavigationLink { FinancialReviewView(model: model) } label: { SettingsEntry(title: "成员与资产核对", detail: "确认财务归属，对照旧整体与分项资产", icon: "person.crop.circle.badge.checkmark") }.buttonStyle(.plain)
            LifeSection(title: "数据与恢复", icon: "externaldrive") {
                DisclosureGroup("导出备份与隔离恢复") {
                VStack(alignment: .leading, spacing: 16) {
                LifePicker("备份范围", selection: $backupSpaceID) {
                    Text("共同生活").tag(Optional<UUID>.none)
                    ForEach(model.spaces) { Text(model.visibility(for: $0.id) + " · " + $0.name).tag(Optional($0.id)) }
                }
                Button("导出所选范围…") { exportConfirmation = true }
                Text("导出含所选范围的全部记录、修订历史、成员称呼及审计；可能包含私人内容。由你选择保存位置。").font(.caption).foregroundStyle(.secondary)
                Button("校验备份并隔离恢复…") { importing = true }
                if let snapshot = restoreSnapshot {
                    Text("已通过校验：\(snapshot.spaces.count) 个空间，\(Record.project(snapshot.revisions).count) 条记录，\(snapshot.revisions.count) 个修订。")
                    Button("恢复到新的隔离目录") { restore(snapshot) }
                    Button("取消恢复", role: .cancel) { restoreSnapshot = nil; restoreData = nil }
                }
                if let report = restoreReport { Text(report).font(.caption).textSelection(.enabled) }
                if let recoveredData { NavigationLink("预览恢复数据的合并差异") { RecoveryMergeView(model: model, backupData: recoveredData) } }
                Text("恢复不会覆盖当前库，不复用云端共享关系。隔离数据需核对后另行迁移。").font(.caption).foregroundStyle(.secondary)
            }
                }
                }
            LifeSection(title: "回收站", icon: "trash") {
                Text("删除的内容在 30 天内可恢复。").font(.caption).foregroundStyle(.secondary)
                let deleted = model.records.filter(\.deleted)
                if deleted.isEmpty { Text("回收站是空的").foregroundStyle(.secondary) }
                ForEach(deleted) { record in RecordLink(model: model, record: record) { VStack(alignment: .leading, spacing: 6) { Text(record.body.title); ResourceOwnership(model: model, spaceID: record.latest.spaceID) } } }
            }
            LifeSection(title: "迁移与分享核对", icon: "arrow.triangle.branch") {
                DisclosureGroup("查看待处理与已分享的内容") {
                VStack(alignment: .leading, spacing: 16) {
                if model.pendingShares.isEmpty && model.workspace.pendingSpaces.isEmpty && !model.records.contains(where: { $0.body.sharedDestination != nil }) { Text("没有需要核对的内容").foregroundStyle(.secondary) }
                ForEach(model.pendingShares) { plan in
                    Text("待完成分享 · \(plan.sources.count) 条")
                    Button("继续完成分享") { model.perform { try model.share(plan) } }
                }
                ForEach(model.workspace.pendingSpaces) { source in
                    NavigationLink("待迁入的本地内容 · " + source.name) { LegacyRecordsView(model: model, source: source) }
                }
                ForEach(model.records.filter { $0.body.sharedDestination != nil }) { r in
                    RecordLink(model: model, record: r) { VStack(alignment: .leading, spacing: 6) { Text("已分享来源 · " + r.body.title); ResourceOwnership(model: model, spaceID: r.latest.spaceID) } }
                }
            }
                }
                }
            LifeSection(title: "关于 Nobis", icon: "leaf") {
                Text("Nobis 0.1 · A Family Studio").font(.system(.title3, design: .serif))
                Text("Pro nobis · 为了我们").foregroundStyle(.secondary)
                DisclosureGroup("开源许可") {
                    Text("MDTextKit · Markdown 编辑组件").font(.headline)
                    if let url = Bundle.module.url(forResource: "MDTextKit-LICENSE", withExtension: "txt"),
                       let license = try? String(contentsOf: url, encoding: .utf8) {
                        Text(license).font(.caption).textSelection(.enabled)
                    }
                }
                DisclosureGroup("AI 入口与数据边界") {
                Text("v0.1 提供导出文件上的结构化只读 CLI 样例。它不能打开应用数据库，也不能修改记录。导出给外部客户端后，文件权限由接收方控制。").font(.callout)
            }
            }
        }.navigationTitle("设置")
        .confirmationDialog("导出所选范围的全部业务记录和历史？", isPresented: $exportConfirmation) {
            Button("选择导出位置") { model.perform {
                guard let id = backupSpaceID ?? model.selectedSpaceID, let core = model.core else { throw NobisError.forbidden }
                document = BackupDocument(data: try core.export(spaceID: id)); exportFilename = "Nobis-\(model.selectedSpace?.name ?? "backup")-\(LocalDay(date: Date()))"; exporting = true
            } }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: exportFilename) { result in
            switch result { case .success: model.notice = "备份已导出"; case .failure(let error): model.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            restoreSnapshot = nil; restoreData = nil; recoveredData = nil; restoreReport = nil
            model.perform {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url); restoreSnapshot = try Backup.decode(data); restoreData = data; restoreReport = nil
            }
        }
    }
    private func restore(_ snapshot: Snapshot) {
        model.perform {
            guard let data = restoreData, let core = model.core, let currentSpace = model.selectedSpaceID else { throw NobisError.corruptBackup }
            let target = model.directory.appendingPathComponent("Recovery/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try core.export(spaceID: currentSpace).write(to: target.appendingPathComponent("before-restore.json"), options: .atomic)
            try data.write(to: target.appendingPathComponent("source-backup.json"), options: .atomic)
            let repository = try CoreDataRepository(directory: target.appendingPathComponent("IsolatedStores"), initialSpaces: snapshot.spaces)
            for space in snapshot.spaces {
                var isolated = try repository.load()
                isolated.revisions += snapshot.revisions.filter { $0.spaceID == space.id }; isolated.audits += snapshot.audits.filter { $0.spaceID == space.id }
                try repository.save(isolated)
            }
            let restored = try repository.load()
            guard restored.revisions.count == snapshot.revisions.count, restored.audits.count == snapshot.audits.count else { throw NobisError.corruptBackup }
            var lines = ["隔离恢复成功，当前数据未改变。", "目录：\(target.path)"]
            for space in snapshot.spaces {
                let isolatedCore = FamilyCore(repository: repository, session: AccessSession(memberID: space.ownerID, allowedSpaceIDs: [space.id]))
                for summary in try isolatedCore.ledger(spaceID: space.id) { lines.append("\(space.name) · 净支出 \(Money(minor: summary.netExpense, currency: summary.currency).formatted) · 待核对 \(summary.unresolvedCount)") }
            }
            recoveredData = data; restoreReport = lines.joined(separator: "\n"); restoreSnapshot = nil; restoreData = nil
        }
    }
}

struct LegacyRecordsView: View {
    let model: AppModel
    let source: Space
    var body: some View {
        LifeDetail {
            if let targetID = model.workspace.commonID, targetID != source.id {
                NavigationLink("预览旧成员映射") { MemberMappingView(model: model, source: source, targetID: targetID) }
            }
            Text("本地草稿未自动迁入云家庭，也不计入共同报告。可在设置中按此范围导出备份后核对；本页只读。")
            if let core = model.core {
                switch Result(catching: { try core.records(spaceID: source.id) }) {
                case .failure(let error): InlineIssue(message: error.localizedDescription)
                case .success(let records): ForEach(records) { r in VStack(alignment: .leading) { Text(r.body.title); ResourceOwnership(model: model, spaceID: r.latest.spaceID); Text(r.body.notes).font(.caption); if let money = r.body.money { Text(money.formatted) } }.padding(20).frame(maxWidth: .infinity, alignment: .leading).lifeCard() }
                }
            }
        }.navigationTitle("待迁入的本地内容")
    }
}

private struct SettingsEntry: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
                .frame(width: 38, height: 38).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
