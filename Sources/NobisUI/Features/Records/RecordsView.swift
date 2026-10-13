import SwiftUI
import FamilyDomain
import FamilyCore

enum TaskDateGroup: String, CaseIterable, Identifiable {
    case overdue = "已逾期", today = "今天", upcoming = "接下来", undated = "未定日期", finished = "已完成与归档"
    var id: String { rawValue }

    static func group(for record: Record, today: LocalDay) -> Self {
        if [.completed, .archived, .cancelled, .voided].contains(record.body.status) { return .finished }
        guard let date = record.body.date else { return .undated }
        if date < today { return .overdue }
        return date == today ? .today : .upcoming
    }

    func records(in records: [Record], today: LocalDay) -> [Record] {
        records.filter { Self.group(for: $0, today: today) == self }.sorted {
            if self != .finished, $0.body.date != $1.body.date {
                return ($0.body.date?.description ?? "") < ($1.body.date?.description ?? "")
            }
            if $0.latest.createdAt != $1.latest.createdAt { return $0.latest.createdAt > $1.latest.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct RecordsView: View {
    @Bindable var model: AppModel
    @Environment(\.dynamicTypeSize) private var textSize
    var fixedKind: RecordKind?
    @State private var kind: RecordKind = .task
    @State private var search = ""
    private var scope: LifeScope { model.projectScope }
    @State private var showArchived = false
    @State private var create: RecordKind?
    var activeKind: RecordKind { fixedKind ?? kind }
    var filtered: [Record] { model.records(in: scope).filter { $0.body.kind == activeKind && (showArchived || ![.archived, .voided, .cancelled, .completed].contains($0.body.status)) && (search.isEmpty || $0.body.title.localizedCaseInsensitiveContains(search) || $0.body.notes.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        Group {
            if activeKind == .project { projectWorkspace }
            else { recordList }
        }
        .navigationTitle(fixedKind == .project ? "项目" : "记录")
        .onChange(of: kind) { _, _ in model.recordPanel.close() }
        .searchable(text: $search, prompt: activeKind == .project ? "搜索项目与备注" : "搜索我可见的记录")
        .toolbar { WorkspaceCreateAction(title: "新建\(activeKind.title)") { create = activeKind } }
        .sheet(item: $create) { RecordEditor(model: model, kind: $0) }
    }
    private var projectWorkspace: some View {
        LifePage(title: "一起做的事", subtitle: "把想法变成计划，慢慢完成。", icon: "square.stack.3d.up") {
                LifeScopeControls(scope: $model.projectScope, archived: $showArchived)
                HStack {
                    Text("\(filtered.count) 个项目").font(.subheadline).foregroundStyle(.secondary)
                }
                if filtered.isEmpty {
                    WorkspaceEmptyState(title: search.isEmpty ? "还没有项目" : "没有匹配的项目", icon: "square.stack.3d.up", message: search.isEmpty ? "开始下一件想一起做的事。" : "试试其他关键词或可见范围。", actionTitle: search.isEmpty ? "新建项目" : "清除搜索") {
                        if search.isEmpty { create = .project } else { search = "" }
                    }
                }
                LazyVGrid(columns: [GridItem(textSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 250), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(filtered.sorted { ($0.body.isPinned == true ? 0 : 1) < ($1.body.isPinned == true ? 0 : 1) }) { record in
                        RecordLink(model: model, record: record) { ProjectPreview(model: model, record: record) }.buttonStyle(.plain)
                    }
                }
        }
    }
    private var recordList: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            recordList(today: LocalDay(date: context.date))
        }
    }

    private func recordList(today: LocalDay) -> some View {
        LifeDetail {
            LifeScopeControls(scope: $model.projectScope, archived: $showArchived)
            if fixedKind == nil {
                LifeSection(title: "记录类型", icon: "line.3.horizontal.decrease") {
                    DirectSelection(title: "记录类型", selection: $kind,
                        options: RecordKind.allCases.filter { ![.document, .comment, .project, .category, .monthlyIncome, .assetSnapshot, .transaction].contains($0) }, showsTitle: false) { $0.title }
                }
            }
            if activeKind == .transaction {
                NavigationLink("收支工作台 · 筛选、导入与导出") { LedgerWorkspace(model: model) }
            }

            if filtered.isEmpty {
                WorkspaceEmptyState(
                    title: search.isEmpty ? "暂无\(activeKind.title)" : "没有匹配的记录",
                    icon: search.isEmpty ? activeKind.icon : "magnifyingglass",
                    message: search.isEmpty ? "记下下一件事，或调整筛选查看历史记录。" : "试试其他关键词或可见范围。",
                    actionTitle: search.isEmpty ? "新建\(activeKind.title)" : "清除搜索"
                ) {
                    if search.isEmpty { create = activeKind } else { search = "" }
                }
            } else if activeKind == .task {
                taskSections(today: today)
            } else {
                LifeSection(title: "\(activeKind.title) · \(filtered.count) 条", icon: activeKind.icon) {
                    ForEach(filtered) { record in
                        RecordLink(model: model, record: record) { RecordRow(model: model, record: record) }
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func taskSections(today: LocalDay) -> some View {
        ForEach(TaskDateGroup.allCases) { group in
            let records = group.records(in: filtered, today: today)
            if !records.isEmpty {
                LifeSection(title: "\(group.rawValue) · \(records.count)", icon: "checklist") {
                    ForEach(records) { record in TaskRow(model: model, record: record) }
                }
            }
        }
    }
}

struct RecordDetail: View {
    let model: AppModel
    let recordID: UUID
    var onEdit: (() -> Void)? = nil
    @State private var editing = false
    @State private var deleting = false
    @State private var archivingProject = false
    @State private var sharePlan: SharingPlan?
    @State private var adding: RecordKind?
    private var record: Record? { model.records.first { $0.id == recordID } }
    var body: some View {
        Group {
            if let record {
                LifeDetail {
                    LifeSection(title: "记录", icon: "doc.text") {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: record.body.kind == .task ? (record.body.status == .completed ? "checkmark.circle.fill" : "checklist") : record.body.kind.icon)
                                .font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                            Text(record.body.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                            Label(record.deleted ? "回收站" : record.conflicted ? "待核对" : record.body.status.title,
                                  systemImage: record.conflicted ? "exclamationmark.triangle" : "circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(record.conflicted ? Color.orange : Color.secondary)
                        }.padding(.vertical, 8)
                    }
                    LifeSection(title: "基本信息", icon: "list.bullet.rectangle") {
                        LabeledContent("归属") { ResourceOwnership(model: model, spaceID: record.latest.spaceID, detailed: true) }
                        RecordCreator(model: model, record: record)
                        if let member = model.space(for: record)?.members.first(where: { $0.id == record.body.memberID }) { LabeledContent(record.body.kind == .task ? "负责人" : "付款 / 收款人") { MemberIdentityBadge(member: member) } }
                        if let date = record.body.date { LabeledContent(record.body.kind == .subscription ? "下次计费" : "日期", value: date.description) }
                        if let end = record.body.endDate { LabeledContent("结束日期", value: end.description) }
                        if let start = record.body.startAt, !record.body.allDay { LabeledContent("开始", value: start.formatted()); LabeledContent("时区", value: record.body.timeZone) }
                        if let end = record.body.endAt, !record.body.allDay { LabeledContent("结束", value: end.formatted()) }
                        if !record.body.location.isEmpty { LabeledContent("地点", value: record.body.location) }
                        if let money = record.body.money { LabeledContent("金额", value: money.formatted) }
                        if record.body.kind == .subscription {
                            LabeledContent("周期", value: "每 \(record.body.cycleCount) \(record.body.cycleUnit.title)")
                            Text("预计续费不是已发生支出。取消状态仅在你已到供应商处完成取消后设置。").font(.caption).foregroundStyle(.secondary)
                        }
                        if record.body.kind == .transaction {
                            LabeledContent("类型", value: record.body.transactionKind.title)
                            LabeledContent("账户", value: record.body.account)
                            LabeledContent("分类", value: record.body.category)
                            LabeledContent("记账方式", value: record.body.accountingMode.title)
                            LabeledContent("消费归属", value: record.body.finance?.consumption == .personal ? record.body.finance?.consumer ?? "" : record.body.finance?.consumption.title ?? "未标注")
                            if let recorder = record.body.finance?.originalRecorder, !recorder.isEmpty { LabeledContent("原记录人", value: recorder) }
                            ForEach(record.body.splits, id: \.memberID) { split in
                                HStack {
                                    MemberIdentityBadge(name: model.space(for: record)?.members.first { $0.id == split.memberID }?.name ?? "历史成员", identity: split.memberID.uuidString)
                                    Spacer()
                                    Text(Money(minor: split.minor, currency: record.body.money?.currency ?? .CNY).formatted)
                                }
                            }
                        }
                    }
                    if [.monthlyIncome, .assetSnapshot].contains(record.body.kind) {
                        LabeledContent("财务归属") { FinancialOwnershipBadge(model: model, record: record) }
                    }
                    Section { RelatedResources(model: model, record: record) }
                    FinancialRecordDetails(record: record)
                    if !record.body.notes.isEmpty { LifeSection(title: "备注", icon: "list.bullet.rectangle") { Text(record.body.notes).textSelection(.enabled) } }
                    if record.body.sharedDestination != nil { Text("已分享来源 · 原历史仅自己可见。请在共同记录中继续编辑。").font(.callout) }
                    if record.conflicted {
                        LifeSection(title: "比较并发版本", icon: "list.bullet.rectangle") {
                            Text("请选择保留的版本。新修订将引用所有当前分支，原始历史会保留。删除分支存在时不会自动恢复记录。").font(.caption)
                            ForEach(record.heads) { revision in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(revision.deleted ? "已删除版本" : revision.body.title).fontWeight(.semibold)
                                    Text("\(revision.body.status.title) · \(revision.body.date?.description ?? "无日期") · \(revision.body.money?.formatted ?? "无金额")")
                                    Text(revision.body.notes).font(.caption)
                                    Text(revision.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                    Button("保留此版本") { model.perform { try model.save(revision.body, spaceID: record.latest.spaceID, existing: record, deleted: revision.deleted) } }
                                }.padding(.vertical, 8)
                            }
                        }
                    } else if !record.deleted && record.body.sharedDestination == nil && record.body.kind != .transaction {
                        LifeSection(title: "下一步", icon: "list.bullet.rectangle") {
                            if record.body.kind == .task { Button(record.body.status == .completed ? "重新打开任务" : "完成任务") { model.changeStatus(record, to: record.body.status == .completed ? .active : .completed) } }
                            if record.body.kind == .project { Button(record.body.status == .archived ? "恢复项目" : "归档项目") { if record.body.status == .archived { model.changeStatus(record, to: .active) } else { archivingProject = true } } }
                            if record.body.kind == .subscription && record.body.status == .active { Button("已复核保留 · 推进到下一期") { model.advance(record) } }
                            if record.body.kind != .transaction { Button(role: .destructive) { deleting = true } label: { Label("移入回收站", systemImage: "trash").foregroundStyle(.red) } }
                        }
                    } else if record.deleted && record.body.sharedDestination == nil {
                        Button("恢复此记录") { model.perform { try model.save(record.body, spaceID: record.latest.spaceID, existing: record) } }
                    }
                    if record.body.kind == .project {
                        if record.body.sharedDestination == nil { ProjectBudgetSummary(model: model, record: record) }
                        LifeSection(title: "项目中的记录", icon: "list.bullet.rectangle") {
                            let linked = model.activeRecords.filter { $0.body.projectIDs.contains(record.id) }
                            if linked.isEmpty { Text("录入任务、日程或账单时，可以关联此项目。").foregroundStyle(.secondary) }
                            ForEach(linked) { child in RecordLink(model: model, record: child) { RecordRow(model: model, record: child) } }
                            let transactions = linked.filter { $0.body.kind == .transaction && $0.body.status == .confirmed && !$0.conflicted }
                            ForEach(Currency.allCases, id: \.self) { currency in
                                let values = transactions.filter { $0.body.money?.currency == currency && [.expense, .refund].contains($0.body.transactionKind) }.map { ($0.body.money?.minor ?? 0) * ($0.body.transactionKind == .refund ? -1 : 1) }
                                if !values.isEmpty { Text("项目净支出：\(netAmount(values, currency: currency))").font(.callout) }
                            }
                        }
                    }
                    LifeSection(title: "记录历史", icon: "clock.arrow.circlepath") {
                        DisclosureGroup("修订历史") {
                        if let history = try? model.core?.history(record.id, spaceID: record.latest.spaceID) {
                            ForEach(history) { revision in VStack(alignment: .leading, spacing: 4) {
                                Text("\(revision.deleted ? "移入回收站" : revision.body.status.title) · \(revision.createdAt.formatted())")
                                Text(revision.id.uuidString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            } }
                        }
                        }
                    }
                }.buttonStyle(.borderless).navigationTitle(onEdit == nil ? record.body.kind.title : "")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if onEdit == nil && !record.deleted && !record.conflicted && record.body.sharedDestination == nil {
                            Button("编辑") { editing = true }.disabled(!model.canWrite(spaceID: record.latest.spaceID))
                        }
                    }
                    ToolbarItemGroup(placement: .automatic) {
                    if !record.deleted && record.body.sharedDestination == nil && model.space(for: record)?.kind == .personal {
                        Button("分享给我们") { model.perform {
                            guard let core = model.core, let target = model.workspace.commonID else { throw NobisError.forbidden }
                            sharePlan = try core.previewSharing(recordID: record.id, from: record.latest.spaceID, to: target)
                        } }
                    }
                    if record.body.kind == .project && !record.deleted && record.body.sharedDestination == nil {
                        Menu {
                            Button("添加任务") { adding = .task }
                            Button("添加日程") { adding = .event }
                            Button("记一笔项目支出") { adding = .transaction }
                            Button("添加子项目") { adding = .project }
                        } label: { Label("项目内新建", systemImage: "plus") }
                    }
                    }
                }
                .navigationDestination(isPresented: Binding(get: { editing && record.body.kind == .document }, set: { editing = $0 })) { DocumentEditor(model: model, existing: record, embedded: true).navigationTitle(record.body.title) }
                .sheet(isPresented: Binding(get: { editing && record.body.kind != .document }, set: { editing = $0 })) { if [.monthlyIncome, .assetSnapshot].contains(record.body.kind) { FinancialRecordEditor(model: model, kind: record.body.kind, existing: record) } else { RecordEditor(model: model, kind: record.body.kind, existing: record) } }
                .confirmationDialog("归档项目？未完成的待办和笔记清单会继续保留，费用不变。", isPresented: $archivingProject, titleVisibility: .visible) { Button("归档项目") { model.changeStatus(record, to: .archived) } }
                .confirmationDialog("将这条记录移入回收站？30 天内可恢复。", isPresented: $deleting) { Button("移入回收站", role: .destructive) { model.perform { try model.save(record.body, spaceID: record.latest.spaceID, existing: record, deleted: true) } } }
                .sheet(item: $adding) { RecordEditor(model: model, kind: $0, project: record) }
                .sheet(item: $sharePlan) { plan in
                    NavigationStack {
                        LifeDetail {
                            Text("分享以下当前内容，包括备注和金额。原私密修订历史、审计和迁移源包不会上传。完成后原来源只读，不重复计入合计。")
                            Group {
                                ForEach(plan.sources) { source in
                                    VStack(alignment: .leading) {
                                        Text(source.body.title).font(.headline)
                                        Text(source.body.kind.title)
                                        if !source.body.notes.isEmpty { Text(source.body.notes).font(.caption) }
                                        if let date = source.body.date { Text("日期：\(date)") }
                                        if let money = source.body.money { Text(money.formatted) }
                                        if let budget = source.body.budget { Text("预算：\(budget.limit.formatted)"); ForEach(budget.items) { item in Text("\(item.name)：\(item.amount.formatted)") } }
                                        if source.body.kind == .transaction { Text("\(source.body.transactionKind.title) · \(source.body.category) · \(source.body.account)") }
                                        DisclosureGroup("核对全部当前字段") {
                                            Text(sharingFields(source.body)).font(.caption).textSelection(.enabled)
                                        }
                                        FinancialRecordDetails(record: Record.project([source])[0])
                                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
                                }
                                Text("将分享 \(plan.sources.count) 条当前内容。")
                            }
                        }.buttonStyle(.borderless).navigationTitle("分享预览").toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { sharePlan = nil } }
                            ToolbarItem(placement: .confirmationAction) { Button("确认分享") { model.perform { try model.share(plan); sharePlan = nil } } }
                        }
                    }.editorDimensions(height: 440)
                }
            } else { ContentUnavailableView("记录不可用", systemImage: "doc.questionmark") }
        }
    }
    private func sharingFields(_ body: RecordBody) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(body)).map { String(decoding: $0, as: UTF8.self) } ?? "内容暂不可用"
    }
    private func netAmount(_ values: [Int64], currency: Currency) -> String { do { return try Money(minor: Money.sum(values), currency: currency).formatted } catch { return "合计超出范围，需核对" } }
}
