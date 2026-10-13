import SwiftUI
import FamilyDomain
import FamilyCore

struct FinancialReviewView: View {
    let model: AppModel
    @State private var spaceID: UUID?
    @State private var kind = RecordKind.monthlyIncome
    @State private var owner = ""
    @State private var search = ""
    @State private var selected: Set<UUID> = []
    @State private var pending: [Record] = []
    @State private var onlyUnknown = true
    @State private var error: String?
    @State private var message: String?
    @State private var creatingAsset = false
    @State private var baselineID: UUID?
    @State private var breakdownIDs: Set<UUID> = []
    init(model: AppModel, spaceID: UUID? = nil) { self.model = model; _spaceID = State(initialValue: spaceID) }
    private var records: [Record] { model.records.filter { $0.latest.spaceID == spaceID && !$0.deleted && $0.body.sharedDestination == nil } }
    private var candidates: [Record] { records.filter { $0.body.kind == kind && $0.body.status == .active && !$0.conflicted && (!onlyUnknown || $0.body.financialOwner == nil) && (search.isEmpty || $0.body.title.localizedCaseInsensitiveContains(search)) }.sorted { $0.body.title < $1.body.title } }
    private var chosenOwner: FinancialOwner? {
        if owner == "joint" { return FinancialOwner(kind: .joint) }
        return UUID(uuidString: owner).map { FinancialOwner(kind: .member, memberID: $0) }
    }
    private var assets: [Record] { records.filter { $0.body.kind == .assetSnapshot && $0.body.status == .active && !$0.conflicted }.sorted { ($0.body.date?.description ?? "") > ($1.body.date?.description ?? "") } }
    var body: some View {
        LifeDetail {
            LifePicker("核对范围", selection: $spaceID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.spaces) { Text(model.visibility(for: $0.id) + " · " + $0.name).tag(Optional($0.id)) }
            }
            LifeSection(title: "确认收入与资产归属", icon: "person.crop.circle.badge.checkmark") {
                Text("Minty 未记录收入人或资产持有人，请根据实际情况选择。原记录人、消费归属称呼不代表付款人，也不会据此关联账号。").font(.caption).foregroundStyle(.secondary)
                Picker("记录类型", selection: $kind) { Text("收入").tag(RecordKind.monthlyIncome); Text("资产快照").tag(RecordKind.assetSnapshot) }
                Toggle("只显示归属待确认", isOn: $onlyUnknown)
                LifePicker("确认归属为", selection: $owner) {
                    Text("请选择，不自动推断").tag("")
                    if kind == .assetSnapshot { Text("共同持有（不代表整体资产）").tag("joint") }
                    ForEach(model.spaces.first { $0.id == spaceID }?.members ?? []) { Text($0.name).tag($0.id.uuidString) }
                }
                LifeTextField("筛选记录名称或收入期间", text: $search)
                LifeAdaptiveRow {
                    Button("选择当前列表全部（\(candidates.count) 条）") { selected = Set(candidates.map(\.id)); pending = [] }
                    Button("清除选择") { selected = []; pending = [] }
                    Text("已选 \(selected.count) 条").font(.caption)
                }
                if candidates.isEmpty { Text("当前条件下没有可确认的记录。").foregroundStyle(.secondary) }
                if records.contains(where: { $0.body.kind == kind && $0.conflicted }) { Text("冲突记录暂不参与，请先在详情中解决冲突。").foregroundStyle(.orange) }
                DisclosureGroup("逐条选择（\(candidates.count) 条）") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(candidates) { record in
                        Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { on in
                            if on { selected.insert(record.id) } else { selected.remove(record.id) }; pending = []
                        })) {
                            VStack(alignment: .leading) {
                                Text(record.body.title)
                                FinancialOwnershipBadge(model: model, record: record)
                                if let income = record.body.incomeMonth { Text("税后 \(income.net.formatted)").font(.caption) }
                                if let asset = record.body.assetPosition { Text("\(record.body.date?.description ?? "") · \(asset.currency.rawValue)").font(.caption) }
                            }
                        }
                    }
                }
                }
                Button("预览归属调整") { previewOwnership() }.disabled(selected.isEmpty || chosenOwner == nil || !canWrite)
            }
            if !pending.isEmpty {
                LifeSection(title: "核对后保存", icon: "checklist") {
                    Text("将为所选 \(pending.count) 条记录确认归属；金额、日期和可见范围保持不变，原修订保留。")
                    DisclosureGroup("查看所选记录") { ForEach(pending) { record in Text(record.body.title).font(.caption) } }
                    Button("确认保存归属") { commitOwnership() }.disabled(!canWrite)
                    Button("取消本次调整") { pending = [] }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let error { InlineIssue(message: error) }
            assetReview
        }.navigationTitle("成员与资产核对")
        .sheet(isPresented: $creatingAsset) { FinancialRecordEditor(model: model, kind: .assetSnapshot, initialSpaceID: spaceID) }
        .onAppear { if spaceID == nil { spaceID = model.workspace.commonID } }
        .onChange(of: spaceID) { _, _ in search = ""; owner = ""; selected = []; pending = []; baselineID = nil; breakdownIDs = []; error = nil; message = nil }
        .onChange(of: search) { _, _ in selected = []; pending = []; error = nil; message = nil }
        .onChange(of: kind) { _, _ in search = ""; owner = ""; selected = []; pending = []; error = nil; message = nil }
        .onChange(of: owner) { _, _ in pending = []; error = nil; message = nil }
        .onChange(of: onlyUnknown) { _, _ in selected = []; pending = [] }
        .onChange(of: baselineID) { _, _ in breakdownIDs = [] }
    }
    private var canWrite: Bool { spaceID.map { model.canWrite(spaceID: $0) } ?? false }
    private func previewOwnership() {
        do {
            guard let core = model.core, let spaceID, let chosenOwner else { throw NobisError.forbidden }
            let selection = candidates.filter { selected.contains($0.id) }
            let changes = try core.ownershipChanges(selection, owner: chosenOwner, spaceID: spaceID)
            let ids = Set(changes.map(\.id)); pending = selection.filter { ids.contains($0.id) }
            error = nil; message = pending.isEmpty ? "所选归属已一致，无需修改。" : nil
        } catch { self.error = error.localizedDescription; pending = [] }
    }
    private func commitOwnership() {
        do {
            guard let core = model.core, let spaceID, let chosenOwner else { throw NobisError.forbidden }
            // Recheck both captured revision heads and newly introduced duplicate snapshots.
            let changes = try core.ownershipChanges(pending, owner: chosenOwner, spaceID: spaceID)
            try core.saveBatch(changes, spaceID: spaceID)
            message = "已确认 \(changes.count) 条记录的归属。"; pending = []; selected = []; error = nil; model.refresh()
        } catch { self.error = error.localizedDescription; pending = [] }
    }
    @ViewBuilder private var assetReview: some View {
        LifeSection(title: "旧整体与分项资产核对", icon: "equal.square") {
            Text("仅比较同日、同币种的完整快照。旧整体与分项不会相加计入报告；核对不会修改、合并或归档任何快照。").font(.caption).foregroundStyle(.secondary)
            Button("记录分项资产快照") { creatingAsset = true }.disabled(!canWrite)
            LifePicker("旧整体快照", selection: $baselineID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(assets.filter { $0.body.financialOwner == nil }) { record in Text("\(record.body.title) · \(record.body.assetPosition?.currency.rawValue ?? "")").tag(Optional(record.id)) }
            }
            if let baseline = assets.first(where: { $0.id == baselineID }) {
                RecordLink(model: model, record: baseline) { Label("查看旧整体明细", systemImage: "doc.text.magnifyingglass") }
                let choices = assets.filter { $0.id != baseline.id && $0.body.financialOwner != nil && $0.body.date == baseline.body.date && $0.body.assetPosition?.currency == baseline.body.assetPosition?.currency }
                if choices.isEmpty { Text("没有同日、同币种且归属已确认的分项快照。请先记录实际持有情况，不按比例拆分旧余额。").foregroundStyle(.secondary) }
                ForEach(choices) { record in
                    Toggle(isOn: Binding(get: { breakdownIDs.contains(record.id) }, set: { if $0 { breakdownIDs.insert(record.id) } else { breakdownIDs.remove(record.id) } })) {
                        FinancialOwnershipBadge(model: model, record: record)
                    }
                    RecordLink(model: model, record: record) { Text(record.body.title).font(.caption) }
                }
                if !breakdownIDs.isEmpty, let core = model.core, let spaceID {
                    switch Result(catching: { try core.reconcileAssets(baselineID: baseline.id, breakdownIDs: breakdownIDs, spaceID: spaceID) }) {
                    case .failure(let error): InlineIssue(message: error.localizedDescription)
                    case .success(let review):
                        Text(review.matches ? "所选分项的九项金额与旧整体一致" : "所选分项与旧整体存在差额").font(.headline)
                        Text("差额 = 所选分项合计 − 旧整体。金额一致不代表范围已完整；请确认各成员及共同持有部分没有遗漏或重叠。").font(.caption).foregroundStyle(.secondary)
                        ForEach(AssetComponent.allCases, id: \.self) { component in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(component.title).font(.subheadline)
                                FinancialValueRow("旧整体", value: Money(minor: baseline.body.assetPosition?.amounts[component] ?? 0, currency: review.currency).formatted)
                                FinancialValueRow("所选分项合计", value: Money(minor: review.totals.amounts[component] ?? 0, currency: review.currency).formatted)
                                FinancialValueRow("差额", value: Money(minor: review.differences[component] ?? 0, currency: review.currency).formatted)
                            }
                        }
                    }
                }
            }
        }
    }
}
