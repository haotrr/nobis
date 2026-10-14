import Foundation
import Testing
import PolarMark
@testable import NobisUI

@MainActor @Suite("编辑器基础操作")
struct NoteEditorBasicsTests {
    @Test func clearFormattingKeepsContentAndStructures() throws {
        let source = "## **中文😀** 与 *文字*\n- [x] 清单\n\n```\n**代码**\n```\n![图](https://example.com/a.png)\n"
        let ast = PMKAST(markdown: source)
        let result = try #require(ast.clearFormatting(selection: NSRange(location: 0, length: source.utf16.count)))
        let value = (source as NSString).replacingCharacters(in: result.replacementRange, with: result.replacementString)
        #expect(value.contains("中文😀 与 文字"))
        #expect(!value.hasPrefix("##"))
        #expect(value.contains("- [x] 清单"))
        #expect(value.contains("**代码**"))
        #expect(value.contains("![图](https://example.com/a.png)"))
    }

    @Test func clearPartialSelectionPreservesEmojiAndSelection() throws {
        let source = "前 **中文😀** 后"
        let selection = (source as NSString).range(of: "中文😀")
        let result = try #require(PMKAST(markdown: source).clearFormatting(selection: selection))
        let value = (source as NSString).replacingCharacters(in: result.replacementRange, with: result.replacementString)
        #expect(value == "前 中文😀 后")
        #expect((value as NSString).substring(with: result.proposedSelection) == "中文😀")
    }

    @Test func findAcrossBlocksAndIgnoreEmbeddedData() {
        let blocks = DocumentBlocks.parse("前😀目标\n| 标题 |\n| --- |\n| 目标 |\n```swift\n目标\n```\n![目标](data:image/jpeg;base64,目标)\n目标")
        let matches = NoteDocumentSearch.matches(in: blocks, query: "目标")
        #expect(matches.count == 4)
        #expect(matches[0].range.location == 3)
        #expect(matches[1].row == 1)
        #expect(matches[1].column == 0)
        #expect(matches[2].source == "目标")
        #expect(NoteDocumentSearch.matches(in: blocks, query: "").isEmpty)
    }

    @Test func currentTableRowColumnAndUndoRestoreFocus() throws {
        let buffer = DocumentBlockBuffer("| A | B |\n| --- | --- |\n| 一 | 二 |\n| 三 | 四 |\n")
        buffer.undo.groupsByEvent = false
        let id = buffer.blocks[0].id
        let focus = NoteEditorFocus(target: "\(id)-1-1", range: NSRange(location: 0, length: 1))
        buffer.focus = focus
        let original = buffer.blocks
        buffer.undo.beginUndoGrouping()
        buffer.changeTable(id, action: .rowAfter)
        buffer.undo.endUndoGrouping()
        guard case .table(let rows, _) = buffer.blocks[0].content else { Issue.record("missing table"); return }
        #expect(rows == [["A", "B"], ["一", "二"], ["", ""], ["三", "四"]])
        #expect(buffer.focusRequest?.target == "\(id)-2-1")
        buffer.undo.undo()
        #expect(buffer.blocks == original)
        #expect(buffer.focusRequest?.target == focus.target)
        #expect(buffer.focusRequest?.range == focus.range)
        buffer.undo.beginUndoGrouping()
        buffer.changeTable(id, action: .deleteColumn)
        buffer.undo.endUndoGrouping()
        guard case .table(let columns, _) = buffer.blocks[0].content else { return }
        #expect(columns == [["A"], ["一"], ["三"]])
        buffer.undo.undo()
        #expect(buffer.blocks == original)
        buffer.undo.beginUndoGrouping()
        buffer.changeTable(id, action: .rowDown)
        buffer.undo.endUndoGrouping()
        guard case .table(let moved, _) = buffer.blocks[0].content else { return }
        #expect(moved[2] == ["一", "二"])
    }
}
