import Foundation
import FamilyCore
import PolarMark

struct NoteSearchMatch: Equatable {
    var block: Int
    var row: Int?
    var column: Int?
    var range: NSRange
    var source: String
    var segments: [NSRange]? = nil
    var plainText = false
    func isValid(in block: DocumentBlock) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= source.utf16.count else { return false }
        switch block.content {
        case .text(let value), .code(_, let value): return row == nil && column == nil && value == source
        case .table(let rows, _):
            guard let row, let column, rows.indices.contains(row), rows[row].indices.contains(column) else { return false }
            return rows[row][column] == source
        case .image: return false
        }
    }
}

enum NoteDocumentSearch {
    static func matches(in blocks: [DocumentBlock], query: String, caseSensitive: Bool = false) -> [NoteSearchMatch] {
        guard !query.isEmpty else { return [] }
        var result: [NoteSearchMatch] = []
        func append(_ value: String, block: Int, row: Int? = nil, column: Int? = nil, plainText: Bool = false) {
            let projection = NoteSearchProjection(value, plainText: plainText)
            let source = projection.text as NSString
            var offset = 0
            while offset < source.length {
                let range = source.range(of: query, options: caseSensitive ? [] : [.caseInsensitive], range: NSRange(location: offset, length: source.length - offset))
                guard range.location != NSNotFound else { break }
                let segments = projection.segments(for: range)
                if let first = segments.first, let last = segments.last {
                    let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                    result.append(NoteSearchMatch(block: block, row: row, column: column, range: span, source: value, segments: segments, plainText: plainText))
                }
                offset = NSMaxRange(range)
            }
        }
        for (index, block) in blocks.enumerated() {
            switch block.content {
            case .text(let value): append(value, block: index)
            case .code(_, let value): append(value, block: index, plainText: true)
            case .table(let rows, _):
                for (r, cells) in rows.enumerated() { for (c, value) in cells.enumerated() { append(value, block: index, row: r, column: c) } }
            case .image: break // Do not search embedded binary data or hidden image URLs.
            }
        }
        return result
    }
}

/// Visible UTF-16 positions mapped back to editable Markdown. Syntax and link URLs
/// never become hits; inline formatting may divide one visible match into segments.
struct NoteSearchProjection {
    let text: String
    let offsets: [Int]
    init(_ source: String, plainText: Bool) {
        let units = Array(source.utf16)
        var hidden = Set<Int>()
        if !plainText {
            PMKAST(markdown: source).rootNode.walk { node in
                var ranges = node.markerRanges
                if node.type == .link {
                    ranges += [NSRange(location: node.range.location, length: node.contentRange.location - node.range.location),
                               NSRange(location: NSMaxRange(node.contentRange), length: NSMaxRange(node.range) - NSMaxRange(node.contentRange))]
                }
                for range in ranges where range.location >= 0 && NSMaxRange(range) <= units.count {
                    hidden.formUnion(range.location..<NSMaxRange(range))
                }
            }
        }
        offsets = units.indices.filter { !hidden.contains($0) }
        text = String(decoding: offsets.map { units[$0] }, as: UTF16.self)
    }
    func segments(for range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        for offset in offsets[range.location..<NSMaxRange(range)] {
            if let last = result.last, NSMaxRange(last) == offset { result[result.count - 1].length += 1 }
            else { result.append(NSRange(location: offset, length: 1)) }
        }
        return result
    }
}

import SwiftUI

struct NoteSearchReplacement: Equatable {
    let source: String
    let matches: [NoteSearchMatch]
    let replacement: String

    func applying(to blocks: [DocumentBlock]) throws -> [DocumentBlock] {
        guard blocks.map(\.markdown).joined() == source else { throw NoteImageEditError.changed }
        var next = blocks
        for (index, hits) in Dictionary(grouping: matches, by: \.block) {
            guard next.indices.contains(index) else { throw NoteImageEditError.changed }
            switch next[index].content {
            case .text(let value): next[index].content = .text(try replacing(value, hits: hits))
            case .code(let language, let value): next[index].content = .code(language: language, body: try replacing(value, hits: hits))
            case .table(var rows, let alignment):
                for hit in hits {
                    guard let row = hit.row, let column = hit.column, rows.indices.contains(row), rows[row].indices.contains(column) else { throw NoteImageEditError.changed }
                }
                for row in rows.indices { for column in rows[row].indices {
                    let cellHits = hits.filter { $0.row == row && $0.column == column }
                    if !cellHits.isEmpty { rows[row][column] = try replacing(rows[row][column], hits: cellHits) }
                } }
                next[index].content = .table(rows: rows, alignment: alignment)
            case .image: throw NoteImageEditError.changed
            }
        }
        try DocumentContentLimits.validate(next.map(\.markdown).joined())
        return next
    }

    private func replacing(_ value: String, hits: [NoteSearchMatch]) throws -> String {
        let length = value.utf16.count
        var edits: [(range: NSRange, value: String)] = []
        var covered = Set<Int>(), starts = Set<Int>()
        for hit in hits {
            guard hit.source == value else { throw NoteImageEditError.changed }
            let segments = hit.segments ?? [hit.range]
            for (index, range) in segments.enumerated() {
                guard range.location >= 0, NSMaxRange(range) <= length else { throw NoteImageEditError.changed }
                edits.append((range, index == 0 ? replacement : ""))
                covered.formUnion(range.location..<NSMaxRange(range))
            }
            if let first = segments.first { starts.insert(first.location) }
        }
        if hits.first?.plainText != true {
            let visible = NoteSearchProjection(value, plainText: false).offsets
            var markers: [NSRange] = []
            PMKAST(markdown: value).rootNode.walk { node in
                guard [.strong, .emphasis, .strikethrough, .underline, .highlighter, .code, .link].contains(node.type) else { return }
                let positions = visible.filter { NSLocationInRange($0, node.contentRange) }
                guard !positions.isEmpty, positions.allSatisfy({ covered.contains($0) }),
                      replacement.isEmpty || !starts.contains(where: { NSLocationInRange($0, node.contentRange) }) else { return }
                markers += node.markerRanges
                if node.type == .link {
                    markers += [NSRange(location: node.range.location, length: node.contentRange.location - node.range.location),
                                NSRange(location: NSMaxRange(node.contentRange), length: NSMaxRange(node.range) - NSMaxRange(node.contentRange))]
                }
            }
            var merged: [NSRange] = []
            for range in markers.sorted(by: { $0.location < $1.location }) where range.length > 0 {
                if let last = merged.last, NSMaxRange(last) >= range.location { merged[merged.count - 1] = NSUnionRange(last, range) }
                else { merged.append(range) }
            }
            edits += merged.map { ($0, "") }
        }
        let result = NSMutableString(string: value)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { result.replaceCharacters(in: edit.range, with: edit.value) }
        return result as String
    }

}

@MainActor @Observable
final class NoteSearchSession {
    var isPresented = false
    var query = ""
    var replacement = ""
    var showsReplacement = false
    var caseSensitive = false
    var index = -1
    var composing = false
    var issue: String?
    var request: RichEditRequest?
    var focusToken = UUID()
    private var snapshot = ""
    private var lastQuery = ""
    private var lastCaseSensitive = false
    var matches: [NoteSearchMatch] = []
    func refresh(in text: String) {
        guard snapshot != text || lastQuery != query || lastCaseSensitive != caseSensitive else { return }
        snapshot = text; lastQuery = query; lastCaseSensitive = caseSensitive
        matches = NoteDocumentSearch.matches(in: DocumentBlocks.parse(text), query: query, caseSensitive: caseSensitive)
        // Editing invalidates the selected hit. Never report an old ordinal for new results.
        index = -1
        if request?.match != nil { request = nil }
        issue = nil
    }
    func open() { guard !composing else { return }; isPresented = true; focusToken = UUID() }
    func close() { isPresented = false; request = nil; index = -1 }
    func navigate(_ delta: Int, in text: String) {
        refresh(in: text)
        guard !matches.isEmpty, !composing else { return }
        index = index < 0 ? (delta > 0 ? 0 : matches.count - 1) : (index + delta + matches.count) % matches.count
        request = RichEditRequest(action: "find-match", match: matches[index])
    }
    func replace(all: Bool, in text: String) {
        refresh(in: text)
        guard !matches.isEmpty, !composing else { return }
        if index < 0 { index = 0 }
        let plan = NoteSearchReplacement(source: text, matches: all ? matches : [matches[index]], replacement: replacement)
        do {
            _ = try plan.applying(to: DocumentBlocks.parse(text))
            request = RichEditRequest(action: "replace-matches", replacement: plan)
        } catch { issue = error.localizedDescription }
    }
    func didReplace(_ plan: NoteSearchReplacement, text: String) {
        refresh(in: text)
        request = nil
        guard plan.matches.count == 1, let previous = plan.matches.first, !matches.isEmpty else { return }
        let boundary = previous.range.location + plan.replacement.utf16.count
        index = matches.firstIndex { hit in
            if hit.block != previous.block { return hit.block > previous.block }
            if hit.row != previous.row { return (hit.row ?? 0) > (previous.row ?? 0) }
            if hit.column != previous.column { return (hit.column ?? 0) > (previous.column ?? 0) }
            return hit.range.location >= boundary
        } ?? 0
        request = RichEditRequest(action: "find-match", match: matches[index])
    }
    func ranges(in block: Int, row: Int? = nil, column: Int? = nil) -> [NSRange] {
        guard isPresented else { return [] }
        return matches.filter { $0.block == block && $0.row == row && $0.column == column }.flatMap { $0.segments ?? [$0.range] }
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
    private var matches: [NoteSearchMatch] { session.matches }
    var body: some View {
        VStack(spacing: 6) {
            TextField("查找正文、表格和代码", text: $session.query).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { session.navigate(1, in: text) }
                #if os(macOS)
                .onExitCommand { session.close(); focused = false }
                #endif
            if session.showsReplacement {
                TextField("替换为（留空表示删除）", text: $session.replacement).textFieldStyle(.roundedBorder)
                HStack {
                    Button { session.replace(all: false, in: text) } label: { NoteToolbarLabel(title: "替换当前") }
                    Button { session.replace(all: true, in: text) } label: { NoteToolbarLabel(title: "全部替换") }
                    Spacer()
                }.noteToolbarControls().disabled(matches.isEmpty || session.composing)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    resultCount.fixedSize()
                    Spacer(minLength: 8)
                    navigationControls
                }
                VStack(alignment: .leading, spacing: 4) {
                    resultCount
                    ScrollView(.horizontal) { navigationControls }
                        .scrollIndicators(.hidden)
                }
            }
            if let issue = session.issue { Text(issue).font(.caption).foregroundStyle(.red) }

        }
        .background(.background)
        .onAppear { session.refresh(in: text); focused = true }
        .onChange(of: session.focusToken) { _, _ in focused = true }
        .onChange(of: session.query) { _, _ in session.refresh(in: text) }
        .onChange(of: session.caseSensitive) { _, _ in session.refresh(in: text) }
        .onChange(of: text) { _, _ in session.refresh(in: text) }
    }
    private var resultCount: some View {
        Text(session.query.isEmpty ? "输入查找内容" : matches.isEmpty ? "无匹配" : (session.index < 0 ? "共 \(matches.count) 处" : "\(session.index + 1) / \(matches.count)"))
            .font(.caption).foregroundStyle(countColor).accessibilityLabel("查找结果")
    }
    private var navigationControls: some View {
        HStack(spacing: 4) {
            Button { session.navigate(-1, in: text) } label: { NoteToolbarLabel(symbol: "chevron.up") }
                .accessibilityLabel("上一个匹配").help("上一个匹配")
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(matches.isEmpty || session.composing)
            Button { session.navigate(1, in: text) } label: { NoteToolbarLabel(symbol: "chevron.down") }
                .accessibilityLabel("下一个匹配").help("下一个匹配")
                .keyboardShortcut("g").disabled(matches.isEmpty || session.composing)
            Menu {
                Toggle("显示替换", isOn: $session.showsReplacement)
                Toggle("区分大小写", isOn: $session.caseSensitive)
            } label: { NoteToolbarLabel(symbol: "ellipsis.circle", menu: true) }.accessibilityLabel("查找选项")
            Button { session.close(); focused = false } label: { NoteToolbarLabel(title: "完成") }
        }.noteToolbarControls().fixedSize(horizontal: true, vertical: true)
    }

}
