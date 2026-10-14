import SwiftUI
import FamilyCore

/// A small native Markdown subset. Unsupported syntax remains readable source text.
private struct BasicMarkdownPreview: View {
    let source: String
    var highlightedLine: Int? = nil
    var onToggle: ((Int) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text): inline(text).font(level == 1 ? .title : level == 2 ? .title2 : .headline).fontWeight(.semibold)
                case .paragraph(let text): inline(text)
                case .quote(let text): HStack { Rectangle().fill(.secondary).frame(width: 3); inline(text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case .list(let marker, let text): HStack(alignment: .top) { Text(marker).foregroundStyle(.secondary); inline(text) }
                case .code(let text): Text(text).font(.system(.body, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                case .task(let line, let checked, let text):
                    HStack(alignment: .top) {
                        if let onToggle {
                            Button { onToggle(line) } label: { Image(systemName: checked ? "checkmark.circle.fill" : "circle") }
                                .buttonStyle(.borderless).touchTarget().accessibilityLabel("\(checked ? "取消完成" : "完成")：\(text)")
                        } else { Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary) }
                        inline(text).strikethrough(checked).padding(.top, onToggle == nil ? 0 : 10)
                    }.id("checklist-\(line)")
                        .padding(4).background(highlightedLine == line ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                GridRow { ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in inline(cell).fontWeight(index == 0 ? .semibold : .regular) } }
                                if index == 0 { Divider() }
                            }
                        }.padding(12)
                    }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                case .image(let alt, let address): MarkdownRemoteImage(alt: alt, address: address)
                case .divider: Divider()
                }
            }
        }.textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}

private struct MarkdownRemoteImage: View {
    let alt: String
    let address: String
    @State private var loaded = false
    var body: some View {
        if let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil {
            if loaded {
                AsyncImage(url: url) { phase in
                    NoteImageViewport(phase: phase, label: alt.isEmpty ? "文档图片" : alt)
                }
            } else {
                NoteImageCanvas {
                    Button { loaded = true } label: { Label("加载图片：\(alt.isEmpty ? url.host! : alt)", systemImage: "photo") }
                        .help("从 \(url.host!) 加载外部图片").touchTarget().padding(12)
                }
            }
        } else { Label(alt.isEmpty ? "图片需要 HTTPS 地址" : "\(alt) · 图片需要 HTTPS 地址", systemImage: "photo") }
    }
}

struct MarkdownPreview: View {
    let source: String
    var highlightedLine: Int? = nil
    var onToggle: ((Int) -> Void)? = nil
    @State private var loadImages = false
    var body: some View {
        #if os(macOS)
        if highlightedLine == nil && onToggle == nil {
            VStack(alignment: .leading) {
                MDTextKitEditor(text: .constant(source), editable: false, loadImages: loadImages)
                if !loadImages && source.contains("![") {
                    Button("加载外部图片") { loadImages = true }.buttonStyle(.borderless)
                }
            }
        } else {
            BasicMarkdownPreview(source: source, highlightedLine: highlightedLine, onToggle: onToggle)
        }
        #else
        BasicMarkdownPreview(source: source, highlightedLine: highlightedLine, onToggle: onToggle)
        #endif
    }
}
