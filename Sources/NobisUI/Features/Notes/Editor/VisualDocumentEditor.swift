import SwiftUI

@MainActor @Observable
final class DocumentBlockBuffer {
    var blocks: [DocumentBlock]
    let undo = UndoManager()
    var emitted: String
    init(_ source: String) { blocks = DocumentBlocks.parse(source); emitted = source }
    func edit(_ id: UUID, _ change: (inout DocumentBlock) -> Void) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        // Bindings may read another field of this block while constructing the update.
        var block = blocks[index]
        change(&block)
        blocks[index] = block
    }
    func replace(_ next: [DocumentBlock], undo: UndoManager?) {
        let old = blocks
        undo?.registerUndo(withTarget: self) { [weak undo] target in target.replace(old, undo: undo) }
        blocks = next
    }
}

/// Text, tables, images and code share one document and the same draft/save pipeline.
struct BlockDocumentEditor: View {
    @Binding var text: String
    var request: RichEditRequest?
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight = 22.0
    @ScaledMetric(relativeTo: .body) private var compactLineHeight = 21.0
    @State private var buffer: DocumentBlockBuffer
    @State private var activeText: String?
    @State private var requestTarget: String?
    @State private var pendingRequest: RichEditRequest?

    init(text: Binding<String>, request: RichEditRequest? = nil) {
        _text = text; self.request = request
        _buffer = State(initialValue: DocumentBlockBuffer(text.wrappedValue))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(buffer.blocks) { block in
                switch block.content {
                case .text(let source):
                    MarkdownTextEditor(text: textBinding(block.id), request: requestTarget == block.id.uuidString ? pendingRequest : nil,
                                       onFocus: { activeText = block.id.uuidString }, sharedUndoManager: buffer.undo)
                        .frame(height: textHeight(source)).frame(maxWidth: .infinity)
                case .code(let language, let body):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                            TextField("语言（可选）", text: Binding(get: { code(block.id).0 }, set: { value in edit(block.id) { $0.content = .code(language: value, body: code(block.id).1) } }))
                                .textFieldStyle(.plain).font(.caption).accessibilityLabel("代码语言")
                            blockMenu(block)
                        }
                        MarkdownTextEditor(text: Binding(get: { code(block.id).1 }, set: { value in edit(block.id) { $0.content = .code(language: code(block.id).0, body: value) } }), onFocus: { activeText = "code:\(block.id)" }, sharedUndoManager: buffer.undo, plainText: true)
                            .frame(height: max(92, min(480, CGFloat(body.components(separatedBy: "\n").count) * compactLineHeight + 24)))
                            .accessibilityLabel(language.isEmpty ? "代码内容" : "\(language) 代码内容")

                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                case .table(let rows, _):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("表格", systemImage: "tablecells").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("添加行") { transformTable(block.id) { rows, _ in rows.append(Array(repeating: "", count: rows.first?.count ?? 2)) } }
                                Button("添加列") { transformTable(block.id) { rows, alignment in for index in rows.indices { rows[index].append("") }; alignment.append("---") } }
                                if rows.count > 1 { Button("删除末行", role: .destructive) { transformTable(block.id) { rows, _ in rows.removeLast() } } }
                                if (rows.first?.count ?? 0) > 1 { Button("删除末列", role: .destructive) { transformTable(block.id) { rows, alignment in for index in rows.indices { rows[index].removeLast() }; if !alignment.isEmpty { alignment.removeLast() } } } }
                            } label: { Image(systemName: "tablecells.badge.ellipsis") }.accessibilityLabel("调整表格")
                            blockMenu(block)
                        }
                        ScrollView(.horizontal) {
                            VStack(spacing: 1) {
                                ForEach(rows.indices, id: \.self) { row in
                                    HStack(spacing: 1) {
                                        ForEach(rows[row].indices, id: \.self) { column in
                                            let key = "\(block.id)-\(row)-\(column)"
                                            MarkdownTextEditor(text: cellBinding(block.id, row, column), request: requestTarget == key ? pendingRequest : nil, onFocus: { activeText = key }, sharedUndoManager: buffer.undo)
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
                        HStack { Label("图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary); Spacer(); blockMenu(block) }
                        if let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 420).accessibilityLabel(alt.isEmpty ? "笔记图片" : alt)
                                case .failure: Label("图片暂时无法加载，可检查或替换地址", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
                                default: ProgressView("正在加载图片").frame(maxWidth: .infinity, minHeight: 100)
                                }
                            }.id(address)
                        } else {
                            Label(address.isEmpty ? "添加图片地址后显示图片" : "请使用 HTTPS 图片地址", systemImage: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
                        }
                        TextField("图片说明", text: imageBinding(block.id, field: 0), axis: .vertical).textFieldStyle(.plain).font(.callout).accessibilityLabel("图片说明")
                        DisclosureGroup("替换图片与设置") {
                            TextField("https://", text: imageBinding(block.id, field: 1)).textFieldStyle(.roundedBorder).accessibilityLabel("图片地址")
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
        .onChange(of: buffer.blocks) { _, blocks in
            let source = blocks.map(\.markdown).joined()
            buffer.emitted = source
            if text != source { text = source }
        }
        .onChange(of: text) { _, source in
            if source != buffer.emitted { buffer.undo.removeAllActions(); buffer.emitted = source; buffer.blocks = DocumentBlocks.parse(source); activeText = nil; pendingRequest = nil; requestTarget = nil }
        }
        .onChange(of: request) { _, request in
            switch request?.action {
            case "insert-table": insert(.table(rows: [["列一", "列二"], ["", ""]], alignment: ["---", "---"]))
            case "insert-image": insert(.image(alt: "", address: "", title: ""))
            case "insert-code": insert(.code(language: "", body: ""))
            default:
                requestTarget = activeText ?? buffer.blocks.first(where: { if case .text = $0.content { true } else { false } })?.id.uuidString
                pendingRequest = request
            }
        }
    }
    private func textHeight(_ text: String) -> CGFloat { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 24 : max(58, min(620, CGFloat(text.components(separatedBy: "\n").count + text.count / 65) * bodyLineHeight + 20)) }
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
    private func insert(_ content: DocumentBlock.Content) {
        var next = buffer.blocks
        // Insert after the focused text block; appending is the predictable fallback.
        let index = next.firstIndex(where: { $0.id.uuidString == activeText }).map { $0 + 1 } ?? next.count
        var insertion = index
        if index > 0, !next[index - 1].markdown.hasSuffix("\n") {
            next.insert(DocumentBlock(.text("\n")), at: insertion); insertion += 1
        }
        next.insert(DocumentBlock(content), at: insertion)
        buffer.replace(next, undo: buffer.undo)
    }
    private func blockMenu(_ block: DocumentBlock) -> some View {
        Menu {
            Button("撤销") { if buffer.undo.canUndo { buffer.undo.undo() } }
            Button("重做") { if buffer.undo.canRedo { buffer.undo.redo() } }
            Divider()
            Button("在下方添加正文") {
                var next = buffer.blocks
                if let index = next.firstIndex(where: { $0.id == block.id }) { next.insert(DocumentBlock(.text("\n")), at: index + 1); buffer.replace(next, undo: buffer.undo) }
            }
            Button("删除此内容", role: .destructive) {
                var next = buffer.blocks.filter { $0.id != block.id }
                if next.isEmpty { next = [DocumentBlock(.text(""))] }
                buffer.replace(next, undo: buffer.undo)
            }
        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("内容操作")
    }
}

struct NoteEditorSelection: Equatable {
    var enabled = true
    var composing = false
    var inTable = false
    var selected: Set<String> = []
    var mixed: Set<String> = []
}

/// Both platforms keep the same Markdown draft and save boundary.
struct VisualDocumentEditor: View {
    @Binding var text: String
    var request: RichEditRequest?
    var preserveSelection = false
    var onSelection: (NoteEditorSelection) -> Void = { _ in }
    var body: some View {
        #if os(macOS)
        MDTextKitEditor(text: $text, request: request, preserveSelection: preserveSelection, onSelection: onSelection)
        #else
        BlockDocumentEditor(text: $text, request: request)
        #endif
    }
}
