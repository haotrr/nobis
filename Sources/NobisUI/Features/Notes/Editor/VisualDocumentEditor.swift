import SwiftUI
import FamilyCore
#if os(iOS)
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
#endif

@MainActor @Observable
final class DocumentBlockBuffer {
    var blocks: [DocumentBlock]
    let undo = UndoManager()
    var focus: NoteEditorFocus?
    var focusRequest: NoteEditorFocus?
    var emitted: String
    init(_ source: String) { blocks = DocumentBlocks.parse(source); emitted = source }
    func edit(_ id: UUID, _ change: (inout DocumentBlock) -> Void) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        // Bindings may read another field of this block while constructing the update.
        var block = blocks[index]
        change(&block)
        blocks[index] = block
    }
    func replace(_ next: [DocumentBlock], undo: UndoManager?, focus nextFocus: NoteEditorFocus? = nil) {
        let old = blocks, oldFocus = focus
        undo?.registerUndo(withTarget: self) { [weak undo] target in target.replace(old, undo: undo, focus: oldFocus) }
        blocks = next
        focus = nextFocus ?? focus
        if let nextFocus { focusRequest = NoteEditorFocus(target: nextFocus.target, range: nextFocus.range) }
    }

    func insert(_ content: DocumentBlock.Content) {
        var next = blocks
        let block = DocumentBlock(content)
        let index = focus.flatMap { focus in next.firstIndex { focus.belongs(to: $0.id) } }
        var insertion = index.map { $0 + 1 } ?? next.count
        if let index, case .text(let text) = next[index].content, let focus {
            // Insert after the selection, preserving its text. Clamp to a Character boundary.
            let start = min(text.utf16.count, max(0, focus.range.location))
            let offset = start + min(text.utf16.count - start, max(0, focus.range.length))
            var boundary = 0
            for character in text {
                let end = boundary + String(character).utf16.count
                if end > offset { break }
                boundary = end
            }
            let source = text as NSString
            var prefix = source.substring(to: boundary)
            if !prefix.isEmpty && !prefix.hasSuffix("\n") { prefix += "\n" }
            next[index].content = .text(prefix)
            let suffix = DocumentBlock(.text(source.substring(from: boundary)))
            next.insert(suffix, at: insertion)
        } else if insertion > 0, !next[insertion - 1].markdown.hasSuffix("\n") {
            next.insert(DocumentBlock(.text("\n")), at: insertion)
            insertion += 1
        }
        next.insert(block, at: insertion)
        let target: String
        switch content {
        case .text: target = block.id.uuidString
        case .code: target = "code:\(block.id)"
        case .table: target = "\(block.id)-0-0"
        case .image: target = "image:\(block.id)"
        }
        replace(next, undo: undo, focus: NoteEditorFocus(target: target))
    }
}

/// Text, tables, images and code share one document and the same draft/save pipeline.
struct BlockDocumentEditor: View {
    @Binding var text: String
    var request: RichEditRequest?
    var onSelection: (NoteEditorSelection) -> Void = { _ in }
    var onFind: () -> Void = {}
    var search: NoteSearchSession
    @State private var imageEditing: DocumentBlock?
    @State private var composing = false
    @ScaledMetric(relativeTo: .body) private var compactLineHeight = 21.0
    @State private var buffer: DocumentBlockBuffer
    @State private var activeText: String?
    @State private var requestTarget: String?
    @State private var pendingRequest: RichEditRequest?
    @FocusState private var imageFocus: String?
    #if os(iOS)
    @State private var showPhotos = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoIssue: String?
    @State private var importingPhoto = false
    @State private var photoFocus: NoteEditorFocus?
    #endif

    init(text: Binding<String>, request: RichEditRequest? = nil, onSelection: @escaping (NoteEditorSelection) -> Void = { _ in }, onFind: @escaping () -> Void = {}, search: NoteSearchSession = NoteSearchSession()) {
        _text = text; self.search = search; self.request = request; self.onSelection = onSelection; self.onFind = onFind
        _buffer = State(initialValue: DocumentBlockBuffer(text.wrappedValue))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(buffer.blocks) { block in
                switch block.content {
                case .text:
                    MarkdownTextEditor(text: textBinding(block.id), request: requestTarget == block.id.uuidString ? pendingRequest : nil,
                                       onFocus: { activeText = block.id.uuidString }, sharedUndoManager: buffer.undo, onFind: onFind, onSelection: { selectionChanged($0, target: block.id.uuidString) },
                                       expandsToContent: true, focusRequest: focusRequest(block.id.uuidString), searchRanges: highlightRanges(block))
                        .frame(maxWidth: .infinity)
                case .code(let language, let body):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                            TextField("语言（可选）", text: Binding(get: { code(block.id).0 }, set: { value in edit(block.id) { $0.content = .code(language: value, body: code(block.id).1) } }))
                                .textFieldStyle(.plain).font(.caption).accessibilityLabel("代码语言")
                            blockMenu(block)
                        }
                        MarkdownTextEditor(text: Binding(get: { code(block.id).1 }, set: { value in edit(block.id) { $0.content = .code(language: code(block.id).0, body: value) } }), onFocus: { activeText = "code:\(block.id)" }, sharedUndoManager: buffer.undo, onFind: onFind, plainText: true, onSelection: { selectionChanged($0, target: "code:\(block.id)") }, focusRequest: focusRequest("code:\(block.id)"), searchRanges: highlightRanges(block))
                            .frame(height: max(92, min(480, CGFloat(body.components(separatedBy: "\n").count) * compactLineHeight + 24)))
                            .accessibilityLabel(language.isEmpty ? "代码内容" : "\(language) 代码内容")

                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                case .table(let rows, _):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("表格", systemImage: "tablecells").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                let cell = buffer.tableCell(block.id)
                                Button("在当前行上方插入") { buffer.changeTable(block.id, action: .rowBefore) }
                                Button("在当前行下方插入") { buffer.changeTable(block.id, action: .rowAfter) }
                                Button("删除当前行", role: .destructive) { buffer.changeTable(block.id, action: .deleteRow) }.disabled(cell.row == 0 || rows.count <= 1)
                                Button("当前行上移") { buffer.changeTable(block.id, action: .rowUp) }.disabled(cell.row <= 1)
                                Button("当前行下移") { buffer.changeTable(block.id, action: .rowDown) }.disabled(cell.row == 0 || cell.row >= rows.count - 1)
                                Divider()
                                Button("在当前列左侧插入") { buffer.changeTable(block.id, action: .columnBefore) }
                                Button("在当前列右侧插入") { buffer.changeTable(block.id, action: .columnAfter) }
                                Button("删除当前列", role: .destructive) { buffer.changeTable(block.id, action: .deleteColumn) }.disabled((rows.first?.count ?? 0) <= 1)
                                Button("当前列左移") { buffer.changeTable(block.id, action: .columnLeft) }.disabled(cell.column == 0)
                                Button("当前列右移") { buffer.changeTable(block.id, action: .columnRight) }.disabled(cell.column >= (rows.first?.count ?? 1) - 1)

                            } label: { Image(systemName: "tablecells.badge.ellipsis") }.accessibilityLabel("调整表格").disabled(composing)
                            blockMenu(block)
                        }
                        ScrollView(.horizontal) {
                            VStack(spacing: 1) {
                                ForEach(rows.indices, id: \.self) { row in
                                    HStack(spacing: 1) {
                                        ForEach(rows[row].indices, id: \.self) { column in
                                            let key = "\(block.id)-\(row)-\(column)"
                                            MarkdownTextEditor(text: cellBinding(block.id, row, column), request: requestTarget == key ? pendingRequest : nil, onFocus: { activeText = key }, sharedUndoManager: buffer.undo, onFind: onFind, inlineOnly: true, onSelection: { selectionChanged($0, target: key) }, focusRequest: focusRequest(key), searchRanges: highlightRanges(block, row: row, column: column))
                                                .frame(width: 180, height: max(44, CGFloat(rows[row][column].components(separatedBy: "\n").count) * compactLineHeight + 16))
                                                .background(row == 0 ? Color.accentColor.opacity(0.08) : Color.clear)
                                                .accessibilityLabel("第 \(row + 1) 行，第 \(column + 1) 列")
                                                .overlay(Rectangle().stroke(.quaternary, lineWidth: 1))
                                        }
                                    }
                                }
                            }.padding(1)
                        }
                    }
                case .image(let alt, let address, let title):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("查看与编辑") { imageEditing = block }.disabled(composing)
                            blockMenu(block)
                        }
                        if address.hasPrefix(NoteEmbeddedImage.prefix) {
                            NoteEmbeddedImageView(address: address, label: alt.isEmpty ? "笔记照片" : alt)
                        } else if let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil {
                            AsyncImage(url: url) { phase in
                                NoteImageViewport(phase: phase, label: alt.isEmpty ? "笔记图片" : alt)
                            }.id(address)
                        } else {
                            NoteImageCanvas {
                                Label(address.isEmpty ? "添加图片地址后显示图片" : "请使用 HTTPS 图片地址", systemImage: "photo").foregroundStyle(.secondary).padding(12)
                            }
                        }
                        TextField("图片说明", text: imageBinding(block.id, field: 0), axis: .vertical).textFieldStyle(.plain).font(.callout).accessibilityLabel("图片说明").focused($imageFocus, equals: "image:\(block.id)")
                        DisclosureGroup("替换图片与设置") {
                            if address.hasPrefix(NoteEmbeddedImage.prefix) {
                                Text("照片已保存在笔记中").foregroundStyle(.secondary)
                            } else {
                                TextField("https://", text: imageBinding(block.id, field: 1)).textFieldStyle(.roundedBorder).accessibilityLabel("图片地址")
                            }
                            TextField("图片标题（可选）", text: imageBinding(block.id, field: 2)).textFieldStyle(.roundedBorder)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    .help(title.isEmpty ? alt : title)
                }
            }
            if case .text = buffer.blocks.last?.content { } else {
                Button("继续写正文", systemImage: "text.cursor") { insert(.text("\n")) }.buttonStyle(.borderless)
            }
        }
        .sheet(item: $imageEditing) { block in
            if case .image(let alt, let address, let title) = block.content {
                NoteImageInspector(content: NoteImageContent(alt: alt, address: address, title: title), apply: { replacement in
                    try buffer.replaceImage(block, with: replacement)
                }, close: { imageEditing = nil })
            }
        }
        #if os(iOS)
        .disabled(importingPhoto)
        .photosPicker(isPresented: $showPhotos, selection: $selectedPhoto, matching: .images)
        .overlay(alignment: .top) {
            if importingPhoto {
                HStack { ProgressView("正在添加照片…"); Button("取消") { selectedPhoto = nil } }
                    .padding(12).background(.regularMaterial, in: Capsule())
            }
        }
        .alert("照片未添加", isPresented: Binding(get: { photoIssue != nil }, set: { if !$0 { photoIssue = nil } })) {
            Button("好", role: .cancel) { photoIssue = nil }
        } message: { Text(photoIssue ?? "") }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            importingPhoto = true
            defer { importingPhoto = false }
            do {
                guard let photo = try await selectedPhoto.loadTransferable(type: NotePickedPhoto.self) else { throw NoteEmbeddedImage.ImportError.invalid }
                guard !Task.isCancelled else { return }
                try DocumentContentLimits.validate(text + "\n" + DocumentBlock(.image(alt: "照片", address: photo.address, title: "")).markdown)
                buffer.focus = photoFocus
                insert(.image(alt: "照片", address: photo.address, title: ""))
            } catch {
                if !Task.isCancelled { photoIssue = error.localizedDescription }
            }
        }
        #endif
        .onChange(of: buffer.focusRequest) { _, focus in
            if let focus, focus.target.hasPrefix("image:") { imageFocus = focus.target }
        }
        .onChange(of: imageFocus) { _, target in
            if let target { buffer.focus = NoteEditorFocus(target: target); activeText = target }
        }
        .onChange(of: buffer.blocks) { _, blocks in
            let source = blocks.map(\.markdown).joined()
            buffer.emitted = source
            if text != source { text = source }
        }
        .onChange(of: text) { _, source in
            if source != buffer.emitted { buffer.undo.removeAllActions(); buffer.emitted = source; buffer.blocks = DocumentBlocks.parse(source); activeText = nil; pendingRequest = nil; requestTarget = nil }
        }
        .onChange(of: request) { _, request in
            guard !composing else { return }
            if let plan = request?.replacement {
                do {
                    let next = try plan.applying(to: buffer.blocks)
                    buffer.undo.beginUndoGrouping()
                    buffer.replace(next, undo: buffer.undo)
                    buffer.undo.endUndoGrouping()
                    search.didReplace(plan, text: next.map(\.markdown).joined())
                } catch { search.issue = error.localizedDescription }
                return
            }
            if let match = request?.match, buffer.blocks.indices.contains(match.block) {
                let block = buffer.blocks[match.block]
                guard match.isValid(in: block) else { return }
                let target: String
                if let row = match.row, let column = match.column { target = "\(block.id)-\(row)-\(column)" }
                else if case .code = block.content { target = "code:\(block.id)" }
                else { target = block.id.uuidString }
                activeText = target
                buffer.focusRequest = NoteEditorFocus(target: target, range: match.range)
                return
            }
            switch request?.action {
            case "insert-table": insert(.table(rows: [["列一", "列二"], ["", ""]], alignment: ["---", "---"]))
            #if os(iOS)
            case "insert-photo":
                guard !importingPhoto else { return }
                photoFocus = buffer.focus
                selectedPhoto = nil
                showPhotos = true
            #endif
            case "insert-image": insert(.image(alt: "", address: "", title: ""))
            case "insert-code": insert(.code(language: "", body: ""))
            default:
                requestTarget = activeText ?? buffer.blocks.first(where: { if case .text = $0.content { true } else { false } })?.id.uuidString
                pendingRequest = request
            }
        }
    }
    private func highlightRanges(_ block: DocumentBlock, row: Int? = nil, column: Int? = nil) -> [NSRange] {
        guard let index = buffer.blocks.firstIndex(where: { $0.id == block.id }) else { return [] }
        guard search.isPresented else { return [] }
        return search.matches.filter { $0.block == index && $0.row == row && $0.column == column && $0.isValid(in: block) }.flatMap { $0.segments ?? [$0.range] }
    }
    private func selectionChanged(_ state: NoteEditorSelection, target: String) {
        composing = state.composing
        if activeText == target { buffer.focus = NoteEditorFocus(target: target, range: state.range) }
        onSelection(state)
    }
    private func focusRequest(_ target: String) -> NoteEditorFocus? {
        buffer.focusRequest?.target == target ? buffer.focusRequest : nil
    }
    private func edit(_ id: UUID, _ change: (inout DocumentBlock) -> Void) { buffer.edit(id, change) }
    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { if case .text(let value) = buffer.blocks.first(where: { $0.id == id })?.content { value } else { "" } },
                set: { value in edit(id) { $0.content = .text(value) } })
    }
    private func code(_ id: UUID) -> (String, String) {
        if case .code(let language, let body) = buffer.blocks.first(where: { $0.id == id })?.content { return (language, body) }; return ("", "")
    }
    private func cellBinding(_ id: UUID, _ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: {
            if case .table(let rows, _) = buffer.blocks.first(where: { $0.id == id })?.content, rows.indices.contains(row), rows[row].indices.contains(column) { return rows[row][column] }; return ""
        }, set: { value in edit(id) { block in
            if case .table(var rows, let alignment) = block.content, rows.indices.contains(row), rows[row].indices.contains(column) { rows[row][column] = value; block.content = .table(rows: rows, alignment: alignment) }
        } })
    }
    private func imageBinding(_ id: UUID, field: Int) -> Binding<String> {
        Binding(get: { if case .image(let alt, let address, let title) = buffer.blocks.first(where: { $0.id == id })?.content { return [alt, address, title][field] }; return "" }, set: { value in
            edit(id) { block in if case .image(let alt, let address, let title) = block.content {
                var fields = [alt, address, title]; fields[field] = value; block.content = .image(alt: fields[0], address: fields[1], title: fields[2])
            } }
        })
    }
    private func transformTable(_ id: UUID, _ change: (inout [[String]], inout [String]) -> Void) {
        var next = buffer.blocks
        guard let index = next.firstIndex(where: { $0.id == id }), case .table(var rows, var alignment) = next[index].content else { return }
        change(&rows, &alignment); next[index].content = .table(rows: rows, alignment: alignment)
        buffer.replace(next, undo: buffer.undo)
    }
    private func insert(_ content: DocumentBlock.Content) { buffer.insert(content) }
    private func blockMenu(_ block: DocumentBlock) -> some View {
        Menu {
            Button("撤销") { if buffer.undo.canUndo { buffer.undo.undo() } }
            Button("重做") { if buffer.undo.canRedo { buffer.undo.redo() } }
            Divider()
            Button("在下方添加正文") {
                var next = buffer.blocks
                if let index = next.firstIndex(where: { $0.id == block.id }) {
                    let text = DocumentBlock(.text("\n"))
                    next.insert(text, at: index + 1)
                    buffer.replace(next, undo: buffer.undo, focus: NoteEditorFocus(target: text.id.uuidString))
                }
            }
            Button("删除此内容", role: .destructive) {
                var next = buffer.blocks.filter { $0.id != block.id }
                if next.isEmpty { next = [DocumentBlock(.text(""))] }
                buffer.replace(next, undo: buffer.undo)
            }
        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("内容操作").disabled(composing)
    }
}

struct NoteEditorFocus: Equatable {
    let id = UUID()
    let target: String
    var range = NSRange(location: 0, length: 0)
    func belongs(to block: UUID) -> Bool {
        target == block.uuidString || target == "code:\(block)" || target == "image:\(block)" || target.hasPrefix("\(block)-")
    }
}

struct NoteEditorSelection: Equatable {
    var range = NSRange(location: 0, length: 0)
    var enabled = true
    var composing = false
    var inTable = false
    var selected: Set<String> = []
    var mixed: Set<String> = []
}

/// Both platforms keep the same Markdown draft and search scope.
struct VisualDocumentEditor: View {
    @Binding var text: String
    var request: RichEditRequest?
    var preserveSelection = false
    var onSelection: (NoteEditorSelection) -> Void = { _ in }
    var search: NoteSearchSession = NoteSearchSession()
    @State private var forwardedRequest: RichEditRequest?
    var body: some View {
        Group {
            #if os(macOS)
            MDTextKitEditor(text: $text, request: forwardedRequest, preserveSelection: preserveSelection || search.isPresented, onSelection: selectionChanged, onFind: { search.open() }, search: search)
            #else
            BlockDocumentEditor(text: $text, request: forwardedRequest, onSelection: selectionChanged, onFind: { search.open() }, search: search)
            #endif
        }
        .onChange(of: request) { _, value in
            forwardedRequest = value
            search.request = nil
            if value?.action == "show-find" { search.open() }
        }
        .onChange(of: search.request) { _, value in
            if let value { forwardedRequest = value }
        }
        .onChange(of: search.isPresented) { _, visible in
            if !visible { forwardedRequest = nil }
        }
        .onChange(of: text) { _, value in search.refresh(in: value) }
        .onAppear { search.refresh(in: text); forwardedRequest = search.request ?? request }
    }
    private func selectionChanged(_ selection: NoteEditorSelection) {
        search.composing = selection.composing
        onSelection(selection)
    }
}

#if os(iOS)
struct NotePickedPhoto: Transferable, Sendable {
    let address: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let address = try await Task.detached(priority: .userInitiated) { try NoteEmbeddedImage.importFile(url) }.value
            return NotePickedPhoto(address: address)
        }
    }
}
#endif
