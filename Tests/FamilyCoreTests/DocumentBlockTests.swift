import Foundation
import Testing
import FamilyCore
@testable import NobisUI

@Suite("可视化文档内容") @MainActor struct DocumentBlockTests {
    @Test func mixedBlocksKeepOriginalSource() {
        let source = "# 出发\n\n| 名称 | 说明 |\n| :--- | ---: |\n| 相机 | **电池** |\n\n![海边](https://example.com/a.png \"海\")\n\n```swift\nlet x = \"**原样**\"\n- [ ] 不是待办\n```\n\n- [ ] 买票\n"
        let blocks = DocumentBlocks.parse(source)
        #expect(blocks.map(\.markdown).joined() == source)
        #expect(blocks.contains { if case .table = $0.content { true } else { false } })
        #expect(blocks.contains { if case .image = $0.content { true } else { false } })
        #expect(blocks.contains { if case .code = $0.content { true } else { false } })
        #expect(!blocks.contains { if case .text(let text) = $0.content { text.contains("```") || text.contains("![") || text.contains("| :---") } else { false } })
    }
    @Test func codeFencesSurviveEditingAndReloading() {
        let body = "let a = 1\n```\n原样 **中文** 😀\n"
        let block = DocumentBlock(.code(language: "swift", body: body))
        let parsed = DocumentBlocks.parse(block.markdown)
        #expect(parsed.first?.content == block.content)
        #expect(block.markdown.hasPrefix("````swift"))
        let unclosed = "~~~python\nprint('hi')"
        #expect(DocumentBlocks.parse(unclosed).map(\.markdown).joined() == unclosed)
    }
    @Test func tableEscapesAndIrregularRows() {
        let source = "| 项目 | 内容 |\n| --- | :---: |\n| **名字** | a\\|b<br>下一行 |\n| 额外 | 单元格 | 不丢失 |"
        var block = DocumentBlocks.parse(source)[0]
        guard case .table(var rows, let alignment) = block.content else { Issue.record("table missing"); return }
        #expect(rows[1][1] == "a|b\n下一行")
        #expect(rows[0].count == 3)
        rows[1][0] = "新名字😀"
        block.content = .table(rows: rows, alignment: alignment)
        #expect(DocumentBlocks.parse(block.markdown).first?.content == block.content)
    }
    @Test func tableLiteralBackslashAndPipeSurvive() {
        let block = DocumentBlock(.table(rows: [["Header"], [#"a\|b"#]], alignment: ["---"]))
        #expect(DocumentBlocks.parse(block.markdown)[0].content == block.content)
        #expect(MarkdownBlock.parse(block.markdown) == [.table([["Header"], [#"a\|b"#]])])
    }
    @Test func imageFieldsRoundTrip() {
        let block = DocumentBlock(.image(alt: "海]景", address: "https://example.com/a(b).png", title: "我们的\"海\""))
        #expect(DocumentBlocks.parse(block.markdown).first?.content == block.content)
    }
    @Test func inlineImagesAndCodeAreVisual() {
        let source = "出发 ![图](https://example.com/a(b).png) 继续\n"
        let blocks = DocumentBlocks.parse(source)
        #expect(blocks.map(\.markdown).joined() == source)
        #expect(blocks.count == 3)
        let rich = RichMarkdown.decode("执行 `**literal**` 指令")
        #expect(rich.string == "执行 **literal** 指令")
        #expect(RichMarkdown.encode(rich) == "执行 `**literal**` 指令")
    }
    @Test func codeContentNeverLeaksIntoTodos() {
        let block = DocumentBlock(.code(language: "markdown", body: "```\n- [ ] 示例\n```"))
        let parsed = MarkdownBlock.parse(block.markdown + "- [ ] 真待办")
        #expect(parsed.filter { if case .task = $0 { true } else { false } }.count == 1)
        let image = DocumentBlock(.image(alt: "海", address: "https://example.com/a.png", title: "海边"))
        #expect(MarkdownBlock.parse(image.markdown) == [.image("海", "https://example.com/a.png")])
    }
    @Test func codeBindingCanReadSiblingFieldDuringEdit() {
        let buffer = DocumentBlockBuffer("```swift\nold\n```")
        let id = buffer.blocks[0].id
        buffer.edit(id) { block in
            if case .code(let language, _) = buffer.blocks[0].content { block.content = .code(language: language, body: "new😀") }
        }
        #expect(DocumentBlocks.parse(buffer.blocks[0].markdown)[0].content == .code(language: "swift", body: "new😀"))
    }
    @Test func structureUndoRedo() {
        let buffer = DocumentBlockBuffer("正文")
        let manager = UndoManager(); manager.groupsByEvent = false
        let original = buffer.blocks
        manager.beginUndoGrouping()
        buffer.replace(original + [DocumentBlock(.code(language: "swift", body: "let a = 1"))], undo: manager)
        manager.endUndoGrouping()
        #expect(buffer.blocks.count == 2)
        manager.undo(); #expect(buffer.blocks == original)
        manager.redo(); #expect(buffer.blocks.count == 2)
    }
    @Test func insertionSplitsAtSelectionAndUndoRestoresIdentityAndFocus() {
        let source = "前半👨‍👩‍👧后半\n继续"
        let buffer = DocumentBlockBuffer(source)
        let original = buffer.blocks
        let range = (source as NSString).range(of: "👨‍👩‍👧")
        buffer.focus = NoteEditorFocus(target: original[0].id.uuidString, range: range)
        buffer.undo.groupsByEvent = false
        buffer.undo.beginUndoGrouping()
        buffer.insert(.table(rows: [["列"]], alignment: ["---"]))
        buffer.undo.endUndoGrouping()
        #expect(buffer.blocks[0].content == .text("前半👨‍👩‍👧\n"))
        #expect(buffer.blocks[2].content == .text("后半\n继续"))
        #expect(buffer.focusRequest?.target == "\(buffer.blocks[1].id)-0-0")
        let inserted = buffer.blocks
        buffer.undo.undo()
        #expect(buffer.blocks == original)
        #expect(buffer.focusRequest?.target == original[0].id.uuidString)
        #expect(buffer.focusRequest?.range == range)
        buffer.undo.redo()
        #expect(buffer.blocks == inserted)
    }

    @Test func insertionFromCellOrCodeStaysBesideItsBlock() {
        for code in [false, true] {
            let buffer = DocumentBlockBuffer(code ? "```swift\nabc\n```\n尾段" : "| A |\n| --- |\n| B |\n尾段")
            let first = buffer.blocks[0]
            buffer.focus = NoteEditorFocus(target: code ? "code:\(first.id)" : "\(first.id)-1-0")
            buffer.insert(.image(alt: "图片", address: "https://example.com/a.png", title: ""))
            #expect(buffer.blocks[0] == first)
            #expect(buffer.blocks[1].content == .image(alt: "图片", address: "https://example.com/a.png", title: ""))
            #expect(buffer.blocks.last?.markdown == "尾段")
        }
    }

}
