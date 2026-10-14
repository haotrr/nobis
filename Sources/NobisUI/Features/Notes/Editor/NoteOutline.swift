import SwiftUI
import PolarMark

struct NoteOutlineEntry: Identifiable {
    let level: Int
    let title: String
    let match: NoteSearchMatch
    var id: String { "\(match.block):\(match.range.location)" }
}

enum NoteOutline {
    static func entries(in source: String) -> [NoteOutlineEntry] {
        var entries: [NoteOutlineEntry] = []
        for (index, block) in DocumentBlocks.parse(source).enumerated() {
            guard case .text(let text) = block.content else { continue }
            let ast = PMKAST(markdown: text)
            ast.rootNode.walk { node in
                guard node.type == .heading else { return }
                let rawTitle = ast.substring(node.contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
                let title: String
                if let plain = PMKAST(markdown: rawTitle).clearFormatting(selection: NSRange(location: 0, length: rawTitle.utf16.count), inlineOnly: true) {
                    title = (rawTitle as NSString).replacingCharacters(in: plain.replacementRange, with: plain.replacementString)
                } else { title = rawTitle }
                entries.append(NoteOutlineEntry(level: node.level, title: title.isEmpty ? "未命名标题" : title,
                    match: NoteSearchMatch(block: index, range: node.contentRange, source: text)))
            }
        }
        return entries
    }
}

struct NoteOutlineMenu: View {
    let text: String
    let session: NoteSearchSession
    var body: some View {
        Menu {
            let entries = NoteOutline.entries(in: text)
            if entries.isEmpty { Text("添加标题后显示大纲") }
            ForEach(entries) { entry in
                Button(String(repeating: "　", count: min(3, max(0, entry.level - 1))) + entry.title) {
                    session.request = RichEditRequest(action: "find-match", match: entry.match)
                }
            }
        } label: { Image(systemName: "list.bullet.indent").touchTarget() }
        .accessibilityLabel("文档大纲").help("文档大纲与章节跳转").disabled(session.composing)
    }
}
