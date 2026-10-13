import SwiftUI
import FamilyCore
import FamilyDomain

struct ProjectWorkspace: View {
    let model: AppModel
    let projectID: UUID
    @State private var create: RecordKind?
    @State private var note = false
    @State private var addingExisting = false
    @State private var archiving = false
    private var project: Record? { model.activeRecords.first { $0.id == projectID } }
    private var children: [Record] { model.activeRecords.filter { $0.body.parentProjectID == projectID } }
    private var content: [Record] {
        let ids = Set([projectID] + children.map(\.id))
        return model.activeRecords.filter { !ids.isDisjoint(with: $0.body.projectIDs) }
    }
    private var unfinished: Int { content.filter { $0.body.kind == .task && $0.body.status == .active }.count + NoteChecklistItem.items(in: content).count }
    var body: some View {
        Group {
            if let project {
                LifeDetail {
                    LifeSection(title: "项目概览", icon: "square.stack.3d.up") {
                        ResourceOwnership(model: model, spaceID: project.latest.spaceID, detailed: true)
                        if !project.body.notes.isEmpty { Text(project.body.notes).foregroundStyle(.secondary) }
                        HStack {
                            Label("\(unfinished) 项未完成", systemImage: "checklist")
                            Spacer()
                            Text(project.body.status.title).foregroundStyle(.secondary)
                        }.font(.callout)
                        NavigationLink("项目信息与预算") { RecordDetail(model: model, recordID: projectID) }
                    }
                    LifeSection(title: "待办", icon: "checklist") {
                        let tasks = content.filter { $0.body.kind == .task && $0.body.status == .active }
                        ForEach(tasks) { TaskRow(model: model, record: $0) }
                        ForEach(NoteChecklistItem.items(in: content)) { NoteChecklistRow(model: model, item: $0) }
                        if unfinished == 0 { Text("没有未完成事项").foregroundStyle(.secondary) }
                    }
                    let events = content.filter { $0.body.kind == .event && $0.body.status == .active }
                    if !events.isEmpty {
                        LifeSection(title: "日程", icon: "calendar") {
                            ForEach(events.sorted { ($0.body.startAt ?? $0.body.date?.date() ?? .distantFuture) < ($1.body.startAt ?? $1.body.date?.date() ?? .distantFuture) }) { row($0) }
                        }
                    }
                    LifeSection(title: "笔记", icon: "doc.text") {
                        ForEach(content.filter { $0.body.kind == .document && $0.body.status != .archived }) { row($0) }
                        Button("新建项目笔记", systemImage: "square.and.pencil") { note = true }.disabled(!model.canWrite(spaceID: project.latest.spaceID))
                    }
                    ProjectBudgetSummary(model: model, record: project, allowsManagement: false)
                    let finances = content.filter { [.transaction, .subscription].contains($0.body.kind) && $0.body.status != .voided }
                    if !finances.isEmpty {
                        LifeSection(title: "费用与订阅", icon: "creditcard") {
                            ForEach(finances) { row($0) }
                        }
                    }
                    if !children.isEmpty { LifeSection(title: "子项目", icon: "folder") { ForEach(children) { row($0) } } }
                    RelatedResources(model: model, record: project)
                }.navigationTitle(project.body.title)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("新建笔记") { note = true }
                                Button("新建待办") { create = .task }
                                Button("新建日程") { create = .event }
                                Button("记一笔") { create = .transaction }
                                Button("记录订阅") { create = .subscription }
                                if project.body.parentProjectID == nil { Button("新建子项目") { create = .project } }
                                Button("加入已有内容") { addingExisting = true }
                                Divider()
                                Button(project.body.isPinned == true ? "取消置顶" : "置顶项目") { model.perform { var body = project.body; body.isPinned = !(body.isPinned ?? false); try model.save(body, spaceID: project.latest.spaceID, existing: project) } }
                                Button(project.body.status == .archived ? "恢复项目" : "归档项目") {
                                    if project.body.status == .archived { model.changeStatus(project, to: .active) }
                                    else { archiving = true }
                                }
                            } label: { Label("项目操作", systemImage: "ellipsis.circle") }.disabled(!model.canWrite(spaceID: project.latest.spaceID) || project.conflicted)
                        }
                    }
                    .confirmationDialog("归档项目？", isPresented: $archiving, titleVisibility: .visible) {
                        Button("归档项目") { model.changeStatus(project, to: .archived) }
                    } message: { Text("还有 \(unfinished) 项未完成事项。归档仅收起项目，待办和笔记清单仍保留，费用不变。") }
                    .navigationDestination(isPresented: $note) { DocumentEditor(model: model, project: project, embedded: true).navigationTitle("新建项目笔记") }
                    .sheet(item: $create) { RecordEditor(model: model, kind: $0, project: project) }
                    .sheet(isPresented: $addingExisting) { AddProjectContent(model: model, project: project) }
            } else { ContentUnavailableView("项目不可用", systemImage: "folder.badge.questionmark") }
        }
    }
    private func row(_ record: Record) -> some View { RecordLink(model: model, record: record) { RecordRow(model: model, record: record) }.buttonStyle(.plain) }
}

private struct AddProjectContent: View {
    let model: AppModel
    let project: Record
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            LifeDetail {
                Text("加入同一可见范围内尚无项目的内容。已有项目的内容可在编辑页调整所属项目。").font(.callout).foregroundStyle(.secondary)
                if let issue { InlineIssue(message: issue) }
                ForEach(WorkspaceQuery.search(search, in: model.activeRecords).filter { $0.latest.spaceID == project.latest.spaceID && $0.body.projectIDs.isEmpty && [.document, .task, .event, .transaction, .subscription].contains($0.body.kind) && !$0.conflicted }) { record in
                    Button {
                        do { var body = record.body; body.projectIDs = [project.id]; try model.save(body, spaceID: record.latest.spaceID, existing: record); dismiss() }
                        catch { issue = error.localizedDescription }
                    } label: { Label(record.body.title, systemImage: record.body.kind.icon).padding(16).frame(maxWidth: .infinity, alignment: .leading).lifeCard() }.buttonStyle(.plain)
                }
            }.searchable(text: $search).navigationTitle("加入\(project.body.title)")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.frame(minWidth: 320, minHeight: 400)
    }
}
