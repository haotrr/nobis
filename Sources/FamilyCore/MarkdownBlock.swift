import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case task(Int, Bool, String), table([[String]]), image(String, String)
    case heading(Int, String), paragraph(String), quote(String), list(String, String), code(String), divider

    private static func cells(_ line: String) -> [String] {
        guard line.contains("|") else { return [] }
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
        guard !pieces.isEmpty else { return [] }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n") }
    }
    private static func isTableDivider(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
    public static func togglingTask(in source: String, line: Int) -> String? {
        guard parse(source).contains(where: { if case .task(let index, _, _) = $0 { return index == line }; return false }) else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard let range = lines[line].range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return nil }
        lines[line].replaceSubrange(range, with: lines[line][range] == "[ ]" ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }
    public static func parse(_ source: String) -> [Self] {
        var result: [Self] = [], paragraph: [String] = [], code: [String] = []
        var fence: String?
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        let lines = source.components(separatedBy: "\n")
        var skipUntil = -1
        for (lineNumber, line) in lines.enumerated() {
            if lineNumber < skipUntil { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                let run = trimmed.prefix(while: { $0 == current.first! })
                if run.count >= current.count && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty { result.append(.code(code.joined(separator: "\n"))); code = []; fence = nil }
                else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flush(); fence = String(trimmed.prefix(while: { $0 == trimmed.first! })); continue }
            if trimmed.isEmpty { flush(); continue }
            if lineNumber + 1 < lines.count, trimmed.contains("|"), isTableDivider(lines[lineNumber + 1]) {
                flush()
                var rows = [cells(trimmed)]
                var index = lineNumber + 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                result.append(.table(rows)); skipUntil = index; continue
            }
            if trimmed.hasPrefix("!["), let regex = try? NSRegularExpression(pattern: #"^!\[((?:\\.|[^\]])*)\]\(\s*(?:<([^>]*)>|([^\s]+?))(?:\s+\"((?:\\.|[^\"])*)\")?\s*\)$"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) {
                let ns = trimmed as NSString
                let alt = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "\\]", with: "]").replacingOccurrences(of: "\\\\", with: "\\")
                let addressRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                flush(); result.append(.image(alt, ns.substring(with: addressRange))); continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); result.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1)))); continue
            }
            if ["---", "***", "___"].contains(trimmed) { flush(); result.append(.divider); continue }
            if trimmed.hasPrefix("> ") { flush(); result.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if ["- ", "* ", "+ "].contains(String(trimmed.prefix(2))) {
                flush()
                let item = String(trimmed.dropFirst(2))
                if item.hasPrefix("[ ] ") { result.append(.task(lineNumber, false, String(item.dropFirst(4)))) }
                else if item.lowercased().hasPrefix("[x] ") { result.append(.task(lineNumber, true, String(item.dropFirst(4)))) }
                else { result.append(.list("•", item)) }
                continue
            }
            if let range = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
                flush()
                let item = String(trimmed[range.upperBound...])
                if item.hasPrefix("[ ] ") { result.append(.task(lineNumber, false, String(item.dropFirst(4)))) }
                else if item.lowercased().hasPrefix("[x] ") { result.append(.task(lineNumber, true, String(item.dropFirst(4)))) }
                else { result.append(.list(String(trimmed[range]).trimmingCharacters(in: .whitespaces), item)) }
                continue
            }
            paragraph.append(line)
        }
        flush()
        if fence != nil { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }
}
