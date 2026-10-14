import Foundation

struct NoteSearchMatch: Equatable {
    var block: Int
    var row: Int?
    var column: Int?
    var range: NSRange
    var source: String
}

enum NoteDocumentSearch {
    static func matches(in blocks: [DocumentBlock], query: String) -> [NoteSearchMatch] {
        guard !query.isEmpty else { return [] }
        var result: [NoteSearchMatch] = []
        func append(_ value: String, block: Int, row: Int? = nil, column: Int? = nil) {
            let source = value as NSString
            var offset = 0
            while offset < source.length {
                let range = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: offset, length: source.length - offset))
                guard range.location != NSNotFound else { break }
                result.append(NoteSearchMatch(block: block, row: row, column: column, range: range, source: value))
                offset = NSMaxRange(range)
            }
        }
        for (index, block) in blocks.enumerated() {
            switch block.content {
            case .text(let value): append(value, block: index)
            case .code(_, let value): append(value, block: index)
            case .table(let rows, _):
                for (r, cells) in rows.enumerated() { for (c, value) in cells.enumerated() { append(value, block: index, row: r, column: c) } }
            case .image: break // Do not search embedded binary data or hidden image URLs.
            }
        }
        return result
    }
}

import SwiftUI

@MainActor @Observable
final class NoteSearchSession {
    var isPresented = false
    var query = ""
    var index = -1
    var composing = false
    var request: RichEditRequest?
    var focusToken = UUID()
    func open() { guard !composing else { return }; isPresented = true; focusToken = UUID() }
    func navigate(_ delta: Int, in text: String) {
        let matches = NoteDocumentSearch.matches(in: DocumentBlocks.parse(text), query: query)
        guard !matches.isEmpty, !composing else { return }
        index = index < 0 ? (delta > 0 ? 0 : matches.count - 1) : (index + delta + matches.count) % matches.count
        request = RichEditRequest(action: "find-match", match: matches[index])
    }
}

struct NoteDocumentSearchBar: View {
    private var countColor: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }
    @Bindable var session: NoteSearchSession
    var text: String
    @FocusState private var focused: Bool
    private var matches: [NoteSearchMatch] { NoteDocumentSearch.matches(in: DocumentBlocks.parse(text), query: session.query) }
    var body: some View {
        VStack(spacing: 6) {
            TextField("查找正文、表格和代码", text: $session.query).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { session.navigate(1, in: text) }
            HStack {
                Text(session.query.isEmpty ? "输入查找内容" : matches.isEmpty ? "无匹配" : "\(max(0, session.index + 1)) / \(matches.count)")
                    .font(.caption).foregroundStyle(countColor).accessibilityLabel("查找结果")
                Spacer()
                Button("上一个", systemImage: "chevron.up") { session.navigate(-1, in: text) }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).help("上一个匹配")
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(matches.isEmpty || session.composing)
                Button("下一个", systemImage: "chevron.down") { session.navigate(1, in: text) }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).help("下一个匹配")
                    .keyboardShortcut("g").disabled(matches.isEmpty || session.composing)
                Button("完成") { session.isPresented = false; focused = false }
            }.buttonStyle(.borderless)
        }
        .background(.background)
        .onAppear { focused = true }
        .onChange(of: session.focusToken) { _, _ in focused = true }
        .onChange(of: session.query) { _, _ in session.index = -1 }
    }
}
