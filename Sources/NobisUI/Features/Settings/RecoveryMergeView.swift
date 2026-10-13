import SwiftUI
import FamilyDomain
import FamilyCore

struct RecoveryMergeView: View {
    let model: AppModel
    var backupData: Data? = nil
    var liveSourceID: UUID? = nil
    @State var sourceID: UUID?
    @State var targetID: UUID?
    @State var members: [UUID: UUID] = [:]
    @State private var data: Data?
    @State private var snapshot: Snapshot?
    @State private var plan: RecoveryMergePlan?
    @State private var keeping: Set<UUID> = []
    @State private var error: String?
    @State private var receipt: String?
    @State private var confirming = false
    private var source: Space? { snapshot?.spaces.first { $0.id == sourceID } }
    private var target: Space? { model.spaces.first { $0.id == targetID } }
    private var sourceMembers: [UUID] {
        guard let snapshot, let source else { return [] }
        let records = Record.project(snapshot.revisions.filter { $0.spaceID == source.id }).filter { !$0.deleted && $0.body.sharedDestination == nil }
        return Set(source.members.map(\.id) + records.flatMap { [$0.body.memberID,$0.body.financialOwner?.memberID,$0.body.completedBy].compactMap { $0 } + $0.body.splits.map(\.memberID) }).sorted { $0.uuidString < $1.uuidString }
    }
    var body: some View {
        LifeDetail {
            Text("先核对成员、差异与冲突，再新增当前版本。目标已有内容不会被覆盖；源备份保留完整修订与审计。私密范围不能合并到共同范围。").font(.caption).foregroundStyle(.secondary)
            LifePicker("备份来源范围", selection: $sourceID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(snapshot?.spaces ?? []) { Text($0.name + ($0.kind == .personal ? " · 私密" : " · 共同")).tag(Optional($0.id)) }
            }.disabled(liveSourceID != nil)
            LifePicker("迁入目标范围", selection: $targetID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.spaces.filter { $0.kind == source?.kind && $0.id != liveSourceID }) { Text(model.visibility(for: $0.id) + " · " + $0.name).tag(Optional($0.id)) }
            }
            ForEach(sourceMembers, id: \.self) { id in
                LifePicker(source?.members.first { $0.id == id }?.name ?? "历史成员 \(id.uuidString.prefix(8))", selection: Binding<UUID?>(get: { members[id] }, set: { members[id] = $0; invalidate() })) {
                    Text("尚未映射").tag(Optional<UUID>.none)
                    ForEach(target?.members ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Button("预览差异与冲突") { review() }.disabled(source == nil || target == nil)
            if let plan {
                Text("新增 \(plan.additions) 条 · 阻断 \(plan.conflicts) 条 · 跳过或保留 \(plan.items.count - plan.additions - plan.conflicts) 条").font(.headline)
                Text("迁入后，旧本地内容仍保留在原范围；不会自动归档或计入新的共同范围。源历史保存在迁入回执目录。").font(.caption)
                Button("确认迁入…") { confirming = true }.disabled(!plan.canCommit || !model.canWrite(spaceID: plan.targetSpace.id))
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.source.body.title).font(.headline)
                            Text(item.detail).font(.caption).foregroundStyle([.conflict, .difference].contains(item.disposition) ? .orange : .secondary)
                            if let target = item.target, !target.deleted, !target.conflicted, !item.source.conflicted,
                               item.disposition == .difference || item.disposition == .kept {
                                Toggle("明确保留目标版本", isOn: Binding(get: { keeping.contains(item.id) }, set: { if $0 { keeping.insert(item.id) } else { keeping.remove(item.id) }; review() }))
                            }
                            DisclosureGroup("备份原值（成员按上方映射）") { Text(json(item.source.body)).font(.caption.monospaced()).textSelection(.enabled) }
                            if let target = item.target { DisclosureGroup("目标当前值") { Text(json(target.body)).font(.caption.monospaced()).textSelection(.enabled) } }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
                    }
                }
            }
            if let error { InlineIssue(message: error) }
            if let receipt { Text(receipt).textSelection(.enabled) }
        }.navigationTitle("恢复合并")
        .onAppear { load() }
        .onChange(of: sourceID) { old, _ in if old != nil { members = [:] }; keeping = []; invalidate() }
        .onChange(of: targetID) { old, _ in if old != nil { members = [:] }; keeping = []; invalidate() }
        .confirmationDialog("确认新增到「\(target?.name ?? "目标范围")」？", isPresented: $confirming) {
            Button("保存备份并迁入") { commit() }
            Button("取消", role: .cancel) { }
        } message: { Text("将保存目标迁入前备份和完整来源备份，再一次性写入已预览的新增记录。有冲突或预览已过期时不会写入。") }
    }
    private func json(_ body: RecordBody) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return (try? encoder.encode(body)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法显示字段"
    }
    private func invalidate() { plan = nil; error = nil; receipt = nil }
    private func load() {
        guard data == nil else { return }
        do {
            guard let core = model.core else { throw NobisError.forbidden }
            let raw: Data
            if let backupData { raw = backupData }
            else if let liveSourceID { raw = try core.export(spaceID: liveSourceID) }
            else { throw NobisError.corruptBackup }
            snapshot = try Backup.decode(raw); data = raw
            if sourceID == nil { sourceID = liveSourceID ?? (snapshot?.spaces.count == 1 ? snapshot?.spaces.first?.id : nil) }
        } catch { self.error = error.localizedDescription }
    }
    private func review() {
        do {
            guard let core = model.core, let sourceID, let targetID else { throw NobisError.forbidden }
            if let liveSourceID { data = try core.export(spaceID: liveSourceID); snapshot = try data.map(Backup.decode) }
            guard let data else { throw NobisError.corruptBackup }
            plan = try core.previewRecovery(data, sourceSpaceID: sourceID, targetSpaceID: targetID, members: members, keepingTarget: keeping)
            error = nil; receipt = nil
        } catch { self.error = error.localizedDescription; plan = nil }
    }
    private func commit() {
        do {
            guard let core = model.core, let plan, let data, let snapshot else { throw NobisError.forbidden }
            if let liveSourceID { guard try Backup.decode(core.export(spaceID: liveSourceID)) == snapshot else { throw NobisError.validation("来源已变化，请重新预览。") } }
            let folder = model.directory.appendingPathComponent("RecoveryMerge/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try core.export(spaceID: plan.targetSpace.id).write(to: folder.appendingPathComponent("before-merge.json"), options: .atomic)
            try data.write(to: folder.appendingPathComponent("source-backup.json"), options: .atomic)
            let count = try core.commitRecovery(plan)
            self.plan = nil; error = nil; receipt = "已迁入 \(count) 条。目标原记录及源历史保留。备份目录：\(folder.path)"; model.refresh()
        } catch { self.error = error.localizedDescription; plan = nil }
    }
}
