import SwiftUI
import Charts
import FamilyCore
import FamilyDomain

struct ChartSelectionOverlay<Value: Plottable>: View {
    let proxy: ChartProxy
    var horizontal = false
    @Binding var selection: Value?
    var body: some View {
        GeometryReader { geometry in
            Color.clear.contentShape(Rectangle()).onTapGesture { location in
                guard let plot = proxy.plotFrame else { return }
                let frame = geometry[plot]
                guard frame.contains(location) else { selection = nil; return }
                selection = horizontal ? proxy.value(atX: location.x - frame.minX, as: Value.self) : proxy.value(atY: location.y - frame.minY, as: Value.self)
            }
        }.accessibilityHidden(true)
    }
}

/// Keep each datum separate even when the platform would merge adjacent Text views.
struct ChartAccessibleValue: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).lineLimit(1)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

struct AmountBar: Identifiable {
    let id: String
    let label: String
    let amount: Int64
}
/// Tap selection plus an exact-value list; vertical drags remain available to the page.
struct AmountBars: View {
    let rows: [AmountBar]
    let currency: Currency
    @State private var selected: String?
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 38
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(rows) { row in
                BarMark(x: .value("金额", Double(row.amount) / Double(currency.factor)), y: .value("项目", row.id))
                    .foregroundStyle(row.amount < 0 ? Color.orange : Color.accentColor)
                    .accessibilityLabel(row.label)
                    .accessibilityValue(Money(minor: row.amount, currency: currency).formatted)
            }
            .chartYAxis { AxisMarks { axis in AxisValueLabel { if let id = axis.as(String.self), let row = rows.first(where: { $0.id == id }) { Text(row.label) } } } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }

            .chartOverlay { ChartSelectionOverlay(proxy: $0, selection: $selected) }
            .frame(height: CGFloat(max(rows.count, 1)) * rowHeight + 40)
            if let row = rows.first(where: { $0.id == selected }) {
                Text("\(row.label) · \(Money(minor: row.amount, currency: currency).formatted)").font(.callout).monospacedDigit()
            }
            Text("点选图中条目查看金额；完整数字与明细入口见下方。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CategorySpendingChart: View {
    let model: AppModel
    let value: PeriodStatement
    let period: LedgerPeriod
    @State private var expanded = false
    private var rows: [AmountBar] {
        value.categories.map { AmountBar(id: $0.key, label: $0.key.isEmpty ? "未分类" : $0.key, amount: $0.value) }
            .sorted { $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount }
    }
    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("支出分类 · \(value.currency.rawValue)").font(.headline)
                AmountBars(rows: expanded ? rows : Array(rows.prefix(6)), currency: value.currency)
                Text("净支出已扣除退款；负值表示本期退款多于支出。").font(.caption).foregroundStyle(.secondary)
                ForEach(expanded ? rows : Array(rows.prefix(6))) { row in
                    NavigationLink {
                        LedgerWorkspace(model: model, period: period, category: row.id, currency: value.currency)
                    } label: { FinancialValueRow(row.label, value: Money(minor: row.amount, currency: value.currency).formatted) }
                }
                if rows.count > 6 { Button(expanded ? "收起分类" : "查看全部 \(rows.count) 类") { expanded.toggle() } }
            }.padding(.vertical, 12)
        }
    }
}

struct AnnualTrend: View {
    let model: AppModel
    let core: FamilyCore
    let space: UUID
    let year: Int
    var currency: Currency? = nil
    private var recordedCurrencies: [Currency] { Array(Set(((try? core.records(spaceID: space)) ?? []).compactMap { $0.body.money?.currency ?? $0.body.incomeMonth?.net.currency })).sorted { $0.rawValue < $1.rawValue } }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 210
    @State private var selection: String?
    var body: some View {
        LifeSection(title: "月度收支 · 已记录", icon: "chart.bar") {
            Text("未来月份不绘制；无记录不等于零收支。月内数据截至今天，仍可能未记全。").font(.caption).foregroundStyle(.secondary)
            ForEach(recordedCurrencies.filter { currency == nil || $0 == currency }, id: \.self) { currency in
                switch Result(catching: { try FinancialChartData.months(core: core, spaceID: space, year: year, currency: currency, today: LocalDay(date: Date())) }) {
                case .failure(let error): InlineIssue(message: error.localizedDescription)
                case .success(let points):
                    if !points.isEmpty {
                        if !points.contains(where: { $0.income != nil || $0.expense != nil }) { Text("没有已记录的月度收支；非月度收入见下方年报核对。").font(.caption) }
                        Text(currency.rawValue).font(.headline)
                        Chart(points) { point in
                            if let income = point.income {
                                BarMark(x: .value("月份", String(point.month)), y: .value("金额", Double(income) / Double(currency.factor)), stacking: .unstacked)
                                    .foregroundStyle(by: .value("类别", "收入")).position(by: .value("类别", "收入"), axis: .horizontal)
                            }
                            if let expense = point.expense {
                                BarMark(x: .value("月份", String(point.month)), y: .value("金额", Double(expense) / Double(currency.factor)), stacking: .unstacked)
                                    .foregroundStyle(by: .value("类别", "净支出")).position(by: .value("类别", "净支出"), axis: .horizontal)
                            }
                        }.frame(height: chartHeight).chartXScale(domain: points.map { String($0.month) })
                            .chartXAxis { AxisMarks(values: dynamicTypeSize.isAccessibilitySize ? Array(Set(["1", String(points.last?.month ?? 1)])).sorted { Int($0)! < Int($1)! } : points.map { String($0.month) }) { value in AxisValueLabel { if let month = value.as(String.self) { Text("\(month)月") } } } }
                            .chartYAxis { AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 4)) }
                            .accessibilityRepresentation {
                                VStack {
                                    ForEach(points) { point in
                                        ChartAccessibleValue("\(point.month) 月，收入 \(point.income.map { money($0, currency) } ?? "无记录")，净支出 \(point.expense.map { money($0, currency) } ?? "无记录")")
                                    }
                                }
                            }

                            .chartOverlay { ChartSelectionOverlay(proxy: $0, horizontal: true, selection: $selection) }
                        if let point = points.first(where: { String($0.month) == selection }) { monthRow(point, currency: currency) }
                        if case .success(let report) = Result(catching: { try core.financialReport(spaceID: space, year: year) }), let total = report.totals.first(where: { $0.currency == currency }) {
                            Text("年报核对：月度到账 \(money(total.monthlyNet, currency)) ＋ 非月度 \(money(total.nonMonthlyNet, currency)) ＋ 流水收入 \(money(total.cashIncome, currency)) ＝ \((try? total.income).map { money($0, currency) } ?? "超出范围")").font(.caption)
                            Text("非月度收入保留原年份，不进入月度图；年报还可能含已记入的未来日期记录。").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("逐月金额与流水明细") { ForEach(points) { monthRow($0, currency: currency) } }
                    }
                }
            }
        }
    }
    private func money(_ amount: Int64, _ currency: Currency) -> String { Money(minor: amount, currency: currency).formatted }
    private func monthRow(_ point: FinancialMonthPoint, currency: Currency) -> some View {
        NavigationLink { FinancialDashboard(model: model, period: LedgerPeriod(year: year, month: point.month), currency: currency) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(point.month) 月 · 查看报告与明细")
                Text("收入 \(point.income.map { money($0, currency) } ?? "无记录") · 净支出 \(point.expense.map { money($0, currency) } ?? "无记录")").font(.caption)
                if point.unresolved > 0 { Text("\(point.unresolved) 条待核对，未计入").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct YearComparisonChart: View {
    let model: AppModel
    let core: FamilyCore
    let space: UUID
    var currency: Currency? = nil
    private var recordedCurrencies: [Currency] { Array(Set(((try? core.records(spaceID: space)) ?? []).compactMap { $0.body.money?.currency ?? $0.body.incomeMonth?.net.currency })).sorted { $0.rawValue < $1.rawValue } }
    @State private var expanded = false
    struct Row: Identifiable {
        var id: Int { year }
        let year: Int
        let income: Int64?
        let expense: Int64?
        let incomeMonths: Int
        let expenseMonths: Int
        let unresolved: Int
    }
    private func rows(_ currency: Currency) throws -> [Row] {
        let today = LocalDay(date: Date())
        let records = try core.records(spaceID: space)
        let years = Set(records.flatMap { $0.heads.compactMap { $0.body.incomeMonth?.year ?? ($0.body.kind == .transaction ? $0.body.date?.year : nil) } }).filter { $0 <= today.year }.sorted()
        return try years.map { year in
            let yearly = try FamilyCore.financialReport(records: records, year: year)
            let annual = yearly.totals.first { $0.currency == currency }
            let cutoff = try (try? LocalDay(year, today.month, today.day)) ?? LocalDay(year, today.month, 28)
            let ytd = try FamilyCore.financialReport(records: records, year: year, through: cutoff)
            let expense = ytd.totals.first { $0.currency == currency }
            let months = try FinancialChartData.months(records: records, year: year, currency: currency, today: cutoff)
            let hasIncome = records.contains { r in annual?.sourceIDs.contains(r.id) == true && (r.body.kind == .monthlyIncome || r.body.transactionKind == .income) }
            let hasExpense = records.contains { r in expense?.sourceIDs.contains(r.id) == true && r.body.kind == .transaction && [.expense, .refund].contains(r.body.transactionKind) }
            return Row(year: year, income: hasIncome ? try annual?.income : nil, expense: hasExpense ? try expense?.netExpense : nil, incomeMonths: Set(records.filter { annual?.sourceIDs.contains($0.id) == true && (($0.body.incomeMonth?.month ?? $0.body.date?.month ?? 0) > 0) && ($0.body.kind == .monthlyIncome || $0.body.transactionKind == .income) }.compactMap { $0.body.incomeMonth?.month ?? $0.body.date?.month }).count, expenseMonths: months.filter { $0.expense != nil }.count, unresolved: yearly.unresolvedCount + ytd.unresolvedCount)
        }
    }
    var body: some View {
        LifeSection(title: "跨年对比", icon: "chart.bar.xaxis") {
            DisclosureGroup("查看年度收入与支出同期对比", isExpanded: $expanded) {
                if expanded {
                    Text("收入为各年已记录全年金额（含非月度）；当前年尚未结束。支出统一截至各年的今天同月同日。仅比较已有记录，不推断缺失月份，也不计算可能误导的同比百分比。").font(.caption).foregroundStyle(.secondary)
                    ForEach(recordedCurrencies.filter { currency == nil || $0 == currency }, id: \.self) { currency in
                        switch Result(catching: { try rows(currency) }) {
                        case .failure(let error): InlineIssue(message: error.localizedDescription)
                        case .success(let rows):
                            if rows.contains(where: { $0.income != nil || $0.expense != nil }) {
                                Text("年度收入 · \(currency.rawValue)").font(.headline)
                                AmountBars(rows: rows.compactMap { row in row.income.map { AmountBar(id: String(row.year), label: String(row.year), amount: $0) } }, currency: currency)
                                Text("同期净支出 · \(currency.rawValue)").font(.headline)
                                AmountBars(rows: rows.compactMap { row in row.expense.map { AmountBar(id: String(row.year), label: String(row.year), amount: $0) } }, currency: currency)
                                ForEach(rows) { row in
                                    NavigationLink { FinancialDashboard(model: model, period: LedgerPeriod(year: row.year), currency: currency) } label: {
                                        VStack(alignment: .leading) {
                                            Text("\(String(row.year)) 年 · 查看年报")
                                            Text("收入 \(row.income.map { Money(minor: $0, currency: currency).formatted } ?? "无记录") · 同期净支出 \(row.expense.map { Money(minor: $0, currency: currency).formatted } ?? "无记录")").font(.caption)
                                            Text("有月度收入记录 \(row.incomeMonths) 个月 · 有同期支出记录 \(row.expenseMonths) 个月\(row.unresolved > 0 ? " · 存在未计入记录" : "")").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AssetHistoryTrend: View {
    let model: AppModel
    let records: [Record]
    let year: Int
    let month: Int?
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 190
    @State private var selectedDay: Date?
    @State private var firstID: UUID?
    @State private var lastID: UUID?
    private var cutoff: LocalDay {
        let end = (try? LedgerPeriod(year: year, month: month).bounds().through) ?? LocalDay(date: Date())
        return min(end, LocalDay(date: Date()))
    }
    var body: some View {
        let all = FinancialChartData.snapshots(records, through: cutoff)
        LifeSection(title: "资产变化 · 实际快照", icon: "chart.xyaxis.line") {
            Text("截至 \(cutoff.description)；仅绘制实际快照，不补齐或平滑缺失日期。各来源、持有范围与币种分别比较；重复或冲突日期不参与比较。").font(.caption).foregroundStyle(.secondary)
            if records.contains(where: { $0.conflicted }) { Text("存在冲突快照，相关日期不参与比较。").font(.caption).foregroundStyle(.orange) }
            if all.isEmpty { Text("截止日期前没有可比较的完整快照。") }
            ForEach(Currency.allCases, id: \.self) { currency in
                let available = all.filter { $0.body.assetPosition?.currency == currency }
                let points = available.filter { $0.body.date?.year == year }
                if !available.isEmpty {
                    Text(currency.rawValue).font(.headline)
                    if !points.isEmpty {
                        Chart(points) { record in
                            if let day = record.body.date, let net = try? record.body.assetPosition?.net() {
                                PointMark(x: .value("日期", day.date()), y: .value("净资产", Double(net) / Double(currency.factor)))
                                    .accessibilityLabel(day.description).accessibilityValue(Money(minor: net, currency: currency).formatted)
                            }
                        }.frame(height: chartHeight).chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 2)) }
                            .chartOverlay { ChartSelectionOverlay(proxy: $0, horizontal: true, selection: $selectedDay) }
                        if let selectedDay, let nearest = points.min(by: { abs(($0.body.date?.date() ?? .distantPast).timeIntervalSince(selectedDay)) < abs(($1.body.date?.date() ?? .distantPast).timeIntervalSince(selectedDay)) }) { snapshotLink(nearest) }
                    } else { Text("本年暂无快照；可比较截止日前的历史记录。").font(.caption).foregroundStyle(.secondary) }
                    comparison(available, currency: currency)
                    DisclosureGroup("快照金额与明细") { ForEach(available.reversed()) { snapshotLink($0) } }
                }
            }
        }
    }
    private func snapshotLink(_ record: Record) -> some View {
        NavigationLink { RecordDetail(model: model, recordID: record.id) } label: {
            Text("\(record.body.date?.description ?? "") · 净资产 \((try? record.body.assetPosition?.net()).map { Money(minor: $0, currency: record.body.assetPosition!.currency).formatted } ?? "无法计算")")
        }
    }
    @ViewBuilder private func comparison(_ records: [Record], currency: Currency) -> some View {
        let last = records.first { $0.id == lastID } ?? records.last!
        let first = records.first { $0.id == firstID } ?? (records.count > 1 ? records[records.count - 2] : records[0])
        if let position = last.body.assetPosition {
            DisclosureGroup("资产与负债结构 · \(last.body.date?.description ?? "")") {
                AmountBars(rows: AssetComponent.allCases.filter { !($0.liability) }.map { AmountBar(id: $0.rawValue, label: $0.title, amount: position.amounts[$0] ?? 0) }, currency: currency)
                Text("负债余额").font(.headline)
                AmountBars(rows: AssetComponent.allCases.filter(\.liability).map { AmountBar(id: $0.rawValue, label: $0.title, amount: position.amounts[$0] ?? 0) }, currency: currency)
                ForEach(AssetComponent.allCases, id: \.self) { component in FinancialValueRow(component.title, value: Money(minor: position.amounts[component] ?? 0, currency: currency).formatted) }
                snapshotLink(last)
            }
        }
        if records.count > 1 {
            DisclosureGroup("比较两次快照") {
                LifePicker("起点快照", selection: Binding(get: { first.id }, set: { firstID = $0 }), selectedTitle: first.body.date?.description) { ForEach(records) { Text($0.body.date?.description ?? "").tag($0.id) } }
                LifePicker("终点快照", selection: Binding(get: { last.id }, set: { lastID = $0 }), selectedTitle: last.body.date?.description) { ForEach(records) { Text($0.body.date?.description ?? "").tag($0.id) } }
                if let start = first.body.date, let end = last.body.date, start < end,
                   let before = first.body.assetPosition, let after = last.body.assetPosition {
                    switch Result(catching: { try FinancialChartData.changes(from: before, to: after) }) {
                    case .failure(let error): InlineIssue(message: error.localizedDescription)
                    case .success(let changes):
                        Text("\(start.description) → \(end.description) · 间隔 \(Calendar.current.dateComponents([.day], from: start.date(), to: end.date()).day ?? 0) 天")
                        Text("分项余额增减；负债增加会降低净资产。变化可能来自收入、支出、转移或估值，不等于投资收益。").font(.caption).foregroundStyle(.secondary)
                        AmountBars(rows: AssetComponent.allCases.map { AmountBar(id: $0.rawValue, label: $0.title, amount: changes[$0] ?? 0) }, currency: currency)
                        ForEach(AssetComponent.allCases, id: \.self) { component in FinancialValueRow(component.title, value: Money(minor: changes[component] ?? 0, currency: currency).formatted) }
                        snapshotLink(first); snapshotLink(last)
                    }
                } else { Text("请选择早于终点的起点日期。").foregroundStyle(.secondary) }
            }
        } else { Text("仅有一份快照，暂不能比较变化。").font(.caption).foregroundStyle(.secondary) }
    }
}
