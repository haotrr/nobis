import SwiftUI
import FamilyDomain
import FamilyCore

struct ProjectBudgetEditor: View {
    @Binding var value: RecordBody
    let projects: [Record]
    let currentID: UUID?
    @Binding var limit: String
    @Binding var currency: Currency
    @Binding var itemName: String
    @Binding var itemAmount: String
    @State private var message: String?
    var body: some View {
        LifeFormSection(title: "项目预算", icon: "chart.bar") {
            LifePicker("父项目", selection: $value.parentProjectID) {
                Text("顶层项目").tag(Optional<UUID>.none)
                ForEach(projects.filter { $0.id != currentID && $0.body.parentProjectID == nil }) { Text($0.body.title).tag(Optional($0.id)) }
            }
            LifeTextField("预算金额", text: $limit)
            LifePicker("预算币种", selection: $currency) { ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.disabled(!(value.budget?.items.isEmpty ?? true))
            if let budget = value.budget {
                Text("计划项随项目一起保存").font(.caption).foregroundStyle(.secondary)
                ForEach(budget.items) { item in HStack { VStack(alignment: .leading) { Text(item.name); Text(item.amount.formatted).font(.caption) }; Spacer(); Button("移除") { value.budget?.items.removeAll { $0.id == item.id } } } }
            }
            if value.budget != nil {
                LifeTextField("计划项名称", text: $itemName)
                LifeTextField("计划金额", text: $itemAmount)
                Button("添加计划项") {
                    do {
                        let money = try Money.parse(itemAmount, currency: currency)
                        guard money.minor > 0, !itemName.trimmingCharacters(in: .whitespaces).isEmpty else { throw NobisError.validation("请填写名称和正数金额。") }
                        value.budget?.items.append(BudgetItem(name: itemName, amount: money)); itemName = ""; itemAmount = ""; message = nil
                    } catch { message = error.localizedDescription }
                }
            }
            if let message { InlineIssue(message: message) }
        }
    }
}
struct ProjectBudgetSummary: View {
    let model: AppModel
    let record: Record
    var allowsManagement = true
    @State private var target: UUID?
    @State private var confirming = false
    private func remaining(_ budget: Money, actual: Int64) -> String {
        let (difference, overflow) = budget.minor.subtractingReportingOverflow(actual)
        guard !overflow, difference != Int64.min else { return "金额超出范围，请核对" }
        return Money(minor: abs(difference), currency: budget.currency).formatted
    }
    var body: some View {
        LifeSection(title: "预算与实际 · 包含子项目", icon: "chart.bar") {
            if let core = model.core {
                switch Result(catching: { try core.projectSpending(record.id, spaceID: record.latest.spaceID) }) {
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.orange)
                case .success(let summary):
                    if let budget = record.body.budget {
                        LabeledContent("预算", value: budget.limit.formatted)
                        let actual = summary.actual[budget.limit.currency] ?? 0
                        LabeledContent(actual > budget.limit.minor ? "超出预算" : "剩余预算", value: remaining(budget.limit, actual: actual))
                        ForEach(budget.items) { item in VStack(alignment: .leading) { Text(item.name); Text("计划 \(item.amount.formatted) · 实际 \(Money(minor: summary.itemActual[item.id] ?? 0, currency: item.amount.currency).formatted)").font(.caption) } }
                    }
                    if record.body.budget == nil && summary.actual.isEmpty { Text("尚未设置预算，也没有实际支出").foregroundStyle(.secondary) }
                    ForEach(Currency.allCases, id: \.self) { currency in if let amount = summary.actual[currency] { LabeledContent("实际净支出", value: Money(minor: amount, currency: currency).formatted) } }
                    if summary.unresolvedCount > 0 { Text("\(summary.unresolvedCount) 笔草稿或冲突未计入，合计尚不完整。").foregroundStyle(.orange) }
                }
            }
            if allowsManagement {
            LifePicker("合并到项目", selection: $target) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.activeRecords.filter { $0.latest.spaceID == record.latest.spaceID && $0.body.kind == .project && $0.id != record.id && $0.body.status != .archived }) { Text($0.body.title).tag(Optional($0.id)) }
            }
            Button("预览合并说明") { confirming = true }.disabled(target == nil)
            }
        }.confirmationDialog("合并关联记录及计划项，预算相加，原项目归档。历史修订保留；有子项目时需先处理子项目。", isPresented: $confirming) {
            Button("确认合并") { model.perform { guard let target, let core = model.core else { throw NobisError.forbidden }; try core.mergeProject(record.id, into: target, spaceID: record.latest.spaceID); model.refresh() } }
        }
    }
}
