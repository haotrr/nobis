import SwiftUI
import UniformTypeIdentifiers
import FamilyDomain
import FamilyCore

struct DocumentsView: View {
    @Bindable var model: AppModel
    private var scope: LifeScope { model.noteScope }
    @State private var group = ""
    @State private var pinnedOnly = false
    @State private var search = ""
    @State private var archived = false
    @State private var creating = false
    @State private var deleting: Record?
    @AppStorage("notes.sortOrder") private var sortOrder = "modifiedDescending"
    private var documents: [Record] {
        model.records(in: scope).filter {
            $0.body.kind == .document && (group.isEmpty || (group == "ungrouped" ? ($0.body.noteGroup ?? "").isEmpty : "group:" + ($0.body.noteGroup ?? "") == group)) && (!pinnedOnly || $0.body.isPinned == true) && (archived || $0.body.status != .archived) &&
            (search.isEmpty || $0.body.title.localizedCaseInsensitiveContains(search) || $0.body.notes.localizedCaseInsensitiveContains(search))
        }.sorted {
            if ($0.body.isPinned == true) != ($1.body.isPinned == true) { return $0.body.isPinned == true }
            if sortOrder == "title" {
                let comparison = $0.body.title.localizedStandardCompare($1.body.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            } else if $0.latest.createdAt != $1.latest.createdAt {
                return sortOrder == "modifiedAscending" ? $0.latest.createdAt < $1.latest.createdAt : $0.latest.createdAt > $1.latest.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var body: some View {
        LifePage {
            LifeScopeControls(scope: $model.noteScope, archived: $archived, archivedTitle: "显示归档")
            LifeAdaptiveRow {
            Picker("分组", selection: $group) {
                Text("全部").tag(""); Text("未分组").tag("ungrouped")
                ForEach(Array(Set(model.records(in: scope).filter { $0.body.kind == .document }.compactMap { $0.body.noteGroup }.filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag("group:" + $0) }
            }.pickerStyle(.menu)
            Toggle(isOn: $pinnedOnly) { Label("置顶", systemImage: "pin") }
                .toggleStyle(.button).help("只看置顶笔记")
            sortPicker
            Text("\(documents.count) 篇").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
            LazyVStack(spacing: 16) {
            if documents.isEmpty {
                WorkspaceEmptyState(title: search.isEmpty ? "还没有笔记" : "没有匹配的笔记",
                    icon: search.isEmpty ? "doc.text" : "magnifyingglass",
                    message: search.isEmpty ? "记下想法，也留给彼此补充。" : "试试其他关键词或可见范围。",
                    actionTitle: search.isEmpty ? "新建笔记" : "清除搜索") {
                        if search.isEmpty { creating = true } else { search = "" }
                    }
            }
            ForEach(documents) { document in
                NavigationLink { DocumentDetail(model: model, documentID: document.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if document.body.isPinned == true { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            Text(document.body.title).font(.headline).lineLimit(2)
                            if model.unreadComments(for: document.id) > 0 { Label("\(model.unreadComments(for: document.id))", systemImage: "bubble.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("有未读评注") }
                            if document.conflicted { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                        documentExcerpt(document.body.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                ResourceOwnership(model: model, spaceID: document.latest.spaceID)
                                Spacer(minLength: 12)
                                Text(document.latest.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                ResourceOwnership(model: model, spaceID: document.latest.spaceID)
                                Text(document.latest.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
                }.buttonStyle(.plain)
                    .contextMenu { managementMenu(document) }
            }
            }
        }
        .confirmationDialog("将笔记移入回收站？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { document in
            Button("移入回收站", role: .destructive) {
                model.perform { try model.save(document.body, spaceID: document.latest.spaceID, existing: document, deleted: true) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { document in
            Text("“\(document.body.title)”及其评注可从回收站恢复。")
        }
        .onChange(of: scope) { _, _ in group = "" }
        .navigationTitle("笔记")
        .searchable(text: $search, prompt: "搜索标题和正文")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Label("新建笔记", systemImage: "plus") }.keyboardShortcut("n").help("新建笔记（⌘N）") } }
        .navigationDestination(isPresented: $creating) { DocumentEditor(model: model, group: group.hasPrefix("group:") ? String(group.dropFirst(6)) : nil, embedded: true).navigationTitle("新建笔记") }
    }
    private var sortPicker: some View {
        Picker("排序", selection: $sortOrder) {
            Text("最近修改优先").tag("modifiedDescending")
            Text("最早修改优先").tag("modifiedAscending")
            Text("标题 A–Z").tag("title")
        }.pickerStyle(.menu).help("置顶笔记始终排在前面")
    }

    @ViewBuilder private func managementMenu(_ document: Record) -> some View {
        let writable = !document.conflicted && model.canWrite(spaceID: document.latest.spaceID)
        Button(document.body.isPinned == true ? "取消置顶" : "置顶笔记", systemImage: "pin") {
            update(document) { $0.isPinned = !($0.isPinned ?? false) }
        }.disabled(!writable)
        Menu {
            Button("无项目", systemImage: document.body.projectIDs.isEmpty ? "checkmark" : "folder") {
                update(document) { $0.projectIDs = [] }
            }.disabled(document.body.projectIDs.isEmpty)
            Divider()
            let projects = model.activeRecords.filter {
                $0.body.kind == .project && $0.latest.spaceID == document.latest.spaceID && $0.body.status != .archived && !$0.conflicted
            }.sorted { $0.body.title.localizedStandardCompare($1.body.title) == .orderedAscending }
            if projects.isEmpty { Text("此可见范围内没有可用项目") }
            ForEach(projects) { project in
                Button(project.body.title, systemImage: document.body.projectIDs.contains(project.id) ? "checkmark" : "folder") {
                    update(document) { $0.projectIDs = [project.id] }
                }.disabled(document.body.projectIDs == [project.id])
            }
        } label: { Label("移动到项目", systemImage: "folder") }
            .disabled(!writable)
        Button(document.body.status == .archived ? "取消归档" : "归档", systemImage: "archivebox") {
            model.changeStatus(document, to: document.body.status == .archived ? .active : .archived)
        }.disabled(!writable)
        Divider()
        sortPicker
        Divider()
        Button("移入回收站", systemImage: "trash", role: .destructive) { deleting = document }
            .disabled(!writable)
    }

    private func update(_ document: Record, change: (inout RecordBody) -> Void) {
        guard !document.conflicted, model.canWrite(spaceID: document.latest.spaceID) else { return }
        var body = document.body
        change(&body)
        model.perform { try model.save(body, spaceID: document.latest.spaceID, existing: document) }
    }
}

private struct CommentDestination: Identifiable {
    let id = UUID()
    let reply: Record?
    var quote: String = ""
}

struct DocumentDetail: View {
    let model: AppModel
    let documentID: UUID
    var checklistLine: Int? = nil
    @State private var showComments = false
    @State private var showResolved = false
    @State private var composer: CommentDestination?
    @State private var deleting = false
    @State private var exporting = false
    @State private var selectingQuote = false
    private var document: Record? { model.activeRecords.first { $0.id == documentID } }
    private var comments: [Record] {
        guard let document else { return [] }
        let all = model.activeRecords.filter { $0.latest.spaceID == document.latest.spaceID && $0.body.kind == .comment }
        let roots = Set(all.filter { $0.body.relatedRecordID == documentID }.map(\.id))
        return all.filter { $0.body.relatedRecordID == documentID || $0.body.relatedRecordID.map(roots.contains) == true }
            .sorted { $0.latest.createdAt < $1.latest.createdAt }
    }
    private var roots: [Record] { comments.filter { $0.body.relatedRecordID == documentID } }
    private var unresolved: [Record] { roots.filter { $0.body.status != .completed || $0.conflicted } }
    private var resolved: [Record] { roots.filter { $0.body.status == .completed && !$0.conflicted } }
    var body: some View {
        Group {
            if let document {
                GeometryReader { geometry in
                    if geometry.size.width >= 820 {
                        HStack(alignment: .top, spacing: 0) {
                            editorOrReader(document).frame(maxWidth: .infinity, maxHeight: .infinity)
                            if showComments {
                                Divider()
                                ScrollViewReader { proxy in
                                    ScrollView { commentsPane(document).padding(20) }
                                        .onChange(of: composer?.id) { _, _ in proxy.scrollTo("comment-composer", anchor: .top) }
                                        .onChange(of: selectingQuote) { _, open in if open { proxy.scrollTo("quote-selector", anchor: .top) } }
                                }.frame(width: 320).background { LifeBackground() }
                            }
                        }
                    } else if !showComments {
                        editorOrReader(document)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    if writable(document) {
                                        DocumentEditor(model: model, existing: document, embedded: true, onFinish: nil)
                                            .id(documentID).frame(height: max(440, geometry.size.height * 0.75))
                                    } else { readingContent(document) }
                                    if showComments {
                                        Divider()
                                        commentsPane(document).padding(20).id("comments-panel")
                                    }
                                }
                            }.background { LifeBackground() }
                                .onAppear { if let checklistLine { proxy.scrollTo("checklist-\(checklistLine)", anchor: .center) } }
                                .onChange(of: showComments) { _, open in if open { proxy.scrollTo("comments-panel", anchor: .top) } }
                                .onChange(of: composer?.id) { _, _ in proxy.scrollTo("comment-composer", anchor: .top) }
                                .onChange(of: selectingQuote) { _, open in if open { proxy.scrollTo("quote-selector", anchor: .top) } }
                        }
                    }
                }
                .navigationTitle(document.body.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { showComments.toggle() } label: {
                            Label(showComments ? "收起评注" : "评注", systemImage: "text.bubble")
                        }.help(showComments ? "收起评注，保留草稿" : "显示评注")
                        Menu {
                            if writable(document) {
                                Button("添加评注", systemImage: "text.bubble") { beginComment() }
                                Button("引用原文评注", systemImage: "text.quote") { showComments = true; selectingQuote = true }
                                if writable(document) {
                                    Button(document.body.isPinned == true ? "取消置顶" : "置顶笔记", systemImage: "pin") { model.perform { var body = document.body; body.isPinned = !(body.isPinned ?? false); try model.save(body, spaceID: document.latest.spaceID, existing: document) } }
                                    Button(document.body.status == .archived ? "取消归档" : "归档", systemImage: "archivebox") { model.changeStatus(document, to: document.body.status == .archived ? .active : .archived) }
                                }
                            }
                            Button("导出 Markdown", systemImage: "square.and.arrow.up") { exporting = true }.keyboardShortcut("s", modifiers: [.command, .shift])
                            NavigationLink { RecordDetail(model: model, recordID: document.id) } label: { Label("笔记信息与历史", systemImage: "info.circle") }
                            if writable(document) {
                                Button("移入回收站", systemImage: "trash", role: .destructive) { deleting = true }
                            }
                        } label: { Label("更多", systemImage: "ellipsis.circle") }.help("笔记操作")
                    }
                }
                .fileExporter(isPresented: $exporting, document: MarkdownDocument(text: document.body.notes), contentType: UTType(filenameExtension: "md") ?? .plainText, defaultFilename: document.body.title + ".md") { result in
                    if case .failure(let error) = result { model.error = error.localizedDescription }
                }
                .onChange(of: showComments) { _, open in if open { model.markCommentsRead(comments) } }
                .onChange(of: comments.map { $0.latest.id }) { _, _ in if showComments { model.markCommentsRead(comments) } }
                .confirmationDialog("将笔记移入回收站？", isPresented: $deleting) {
                    Button("移入回收站", role: .destructive) { model.perform { try model.save(document.body, spaceID: document.latest.spaceID, existing: document, deleted: true) } }
                } message: { Text("笔记和评注可以从回收站恢复。") }
            } else { ContentUnavailableView("笔记不可用", systemImage: "doc.text") }
        }
    }
    private func beginComment(reply: Record? = nil, quote: String = "") {
        showComments = true; selectingQuote = false
        composer = CommentDestination(reply: reply, quote: quote)
    }
    @ViewBuilder private func editorOrReader(_ document: Record) -> some View {
        if writable(document) { DocumentEditor(model: model, existing: document, embedded: true, onFinish: nil).id(documentID) }
        else {
            ScrollViewReader { proxy in
                ScrollView { readingContent(document) }.background { LifeBackground() }
                    .onAppear { if let checklistLine { proxy.scrollTo("checklist-\(checklistLine)", anchor: .center) } }
            }
        }
    }
    private func readingContent(_ document: Record) -> some View {
VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(document.body.title).font(.title.bold()).textSelection(.enabled)
                        ResourceOwnership(model: model, spaceID: document.latest.spaceID, detailed: true)
                        RecordCreator(model: model, record: document)
                        Text("最后编辑：\(model.space(for: document)?.members.first { $0.id == document.latest.actorID }?.name ?? "历史成员") · \(document.latest.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        if document.body.status == .archived { Label("已归档", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
                    }
                    if document.conflicted {
                        Label("有多个正文版本待核对", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        NavigationLink("比较版本") { RecordDetail(model: model, recordID: document.id) }
                    }
                    if document.body.notes.isEmpty { Text("暂无正文").foregroundStyle(.secondary) }
                    else {
                        MarkdownPreview(source: document.body.notes, highlightedLine: checklistLine, onToggle: writable(document) ? { line in
                            guard let notes = MarkdownBlock.togglingTask(in: document.body.notes, line: line) else { return }
                            var body = document.body; body.notes = notes
                            model.perform { try model.save(body, spaceID: document.latest.spaceID, existing: document) }
                        } : nil).lineSpacing(4).id(document.latest.id)
                    }
                    RelatedResources(model: model, record: document)
                    Button { showComments = true } label: { Label("评注 · \(roots.count)", systemImage: "text.bubble") }.buttonStyle(.borderless)
                }.padding(24).frame(maxWidth: 760, alignment: .leading).lifeCard().padding(20).frame(maxWidth: .infinity)
    }
    private func commentsPane(_ document: Record) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("评注 · \(unresolved.count)").font(.headline)
                Spacer()
                if writable(document) { Button { beginComment() } label: { Label("添加评注", systemImage: "plus.bubble") }.buttonStyle(.borderless) }
            }
            if selectingQuote {
                QuoteSelectionSheet(source: document.body.notes, embedded: true, onCancel: { selectingQuote = false }) { quote in beginComment(quote: quote) }.id("quote-selector")
            }
            if let destination = composer, writable(document) {
                DocumentCommentEditor(model: model, document: document, reply: destination.reply, initialQuote: destination.quote, onClose: { composer = nil }) { composer = nil }
                    .id(destination.id).id("comment-composer")
                Divider()
            }
            if roots.isEmpty && composer == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有评注").font(.callout.weight(.medium))
                    Text("补充想法，或引用一段原文展开讨论。").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            ForEach(unresolved) { thread($0, document: document) }
            if !resolved.isEmpty {
                DisclosureGroup("已解决 · \(resolved.count)", isExpanded: $showResolved) {
                    ForEach(resolved) { thread($0, document: document).padding(.top, 12) }
                }.font(.callout)
            }
        }
    }
    private func writable(_ document: Record) -> Bool { !document.conflicted && model.canWrite(spaceID: document.latest.spaceID) }
    private func thread(_ root: Record, document: Record) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            commentRow(root, document: document)
            ForEach(comments.filter { $0.body.relatedRecordID == root.id }) { reply in
                commentRow(reply, document: document).padding(.leading, 16)
            }
            if writable(document) && !root.conflicted {
                HStack {
                    if root.body.status == .active {
                        Button("回复") { beginComment(reply: root) }.touchTarget()
                    }
                    Spacer()
                    Button(root.body.status == .completed ? "重新打开" : "标记已解决") {
                        model.changeStatus(root, to: root.body.status == .completed ? .active : .completed)
                    }.touchTarget()
                }.font(.callout).buttonStyle(.borderless)
            }
            Divider()
        }
    }
    private func commentRow(_ comment: Record, document: Record) -> some View {
        let original = (try? model.core?.history(comment.id, spaceID: comment.latest.spaceID))?.last ?? comment.latest
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { author(original, document: document); timestamp(original) }
                VStack(alignment: .leading, spacing: 4) { author(original, document: document); timestamp(original) }
            }
            if let quote = comment.body.documentQuote {
                Text("“\(quote)”").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(comment.body.notes).textSelection(.enabled)
            if comment.conflicted { NavigationLink("核对评注状态") { RecordDetail(model: model, recordID: comment.id) } }
        }
    }
    private func author(_ revision: Revision, document: Record) -> some View {
        MemberIdentityBadge(name: model.space(for: document)?.members.first { $0.id == revision.actorID }?.name ?? "历史成员 · \(revision.actorID.uuidString.prefix(4))", identity: revision.actorID.uuidString, avatarData: model.space(for: document)?.members.first { $0.id == revision.actorID }?.avatarData)
    }
    private func timestamp(_ revision: Revision) -> some View {
        Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
    }
}

private struct DocumentCommentEditor: View {
    let model: AppModel
    let document: Record
    let reply: Record?
    let initialQuote: String
    let onClose: () -> Void
    let onPosted: () -> Void
    @State private var message = ""
    @State private var quote = ""
    @State private var showQuote = false
    @State private var issue: String?
    @State private var loaded = false
    @State private var writableDraft = false
    @State private var commentID = UUID()
    @State private var draftStatus = ""
    private var store: DocumentDraftStore { DocumentDraftStore(directory: model.directory.appendingPathComponent("CommentDrafts")) }
    private var key: UUID { reply?.id ?? document.id }
    private var dirty: Bool { !message.isEmpty || !quote.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reply { Text("回复：\(reply.body.notes)").font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            TextField(reply == nil ? "写下评注" : "写下回复", text: $message, axis: .vertical)
                .lineLimit(4...12).textFieldStyle(.roundedBorder)
            if reply == nil {
                DisclosureGroup("引用原文（可选）", isExpanded: $showQuote) {
                    TextField("粘贴要讨论的正文片段", text: $quote, axis: .vertical).lineLimit(2...6)
                    Text("引用已保存的原文，保留当时的文字。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !draftStatus.isEmpty { Text(draftStatus).font(.caption).foregroundStyle(.secondary) }
            if let issue { InlineIssue(message: issue) }
            HStack {
                Button("收起") { if dirty { persist(); if draftStatus == "草稿已保存在此设备" { onClose() } } else { onClose() } }
                    .help("收起输入，保留尚未发布的草稿")
                Spacer()
                Button(reply == nil ? "发布评注" : "发布回复", action: post)
                    .lifePrimaryAction().keyboardShortcut(.return, modifiers: .command)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !writableDraft)
            }.buttonStyle(.borderless)
        }
        .onAppear {
            guard !loaded else { return }; loaded = true
            do {
                if let draft = try store.read(key) {
                    message = draft.body.notes
                    quote = initialQuote.isEmpty ? draft.body.documentQuote ?? "" : initialQuote
                    commentID = draft.recordID ?? commentID
                } else { quote = initialQuote }
                showQuote = !quote.isEmpty; writableDraft = true
                if dirty { persist() }
            } catch { issue = error.localizedDescription; draftStatus = "草稿读取失败，未覆盖原草稿" }
        }
        .onChange(of: message) { _, _ in persist() }
        .onChange(of: quote) { _, _ in persist() }
    }
    private func persist() {
        guard loaded, writableDraft, model.spaces.contains(where: { $0.id == document.latest.spaceID }), model.canWrite(spaceID: document.latest.spaceID) else { return }
        if !dirty { do { try store.remove(key); draftStatus = "" } catch { issue = error.localizedDescription }; return }
        var body = RecordBody(kind: .comment, title: "评注")
        body.notes = message; body.documentQuote = quote.isEmpty ? nil : quote; body.relatedRecordID = key
        do { try store.save(DocumentDraft(body: body, spaceID: document.latest.spaceID, recordID: commentID, expected: []), key: key); draftStatus = "草稿已保存在此设备" }
        catch { issue = error.localizedDescription; draftStatus = "草稿保存失败，请保留此窗口" }
    }
    private func post() {
        var body = RecordBody(kind: .comment, title: "评注")
        body.notes = message; body.relatedRecordID = reply?.id ?? document.id
        body.documentQuote = reply == nil && !quote.isEmpty ? quote : nil
        do {
            guard writableDraft else { throw NobisError.validation("请先重新打开评注草稿。") }
            try model.save(body, spaceID: document.latest.spaceID, recordID: commentID)
            do { try store.remove(key) } catch { model.error = "评注已发布，但旧草稿清理失败：" + error.localizedDescription }
            onPosted()
        } catch { issue = error.localizedDescription }
    }
}

struct DocumentEditor: View {
    let model: AppModel
    @State private var existing: Record?
    @Environment(\.dismiss) private var dismiss
    @State private var value: RecordBody
    @State private var spaceID: UUID?
    @State private var showInfo = false
    @State private var showHelp = false
    @State private var formatRequest: RichEditRequest?
    @State private var editorSelection = NoteEditorSelection()
    @State private var showLink = false
    @State private var linkURL = ""
    @State private var issue: String?
    @State private var discard = false
    @State private var initial: RecordBody
    @State private var initialSpaceID: UUID?
    @State private var expected: Set<UUID> = []
    @State private var savedRecordID = UUID()
    @State private var draftStatus = "尚未修改"
    @State private var draftLoaded = false
    @State private var draftWritable = false
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase
    private let embedded: Bool
    private let onFinish: (() -> Void)?
    private let creationProject: Record?
    private var draftKey: UUID? { existing?.id ?? creationProject?.id ?? initialSpaceID }
    init(model: AppModel, existing: Record? = nil, project: Record? = nil, group: String? = nil, embedded: Bool = false, onFinish: (() -> Void)? = nil) {
        self.embedded = embedded; self.onFinish = onFinish
        self.creationProject = project
        self.model = model; _existing = State(initialValue: existing)
        _draftStatus = State(initialValue: existing == nil ? "尚未保存" : "所有修改已保存")
        var body = existing?.body ?? RecordBody(kind: .document, title: "")
        if existing == nil { body.noteGroup = group }
        if let project, existing == nil { body.projectIDs = [project.id] }
        _initial = State(initialValue: body); _value = State(initialValue: body)
        let space = existing?.latest.spaceID ?? project?.latest.spaceID ?? model.selectedSpaceID
        _initialSpaceID = State(initialValue: space); _spaceID = State(initialValue: space)
    }
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var keyboardVisible = false
    @FocusState private var titleFocused: Bool
    private var compactHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact || (keyboardVisible && textSize.isAccessibilitySize)
        #else
        false
        #endif
    }
    private var dirty: Bool { value != initial || spaceID != initialSpaceID }
    private var projectName: String { model.activeRecords.first { $0.id == value.projectIDs.first }?.body.title ?? "无项目" }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("标题", text: $value.title, prompt: Text("标题").foregroundColor(.gray), axis: .vertical).focused($titleFocused).font(.title2.weight(.semibold)).textFieldStyle(.plain).lineLimit(1...3)
                    #if os(iOS)
                    if !compactHeight || showInfo {
                    DisclosureGroup("归属与项目", isExpanded: $showInfo) {
                        VStack(alignment: .leading, spacing: 12) {
                            if existing == nil && creationProject == nil {
                                RecordVisibilityField(model: model, spaceID: Binding(get: { spaceID }, set: { spaceID = $0; value.projectIDs = []; value.referenceIDs = nil }), editable: true)
                            } else if let spaceID {
                                ResourceOwnership(model: model, spaceID: spaceID)
                            }
                            LifePicker("所属项目", selection: Binding(get: { value.projectIDs.first }, set: { value.projectIDs = $0.map { [$0] } ?? [] })) {
                                Text("无").tag(Optional<UUID>.none)
                                ForEach(model.activeRecords.filter { $0.body.kind == .project && $0.latest.spaceID == spaceID }) { Text($0.body.title).tag(Optional($0.id)) }
                            }
                            LifeTextField("笔记分组（可选）", text: Binding(get: { value.noteGroup ?? "" }, set: { value.noteGroup = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder)
                            Toggle("置顶笔记", isOn: Binding(get: { value.isPinned ?? false }, set: { value.isPinned = $0 }))
                            ReferenceFields(model: model, spaceID: spaceID, recordID: existing?.id, ids: $value.referenceIDs)
                        }.padding(.top, 8)
                    }.font(.callout).multilineTextAlignment(.leading)
                    }
                    #else
                    VStack(alignment: .leading, spacing: 12) {
                        if existing == nil && creationProject == nil {
                            RecordVisibilityField(model: model, spaceID: Binding(get: { spaceID }, set: { spaceID = $0; value.projectIDs = []; value.referenceIDs = nil }), editable: true)
                        } else if let spaceID {
                            ResourceOwnership(model: model, spaceID: spaceID)
                        }
                        DisclosureGroup(isExpanded: $showInfo) {
                            LifePicker("所属项目", selection: Binding(get: { value.projectIDs.first }, set: { value.projectIDs = $0.map { [$0] } ?? [] })) {
                                Text("无").tag(Optional<UUID>.none)
                                ForEach(model.activeRecords.filter { $0.body.kind == .project && $0.latest.spaceID == spaceID }) { Text($0.body.title).tag(Optional($0.id)) }
                            }.padding(.top, 8)
                            TextField("笔记分组（可选）", text: Binding(get: { value.noteGroup ?? "" }, set: { value.noteGroup = $0.isEmpty ? nil : $0 }))
                            Toggle("置顶笔记", isOn: Binding(get: { value.isPinned ?? false }, set: { value.isPinned = $0 }))
                            ReferenceFields(model: model, spaceID: spaceID, recordID: existing?.id, ids: $value.referenceIDs)
                        } label: { Text("所属项目 · \(projectName)").font(.callout).foregroundStyle(.secondary) }
                    }
                    #endif
                    VisualDocumentEditor(text: $value.notes, request: formatRequest, preserveSelection: showLink, onSelection: { editorSelection = $0 })
                        .frame(minHeight: max(220, geometry.size.height - 240), alignment: .top)
                        .id("note-body")

                }.padding(.horizontal, geometry.size.width < 500 ? 16 : 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .lifeCard().padding(20)
                    .frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
                .background { LifeBackground() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !compactHeight {
                        formattingBar(width: geometry.size.width).padding(.horizontal, 16)
                            .padding(.vertical, 8).background(.regularMaterial)
                    }
                }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if compactHeight && !titleFocused && !showInfo { scroll.scrollTo("note-body", anchor: .top) }
            }
            #endif
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if !embedded { EditorHeading(kind: .document, editing: existing != nil) } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !compactHeight {
            VStack(spacing: 0) {
                if let issue { InlineIssue(message: issue).padding(.horizontal, 24).padding(.top, 8) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { saveStatus; Spacer(minLength: 8); saveActions }
                    VStack(alignment: .leading, spacing: 8) {
                        saveStatus
                        HStack { Spacer(); saveActions }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }.background(.regularMaterial)
            } else if let issue {
                InlineIssue(message: issue).padding(8).background(.regularMaterial)
            }
        }
        #if os(iOS)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { if compactHeight {
            ToolbarItem(placement: .topBarTrailing) { Button(dirty ? "关闭" : "完成", action: cancel) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存", action: save).lifePrimaryAction().disabled(!(existing == nil || dirty) || value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } }
        #endif
        .interactiveDismissDisabled(dirty)
        .confirmationDialog("关闭笔记？", isPresented: $discard) {
            Button("保留草稿并关闭") { persistDraft(); if draftStatus == "草稿已保存在此设备" { finish() } }
            Button("放弃修改", role: .destructive) { do { if let draftKey { try model.draftStore.remove(draftKey) }; draftWritable = false; finish() } catch { issue = error.localizedDescription } }
            Button("继续编辑", role: .cancel) { }
        }
        .onAppear(perform: restoreDraft)
        .onChange(of: value) { _, _ in persistDraft() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { persistDraft() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: MarkdownDocument.readableContentTypes) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 200_000 else { throw NobisError.validation("文件过大，请选择不超过 20,000 字的 Markdown 笔记。") }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.count <= 20_000 else { throw NobisError.validation("笔记正文不能超过 20,000 字。") }
                // Import appends to a nonempty draft, preserving the text already entered.
                value.notes += (value.notes.isEmpty ? "" : "\n\n") + text
                if value.title.isEmpty { value.title = url.deletingPathExtension().lastPathComponent }
            } catch { issue = error.localizedDescription }
        }
        .onChange(of: spaceID) { _, _ in persistDraft() }
        .editorDimensions(width: 680, height: 600, embedded: embedded)
    }
    private var saveStatus: some View {
        Label(draftStatus, systemImage: dirty ? "pencil.line" : "checkmark.circle")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var saveActions: some View {
        HStack(spacing: 12) {
            Button(dirty ? "关闭" : "完成", action: cancel).keyboardShortcut(.cancelAction)
            Button("保存", action: save).keyboardShortcut("s").lifePrimaryAction()
                .disabled(!(existing == nil || dirty) || value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.fixedSize()
    }
    private var blockFormattingDisabled: Bool { !editorSelection.enabled || editorSelection.composing || editorSelection.inTable }
    private func formatButton(_ title: String, action: String) -> some View {
        Button { formatRequest = RichEditRequest(action: action) } label: {
            Label(title, systemImage: editorSelection.mixed.contains(action) ? "minus" : editorSelection.selected.contains(action) ? "checkmark" : "circle")
        }.disabled(!editorSelection.enabled || editorSelection.composing || (editorSelection.inTable && ["heading", "body", "list"].contains(action)))
    }
    private func formattingBar(width: CGFloat) -> some View {
                    ScrollView(.horizontal) {
                    HStack {
                        Menu {
                            formatButton("标题", action: "heading")
                            formatButton("正文", action: "body")
                            formatButton("粗体", action: "bold")
                            formatButton("斜体", action: "italic")
                            formatButton("项目列表", action: "list")
                        } label: { Image(systemName: "textformat").touchTarget() }.help("文字格式").accessibilityLabel("文字格式")
                        Button { showLink = true } label: { Image(systemName: "link").touchTarget() }
                            .disabled(!editorSelection.enabled || editorSelection.composing).help("选中文字后添加链接").keyboardShortcut("k")
                            .popover(isPresented: $showLink) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("选中文字的链接").font(.headline)
                                    TextField("https://", text: $linkURL).textFieldStyle(.roundedBorder)
                                    Button("应用") { formatRequest = RichEditRequest(action: "link:" + linkURL); showLink = false }
                                }.padding(20).frame(width: 300).background { LifeBackground() }
                            }
                        Button { formatRequest = RichEditRequest(action: "checklist") } label: { Image(systemName: "checklist").touchTarget() }.disabled(blockFormattingDisabled).tint(editorSelection.selected.contains("checklist") ? Color.accentColor : nil).help("转为清单").accessibilityLabel("转为清单")
                        Button { formatRequest = RichEditRequest(action: "toggle") } label: { Image(systemName: "checkmark.circle").touchTarget() }.disabled(blockFormattingDisabled).help("切换当前清单完成状态").accessibilityLabel("切换清单完成状态")
                        Menu {
                            Button("表格", systemImage: "tablecells") { formatRequest = RichEditRequest(action: "insert-table") }
                            Button("图片", systemImage: "photo") { formatRequest = RichEditRequest(action: "insert-image") }
                            Button("代码块", systemImage: "chevron.left.forwardslash.chevron.right") { formatRequest = RichEditRequest(action: "insert-code") }
                        } label: { Image(systemName: "plus").touchTarget() }.disabled(blockFormattingDisabled).accessibilityLabel("插入内容")
                        Spacer()
                        Button { importing = true } label: { Image(systemName: "square.and.arrow.down").touchTarget() }
                            .buttonStyle(.borderless).keyboardShortcut("o")
                            .accessibilityLabel("导入 Markdown 文件").help("导入 Markdown（⌘O）")
                        Button { showHelp = true } label: { Image(systemName: "questionmark.circle").touchTarget() }
                            .buttonStyle(.borderless).accessibilityLabel("Markdown 与快捷键").help("写作帮助")
                            .popover(isPresented: $showHelp) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text("写作帮助").font(.headline)
                                        Text("直接编辑排版后的正文，选中文字后使用格式快捷键。").font(.callout)
                                        Text("快捷键").font(.subheadline.weight(.semibold))
                                        Text("⌘S 保存并继续编辑\n⌘B 粗体 · ⌘I 斜体 · ⌘K 链接\n⌘F 查找正文\n⌘G / ⇧⌘G 下一个 / 上一个（Mac）\n⌘O 导入 Markdown\nEsc 关闭（有修改时确认）\n撤销、重做、剪切、复制、粘贴和全选沿用系统快捷键。").font(.callout).textSelection(.enabled)
                                        Divider()
                                        Text("常用语法").font(.subheadline.weight(.semibold))
                                        Text("# 标题\n**粗体**  *斜体*\n- 列表\n- [ ] 待办\n> 引用\n[文字](https://example.com)\n```\n代码块\n```").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        Button("完成") { showHelp = false }.nobisGlassButton()
                                    }.padding(24)
                                }.frame(idealWidth: 320, idealHeight: 360).background { LifeBackground() }
                            }
                    }.frame(minWidth: max(0, width - 32))
                    }.scrollIndicators(.hidden)
    }
    private func restoreDraft() {
        guard !draftLoaded else { return }; draftLoaded = true
        expected = Set(existing?.heads.map(\.id) ?? [])
        do {
            if let draftKey, let draft = try model.draftStore.read(draftKey) {
                guard model.spaces.contains(where: { $0.id == draft.spaceID }), model.canWrite(spaceID: draft.spaceID) else { throw NobisError.forbidden }
                value = draft.body; spaceID = draft.spaceID; expected = draft.expected; savedRecordID = draft.recordID ?? savedRecordID
                draftStatus = "已恢复此设备的草稿，尚未发布"
                if existing != nil && expected != Set(existing!.heads.map(\.id)) { issue = "正文已有新版本。草稿已保留，请复制需要的内容并与最新版本核对；保存不会覆盖新版本。" }
            }
            draftWritable = true
        } catch { issue = error.localizedDescription; draftStatus = "草稿读取失败，未覆盖原草稿" }
    }
    private func persistDraft() {
        guard draftLoaded, draftWritable, let spaceID, let draftKey else { return }
        if !dirty { do { try model.draftStore.remove(draftKey); draftStatus = existing == nil ? "尚未保存" : "所有修改已保存" } catch { issue = error.localizedDescription }; return }
        guard model.spaces.contains(where: { $0.id == spaceID }), model.canWrite(spaceID: spaceID) else { draftStatus = "访问已关闭，草稿未写入"; return }
        do {
            try model.draftStore.save(DocumentDraft(body: value, spaceID: spaceID, recordID: existing?.id ?? savedRecordID, expected: expected), key: draftKey)
            draftStatus = "草稿已保存在此设备"
        } catch { issue = error.localizedDescription; draftStatus = "草稿保存失败，请保留此窗口" }
    }
    private func finish() { if let onFinish { onFinish() } else { dismiss() } }
    private func cancel() { if dirty { discard = true } else { finish() } }
    private func save() {
        guard let spaceID else { issue = "请选择可见范围。"; return }
        do {
            guard draftWritable else { throw NobisError.validation("草稿尚未成功读取，请重新打开编辑器。") }
            try model.save(value, spaceID: spaceID, existing: existing, expected: expected, recordID: existing?.id ?? savedRecordID)
            if let draftKey { do { try model.draftStore.remove(draftKey) } catch { model.error = "笔记已保存，但旧草稿清理失败：" + error.localizedDescription } }
            let id = existing?.id ?? savedRecordID
            existing = try model.core?.record(id, spaceID: spaceID)
            expected = Set(existing?.heads.map(\.id) ?? [])
            initial = value; initialSpaceID = spaceID
            issue = nil; draftStatus = "笔记已保存在此设备"
        }
        catch { issue = error.localizedDescription }
    }
}

/// A compact reading excerpt instead of raw Markdown syntax in the navigation list.
private func documentExcerpt(_ source: String) -> some View {
    var result = Text("")
    var spoken = ""
    var remaining = 180
    for block in MarkdownBlock.parse(source) {
        let content: String
        var checked: Bool?
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text), .list(_, let text): content = text
        case .task(_, let completed, let text):
            checked = completed
            content = text
        case .table(let rows): content = rows.first?.joined(separator: " · ") ?? ""
        case .image(let alt, _): content = alt.isEmpty ? "图片" : alt
        case .code: content = "代码片段"
        case .divider: continue
        }
        guard !content.isEmpty, remaining > 0 else { continue }
        let separator = spoken.isEmpty ? "" : "  "
        let text = String(content.prefix(remaining))
        remaining -= text.count + separator.count + (checked == nil ? 0 : 2)
        var inline = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        inline.link = nil
        if let checked {
            let symbol = Image(systemName: checked ? "checkmark.square" : "square")
            result = Text("\(result)\(separator)\(symbol) \(Text(inline))")
            spoken += separator + (checked ? "已完成：" : "未完成：") + String(inline.characters)
        } else {
            result = Text("\(result)\(separator)\(Text(inline))")
            spoken += separator + String(inline.characters)
        }
    }
    return (spoken.isEmpty ? Text("暂无正文") : result)
        .accessibilityLabel(spoken.isEmpty ? "暂无正文" : spoken)
}
