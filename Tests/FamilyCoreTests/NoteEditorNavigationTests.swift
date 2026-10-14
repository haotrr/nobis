import Foundation
import Testing
@testable import NobisUI

@MainActor @Suite("大纲与图片编辑")
struct NoteEditorNavigationTests {
    @Test func outlineSkipsCodeAndRetainsDuplicateHeadingLocations() {
        let source = "# **第一章**\n正文\n```md\n# 示例标题\n```\n## 第二章\n![图](https://example.com/a.png)\n## 第二章\n"
        let entries = NoteOutline.entries(in: source)
        #expect(entries.map(\.title) == ["第一章", "第二章", "第二章"])
        #expect(entries.map(\.level) == [1, 2, 2])
        #expect(Set(entries.map(\.id)).count == 3)
        let blocks = DocumentBlocks.parse(source)
        for entry in entries {
            guard case .text(let content) = blocks[entry.match.block].content else { Issue.record("outline target is not prose"); return }
            #expect((content as NSString).substring(with: entry.match.range).contains(entry.title))
        }
    }

    @Test func imageEditPreservesSurroundingTextAndRejectsStaleSource() throws {
        let source = "前😀![旧图](https://example.com/old.png)后文"
        let edit = try #require(NoteImageEdit(source: source, at: 3))
        #expect(edit.content.alt == "旧图")
        let replacement = NoteImageContent(alt: "新]图", address: "https://example.com/new.png", title: "说明")
        let updated = try edit.applying(to: source, replacement: replacement)
        #expect(updated.hasPrefix("前😀![新\\]图]"))
        #expect(updated.hasSuffix("后文"))
        #expect(try edit.applying(to: source, replacement: nil) == "前😀后文")
        #expect(throws: NoteImageEditError.self) { try edit.applying(to: source + "改动", replacement: replacement) }
    }

    @Test func imageBlockReplaceDeleteAndUndoPreserveIdentity() throws {
        let buffer = DocumentBlockBuffer("前文\n![旧图](https://example.com/a.png)\n后文")
        let original = buffer.blocks
        let image = original[1]
        buffer.undo.groupsByEvent = false
        buffer.undo.beginUndoGrouping()
        try buffer.replaceImage(image, with: NoteImageContent(alt: "新图", address: "https://example.com/b.png", title: ""))
        buffer.undo.endUndoGrouping()
        #expect(buffer.blocks[1].id == image.id)
        buffer.undo.undo()
        #expect(buffer.blocks == original)
        buffer.undo.beginUndoGrouping()
        try buffer.replaceImage(image, with: nil)
        buffer.undo.endUndoGrouping()
        #expect(buffer.blocks.count == 2)
        #expect(buffer.focus?.belongs(to: buffer.blocks[1].id) == true)
        buffer.undo.undo()
        #expect(buffer.blocks == original)
    }
}
