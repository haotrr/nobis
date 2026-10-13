import SwiftUI
import Charts
import FamilyDomain
import FamilyCore

struct FinancialRecordEditor: View {
    let model: AppModel
    let kind: RecordKind
    let existing: Record?
    let onFinish: (() -> Void)?
    @State private var spaceID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var year = 2026
    @State private var month = 1
    @State private var owner = "unknown"
    @State private var incomeType = "工资"
    @State private var gross = ""
    @State private var net = ""
    @State private var tax = ""
    @State private var day = Date()
    @State private var currency: Currency = .CNY
    @State private var amounts: [AssetComponent: String] = [:]
    @State private var notes = ""
    @State private var error: String?
    @State private var initialDraft: Draft?
    @State private var confirmingDiscard = false
    private var hasLocalChanges: Bool { initialDraft.map { $0 != draft } ?? false }
    private struct Draft: Equatable {
        let spaceID: UUID?
        let year: Int; let month: Int
        let owner: String; let incomeType: String
        let gross: String; let net: String; let tax: String
        let day: Date; let currency: Currency
        let amounts: [AssetComponent: String]; let notes: String
    }
    private var draft: Draft { Draft(spaceID: spaceID, year: year, month: month, owner: owner, incomeType: incomeType, gross: gross, net: net, tax: tax, day: day, currency: currency, amounts: amounts, notes: notes) }

    init(model: AppModel, kind: RecordKind, existing: Record? = nil, onFinish: (() -> Void)? = nil) {
        self.model = model; self.kind = kind; self.existing = existing; self.onFinish = onFinish; _spaceID = State(initialValue: existing?.latest.spaceID ?? model.selectedSpaceID)
        _owner = State(initialValue: existing?.body.financialOwner?.key ?? "unknown")
        let now = LocalDay(date: Date()), income = existing?.body.incomeMonth, assets = existing?.body.assetPosition
        _year = State(initialValue: income?.year ?? now.year); _month = State(initialValue: income?.month ?? now.month)
        _incomeType = State(initialValue: income?.type ?? "工资"); _notes = State(initialValue: existing?.body.notes ?? "")
        _currency = State(initialValue: income?.net.currency ?? assets?.currency ?? .CNY)
        func text(_ money: Money?) -> String { money.map { (Decimal($0.minor) / Decimal($0.currency.factor)).description } ?? "" }
        _gross = State(initialValue: text(income?.gross)); _net = State(initialValue: text(income?.net)); _tax = State(initialValue: text(income?.tax))
        _day = State(initialValue: existing?.body.date?.date() ?? Date())
        _amounts = State(initialValue: Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { component in (component, assets.map { asset in text(Money(minor: asset.amounts[component] ?? 0, currency: asset.currency)) } ?? "0") }))
    }
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            LifeDetail {
                LifeFormSection(title: "基本信息", icon: kind.icon) {
                    RecordVisibilityField(model: model, spaceID: $spaceID, editable: existing == nil)
                    LifePicker(kind == .monthlyIncome ? "收入归属" : "资产持有范围", selection: $owner, selectedTitle: owner == "unknown" ? "归属待确认" : owner == "joint" ? "共同持有" : model.spaces.first { $0.id == spaceID }?.members.first { $0.id.uuidString == owner }?.name ?? "归属待确认") {
                        Text("归属待确认").tag("unknown")
                        if kind == .assetSnapshot { Text("共同持有").tag("joint") }
                        ForEach(model.spaces.first { $0.id == spaceID }?.members ?? []) { Text($0.name).tag($0.id.uuidString) }
                    }
                    LifePicker("币种", selection: $currency) { ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if kind == .monthlyIncome {
                        LabeledContent("年份") { LifeIntegerControl(value: $year, range: 1...9999, suffix: "年", label: "收入年份") }
                        LifePicker("月份", selection: $month) { ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) } }
                        LifeTextField("收入类型", text: $incomeType)
                        LifeTextField("税前收入", text: $gross); LifeTextField("税后到账", text: $net); LifeTextField("税额（未知留空）", text: $tax)
                        Text("税后金额计入月报收入。不要再为同一笔收入录入普通流水；税前与税后的差额也可能含社保等扣款，不自动视为税额。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        DatePicker("快照日期", selection: $day, displayedComponents: .date)
                        Text("这是所选持有范围、此币种的完整余额。共同资产只记一次；旧整体余额先核对，不与分人快照相加。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if kind == .assetSnapshot {
                    LifeFormSection(title: "资产", icon: "chart.pie") { ForEach(AssetComponent.allCases.filter { !$0.liability }, id: \.self) { component in LifeTextField(component.title, text: field(component)) } }
                    LifeFormSection(title: "负债", icon: "creditcard") { ForEach(AssetComponent.allCases.filter(\.liability), id: \.self) { component in LifeTextField(component.title, text: field(component)) } }
                }
                LifeFormSection(title: "备注", icon: "text.alignleft") { LifeTextField("说明", text: $notes, axis: .vertical) }
                if let error { InlineIssue(message: error) }
            }
            .modifier(LifeEditorChrome(title: (existing == nil ? "新建" : "编辑") + kind.title,
                icon: kind.icon, embedded: onFinish != nil, cancel: cancel, save: save,
                hasChanges: onFinish != nil ? model.recordPanel.hasChanges : existing == nil || hasLocalChanges,
                saveTitle: existing == nil ? "保存" : "保存修改"))
        }
        .tint(colorScheme == .dark ? Color(red: 0.65, green: 0.82, blue: 0.73) : Color(red: 0.24, green: 0.43, blue: 0.36))
        .interactiveDismissDisabled(onFinish == nil && hasLocalChanges)
        .confirmationDialog("放弃尚未保存的内容？", isPresented: $confirmingDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .onAppear { if initialDraft == nil { initialDraft = draft } }
        .onChange(of: draft) { _, value in
            if onFinish != nil, let existing, let initialDraft {
                model.recordPanel.updateChanges(value != initialDraft, recordID: existing.id)
            }
        }
        .onChange(of: spaceID) { _, _ in owner = "unknown" }.editorDimensions(width: onFinish == nil ? 600 : 440, height: onFinish == nil ? 640 : 0)
    }
    private func field(_ c: AssetComponent) -> Binding<String> { Binding(get: { amounts[c] ?? "0" }, set: { amounts[c] = $0 }) }
    private func cancel() {
        if onFinish != nil { model.recordPanel.cancelEditing() }
        else if hasLocalChanges { confirmingDiscard = true }
        else { dismiss() }
    }
    private func finish() { if let onFinish { onFinish() } else { dismiss() } }
    private func save() {
        do {
            guard let spaceID else { throw NobisError.forbidden }
            var b = existing?.body ?? RecordBody(kind: kind, title: kind.title); b.notes = notes
            b.financialOwner = owner == "unknown" ? nil : owner == "joint" ? FinancialOwner(kind: .joint) : FinancialOwner(kind: .member, memberID: UUID(uuidString: owner))
            if kind == .monthlyIncome {
                b.incomeMonth = IncomeMonth(year: year, month: month, type: incomeType, gross: try Money.parse(gross, currency: currency), net: try Money.parse(net, currency: currency), tax: tax.isEmpty ? nil : try Money.parse(tax, currency: currency))
                b.title = "\(year)-\(String(format: "%02d", month)) · \(incomeType)"
            } else {
                b.date = LocalDay(date: day); b.title = "资产快照 · \(b.date!)"
                b.assetPosition = AssetPosition(currency: currency, amounts: try Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, try Money.parse(amounts[$0] ?? "", currency: currency).minor) }))
            }
            try model.save(b, spaceID: spaceID, existing: existing); finish()
        } catch { self.error = error.localizedDescription }
    }
}
struct FinancialRecordDetails: View {
    let record: Record
    var embedded = false
    var body: some View {
        Group {
            if embedded { fields }
            else if record.body.incomeMonth != nil || record.body.assetPosition != nil {
                LifeSection(title: "财务明细", icon: "chart.bar") { fields }
            }
        }
    }
    @ViewBuilder private var fields: some View {
        if let i = record.body.incomeMonth {
            Section("月度收入") {
                FinancialValueRow("收入月份", value: "\(i.year)-\(String(format: "%02d", i.month))")
                FinancialValueRow("税前", value: i.gross.formatted); FinancialValueRow("税后到账", value: i.net.formatted)
                FinancialValueRow("税额", value: i.tax?.formatted ?? "未记录")
            }
        }
        if let a = record.body.assetPosition {
            Section("资产负债明细") {
                ForEach(AssetComponent.allCases, id: \.self) { c in FinancialValueRow(c.title, value: Money(minor: a.amounts[c] ?? 0, currency: a.currency).formatted) }
                switch Result(catching: { try (a.assets(), a.liabilities(), a.net()) }) {
                case .success(let totals):
                    FinancialValueRow("总资产", value: Money(minor: totals.0, currency: a.currency).formatted)
                    FinancialValueRow("总负债", value: Money(minor: totals.1, currency: a.currency).formatted)
                    FinancialValueRow("净资产", value: Money(minor: totals.2, currency: a.currency).formatted)
                case .failure(let e): InlineIssue(message: e.localizedDescription)
                }
            }
        }
    }
}

struct FinancialDashboard: View {
    @Bindable var model: AppModel
    private var scope: LifeScope { model.browsingScope }
    @State private var year = LocalDay(date: Date()).year
    @State private var month = LocalDay(date: Date()).month
    @State private var annual = false
    @State private var create: RecordKind?
    @State private var exporting = false
    @State private var document = CSVDocument(data: Data())
    private var selectedMonth: Int? { annual ? nil : month }
    var body: some View {
        LifeDetail {
            VStack(alignment: .leading, spacing: 8) {
                Text("财务报告").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("查看收支、订阅成本与期末资产。").font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 8)
            LifeScopeControls(scope: $model.browsingScope)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    reportType
                    reportDate
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 16) {
                    reportType
                    reportDate
                }
            }.padding(.vertical, 4)
            switch Result(catching: { try model.report(in: scope) }) {
            case .failure(let error): Text(error.localizedDescription)
            case .success(let view):
                report(view.core, space: view.spaceID)
                subscriptions(view.core, space: view.spaceID)
            }
            ForEach(model.spaces.filter { model.workspace.ids(scope).contains($0.id) }) { source in
                if let core = model.core {
                    ResourceOwnership(model: model, spaceID: source.id, detailed: true).padding(.horizontal, 4)
                    positions(core, space: source.id)
                    let assets = model.records(in: scope).filter { $0.latest.spaceID == source.id && $0.body.kind == .assetSnapshot }
                    ForEach(Array(Set(assets.map { $0.body.financialOwner?.key ?? "legacy" })).sorted(), id: \.self) { owner in
                        let group = assets.filter { ($0.body.financialOwner?.key ?? "legacy") == owner }
                        if let first = group.first { FinancialOwnershipBadge(model: model, record: first).padding(.horizontal, 4) }
                        AssetHistoryTrend(records: group, year: year)
                    }
                }
            }
            LifeSection(title: "月度收入记录", icon: "banknote") {
                let incomes = model.records(in: scope).filter { $0.body.kind == .monthlyIncome && $0.body.incomeMonth?.year == year && (annual || $0.body.incomeMonth?.month == month) }
                if incomes.isEmpty { Text("这个期间还没有收入记录。").foregroundStyle(.secondary) }
                Button("录入月度收入", systemImage: "plus") { create = .monthlyIncome }
                ForEach(incomes) { record in
                    RecordLink(model: model, record: record) { VStack(alignment: .leading) { Text(record.body.title); ResourceOwnership(model: model, spaceID: record.latest.spaceID); Text(record.body.incomeMonth?.net.formatted ?? "").font(.caption); if record.conflicted { Text("待核对").foregroundStyle(.orange) } } }
                }
            }
            LifeSection(title: "资产快照历史", icon: "clock.arrow.circlepath") {
                if !model.records(in: scope).contains(where: { $0.body.kind == .assetSnapshot }) { Text("记下当前余额，慢慢积累资产变化的记录。").foregroundStyle(.secondary) }
                Button("记录资产快照", systemImage: "plus") { create = .assetSnapshot }
                ForEach(model.records(in: scope).filter { $0.body.kind == .assetSnapshot }.sorted { ($0.body.date?.description ?? "") > ($1.body.date?.description ?? "") }) { record in RecordLink(model: model, record: record) { VStack(alignment: .leading, spacing: 6) { Text(record.body.title); ResourceOwnership(model: model, spaceID: record.latest.spaceID); Text(record.body.assetPosition?.currency.rawValue ?? "") } } }
            }
        }.buttonStyle(.borderless).navigationTitle(annual ? "年度财务报告" : "月度财务报告")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("录入月度收入") { create = .monthlyIncome }
                    Button("记录资产快照") { create = .assetSnapshot }
                } label: { Label("新建财务记录", systemImage: "plus") }
            }
        }
        .sheet(item: $create) { FinancialRecordEditor(model: model, kind: $0) }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "Nobis-\(scope.title)-报告-\(year)-\(annual ? "全年" : String(month))") { if case .failure(let e) = $0 { model.error = e.localizedDescription } }
    }
    private var reportType: some View {
        DirectSelection(title: "报告类型", selection: $annual, options: [false, true], showsTitle: false) { $0 ? "年报" : "月报" }
            .fixedSize(horizontal: true, vertical: false)
    }
    private var reportDate: some View {
        LifeAdaptiveRow {
            LifeIntegerControl(value: $year, range: 1...9998, suffix: "年", label: "报告年份")
            if !annual {
                Picker("月份", selection: $month) {
                    ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("报告月份")
            }
        }
    }
    @ViewBuilder private func report(_ core: FamilyCore, space: UUID) -> some View {
        switch Result(catching: { try core.financialReport(spaceID: space, year: year, month: selectedMonth) }) {
        case .failure(let e): InlineIssue(message: e.localizedDescription)
        case .success(let report):
            LifeSection(title: "收支与结余", icon: "chart.bar") {
                Text("收入 = 月度税后到账 + 普通收入流水；同一收入只录一次。成员结算不计收支，退款计入实际发生月。资产变化不视为收入。").font(.caption).foregroundStyle(.secondary)
                if report.totals.isEmpty { Text("此期间暂无已确认收支。") }
                if report.unresolvedCount > 0 { Text("\(report.unresolvedCount) 条草稿或冲突未计入，合计尚不完整。").foregroundStyle(.orange) }
                ForEach(report.totals, id: \.currency) { g in
                    StatementSummary(value: g)
                }
                Button("导出报告 CSV") { model.perform { document = CSVDocument(data: try CSV.scoped(core.financialReportCSV(spaceID: space, year: year, month: selectedMonth), scope: scope.rawValue)); exporting = true } }
            }
            if annual { AnnualTrend(core: core, space: space, year: year) }
        }
    }
    @ViewBuilder private func positions(_ core: FamilyCore, space: UUID) -> some View {
        LifeSection(title: "期末资产 · 最近完整快照", icon: "chart.pie") {
            switch Result(catching: { () throws -> [PositionObservation] in
                let start = try LocalDay(year, annual ? 12 : month, 1)
                let next = try start.nextCycle(unit: .month, count: 1, anchor: start)
                return try core.positions(spaceID: space, through: next.addingDays(-1))
            }) {
            case .failure(let e): InlineIssue(message: e.localizedDescription)
            case .success(let observations):
                if observations.isEmpty { Text("暂无截至期末的快照。") }
                Text("各持有范围分别展示，原整体余额与分人资产不相加。归属待确认时请先核对。").font(.caption).foregroundStyle(.secondary)
                ForEach(observations, id: \.id) { observation in
                    if observation.ambiguous { Text("\(observation.currency.rawValue) 最新日期有重复或冲突快照，请核对；不自动选择其中一份。").foregroundStyle(.orange) }
                    else if let r = observation.record { FinancialOwnershipBadge(model: model, record: r); Text("截至 \(r.body.date?.description ?? "") · \(observation.currency.rawValue)"); FinancialRecordDetails(record: r, embedded: true) }
                }
            }
        }
    }
    @ViewBuilder private func subscriptions(_ core: FamilyCore, space: UUID) -> some View {
        LifeSection(title: "订阅成本", icon: "arrow.triangle.2.circlepath") {
            switch Result(catching: { try core.subscriptionCosts(spaceID: space, year: year, month: selectedMonth) }) {
            case .failure(let e): InlineIssue(message: e.localizedDescription)
            case .success(let costs):
                Text("当前启用 \(costs.activeCount) 项 · 暂停 \(costs.pausedCount) 项")
                Text("预计月／年成本按当前价格折算（日／周按每年 365 天），不是扣款日历；实际净支出取所选期间关联的已确认账单。").font(.caption).foregroundStyle(.secondary)
                if costs.unresolvedCount > 0 { Text("\(costs.unresolvedCount) 条待核对，汇总不完整。").foregroundStyle(.orange) }
                ForEach(costs.totals, id: \.currency) { g in
                    FinancialValueRow("预计每月", value: Money(minor: g.monthly, currency: g.currency).formatted)
                    FinancialValueRow("预计每年", value: Money(minor: g.annual, currency: g.currency).formatted)
                    FinancialValueRow("期间实际净支出", value: Money(minor: g.actualPaid, currency: g.currency).formatted)
                    if g.unknownPriceCount > 0 { Text("另有 \(g.unknownPriceCount) 项价格未定，未计入预计金额。").foregroundStyle(.orange) }
                }
            }
        }
    }
}
struct StatementSummary: View {
    let value: PeriodStatement
    var body: some View {
        let g = value
        VStack(alignment: .leading, spacing: 8) {
            Text(g.currency.rawValue).font(.headline)
            switch Result(catching: { try (g.income, g.netExpense, g.surplus) }) {
            case .failure(let e): Text(e.localizedDescription)
            case .success(let amounts):
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        metric("收入", amount: amounts.0)
                        metric("净支出", amount: amounts.1)
                        metric("结余", amount: amounts.2)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        metric("收入", amount: amounts.0)
                        metric("净支出", amount: amounts.1)
                        metric("结余", amount: amounts.2)
                    }
                }.padding(.vertical, 12)
                Divider()
            }
            FinancialValueRow("月度税前收入", value: money(g.gross)); FinancialValueRow("已记录税额", value: money(g.knownTax))
            if g.unknownTaxCount > 0 { Text("\(g.unknownTaxCount) 条收入未记录税额。").font(.caption).foregroundStyle(.orange) }
            ForEach(g.categories.keys.sorted(), id: \.self) { key in FinancialValueRow("分类 · \(key)", value: money(g.categories[key] ?? 0)) }
            ForEach(g.consumption.keys.sorted(), id: \.self) { key in FinancialValueRow("归属 · \(key)", value: money(g.consumption[key] ?? 0)) }
        }
    }
    private func metric(_ title: String, amount: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(money(amount)).font(.title2.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func money(_ value: Int64) -> String { Money(minor: value, currency: self.value.currency).formatted }
}
struct AnnualTrend: View {
    let core: FamilyCore
    let space: UUID
    let year: Int
    struct Point: Identifiable { var id: String { "annual-\(currency.rawValue)-\(month)" }; let month: Int; let currency: Currency; let income: Int64; let expense: Int64; let surplus: Int64 }
    private func points() throws -> [Point] {
        let recorded = try (1...12).flatMap { month in try core.financialReport(spaceID: space, year: year, month: month).totals.map { g in try Point(month: month, currency: g.currency, income: g.income, expense: g.netExpense, surplus: g.surplus) } }
        return Set(recorded.map(\.currency)).flatMap { currency in (1...12).map { month in recorded.first { $0.currency == currency && $0.month == month } ?? Point(month: month, currency: currency, income: 0, expense: 0, surplus: 0) } }
    }
    var body: some View {
        LifeSection(title: "全年收支趋势", icon: "chart.xyaxis.line") {
            switch Result(catching: points) {
            case .failure(let e): InlineIssue(message: e.localizedDescription)
            case .success(let points):
                ForEach(Currency.allCases, id: \.self) { currency in
                    let series = points.filter { $0.currency == currency }
                    if !series.isEmpty {
                        Text(currency.rawValue).font(.headline)
                        Chart(series) { point in
                            LineMark(x: .value("月份", point.month), y: .value("收入", Double(point.income) / Double(currency.factor))).foregroundStyle(by: .value("类别", "收入"))
                            LineMark(x: .value("月份", point.month), y: .value("净支出", Double(point.expense) / Double(currency.factor))).foregroundStyle(by: .value("类别", "净支出"))
                        }.frame(height: 180).chartXScale(domain: 1...12)
                        ForEach(series) { p in Text("\(p.month) 月 · 结余 \(Money(minor: p.surplus, currency: currency).formatted)").font(.caption) }
                    }
                }
            }
        }
    }
}

struct AssetHistoryTrend: View {
    let records: [Record]
    let year: Int
    struct Point: Identifiable { var id: String { "asset-trend-\(recordID.uuidString)" }; let recordID: UUID; let day: LocalDay; let currency: Currency; let net: Int64 }
    private func history() throws -> (points: [Point], excluded: Int) {
        let candidates = records.filter { $0.body.kind == .assetSnapshot && !$0.deleted && $0.heads.contains { $0.body.date?.year == year && $0.body.status == .active } }
        var points: [Point] = [], excluded = 0
        for currency in Currency.allCases {
            let days = Set(candidates.flatMap { $0.heads.compactMap { $0.body.assetPosition?.currency == currency && $0.body.date?.year == year && $0.body.status == .active ? $0.body.date : nil } })
            for day in days {
                let matches = candidates.filter { $0.heads.contains { $0.body.date == day && $0.body.assetPosition?.currency == currency && $0.body.status == .active } }
                guard matches.count == 1, let r = matches.first, !r.conflicted, let asset = r.body.assetPosition else { excluded += 1; continue }
                points.append(Point(recordID: r.id, day: day, currency: currency, net: try asset.net()))
            }
        }
        return (points.sorted { $0.day < $1.day }, excluded)
    }
    var body: some View {
        LifeSection(title: "净资产走势 · 实际快照", icon: "chart.xyaxis.line") {
            switch Result(catching: history) {
            case .failure(let e): InlineIssue(message: e.localizedDescription)
            case .success(let result):
                if result.points.isEmpty { Text("本年暂无可比较的完整快照。") }
                if result.excluded > 0 { Text("\(result.excluded) 条重复或冲突快照未绘图，请在历史中核对。").foregroundStyle(.orange) }
                ForEach(Currency.allCases, id: \.self) { currency in
                    let points = result.points.filter { $0.currency == currency }
                    if !points.isEmpty {
                        Text(currency.rawValue).font(.headline)
                        Chart(points) { p in PointMark(x: .value("日期", p.day.date()), y: .value("净资产", Double(p.net) / Double(currency.factor))) }.frame(height: 160)
                        ForEach(points) { p in Text("\(p.day.description) · \(Money(minor: p.net, currency: currency).formatted)").font(.caption) }
                    }
                }
            }
        }
    }
}

private struct FinancialValueRow: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Text(value).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
