import SwiftUI
import FamilyDomain
import FamilyCore
import UniformTypeIdentifiers

struct MemberMappingView: View {
    let model: AppModel
    let source: Space
    let targetID: UUID
    @State private var mapping: [UUID: UUID] = [:]
    @State private var preview: MemberMappingPreview?
    @State private var error: String?
    @State private var exporting = false
    @State private var document = BackupDocument(data: Data())
    private var target: Space? { model.spaces.first { $0.id == targetID } }
    private var sourceIDs: [UUID] {
        let records = model.records.filter { $0.latest.spaceID == source.id && !$0.deleted && $0.body.sharedDestination == nil }
        return Set(source.members.map(\.id) + records.flatMap { [$0.body.memberID, $0.body.financialOwner?.memberID, $0.body.completedBy].compactMap { $0 } + $0.body.splits.map(\.memberID) }).sorted { $0.uuidString < $1.uuidString }
    }
    var body: some View {
        LifeDetail {
            Text("\(source.name) → \(target?.name ?? "目标家庭不可用")").font(.headline)
            Text("逐个确认旧成员对应关系。可先导出核对文件，再进入差异预览迁入；不修改历史作者，也不授予账号权限。Minty 原记录人和消费归属称呼保持原文。").font(.caption).foregroundStyle(.secondary)
            ForEach(sourceIDs, id: \.self) { id in
                VStack(alignment: .leading) {
                    LifePicker(source.members.first { $0.id == id }?.name ?? "历史成员", selection: Binding<UUID?>(get: { mapping[id] }, set: { mapping[id] = $0; preview = nil; error = nil })) {
                        Text("尚未映射").tag(Optional<UUID>.none)
                        ForEach(target?.members ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("旧标识：\(id.uuidString)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Button("核对映射影响") {
                do {
                    guard let core = model.core else { throw NobisError.forbidden }
                    preview = try core.previewMemberMapping(from: source.id, to: targetID, mapping: mapping); error = nil
                } catch { self.error = error.localizedDescription; preview = nil }
            }.disabled(target == nil)
            if let preview {
                LifeSection(title: "映射影响预览", icon: "checklist") {
                    Text("涉及 \(preview.referencedRecords) 条记录；以下类型可重叠。")
                    LabeledContent("负责人／付款人", value: String(preview.responsibilityOrPayerCount))
                    LabeledContent("含分摊关系", value: String(preview.splitCount))
                    LabeledContent("收入／资产持有人", value: String(preview.financialOwnerCount))
                    LabeledContent("完成者", value: String(preview.completionCount))
                    Text("历史修订作者与审计不会重新署名；金额、付款人与消费归属不会混为同一角色。").font(.caption)
                    Button("导出映射核对文件") {
                        do {
                            guard let core = model.core else { throw NobisError.forbidden }
                            let fresh = try core.previewMemberMapping(from: source.id, to: targetID, mapping: mapping)
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            document = BackupDocument(data: try encoder.encode(fresh)); exporting = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            NavigationLink("预览迁入差异与冲突") { RecoveryMergeView(model: model, liveSourceID: source.id, sourceID: source.id, targetID: targetID, members: mapping) }
            if let error { InlineIssue(message: error) }
        }.navigationTitle("旧成员映射")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Nobis-成员映射核对") { if case .failure(let error) = $0 { self.error = error.localizedDescription } }
    }
}
