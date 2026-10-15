import SwiftUI
import FamilyDomain
import FamilyCore

struct NoteChecklistRow: View {
    let model: AppModel
    let item: NoteChecklistItem
    var inheritedSpaceID: UUID? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.perform { guard let core = model.core else { throw NobisError.forbidden }; try core.toggleChecklist(item); model.refresh() }
            } label: { Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.title3).touchTarget() }
                .buttonStyle(.borderless).disabled(!model.canWrite(spaceID: item.document.latest.spaceID))
                .accessibilityLabel("\(item.completed ? "重新打开" : "完成")：\(item.title)")
            NavigationLink { DocumentDetail(model: model, documentID: item.document.id, checklistLine: item.line) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).strikethrough(item.completed).foregroundStyle(item.completed ? .secondary : .primary)
                    Label(item.document.body.title, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                    if inheritedSpaceID != item.document.latest.spaceID || model.space(for: item.document) == nil {
                        ResourceOwnership(model: model, spaceID: item.document.latest.spaceID)
                    }
                }
            }.buttonStyle(.plain)
        }.padding(.vertical, 5)
    }
}

struct ScheduleWorkspace: View {
    @Bindable var model: AppModel
    private var scope: LifeScope { model.scheduleScope }
    @State private var mode = "待办"
    @State private var day = Date()
    @State private var completed = false
    @State private var search = ""
    @State private var create: RecordKind?
    private var visible: [Record] { WorkspaceQuery.search(search, in: model.records(in: scope)) }
    private var checklist: [NoteChecklistItem] {
        NoteChecklistItem.items(in: model.records(in: scope), includeCompleted: completed).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.document.body.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        LifePage {
            LifeScopeControls(scope: $model.scheduleScope)
            Picker("查看方式", selection: $mode) { Text("待办").tag("待办"); Text("日历").tag("日历"); Text("订阅").tag("订阅") }
                .pickerStyle(.segmented).tint(NobisTheme.controlFill).labelsHidden().frame(maxWidth: 320, alignment: .leading)
            if mode == "待办" {
                Toggle("显示已完成", isOn: $completed).font(.callout)
                ForEach(TaskDateGroup.allCases) { group in
                    let tasks = group.records(in: visible.filter { $0.body.kind == .task && (completed || $0.body.status == .active) }, today: model.today)
                    if !tasks.isEmpty {
                        LifeSection(title: "\(group.rawValue) · \(tasks.count)", icon: group == .overdue ? "exclamationmark.circle" : "checkmark.circle") {
                            LazyVStack(alignment: .leading, spacing: 8) { ForEach(tasks) { TaskRow(model: model, record: $0) } }
                        }
                    }
                }
                if !checklist.isEmpty {
                    LifeSection(title: "笔记清单", icon: "checklist") {
                        LazyVStack(alignment: .leading, spacing: 16) { ForEach(checklist) { NoteChecklistRow(model: model, item: $0) } }
                    }
                }
                if checklist.isEmpty && !visible.contains(where: { $0.body.kind == .task && (completed || $0.body.status == .active) }) {
                    WorkspaceEmptyState(title: "没有待办", icon: "checkmark.circle", message: "新建待办，或在笔记中写下清单。", actionTitle: "新建待办") { create = .task }.lifeCard()
                }
            } else if mode == "日历" {
                #if os(macOS)
                LifeAdaptiveRow {
                    DatePicker("查看日期", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.field)
                    Button("今天") { day = Date() }
                }
                #else
                LifeSection(title: "选择日期", icon: "calendar") {
                    DatePicker("选择日期", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                }
                #endif
                let entries = visible.filter { WorkspaceQuery.occurs($0, on: LocalDay(date: day)) }.sorted { ($0.body.startAt ?? .distantPast) < ($1.body.startAt ?? .distantPast) }
                LifeSection(title: day.formatted(date: .complete, time: .omitted), icon: "sun.max") {
                    if entries.isEmpty { Text("这一天没有安排").foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(entries) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.body.kind == .task ? "待办截止" : record.body.kind == .subscription ? "预计续费" : record.body.allDay ? "全天日程" : record.body.startAt?.formatted(date: .omitted, time: .shortened) ?? "日程").font(.caption).foregroundStyle(.secondary)
                                RecordLink(model: model, record: record) { RecordRow(model: model, record: record) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                LifeSection(title: "生活中的订阅", icon: "arrow.triangle.2.circlepath") {
                    let subscriptions = visible.filter { $0.body.kind == .subscription }
                    if subscriptions.isEmpty { Text("还没有订阅记录").foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(subscriptions) { record in RecordLink(model: model, record: record) { RecordRow(model: model, record: record) }.buttonStyle(.plain) }
                    }
                    Text("预计续费不计入实际支出；付款后在账本记一笔并关联订阅。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("安排").searchable(text: $search, prompt: "搜索待办、笔记清单与日程")
            .toolbar { ToolbarItem(placement: .primaryAction) { Menu { Button("新建待办") { create = .task }; Button("新建日程") { create = .event }; Button("记录订阅") { create = .subscription } } label: { Label("新建", systemImage: "plus") } } }
            .sheet(item: $create) { RecordEditor(model: model, kind: $0) }
    }
}

struct TodayWorkspace: View {
    let model: AppModel
    @State private var searching = false
    @State private var create: RecordKind?
    @State private var note = false
    private var today: LocalDay { model.today }
    private var dueTasks: [Record] { model.activeRecords.filter { $0.body.kind == .task && $0.body.status == .active && $0.body.date.map { $0 <= today } == true }.sorted { ($0.body.date ?? today) < ($1.body.date ?? today) } }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var accent: Color { NobisTheme.accent }
    private var cardColumns: [GridItem] {
        if horizontalSizeClass == .compact || textSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)]
    }
    private var events: [Record] {
        model.activeRecords.filter { $0.body.kind == .event && WorkspaceQuery.occurs($0, on: today) }
            .sorted { ($0.body.startAt ?? .distantPast) < ($1.body.startAt ?? .distantPast) }
    }
    private var checklist: [NoteChecklistItem] { NoteChecklistItem.items(in: model.activeRecords) }
    private var subscriptions: [Record] {
        model.activeRecords.filter { $0.body.kind == .subscription && $0.body.status == .active && $0.body.date.map { $0 <= today.addingDays(7) } == true }
            .sorted { ($0.body.date ?? today) < ($1.body.date ?? today) }
    }
    private var pinned: [Record] { model.activeRecords.filter { $0.body.isPinned == true && $0.body.status != .archived } }
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "sun.horizon.fill")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(today.date().formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("一起过好今天").font(.largeTitle.weight(.semibold))
                }.frame(maxWidth: .infinity).padding(.top, 18).padding(.bottom, 6)

                if events.isEmpty && dueTasks.isEmpty {
                    Label("今天没有日程和到期待办，按自己的节奏来。", systemImage: "leaf")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18).background(NobisSurface.card, in: RoundedRectangle(cornerRadius: 20))
                }

                if !dueTasks.isEmpty {
                    TodaySectionCard(title: "到期与逾期待办 · \(dueTasks.count)", icon: "checkmark.circle") {
                        ForEach(dueTasks) { TaskRow(model: model, record: $0) }
                    }
                }
                if !events.isEmpty {
                    TodaySectionCard(title: "今天的安排 · \(events.count)", icon: "calendar") {
                        ForEach(events) { record in
                            RecordLink(model: model, record: record) { RecordRow(model: model, record: record) }.buttonStyle(.plain)
                        }
                    }
                }
                LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 20) {
                    if !subscriptions.isEmpty {
                        TodaySectionCard(title: "即将续费", subtitle: "未来七天与尚待确认的续费", icon: "arrow.triangle.2.circlepath") {
                            ForEach(subscriptions) { record in
                                RecordLink(model: model, record: record) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(record.body.title).font(.headline)
                                        if let money = record.body.money {
                                            Text(money.formatted).font(.title2.weight(.semibold)).monospacedDigit()
                                        } else { Text("价格待核实").foregroundStyle(.secondary) }
                                        if let date = record.body.date {
                                            Label("\(date.description) · 预计续费", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                                        }
                                        ResourceOwnership(model: model, spaceID: record.latest.spaceID)
                                        HStack { Text("查看订阅"); Image(systemName: "arrow.right") }.font(.callout.weight(.medium)).foregroundStyle(accent).padding(.top, 4)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    TodaySectionCard(title: "笔记清单", icon: "checklist") {
                        if checklist.isEmpty {
                            Text("暂时没有未完成的清单。想到什么，先记下来。")
                                .foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(Array(checklist.prefix(5))) { NoteChecklistRow(model: model, item: $0) }
                        NavigationLink { ScheduleWorkspace(model: model) } label: {
                            HStack { Text("查看全部待办"); Image(systemName: "arrow.right") }
                                .font(.callout.weight(.medium)).foregroundStyle(accent).padding(.top, 10)
                        }.buttonStyle(.plain)
                    }
                }
                if !pinned.isEmpty {
                    TodaySectionCard(title: "置顶", icon: "pin") {
                        ForEach(pinned) { record in
                            RecordLink(model: model, record: record) { RecordRow(model: model, record: record) }.buttonStyle(.plain)
                        }
                    }
                }
                LifeAdaptiveRow {
                    Button { note = true } label: { Label("记下这一刻", systemImage: "square.and.pencil").foregroundStyle(Color.primary) }
                    Button { create = .event } label: { Label("添个安排", systemImage: "calendar.badge.plus").foregroundStyle(Color.primary) }
                }.lifeSecondaryAction()
            }.frame(maxWidth: 980).padding(.horizontal, 24).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }.background { LifeBackground() }
        .navigationTitle("今天")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button { searching = true } label: { Label("搜索全部", systemImage: "magnifyingglass").foregroundStyle(Color.primary) }.keyboardShortcut("f", modifiers: [.command, .shift])
                        Menu { Button("新建笔记") { note = true }; Button("新建待办") { create = .task }; Button("新建日程") { create = .event }; Button("记一笔") { create = .transaction }; Button("新建项目") { create = .project } } label: { Label("新建", systemImage: "plus") }
                    }
                }
            }
            .sheet(isPresented: $searching) { WorkspaceSearch(model: model) }
            .navigationDestination(isPresented: $note) { DocumentEditor(model: model, embedded: true).navigationTitle("新建笔记") }
            .sheet(item: $create) { RecordEditor(model: model, kind: $0) }
    }

}

private struct TodaySectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 12) { content }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .lifeCard()
    }
}

struct WorkspaceSearch: View {
    let model: AppModel
    @State private var query = ""
    @State private var scope: LifeScope = .all
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            LifeDetail {
                LifeScopeControls(scope: $scope)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("搜索笔记、项目、待办、日程与账单").foregroundStyle(.secondary) }
                else {
                    let results = WorkspaceQuery.search(query, in: model.records(in: scope))
                    if results.isEmpty { ContentUnavailableView.search(text: query) }
                    ForEach(results) { record in
                        NavigationLink {
                            if record.body.kind == .document { DocumentDetail(model: model, documentID: record.id) }
                            else if record.body.kind == .project { ProjectWorkspace(model: model, projectID: record.id) }
                            else { RecordDetail(model: model, recordID: record.id) }
                        } label: { RecordRow(model: model, record: record).padding(16).frame(maxWidth: .infinity, alignment: .leading).lifeCard() }
                    }
                }
            }.buttonStyle(.plain).searchable(text: $query, prompt: "搜索全部内容").navigationTitle("搜索")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.frame(minWidth: 320, minHeight: 450)
    }
}

struct ReferenceFields: View {
    let model: AppModel
    let spaceID: UUID?
    let recordID: UUID?
    @Binding var ids: [UUID]?
    var body: some View {
        DisclosureGroup("相关内容 · \(ids?.count ?? 0)") {
            ForEach(model.activeRecords.filter { $0.latest.spaceID == spaceID && $0.id != recordID && $0.body.kind != .comment }) { record in
                Toggle(isOn: Binding(get: { ids?.contains(record.id) == true }, set: { selected in
                    var values = ids ?? []; values.removeAll { $0 == record.id }; if selected { values.append(record.id) }; ids = values.isEmpty ? nil : values
                })) { Label(record.body.title, systemImage: record.body.kind.icon) }
            }
        }
    }
}

struct RelatedResources: View {
    let model: AppModel
    let record: Record
    private var related: [Record] {
        let ids = Set((record.body.referenceIDs ?? []) + record.body.projectIDs + [record.body.parentProjectID, record.body.subscriptionID, record.body.refundOfID].compactMap { $0 })
        return model.activeRecords.filter { $0.id != record.id && $0.latest.spaceID == record.latest.spaceID && (ids.contains($0.id) || $0.body.referenceIDs?.contains(record.id) == true) }
    }
    var body: some View {
        if !related.isEmpty {
            DisclosureGroup("相关内容 · \(related.count)") { ForEach(related) { target in RecordLink(model: model, record: target) { Label(target.body.title, systemImage: target.body.kind.icon).padding(.vertical, 6) } } }
        }
    }
}
