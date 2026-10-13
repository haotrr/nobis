import Foundation

/// Visual blocks retain their original spelling until edited. Newlines are part of each
/// block, so converting one table never rewrites unrelated checklist line numbers.
struct DocumentBlock: Identifiable, Equatable {
    enum Content: Equatable {
        case text(String)
        case code(language: String, body: String)
        case table(rows: [[String]], alignment: [String])
        case image(alt: String, address: String, title: String)
    }
    let id: UUID
    var content: Content
    private var original: String?
    private var initial: Content?
    var trailingNewline: Bool

    init(_ content: Content, original: String? = nil, trailingNewline: Bool = true) {
        id = UUID(); self.content = content; self.original = original
        initial = original == nil ? nil : content; self.trailingNewline = trailingNewline
    }
    var markdown: String {
        if content == initial, let original { return original }
        let ending = trailingNewline ? "\n" : ""
        switch content {
        case .text(let text): return text
        case .code(let language, let body):
            // A longer fence keeps literal fences inside code inert.
            let runs = body.components(separatedBy: .newlines).map { $0.prefix(while: { $0 == "`" }).count }
            let fence = String(repeating: "`", count: max(3, (runs.max() ?? 0) + 1))
            let cleanLanguage = language.replacingOccurrences(of: "`", with: "").components(separatedBy: .newlines).joined(separator: " ")
            return fence + cleanLanguage + "\n" + body + (body.isEmpty ? "" : "\n") + fence + ending
        case .table(let rows, let alignment):
            guard let header = rows.first else { return "" }
            func row(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
            let separator = header.indices.map { index in alignment.indices.contains(index) ? alignment[index] : "---" }
            return ([row(header), row(separator)] + rows.dropFirst().map(row)).joined(separator: "\n") + ending
        case .image(let alt, let address, let title):
            let label = alt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
            let url = address.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: "\n", with: "")
            let caption = title.isEmpty ? "" : " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\""
            return "![" + label + "](<" + url + ">" + caption + ")" + ending
        }
    }
}

enum DocumentBlocks {
    static func parse(_ source: String) -> [DocumentBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [DocumentBlock] = [], text = "", index = 0
        func raw(_ start: Int, _ end: Int) -> String { lines[start..<end].joined(separator: "\n") + (end < lines.count ? "\n" : "") }
        func flush() { if !text.isEmpty { result.append(DocumentBlock(.text(text), original: text)); text = "" } }
        while index < lines.count {
            let line = lines[index]
            if let fence = openingFence(line) {
                flush()
                let start = index; index += 1; let bodyStart = index
                while index < lines.count && !closes(lines[index], fence: fence.marker) { index += 1 }
                let code = lines[bodyStart..<index].joined(separator: "\n")
                if index < lines.count { index += 1 }
                result.append(DocumentBlock(.code(language: fence.language, body: code), original: raw(start, index), trailingNewline: index < lines.count))
            } else if index + 1 < lines.count, let header = cells(line), let separator = cells(lines[index + 1]),
                      header.count == separator.count, separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                flush(); let start = index; var rows = [header]; index += 2
                while index < lines.count, let row = cells(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    // Preserve extra cells rather than silently truncating an irregular table.
                    rows.append(row); index += 1
                }
                let width = rows.map(\.count).max() ?? header.count
                rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
                let alignment = separator + Array(repeating: "---", count: width - separator.count)
                result.append(DocumentBlock(.table(rows: rows, alignment: alignment), original: raw(start, index), trailingNewline: index < lines.count))
            } else if let image = image(line.trimmingCharacters(in: .whitespaces)) {
                flush(); result.append(DocumentBlock(.image(alt: image.alt, address: image.address, title: image.title), original: raw(index, index + 1), trailingNewline: index + 1 < lines.count)); index += 1
            } else {
                // Images in a paragraph become visual blocks too; surrounding text stays editable.
                let ns = line as NSString
                let matches = (try? NSRegularExpression(pattern: #"!\[(?:\\.|[^\]])*\]\((?:[^()]|\([^()]*\))*\)"#))?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? []
                var offset = 0
                for match in matches {
                    let spelling = ns.substring(with: match.range)
                    guard let image = image(spelling) else { continue }
                    text += ns.substring(with: NSRange(location: offset, length: match.range.location - offset)); flush()
                    result.append(DocumentBlock(.image(alt: image.alt, address: image.address, title: image.title), original: spelling, trailingNewline: false))
                    offset = NSMaxRange(match.range)
                }
                text += ns.substring(from: offset) + (index + 1 < lines.count ? "\n" : ""); index += 1
            }
        }
        flush()
        if result.isEmpty { result = [DocumentBlock(.text(""), original: "")] }
        return result
    }
    static func openingFence(_ line: String) -> (marker: String, language: String)? {
        let clean = line.drop(while: { $0 == " " })
        guard line.count - clean.count <= 3, let char = clean.first, char == "`" || char == "~" else { return nil }
        let marker = String(clean.prefix(while: { $0 == char }))
        guard marker.count >= 3 else { return nil }
        return (marker, String(clean.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
    }
    private static func closes(_ line: String, fence: String) -> Bool {
        guard let candidate = openingFence(line) else { return false }
        return candidate.marker.first == fence.first && candidate.marker.count >= fence.count && candidate.language.isEmpty
    }
    static func cells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var pieces: [String] = [], current = "", escaped = false, code = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped { current += character == "|" || character == "\\" ? String(character) : "\\" + String(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "`" { code.toggle(); current.append(character) }
            else if character == "|", !code { pieces.append(current); current = "" }
            else { current.append(character) }
        }
        if escaped { current += "\\" }
        pieces.append(current)
        if pieces.first?.isEmpty == true { pieces.removeFirst() }
        if pieces.last?.isEmpty == true { pieces.removeLast() }
        guard !pieces.isEmpty else { return nil }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n") }
    }
    static func image(_ line: String) -> (alt: String, address: String, title: String)? {
        let pattern = #"^!\[((?:\\.|[^\]])*)\]\(\s*(?:<([^>]*)>|([^\s]+?))(?:\s+\"((?:\\.|[^\"])*)\")?\s*\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return nil }
        let ns = line as NSString
        func group(_ index: Int) -> String { let range = match.range(at: index); return range.location == NSNotFound ? "" : ns.substring(with: range) }
        return (group(1).replacingOccurrences(of: "\\]", with: "]").replacingOccurrences(of: "\\\\", with: "\\"), group(2).isEmpty ? group(3) : group(2), group(4).replacingOccurrences(of: "\\\"", with: "\""))
    }
}
