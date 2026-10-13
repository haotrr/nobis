import SwiftUI
import UniformTypeIdentifiers
import FamilyDomain
import FamilyCore

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct LedgerWorkspace: View {
    @Bindable var model: AppModel
    private var scope: LifeScope { model.browsingScope }
    @State private var filter = LedgerFilter()
    @State private var filtersExpanded = false
    @State private var selecting = false
    @State private var dates = false
    @State private var from = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var through = Date()
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var selected = Set<UUID>()
    @State private var target: UUID?
    @State private var confirming = false
    @State private var importing = false
    @State private var creating = false
    @State private var exporting = false
    @State private var document = CSVDocument(data: Data())
    private var projects: [Record] { model.records(in: scope).filter { $0.body.kind == .project } }
    private var filterProjects: [Record] { model.records(in: .all).filter { $0.body.kind == .project } }
    private func effectiveFilter() throws -> LedgerFilter {
        var f = filter; f.from = dates ? LocalDay(date: from) : nil; f.through = dates ? LocalDay(date: through) : nil
        guard !dates || from <= through else { throw NobisError.validation("起始日期不能晚于结束日期。") }
        if !minimum.isEmpty || !maximum.isEmpty {
            guard let currency = f.currency else { throw NobisError.validation("筛选金额时请先选择币种。") }
            f.minimum = minimum.isEmpty ? nil : try Money.parse(minimum, currency: currency).minor
            f.maximum = maximum.isEmpty ? nil : try Money.parse(maximum, currency: currency).minor
            if let a = f.minimum, let b = f.maximum, a > b { throw NobisError.validation("最低金额不能高于最高金额。") }
        }
        return f
    }
    private var result: Result<[Record], Error> { Result { if scope == .all && !model.pendingShares.isEmpty { throw NobisError.validation("有分享待完成，请在设置中核对后查看全部合计。") }; let f = try effectiveFilter(); return model.records(in: scope).filter { f.matches($0) }.sorted { ($0.body.date?.description ?? "") > ($1.body.date?.description ?? "") } } }
    var body: some View {
        LifePage(title: "每一笔，心里有数", subtitle: "记录日常收支，一起照顾好生活。", icon: "creditcard") {
            LifeScopeControls(scope: $model.browsingScope)
            NavigationLink { FinancialDashboard(model: model) } label: {
                HStack {
                    Label("收入、资产与财务报告", systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 14) {
                DisclosureGroup(isExpanded: $filtersExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("限定日期", isOn: $dates)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20, alignment: .top)], alignment: .leading, spacing: 16) {
                            if dates {
                                LedgerFilterField("开始日期") { DatePicker("从", selection: $from, displayedComponents: .date).labelsHidden() }
                                LedgerFilterField("结束日期") { DatePicker("至", selection: $through, displayedComponents: .date).labelsHidden() }
                            }
                            LedgerFilterField("分类") {
                                Picker("分类", selection: $filter.category) { Text("全部").tag(Optional<String>.none); ForEach(Array(Set(model.records(in: .all).filter { $0.body.kind == .transaction }.map { $0.body.category })).sorted(), id: \.self) { Text($0).tag(Optional($0)) } }.labelsHidden()
                            }
                            LedgerFilterField("项目") {
                                Picker("项目", selection: $filter.projectID) { Text("全部").tag(Optional<UUID>.none); ForEach(filterProjects) { Text($0.body.title).tag(Optional($0.id)) } }.labelsHidden()
                            }
                            LedgerFilterField("币种") {
                                Picker("币种", selection: $filter.currency) { Text("全部").tag(Optional<Currency>.none); ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) } }.labelsHidden()
                            }
                            LedgerFilterField("最低金额") { TextField("不限", text: $minimum).textFieldStyle(.roundedBorder).accessibilityLabel("最低金额") }
                            LedgerFilterField("最高金额") { TextField("不限", text: $maximum).textFieldStyle(.roundedBorder).accessibilityLabel("最高金额") }
                            LedgerFilterField("消费归属") {
                                Picker("消费归属", selection: $filter.consumption) { Text("全部").tag(Optional<ConsumptionKind>.none); ForEach(ConsumptionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }.labelsHidden()
                            }
                            LedgerFilterField("归属称呼") {
                                Picker("归属称呼", selection: $filter.consumer) { Text("全部").tag(Optional<String>.none); ForEach(Array(Set(model.records(in: .all).compactMap { $0.body.finance?.consumer }.filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag(Optional($0)) } }.labelsHidden()
                            }
                        }
                    }.padding(.top, 16)
                } label: {
                    HStack {
                        Label("筛选账单", systemImage: "line.3.horizontal.decrease")
                        Spacer()
                        Text(activeFilterCount == 0 ? "全部账单" : "已启用 \(activeFilterCount) 项条件").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if activeFilterCount > 0 { Button("清除筛选") { filter = LedgerFilter(); dates = false; minimum = ""; maximum = "" } }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
            switch result {
            case .failure(let error): InlineIssue(message: error.localizedDescription)
            case .success(let records):
                LifeSection(title: "收支明细 · \(records.count) 笔", icon: "list.bullet.rectangle") {
                    ForEach(Currency.allCases, id: \.self) { currency in
                        let entries = records.filter { $0.body.money?.currency == currency && !$0.conflicted && $0.body.status == .confirmed }
                        if !entries.isEmpty { totals(entries, currency: currency) }
                    }
                    if records.contains(where: { $0.conflicted || $0.body.status == .draft }) { Text("草稿与冲突未计入合计。").foregroundStyle(.orange) }
                    if records.isEmpty {
                        WorkspaceEmptyState(title: "没有符合条件的账单", icon: "tray", message: "调整筛选条件，或记下第一笔收支。", actionTitle: activeFilterCount > 0 ? "清除筛选" : "记一笔") {
                            if activeFilterCount > 0 { filter = LedgerFilter(); dates = false; minimum = ""; maximum = "" } else { creating = true }
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { r in HStack {
                        if selecting { Button { if selected.contains(r.id) { selected.remove(r.id) } else { selected.insert(r.id) } } label: { Image(systemName: selected.contains(r.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless).accessibilityLabel("选择 \(r.body.title)") }
                        RecordLink(model: model, record: r) { RecordRow(model: model, record: r) }.buttonStyle(.plain)
                    }
                        if r.id != records.last?.id { Divider().opacity(0.35) }
                    }
                    }
                    Button("导出当前结果 CSV") { model.perform { document = CSVDocument(data: try CSV.scoped(LedgerImport.expenseCSV(records), scope: scope.rawValue)); exporting = true } }.disabled(records.isEmpty)
                }
            }
            if !selected.isEmpty {
                LifeSection(title: "已选 \(selected.count) 笔", icon: "checkmark.circle") {
                    Picker("调整到项目", selection: $target) { Text("请选择").tag(Optional<UUID>.none); ForEach(projects) { Text($0.body.title).tag(Optional($0.id)) } }
                    Button("批量调整项目") { confirming = true }.disabled(target == nil)
                    Button("取消选择") { selected.removeAll() }
                }
            }
        }.navigationTitle("账本").searchable(text: $filter.search, prompt: "名称、备注、分类、原记录人")
        .toolbar {
            WorkspaceCreateAction(title: "记一笔") { creating = true }
            ToolbarItemGroup(placement: .automatic) {
                Button { selecting.toggle(); if !selecting { selected.removeAll() } } label: { Label(selecting ? "完成选择" : "批量选择", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle") }
                Button { importing = true } label: { Label("导入账单", systemImage: "square.and.arrow.down") }
            }
        }
        .onChange(of: scope) { _, _ in selected.removeAll(); target = nil }
        .sheet(isPresented: $creating) { RecordEditor(model: model, kind: .transaction) }
        .sheet(isPresented: $importing) { NavigationStack { LedgerImportView(model: model, presentedAsSheet: true) } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "Nobis-\(scope.title)-收支-\(LocalDay(date: Date()))") { if case .failure(let error) = $0 { model.error = error.localizedDescription } }
        .confirmationDialog("将所选账单的项目关联替换为目标项目，并清除原计划项关联？金额和历史修订保留。", isPresented: $confirming) { Button("确认调整") { model.perform { guard let core = model.core, let target, let project = model.activeRecords.first(where: { $0.id == target }) else { throw NobisError.forbidden }; try core.reassignProjects(recordIDs: selected, to: target, spaceID: project.latest.spaceID); selected.removeAll(); model.refresh() } } }
    }
    private var activeFilterCount: Int {
        [dates, filter.category != nil, filter.projectID != nil, filter.currency != nil,
         !minimum.isEmpty, !maximum.isEmpty, filter.consumption != nil, filter.consumer != nil,
         !filter.search.isEmpty].filter { $0 }.count
    }
    private func totals(_ records: [Record], currency: Currency) -> some View {
        Group {
            switch Result(catching: {
                let expense = try Money.sum(records.filter { [.expense, .refund].contains($0.body.transactionKind) }.map { ($0.body.money?.minor ?? 0) * ($0.body.transactionKind == .refund ? -1 : 1) })
                let income = try Money.sum(records.filter { $0.body.transactionKind == .income }.compactMap { $0.body.money?.minor })
                return (Money(minor: expense, currency: currency).formatted, Money(minor: income, currency: currency).formatted)
            }) {
            case .success(let values):
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 32) { amountSummary("净支出", value: values.0); amountSummary("收入", value: values.1) }
                    VStack(alignment: .leading, spacing: 16) { amountSummary("净支出", value: values.0); amountSummary("收入", value: values.1) }
                }.padding(.vertical, 10)
            case .failure(let error): InlineIssue(message: error.localizedDescription)
            }
        }
    }
    private func amountSummary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}
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
    @State private var report: String?
    @State private var confirming = false
    private var review: Result<[RecordChange], Error>? {
        guard let preview, let spaceID, let core = model.core else { return nil }
        return Result { try core.importChanges(preview, spaceID: spaceID, categoryMap: mapping) }
    }
    var body: some View {
        LifeDetail {
            LifeFormSection(title: "导入可见性", icon: "eye") {
                RecordVisibilityField(model: model, spaceID: $spaceID, editable: true)
                Text("支持支付宝／微信支出 CSV、Minty 支出 CSV，以及专用 Minty JSON 迁移包。确认前不会写入业务数据。").font(.caption)
                Button("选择文件…") { choosing = true }
                if !filename.isEmpty { Text(filename).font(.caption) }
            }
            if let preview {
                LifeSection(title: "核对结果", icon: "checkmark.circle") {
                    Text("可解析 \(preview.entries.count) 条 · 跳过 \(preview.skipped) 条 · 错误 \(preview.issues.count) 条")
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange) }
                    ForEach(Array(preview.issues.prefix(100).enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.red) }
                    ForEach(Currency.allCases, id: \.self) { currency in
                        let amounts = preview.entries.filter { $0.body.kind == .transaction && $0.body.money?.currency == currency }.compactMap { $0.body.money?.minor }
                        if !amounts.isEmpty { Text(sum(amounts, currency: currency)) }
                    }
                    Text("下列为文件内金额；已导入记录会在提交时跳过，不重复入账。").font(.caption)
                }
                if let review {
                    switch review {
                    case .success(let changes): Text("本次新增 \(changes.count) 条，已导入或已有分类 \(preview.entries.count - changes.count) 条。")
                    case .failure(let issue): InlineIssue(message: issue.localizedDescription)
                    }
                }
                LifeFormSection(title: "分类映射", icon: "tag") { ForEach(preview.categories, id: \.self) { category in TextField(category, text: Binding(get: { mapping[category] ?? category }, set: { mapping[category] = $0 })) } }
                LifeSection(title: "记录预览（前 100 条）", icon: "list.bullet.rectangle") { ForEach(preview.entries.prefix(100)) { entry in VStack(alignment: .leading) { Text("\(entry.body.kind.title) · \(entry.body.title)"); Text("\(entry.body.date?.description ?? "") \(entry.body.money?.formatted ?? "")").font(.caption) } } }
                Button("确认导入…") { confirming = true }.disabled(!preview.issues.isEmpty || preview.entries.isEmpty || spaceID == nil)
            }
            if let error { InlineIssue(message: error) }
            if let report { Text(report).textSelection(.enabled) }
        }.navigationTitle("导入与迁移").onAppear { if spaceID == nil { spaceID = model.workspace.commonID } }.toolbar {
            if presentedAsSheet { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.editorDimensions()
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .json, .plainText]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20_000_000 else { throw NobisError.validation("文件超过 20 MB，请分批导入。") }
                let data = try Data(contentsOf: url)
                let parsed = try url.pathExtension.lowercased() == "json" ? MintyMigration.preview(data) : LedgerImport.csv(data)
                raw = data; preview = parsed; filename = url.lastPathComponent; if spaceID == nil { spaceID = model.selectedSpaceID }; mapping = [:]; error = nil; report = nil
            } catch { self.error = error.localizedDescription; preview = nil }
        }
        .confirmationDialog("按所选可见性导入预览中的记录？两人共享的内容将对另一位可见。写入前会保存当前空间备份和迁移源文件；这些显式备份在退出家庭后仍保留。", isPresented: $confirming) { Button("确认导入") { commit() } }
    }
    private func sum(_ amounts: [Int64], currency: Currency) -> String { do { return try "支出 \(Money(minor: Money.sum(amounts), currency: currency).formatted)" } catch { return error.localizedDescription } }
    private func commit() {
        do {
            guard let preview, let spaceID, model.workspace.ids(.all).contains(spaceID), let core = model.core else { throw NobisError.forbidden }
            let folder = model.directory.appendingPathComponent("Migration/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try core.export(spaceID: spaceID).write(to: folder.appendingPathComponent("before-import.json"), options: .atomic)
            try raw.write(to: folder.appendingPathComponent("source-" + (filename.lowercased().hasSuffix(".json") ? "minty.json" : "expenses.csv")), options: .atomic)
            let count = try core.commitImport(preview, spaceID: spaceID, categoryMap: mapping)
            report = "已新增 \(count) 条，跳过此前已导入的记录。备份与源文件：\(folder.path)"; self.preview = nil; error = nil
            model.refresh()
        } catch { self.error = error.localizedDescription }
    }
}

private struct LedgerFilterField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
