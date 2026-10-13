import SwiftUI
import UniformTypeIdentifiers
import FamilyDomain
import FamilyCore

struct LedgerImportView: View {
    let model: AppModel
    var presentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var preview: ImportPreview?
    @State private var raw = Data()
    @State private var filename = ""
    @State private var spaceID: UUID?
    @State private var mapping: [String: String] = [:]
    @State private var error: String?
    @State private var receipt: ImportReceipt?
    @State private var confirming = false
    @State private var kind: RecordKind?
    @State private var search = ""
    @State private var limit = 100

    private var review: Result<[RecordChange], Error>? {
        guard let preview, let spaceID, let core = model.core else { return nil }
        return Result { try core.importChanges(preview, spaceID: spaceID, categoryMap: mapping) }
    }
    var body: some View {
        let currentReview = review
        LifeDetail {
            LifeFormSection(title: "导入可见性", icon: "eye") {
                RecordVisibilityField(model: model, spaceID: $spaceID, editable: true)
                Text("支持支出 CSV 与 Minty JSON 迁移包。确认前不会写入业务数据。").font(.caption)
                Button("选择文件…") { choosing = true }
                if !filename.isEmpty { Text(filename).font(.caption) }
            }
            if let preview {
                inspection(preview, review: currentReview)
                if !preview.categories.isEmpty {
                    LifeFormSection(title: "分类映射", icon: "tag") {
                        DisclosureGroup("调整分类名称") {
                            ForEach(preview.categories, id: \.self) { category in
                                LifeTextField(category, text: Binding(get: { mapping[category] ?? category }, set: { mapping[category] = $0 }))
                            }
                        }
                    }
                }
                entries(preview)
                Button("确认导入…") { confirming = true }.disabled(!canCommit(currentReview))
            }
            if let error { InlineIssue(message: error) }
            if let receipt {
                LifeSection(title: "导入完成", icon: "checkmark.circle") {
                    Text("新增 \(receipt.ids.count) 条，已有 \(receipt.existing) 条。")
                    Text("已保存到所选空间；跨设备送达需另行查看同步状态。").font(.caption).foregroundStyle(.secondary)
                    NavigationLink("查看本次新增记录") { ImportedRecordsView(model: model, receipt: receipt) }
                        .disabled(receipt.ids.isEmpty)
                    DisclosureGroup("备份与源文件") { Text(receipt.folder.path).font(.caption).textSelection(.enabled) }
                }
            }
        }.navigationTitle("导入与迁移")
        .onAppear { if spaceID == nil { spaceID = model.workspace.commonID } }
        .onChange(of: kind) { _, _ in limit = 100 }
        .onChange(of: search) { _, _ in limit = 100 }
        .toolbar {
            if presentedAsSheet { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.editorDimensions()
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .json, .plainText]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20_000_000 else { throw NobisError.validation("文件超过 20 MB，请使用保留完整关联的迁移包分批导入。") }
                let data = try Data(contentsOf: url)
                let parsed = try url.pathExtension.lowercased() == "json" ? MintyMigration.preview(data) : LedgerImport.csv(data)
                raw = data; preview = parsed; filename = url.lastPathComponent
                mapping = [:]; kind = nil; search = ""; limit = 100; error = nil; receipt = nil
            } catch { self.error = error.localizedDescription; preview = nil }
        }
        .confirmationDialog("按所选可见性导入？共同空间的内容将对另一位可见。写入前会保存当前空间备份和源文件，退出家庭后这些备份仍保留。", isPresented: $confirming) {
            Button("确认导入") { commit() }
        }
    }
    private func canCommit(_ review: Result<[RecordChange], Error>?) -> Bool {
        if case .success(let changes) = review { return !changes.isEmpty }
        return false
    }
    @ViewBuilder private func inspection(_ preview: ImportPreview, review: Result<[RecordChange], Error>?) -> some View {
        let changes = try? review?.get()
        LifeSection(title: "核对结果", icon: "checkmark.circle") {
            Text("可解析 \(preview.entries.count) 条 · 源文件跳过 \(preview.skipped) 条 · 错误 \(preview.issues.count) 条")
            if case .failure(let issue) = review { InlineIssue(message: issue.localizedDescription) }
            ForEach(ImportInspection(preview: preview, changes: changes).groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.kind.title) · \(group.bodies.count) 条").font(.headline)
                    if let additions = group.additions {
                        Text("新增 \(additions.count) · 已有 \(group.existingCount ?? 0)").font(.caption)
                    } else { Text("尚未通过校验，新增数量待确认").font(.caption).foregroundStyle(.orange) }
                    if group.planCount > 0 { Text("含 \(group.planCount) 个计划项，随项目迁入").font(.caption) }
                    ImportAmounts(bodies: group.bodies, label: "文件内")
                    if let additions = group.additions, !additions.isEmpty { ImportAmounts(bodies: additions, label: "本次新增") }
                    if group.kind == .assetSnapshot { Text("按日期逐份核对余额，不累计不同日期的快照。").font(.caption).foregroundStyle(.secondary) }
                    if group.kind == .subscription { Text("迁入后暂停，核对后启用。").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
            if !preview.retained.isEmpty {
                DisclosureGroup("未进入业务视图 · \(preview.retained.count) 项说明") {
                    ForEach(preview.retained, id: \.self) { Text($0).font(.caption) }
                }
            }
            ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if !preview.issues.isEmpty {
                DisclosureGroup("错误详情 · \(preview.issues.count) 条", isExpanded: .constant(true)) {
                    ForEach(Array(preview.issues.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.red) }
                }
            }
        }
    }
    private func entries(_ preview: ImportPreview) -> some View {
        let entries = preview.entries.filter { (kind == nil || $0.body.kind == kind) && (search.isEmpty || $0.body.title.localizedCaseInsensitiveContains(search) || $0.body.notes.localizedCaseInsensitiveContains(search)) }
        return LifeSection(title: "记录预览 · \(entries.count) 条", icon: "list.bullet.rectangle") {
            Picker("数据类型", selection: $kind) {
                Text("全部类型").tag(Optional<RecordKind>.none)
                ForEach(RecordKind.allCases.filter { type in preview.entries.contains { $0.body.kind == type } }) { Text($0.title).tag(Optional($0)) }
            }
            TextField("搜索名称或备注", text: $search).textFieldStyle(.roundedBorder)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(entries.prefix(limit)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.body.title)
                        ImportRecordValue(value: entry.body)
                    }
                }
            }
            if entries.isEmpty { Text("没有符合条件的记录。").foregroundStyle(.secondary) }
            if entries.count > limit { Button("再显示 100 条（已显示 \(limit) 条）") { limit += 100 } }
        }
    }
    private func commit() {
        do {
            guard let preview, let spaceID, model.workspace.ids(.all).contains(spaceID), let core = model.core else { throw NobisError.forbidden }
            let changes = try core.importChanges(preview, spaceID: spaceID, categoryMap: mapping)
            guard !changes.isEmpty else { return }
            let folder = model.directory.appendingPathComponent("Migration/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try core.export(spaceID: spaceID).write(to: folder.appendingPathComponent("before-import.json"), options: .atomic)
            try raw.write(to: folder.appendingPathComponent(filename.lowercased().hasSuffix(".json") ? "source-minty.json" : "source-expenses.csv"), options: .atomic)
            try core.saveBatch(changes, spaceID: spaceID)
            receipt = ImportReceipt(ids: Set(changes.map(\.id)), existing: preview.entries.count - changes.count, folder: folder)
            self.preview = nil; error = nil; model.refresh()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ImportReceipt {
    let ids: Set<UUID>
    let existing: Int
    let folder: URL
}
private struct ImportedRecordsView: View {
    let model: AppModel
    let receipt: ImportReceipt
    @State private var kind: RecordKind?
    @State private var search = ""
    var body: some View {
        let records = model.activeRecords.filter { receipt.ids.contains($0.id) && (kind == nil || $0.body.kind == kind) && (search.isEmpty || $0.body.title.localizedCaseInsensitiveContains(search)) }
        LifePage {
            Picker("数据类型", selection: $kind) {
                Text("全部类型").tag(Optional<RecordKind>.none)
                ForEach(RecordKind.allCases) { Text($0.title).tag(Optional($0)) }
            }
            Text("\(records.count) 条记录").font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading) {
                ForEach(records) { record in
                    NavigationLink { RecordDetail(model: model, recordID: record.id) } label: {
                        VStack(alignment: .leading) {
                            RecordRow(model: model, record: record)
                            if [.monthlyIncome, .assetSnapshot, .project].contains(record.body.kind) { ImportRecordValue(value: record.body) }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle("本次新增记录").searchable(text: $search, prompt: "搜索名称")
    }
}
private struct ImportAmounts: View {
    let bodies: [RecordBody]
    let label: String
    var body: some View {
        ForEach(Currency.allCases, id: \.self) { currency in
            if bodies.contains(where: { $0.money?.currency == currency && $0.kind == .transaction || $0.incomeMonth?.net.currency == currency }) {
                switch Result(catching: { try ImportInspection.totals(bodies, currency: currency) }) {
                case .failure(let error): InlineIssue(message: error.localizedDescription)
                case .success(let sums):
                    if bodies.contains(where: { $0.kind == .transaction }) {
                        Text("\(label)净支出 \(Money(minor: sums.expense, currency: currency).formatted)").font(.caption).monospacedDigit()
                    }
                    if bodies.contains(where: { $0.kind == .monthlyIncome }) {
                        Text("\(label)税后到账 \(Money(minor: sums.monthlyNet, currency: currency).formatted) · 税前 \(Money(minor: sums.gross, currency: currency).formatted)").font(.caption).monospacedDigit()
                    }
                }
            }
        }
    }
}
private struct ImportRecordValue: View {
    let value: RecordBody
    var body: some View {
        Group {
            if let income = value.incomeMonth {
                Text("\(income.periodTitle) · 税后 \(income.net.formatted)")
            } else if let asset = value.assetPosition {
                switch Result(catching: { try asset.net() }) {
                case .success(let net): Text("\(value.date?.description ?? "") · 净资产 \(Money(minor: net, currency: asset.currency).formatted)")
                case .failure(let error): Text(error.localizedDescription)
                }
            } else if let budget = value.budget { Text("预算 \(budget.limit.formatted) · \(budget.items.count) 个计划项") }
            else { Text("\(value.date?.description ?? "") \(value.money?.formatted ?? "")") }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
