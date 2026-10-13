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
    init(model: AppModel, period: LedgerPeriod? = nil, category: String? = nil, currency: Currency? = nil) {
        var initial = LedgerFilter(); initial.category = category; initial.currency = currency
        if category != nil { initial.transactionKinds = [.expense, .refund] }
        _filter = State(initialValue: initial)
        self.model = model
        if let bounds = try? period?.bounds() {
            _dates = State(initialValue: true)
            _from = State(initialValue: bounds.from.date())
            _through = State(initialValue: bounds.through.date())
        }
    }
    private var months: [LedgerPeriod] {
        LedgerMonthGroup.groups(model.records(in: scope).filter { $0.body.kind == .transaction }).compactMap(\.period)
    }
    private var reportPeriod: LedgerPeriod? {
        guard dates else { return nil }
        let first = LocalDay(date: from), last = LocalDay(date: through)
        guard first.year == last.year else { return nil }
        return LedgerPeriod(year: first.year, month: first.month == last.month ? first.month : nil)
    }
    private func selectPeriod(_ period: LedgerPeriod?) {
        selected.removeAll()
        guard let period else { dates = false; return }
        do { let bounds = try period.bounds(); from = bounds.from.date(); through = bounds.through.date(); dates = true }
        catch { model.error = error.localizedDescription }
    }
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
        LifePage {
            LifeScopeControls(scope: $model.browsingScope)
            NavigationLink { FinancialDashboard(model: model, period: reportPeriod) } label: {
                HStack {
                    Label("收入、资产与财务报告", systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            HStack {
                Menu {
                    Button("全部日期") { selectPeriod(nil) }
                    Button("本月") { let day = LocalDay(date: Date()); selectPeriod(LedgerPeriod(year: day.year, month: day.month)) }
                    ForEach(Array(Set(months.map(\.year))).sorted(by: >), id: \.self) { year in
                        Menu("\(String(year)) 年") {
                            Button("全年") { selectPeriod(LedgerPeriod(year: year)) }
                            ForEach(months.filter { $0.year == year }, id: \.self) { period in
                                Button(period.title) { selectPeriod(period) }
                            }
                        }
                    }
                } label: { Label(dates ? "\(LocalDay(date: from)) 至 \(LocalDay(date: through))" : "全部日期", systemImage: "calendar") }
                Spacer(minLength: 0)
            }
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
                if activeFilterCount > 0 {
                    Text(filterDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text("流水收入不含月度及非月度收入记录；完整收入与结余见财务报告。").font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(LedgerMonthGroup.groups(records)) { group in
                            LazyVStack(alignment: .leading, spacing: 6) {
                                Text(group.period?.title ?? "日期待核对").font(.headline)
                                ForEach(Currency.allCases, id: \.self) { currency in
                                    let valid = group.records.filter { !$0.conflicted && $0.body.status == .confirmed && $0.body.money?.currency == currency }
                                    if !valid.isEmpty { LedgerMonthTotals(records: valid, currency: currency) }
                                }
                                ForEach(group.records) { r in
                                    HStack {
                                        if selecting { Button { if selected.contains(r.id) { selected.remove(r.id) } else { selected.insert(r.id) } } label: { Image(systemName: selected.contains(r.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless).accessibilityLabel("选择 \(r.body.title)") }
                                        RecordLink(model: model, record: r) { RecordRow(model: model, record: r) }.buttonStyle(.plain)
                                    }.id(r.id)
                                    if r.id != group.records.last?.id { Divider().opacity(0.35) }
                                }
                            }
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
        }.navigationTitle("账本").searchable(text: $filter.search, prompt: "搜索名称、分类、账户或归属，空格分词")
        .toolbar {
            WorkspaceCreateAction(title: "记一笔") { creating = true }
            ToolbarItemGroup(placement: .automatic) {
                Button { selecting.toggle(); if !selecting { selected.removeAll() } } label: { Label(selecting ? "完成选择" : "批量选择", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle") }
                Button { importing = true } label: { Label("导入账单", systemImage: "square.and.arrow.down") }
            }
        }
        .onChange(of: scope) { _, _ in selected.removeAll(); target = nil }
        .sheet(isPresented: $creating) { RecordEditor(model: model, kind: .transaction) }
        .sheet(isPresented: $importing) { NavigationStack { LedgerImportView(model: model, presentedAsSheet: true) }.editorDimensions() }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "Nobis-\(scope.title)-收支-\(LocalDay(date: Date()))") { if case .failure(let error) = $0 { model.error = error.localizedDescription } }
        .confirmationDialog("将所选账单的项目关联替换为目标项目，并清除原计划项关联？金额和历史修订保留。", isPresented: $confirming) { Button("确认调整") { model.perform { guard let core = model.core, let target, let project = model.activeRecords.first(where: { $0.id == target }) else { throw NobisError.forbidden }; try core.reassignProjects(recordIDs: selected, to: target, spaceID: project.latest.spaceID); selected.removeAll(); model.refresh() } } }
    }
    private var filterDescription: String {
        var values: [String] = []
        if filter.transactionKinds != nil { values.append("仅支出与退款") }
        if let category = filter.category { values.append("分类：" + category) }
        if let id = filter.projectID { values.append("项目：" + (filterProjects.first { $0.id == id }?.body.title ?? "不可用")) }
        if let currency = filter.currency { values.append(currency.rawValue) }
        if !minimum.isEmpty { values.append("最低 " + minimum) }
        if !maximum.isEmpty { values.append("最高 " + maximum) }
        if let consumption = filter.consumption { values.append(consumption.title) }
        if let consumer = filter.consumer { values.append(consumer) }
        if !filter.search.isEmpty { values.append("搜索：" + filter.search) }
        return values.joined(separator: " · ")
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 16) {
                    amountSummary("净支出", value: values.0)
                    amountSummary("流水收入", value: values.1)
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

private struct LedgerMonthTotals: View {
    let records: [Record]
    let currency: Currency
    var body: some View {
        switch Result(catching: { try ImportInspection.totals(records.map(\.body), currency: currency) }) {
        case .failure(let error): InlineIssue(message: error.localizedDescription)
        case .success(let sums):
            Text("净支出 \(Money(minor: sums.expense, currency: currency).formatted) · 流水收入 \(Money(minor: sums.income, currency: currency).formatted)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }
}
