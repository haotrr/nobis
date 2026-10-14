import SwiftUI
import FamilyDomain
import FamilyCore

struct RecordEditor: View {
    let model: AppModel
    let kind: RecordKind
    let existing: Record?
    let onFinish: (() -> Void)?
    @State private var spaceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var bodyValue: RecordBody
    @State private var amount: String
    @State private var currency: Currency
    @State private var day: Date
    @State private var endDay: Date
    @State private var hasDate: Bool
    @State private var hasEnd = false
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var splitMode = "平均分摊"
    @State private var fixedSplits: [UUID: String] = [:]
    @State private var validation: String?
    @State private var initialDraft: Draft?
    @State private var confirmingDiscard = false
    @State private var budgetLimit: String
    @State private var budgetCurrency: Currency
    @State private var budgetItemName = ""
    @State private var budgetItemAmount = ""
    private var hasLocalChanges: Bool { initialDraft.map { $0 != draft } ?? false }
    private struct Draft: Equatable {
        let spaceID: UUID; let body: RecordBody
        let amount: String; let currency: Currency
        let day: Date; let endDay: Date; let hasDate: Bool; let hasEnd: Bool
        let startAt: Date; let endAt: Date
        let splitMode: String; let fixedSplits: [UUID: String]
        let budgetLimit: String; let budgetCurrency: Currency; let budgetItemName: String; let budgetItemAmount: String
    }
    private var draft: Draft { Draft(spaceID: spaceID, body: bodyValue, amount: amount, currency: currency, day: day, endDay: endDay, hasDate: hasDate, hasEnd: hasEnd, startAt: startAt, endAt: endAt, splitMode: splitMode, fixedSplits: fixedSplits, budgetLimit: budgetLimit, budgetCurrency: budgetCurrency, budgetItemName: budgetItemName, budgetItemAmount: budgetItemAmount) }

    init(model: AppModel, kind: RecordKind, existing: Record? = nil, project: Record? = nil, onFinish: (() -> Void)? = nil) {
        self.model = model; self.kind = kind; self.existing = existing; self.onFinish = onFinish
        let initialSpace = existing?.latest.spaceID ?? project?.latest.spaceID ?? model.selectedSpaceID ?? UUID()
        _spaceID = State(initialValue: initialSpace)
        var value = existing?.body ?? RecordBody(kind: kind, title: "", status: kind == .transaction ? .draft : .active)
        if let project { if kind == .project { value.parentProjectID = project.id } else { value.projectIDs = [project.id] } }
        if existing == nil && kind == .transaction { value.finance = FinanceDetails() }
        if value.memberID == nil && (kind != .transaction || value.accountingMode == .sharedSettlement) { value.memberID = model.core?.session.actorID(in: initialSpace) ?? model.selectedSpace?.members.first?.id }
        _bodyValue = State(initialValue: value)
        _budgetLimit = State(initialValue: value.budget.map { (Decimal($0.limit.minor) / Decimal($0.limit.currency.factor)).description } ?? "")
        _budgetCurrency = State(initialValue: value.budget?.limit.currency ?? .CNY)
        _currency = State(initialValue: value.money?.currency ?? value.unknownPriceCurrency ?? .CNY)
        _amount = State(initialValue: value.money.map { (Decimal($0.minor) / Decimal($0.currency.factor)).description } ?? "")
        _day = State(initialValue: value.date?.date() ?? Date())
        _endDay = State(initialValue: value.endDate?.date() ?? Date())
        _hasEnd = State(initialValue: value.endDate != nil)
        _hasDate = State(initialValue: value.date != nil || [.subscription, .transaction, .event].contains(kind))
        _startAt = State(initialValue: value.startAt ?? Date())
        _endAt = State(initialValue: value.endAt ?? Date().addingTimeInterval(3600))
        _splitMode = State(initialValue: existing == nil ? "平均分摊" : "固定金额")
        _fixedSplits = State(initialValue: Dictionary(uniqueKeysWithValues: value.splits.map { ($0.memberID, (Decimal($0.minor) / Decimal(value.money?.currency.factor ?? 100)).description) }))
    }
    private var space: Space? { model.spaces.first { $0.id == spaceID } }
    private var projects: [Record] { model.activeRecords.filter { $0.latest.spaceID == spaceID && $0.body.kind == .project && $0.body.status != .archived } }
    private var statuses: [RecordStatus] {
        switch kind { case .comment: [.active, .completed]; case .document, .category, .monthlyIncome, .assetSnapshot: [.active, .archived]; case .project: [.draft, .active, .completed, .archived]; case .task: [.active, .completed, .cancelled]; case .subscription: [.active, .paused, .cancelled, .archived]; case .event: [.active, .cancelled]; case .transaction: existing?.body.status == .confirmed ? [.confirmed, .voided] : [.draft, .confirmed, .voided] }
    }
    @Environment(\.colorScheme) private var colorScheme
    private var lifeTint: Color { NobisTheme.accent }
    var body: some View {
        VStack(spacing: 0) {
            LifeDetail {
                LifeFormSection(title: "基本信息", icon: kind.icon) {
                    RecordVisibilityField(model: model,
                        spaceID: Binding(get: { Optional(spaceID) }, set: { if let value = $0 { spaceID = value } }),
                        editable: existing == nil,
                        inherited: !bodyValue.projectIDs.isEmpty || bodyValue.parentProjectID != nil || bodyValue.refundOfID != nil || bodyValue.subscriptionID != nil)
                    LifeTextField("\(kind.title)名称", text: $bodyValue.title)
                    LifePicker("状态", selection: $bodyValue.status) { ForEach(statuses, id: \.self) { Text($0.title).tag($0) } }
                    if kind == .task || kind == .subscription || kind == .transaction {
                        LifePicker(kind == .task ? "负责人" : "付款 / 收款人", selection: $bodyValue.memberID) { Text("未分配").tag(Optional<UUID>.none); ForEach(space?.members ?? []) { Text($0.name).tag(Optional($0.id)) } }
                    }
                }
                if kind == .transaction || kind == .subscription { moneySection }
                if kind == .project {
                    ProjectBudgetEditor(value: $bodyValue, projects: projects, currentID: existing?.id, limit: $budgetLimit, currency: $budgetCurrency, itemName: $budgetItemName, itemAmount: $budgetItemAmount)
                }
                if kind == .event {
                    LifeFormSection(title: "时间与地点", icon: "calendar") {
                        Toggle("全天", isOn: $bodyValue.allDay)
                        if bodyValue.allDay { DatePicker("日期", selection: $day, displayedComponents: .date); DatePicker("结束日期", selection: $endDay, displayedComponents: .date) }
                        else { DatePicker("开始", selection: $startAt); DatePicker("结束", selection: $endAt) }
                        LifeTextField("时区", text: $bodyValue.timeZone)
                        LifeTextField("地点（可选）", text: $bodyValue.location)
                    }
                } else if hasDate || kind == .task || kind == .project || kind == .subscription {
                    LifeFormSection(title: kind == .subscription ? "续费" : "日期", icon: "calendar") {
                        if kind == .task || kind == .project { Toggle("设置日期", isOn: $hasDate) }
                        if hasDate { DatePicker(kind == .subscription ? "下次计费日" : "发生 / 截止日期", selection: $day, displayedComponents: .date) }
                        if kind == .project { Toggle("设置结束日期", isOn: $hasEnd); if hasEnd { DatePicker("结束日期", selection: $endDay, displayedComponents: .date) } }
                        if kind == .subscription {
                            LabeledContent("间隔") { LifeIntegerControl(value: $bodyValue.cycleCount, range: 1...120, suffix: bodyValue.cycleUnit.title, label: "续费间隔") }
                            LifePicker("周期", selection: $bodyValue.cycleUnit) { ForEach(CycleUnit.allCases, id: \.self) { Text($0.title).tag($0) } }
                            Toggle("提前 7 天提醒", isOn: reminder(7)); Toggle("提前 1 天提醒", isOn: reminder(1))
                            Text("保持原始锚点日：1 月 31 日 → 2 月末 → 3 月 31 日。").font(.caption).foregroundStyle(.secondary)
                            if bodyValue.status == .cancelled { Text("请确认已经在供应商处完成取消；Nobis 不会代为取消服务。").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                if kind != .project && !projects.isEmpty {
                    LifeFormSection(title: "所属项目（可选）", icon: "folder") {
                        if bodyValue.projectIDs.count > 1 {
                            Text("旧记录关联了多个项目，当前保留原关联；请核对后选择一个所属项目。")
                        }
                        LifePicker("项目", selection: Binding(get: { bodyValue.projectIDs.count == 1 ? bodyValue.projectIDs.first : nil }, set: { bodyValue.projectIDs = $0.map { [$0] } ?? []; bodyValue.finance?.planItemID = nil })) {
                            Text(bodyValue.projectIDs.count > 1 ? "保留原多项目关联" : "无").tag(Optional<UUID>.none)
                            ForEach(projects) { Text($0.body.title).tag(Optional($0.id)) }
                        }
                    }
                }

                LifeFormSection(title: "关联内容", icon: "link") { ReferenceFields(model: model, spaceID: spaceID, recordID: existing?.id, ids: $bodyValue.referenceIDs) }
                LifeFormSection(title: bodyValue.status == .voided ? "作废原因（必填）" : "备注", icon: "text.alignleft") { LifeTextField("补充说明", text: $bodyValue.notes, axis: .vertical).lineLimit(3...8) }
                if let validation { InlineIssue(message: validation) }
                if existing?.body.status == .confirmed && kind == .transaction { Text("已确认账单可调整分类、项目、归属和备注；修改金额、日期、付款人或分摊须先作废。").font(.caption).foregroundStyle(.secondary) }
            }

            .modifier(LifeEditorChrome(
                title: existing != nil ? "编辑" + kind.title : kind == .transaction ? "记一笔" : kind == .event ? "添加安排" : "新建" + kind.title,
                icon: kind.icon, embedded: onFinish != nil, cancel: cancel, save: save,
                hasChanges: onFinish != nil ? model.recordPanel.hasChanges : existing == nil || hasLocalChanges,
                saveTitle: existing == nil ? "保存" : "保存修改"))
        }
        .tint(lifeTint)
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
        .onChange(of: spaceID) { _, _ in
            bodyValue.referenceIDs = nil
            bodyValue.memberID = nil; bodyValue.splits = []; fixedSplits = [:]
            bodyValue.finance?.planItemID = nil
        }.editorDimensions(width: onFinish == nil ? 600 : 440, height: onFinish == nil ? 640 : 0)
    }
    private var moneySection: some View {
        LifeFormSection(title: kind == .subscription ? "预计费用" : "实际账单", icon: "creditcard") {
            LifeTextField(kind == .subscription ? "价格（留空表示待核实）" : "金额", text: $amount)
            LifePicker("币种", selection: $currency) { ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if kind == .transaction {
                LifePicker("类型", selection: $bodyValue.transactionKind) { ForEach(TransactionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                LifeTextField("分类", text: $bodyValue.category)
                Menu("选择已有分类") {
                    ForEach(Array(Set(model.activeRecords.filter { $0.latest.spaceID == spaceID && $0.body.kind == .category && $0.body.status == .active }.map { $0.body.title } + model.activeRecords.filter { $0.latest.spaceID == spaceID && $0.body.kind == .transaction }.map { $0.body.category })).sorted(), id: \.self) { name in Button(name) { bodyValue.category = name } }
                }
                LifeTextField("账户名称", text: $bodyValue.account)
                LifePicker("记账方式", selection: Binding(get: { bodyValue.accountingMode }, set: { mode in var f = bodyValue.finance ?? FinanceDetails(mode: mode); f.mode = mode; bodyValue.finance = f })) { ForEach(AccountingMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                if bodyValue.accountingMode == .ledgerOnly { Text("统计收入与支出，不产生成员之间的待收待付。付款人可留空。").font(.caption).foregroundStyle(.secondary) }
                if space?.kind == .family {
                    LifePicker("为谁消费", selection: Binding(get: { bodyValue.finance?.consumption ?? .unassigned }, set: { kind in var f = bodyValue.finance ?? FinanceDetails(mode: bodyValue.accountingMode); f.consumption = kind; if kind != .personal { f.consumer = "" }; bodyValue.finance = f })) { ForEach(ConsumptionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if bodyValue.finance?.consumption == .personal { LifeTextField("消费归属称呼", text: Binding(get: { bodyValue.finance?.consumer ?? "" }, set: { bodyValue.finance?.consumer = $0 })) }
                }
                LifePicker("预算计划项", selection: Binding(get: { bodyValue.finance?.planItemID }, set: { id in var f = bodyValue.finance ?? FinanceDetails(mode: bodyValue.accountingMode); f.planItemID = id; bodyValue.finance = f })) {
                    Text("无").tag(Optional<UUID>.none)
                    ForEach(projects.filter { bodyValue.projectIDs.contains($0.id) }.flatMap { $0.body.budget?.items ?? [] }) { item in Text(item.name).tag(Optional(item.id)) }
                }
                if bodyValue.transactionKind == .refund {
                    LifePicker("原支出", selection: $bodyValue.refundOfID) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(model.activeRecords.filter { $0.latest.spaceID == spaceID && $0.body.kind == .transaction && $0.body.transactionKind == .expense && $0.body.status == .confirmed && $0.body.money?.currency == currency && !$0.conflicted }) { Text($0.body.title).tag(Optional($0.id)) }
                    }
                }
                LifePicker("关联订阅（可选）", selection: $bodyValue.subscriptionID) {
                    Text("无").tag(Optional<UUID>.none)
                    ForEach(model.activeRecords.filter { $0.latest.spaceID == spaceID && $0.body.kind == .subscription }) { Text($0.body.title).tag(Optional($0.id)) }
                }
                if bodyValue.accountingMode == .sharedSettlement && bodyValue.transactionKind != .income {
                    if bodyValue.transactionKind != .settlement { LifePicker("分摊方式", selection: $splitMode) { Text("平均分摊").tag("平均分摊"); Text("固定金额").tag("固定金额") } }
                    if splitMode == "固定金额" || bodyValue.transactionKind == .settlement {
                        ForEach(space?.members ?? []) { member in LifeTextField("\(member.name)\(bodyValue.transactionKind == .settlement ? "收到" : "承担")的金额", text: Binding(get: { fixedSplits[member.id] ?? "" }, set: { fixedSplits[member.id] = $0 })) }
                    }
                    if let money = try? Money.parse(amount, currency: currency), let splits = try? computeSplits(money) {
                        ForEach(splits, id: \.memberID) { share in Text("\(space?.members.first { $0.id == share.memberID }?.name ?? "成员")：\(Money(minor: share.minor, currency: currency).formatted)").font(.caption) }
                    }
                    Text("平均分摊的最小单位余数按固定成员顺序分配；请核对后确认账单。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func reminder(_ days: Int) -> Binding<Bool> { Binding(get: { bodyValue.reminderDays.contains(days) }, set: { on in if on { bodyValue.reminderDays.append(days) } else { bodyValue.reminderDays.removeAll { $0 == days } } }) }
    private func computeSplits(_ money: Money) throws -> [ShareAmount] {
        if bodyValue.accountingMode == .ledgerOnly || bodyValue.transactionKind == .income { return [] }
        if splitMode == "平均分摊" && bodyValue.transactionKind != .settlement { return try money.split(members: (space?.members ?? []).map(\.id)) }
        return try (space?.members ?? []).compactMap { member in
            guard let text = fixedSplits[member.id], !text.isEmpty else { return nil }
            let minor = try Money.parse(text, currency: currency).minor
            return minor > 0 ? ShareAmount(memberID: member.id, minor: minor) : nil
        }
    }
    private func cancel() {
        if onFinish != nil { model.recordPanel.cancelEditing() }
        else if hasLocalChanges { confirmingDiscard = true }
        else { dismiss() }
    }
    private func finish() { if let onFinish { onFinish() } else { dismiss() } }
    private func save() {
        do {
            var value = bodyValue
            if kind == .project {
                if budgetLimit.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard value.budget?.items.isEmpty ?? true, budgetItemName.isEmpty, budgetItemAmount.isEmpty else { throw NobisError.validation("有计划项时，请填写预算金额。") }
                    value.budget = nil
                } else {
                    value.budget = ProjectBudget(limit: try Money.parse(budgetLimit, currency: budgetCurrency), items: value.budget?.items ?? [])
                    if !budgetItemName.isEmpty || !budgetItemAmount.isEmpty {
                        let money = try Money.parse(budgetItemAmount, currency: budgetCurrency)
                        guard money.minor > 0, !budgetItemName.trimmingCharacters(in: .whitespaces).isEmpty else { throw NobisError.validation("请填写计划项名称和正数金额。") }
                        value.budget?.items.append(BudgetItem(name: budgetItemName, amount: money))
                    }
                }
            }
            value.date = hasDate || kind == .event ? LocalDay(date: day) : nil
            if kind == .project { value.endDate = hasEnd ? LocalDay(date: endDay) : nil }
            if kind == .event { value.date = value.allDay ? LocalDay(date: day) : nil; value.endDate = value.allDay ? LocalDay(date: endDay) : nil; value.startAt = value.allDay ? nil : startAt; value.endAt = value.allDay ? nil : endAt }
            if kind == .subscription || kind == .transaction { value.money = amount.isEmpty && kind == .subscription ? nil : try Money.parse(amount, currency: currency) }
            if kind == .subscription {
                let previous = existing?.body
                value.billingAnchor = previous?.date == value.date && previous?.cycleUnit == value.cycleUnit && previous?.cycleCount == value.cycleCount ? previous?.billingAnchor ?? value.date : value.date
                value.unknownPriceCurrency = value.money == nil ? currency : nil
            }
            if kind == .transaction, let money = value.money { value.splits = try computeSplits(money) }
            if kind == .transaction && existing?.body.status == .confirmed && value.status == .voided {
                var original = existing!.body; original.status = .voided; original.notes = value.notes; value = original
            }
            try model.save(value, spaceID: spaceID, existing: existing); finish()
        } catch { validation = error.localizedDescription }
    }
}
