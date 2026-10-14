#if os(macOS)
import AppKit
import SwiftUI
import Testing
import MDTextKit
import MDTextKitUI
@testable import NobisUI

@MainActor @Suite(.serialized)
struct MDTextKitIntegrationTests {
    private final class Buffer {
        var value: String
        init(_ value: String) { self.value = value }
        var binding: Binding<String> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }

    private func make(_ source: String, editable: Bool = true) -> (Buffer, MDTextKitEditor.Coordinator) {
        _ = NSApplication.shared
        let buffer = Buffer(source)
        let coordinator = MDTextKitEditor.Coordinator(text: buffer.binding)
        coordinator.update(MDTextKitEditor(text: buffer.binding, editable: editable, loadImages: false))
        return (buffer, coordinator)
    }

    @Test func sourceRoundTripAndReadOnlyTables() {
        let source = "# 中文 👨‍👩‍👧\n\n- [ ] 待办\n- [x] 完成\n\n| 项目 | 说明 |\n| --- | --- |\n| **文字** | A\\|B |\n\n> 引用\n\n```swift\n- [ ] 示例\n```\n\n![图片](https://example.com/test.png)\n"
        let (buffer, coordinator) = make(source, editable: false)
        defer { coordinator.stop() }
        #expect(coordinator.view.markdown == source)
        #expect(buffer.value == source)
        #expect(!coordinator.view.isEditable)
        coordinator.view.mdTextStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: coordinator.view.mdTextStorage.length)) { value, _, _ in
            if let table = value as? MDTableTextAttachment { #expect(table.attachmentViewController == nil) }
        }
        NobisMDTextView.apply("bold", to: coordinator.view)
        #expect(coordinator.view.markdown == source)
    }

    @Test func checklistPublishesAndEchoPreservesUndo() {
        let (buffer, coordinator) = make("- [ ] 采购\n")
        defer { coordinator.stop() }
        coordinator.view.setSelectedRange(NSRange(location: 0, length: 0))
        NobisMDTextView.apply("toggle", to: coordinator.view)
        #expect(buffer.value == "- [x] 采购\n")
        coordinator.update(MDTextKitEditor(text: buffer.binding, loadImages: false))
        #expect(coordinator.view.editorUndoManager.canUndo)
        coordinator.view.editorUndoManager.undo()
        #expect(buffer.value == "- [ ] 采购\n")
        coordinator.view.editorUndoManager.redo()
        #expect(buffer.value == "- [x] 采购\n")
    }

    @Test func linkEditingFindsExistingLabelAndReplacesInsteadOfNesting() {
        let source = "前文 [中文链接](https://example.com/old) 后文"
        let (buffer, coordinator) = make(source)
        defer { coordinator.stop() }
        let view = coordinator.view
        let label = (view.string as NSString).range(of: "中文链接")
        view.setSelectedRange(NSRange(location: label.location + 1, length: 0))
        let context = NobisMDTextView.linkContext(in: view)
        #expect(context.label == "中文链接")
        #expect(context.address == "https://example.com/old")
        NobisMDTextView.apply("link:https://example.com/new", to: view)
        #expect(buffer.value == "前文 [中文链接](https://example.com/new) 后文")
        view.editorUndoManager.undo()
        #expect(buffer.value == source)
        view.setSelectedRange(NSRange(location: label.location + 1, length: 0))
        NobisMDTextView.apply("link:", to: view)
        #expect(buffer.value == "前文 中文链接 后文")
    }

    @Test func checklistReturnContinuesAndEmptyReturnExits() {
        let (buffer, coordinator) = make("- [x] 中文你好")
        defer { coordinator.stop() }
        let view = coordinator.view
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        #expect(buffer.value == "- [x] 中文你好\n- [ ] ")
        view.insertNewline(nil)
        #expect(buffer.value == "- [x] 中文你好\n")
        view.insertText("普通正文", replacementRange: view.selectedRange())
        #expect(buffer.value == "- [x] 中文你好\n普通正文")
    }

    @Test func completedTaskDoesNotStyleFollowingPlainLines() {
        let source = "- [x] 哈哈\n我是谁？你是谁？\n迭代的是什么呢？\n\n正常正文"
        let (buffer, coordinator) = make(source)
        defer { coordinator.stop() }
        let storage = coordinator.view.mdTextStorage
        let text = storage.string as NSString
        let ordinary = text.range(of: "我是谁").location
        let baseline = text.range(of: "正常正文").location
        let task = text.range(of: "哈哈").location
        #expect(storage.attribute(.foregroundColor, at: ordinary, effectiveRange: nil) as? NSColor == storage.attribute(.foregroundColor, at: baseline, effectiveRange: nil) as? NSColor)
        #expect(storage.attribute(.foregroundColor, at: task, effectiveRange: nil) as? NSColor != storage.attribute(.foregroundColor, at: baseline, effectiveRange: nil) as? NSColor)
        coordinator.view.setSelectedRange(NSRange(location: task, length: 0))
        NobisMDTextView.apply("toggle", to: coordinator.view)
        #expect(buffer.value == source.replacingOccurrences(of: "[x]", with: "[ ]"))
        coordinator.view.editorUndoManager.undo()
        #expect(buffer.value == source)
    }

    @Test func tableInsertionAndLinkPublishMarkdown() {
        let (buffer, coordinator) = make("正文")
        defer { coordinator.stop() }
        coordinator.view.setSelectedRange(NSRange(location: 0, length: 2))
        NobisMDTextView.apply("link:https://example.com", to: coordinator.view)
        #expect(buffer.value == "[正文](https://example.com)")
        NobisMDTextView.apply("insert-table", to: coordinator.view)
        #expect(buffer.value.contains("| 列一 | 列二 |"))
        #expect(buffer.value.hasPrefix("[正文](https://example.com)"))
    }

    @Test func compositionKeepsCandidateAndPublishesOnlyCommit() {
        let (buffer, coordinator) = make("开始 ")
        defer { coordinator.stop() }
        let view = coordinator.view
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(buffer.value == "开始 ")
        coordinator.update(MDTextKitEditor(text: buffer.binding, request: RichEditRequest(action: "bold"), loadImages: false))
        #expect(view.hasMarkedText())
        #expect(view.string.contains("zhong"))
        view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(buffer.value == "开始 中文")
        view.editorUndoManager.undo()
        #expect(buffer.value == "开始 ")
        view.editorUndoManager.redo()
        #expect(buffer.value == "开始 中文")
    }

    @Test func tableCellCommitsImmediatelyAndCompositionStaysLocal() throws {
        let source = "| 项目 | 备注 |\n| --- | --- |\n| 原值 | 内容 |\n"
        let (buffer, coordinator) = make(source)
        defer { coordinator.stop() }
        let attachment = try #require(coordinator.view.mdTextStorage.textAttachment(at: 0) as? MDTableTextAttachment)
        let table = try #require(attachment.attachmentViewController as? MDTableAttachmentViewController)
        table.beginEditing(at: (row: 1, column: 0))
        func findEditor(_ view: NSView) -> MDTextView? {
            if let editor = view as? MDTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor($0) }.first
        }
        let cell = try #require(findEditor(table.view))
        cell.setSelectedRange(NSRange(location: 0, length: cell.string.utf16.count))
        cell.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(buffer.value == source)
        #expect(cell.hasMarkedText())
        cell.insertText("中文|说明", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(buffer.value.contains("中文\\|说明"))
        #expect(!buffer.value.contains("zhong"))
        table.endEditing(returnFocus: false)
        coordinator.view.editorUndoManager.undo()
        #expect(buffer.value == source)
    }

    @Test func narrowLayoutAndAppearancePreserveMarkedText() throws {
        let (buffer, coordinator) = make("# 标题\n\n正文 👨‍👩‍👧\n")
        defer { coordinator.stop() }
        let view = coordinator.view
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.markedRange()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(280), 680] {
                view.setFrameSize(NSSize(width: width, height: 500))
                let container = try #require(view.textContainer)
                view.layoutManager?.ensureLayout(for: container)
                #expect(view.hasMarkedText())
                #expect(view.markedRange() == marked)
                #expect(view.string.contains("nihao"))
                #expect(view.layoutManager?.usedRect(for: container).height.isFinite == true)
            }
        }
        #expect(!buffer.value.contains("nihao"))
        view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(buffer.value.hasSuffix("你好"))
    }

    @Test func inMemoryImageRendersWithFlexibleColumnWidth() throws {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let attachment = MDImageTextAttachment(representedAttributedText: NSAttributedString(string: "![图片](https://example.com/a.png)"))
        attachment.imageData = try #require(image.tiffRepresentation)
        attachment.maxTextContainerWidth = 0
        attachment.updateAttachmentImage()
        #expect(attachment.temporaryImage != nil)
        #expect(attachment.attachmentSize.width > 0)
    }

    @Test func externalImportReplacesBufferAndReadOnlyBlocksFormatting() {
        let (buffer, coordinator) = make("旧正文")
        defer { coordinator.stop() }
        buffer.value = "旧正文\n\n## 导入\n新内容"
        coordinator.update(MDTextKitEditor(text: buffer.binding, loadImages: false))
        #expect(coordinator.view.markdown == buffer.value)
        coordinator.update(MDTextKitEditor(text: buffer.binding, editable: false, loadImages: false))
        let source = buffer.value
        NobisMDTextView.apply("checklist", to: coordinator.view)
        #expect(coordinator.view.markdown == source)
    }
    @Test func tableUndoRestoresCellSelectionAndPreservesSurroundingText() throws {
        let source = "前文\n\n| 项目 | 备注 |\n| --- | --- |\n| 原值 | 内容 |\n\n后文"
        let (buffer, coordinator) = make(source)
        defer { coordinator.stop() }
        let host = coordinator.view
        var attachment: MDTableTextAttachment?
        host.mdTextStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: host.mdTextStorage.length)) { value, _, _ in
            if let table = value as? MDTableTextAttachment { attachment = table }
        }
        let table = try #require(attachment?.attachmentViewController as? MDTableAttachmentViewController)
        host.editorUndoManager.groupsByEvent = false
        table.beginEditing(at: (1, 0))
        let first = try #require(table.activeCellEditor)
        first.setSelectedRange(NSRange(location: 1, length: 1))
        host.editorUndoManager.beginUndoGrouping()
        first.insertText("甲", replacementRange: first.selectedRange())
        host.editorUndoManager.endUndoGrouping()
        let afterFirst = buffer.value
        table.beginEditing(at: (1, 1))
        let second = try #require(table.activeCellEditor)
        second.setSelectedRange(NSRange(location: 0, length: 2))
        host.editorUndoManager.beginUndoGrouping()
        second.insertText("乙", replacementRange: second.selectedRange())
        host.editorUndoManager.endUndoGrouping()
        let afterSecond = buffer.value
        host.editorUndoManager.undo()
        #expect(buffer.value == afterFirst)
        #expect(table.activeCellEditor?.selectedRange() == NSRange(location: 0, length: 2))
        host.editorUndoManager.undo()
        #expect(buffer.value == source)
        #expect(table.activeCellEditor?.selectedRange() == NSRange(location: 1, length: 1))
        host.editorUndoManager.redo()
        host.editorUndoManager.redo()
        #expect(buffer.value == afterSecond)
        #expect(buffer.value.hasPrefix("前文\n\n"))
        #expect(buffer.value.hasSuffix("\n\n后文"))
    }

    @Test func longDocumentMeasuresBeyondOldScrollLimitAndInvalidates() {
        let (buffer, coordinator) = make(String(repeating: "一段用于验证长文换行和页面滚动的文字。\n\n", count: 100))
        defer { coordinator.stop() }
        let narrow = coordinator.view.measuredSize(width: 280)
        #expect(narrow.height > 900)
        #expect(coordinator.view.measuredSize(width: 280) == narrow)
        let wide = coordinator.view.measuredSize(width: 680)
        #expect(wide.height <= narrow.height)
        buffer.value = "短文"
        coordinator.update(MDTextKitEditor(text: buffer.binding, loadImages: false))
        #expect(coordinator.view.measuredSize(width: 680).height < wide.height)
    }

    @Test func formattingReportsSelectionMixedAndComposition() {
        let (_, coordinator) = make("**粗体** 普通")
        defer { coordinator.stop() }
        let view = coordinator.view
        view.setSelectedRange(NSRange(location: 2, length: 2))
        #expect(coordinator.selectionState(for: view).selected.contains("bold"))
        view.setSelectedRange(NSRange(location: 2, length: view.string.utf16.count - 2))
        #expect(coordinator.selectionState(for: view).mixed.contains("bold"))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(coordinator.selectionState(for: view).composing)
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!coordinator.selectionState(for: view).composing)
        view.isEditable = false
        #expect(!coordinator.selectionState(for: view).enabled)
    }

    @Test func tableStructureUndoAndBodyEditsShareHistory() throws {
        let source = "前文\n\n| 一 | 二 |\n| --- | --- |\n| 甲 | 乙 |\n"
        let (buffer, coordinator) = make(source)
        defer { coordinator.stop() }
        let host = coordinator.view
        let location = ("前文\n\n" as NSString).length
        func currentTable() throws -> MDTableAttachmentViewController {
            let attachment = try #require(host.mdTextStorage.textAttachment(at: location) as? MDTableTextAttachment)
            return try #require(attachment.attachmentViewController as? MDTableAttachmentViewController)
        }
        let table = try currentTable()
        table.beginEditing(at: (1, 1))
        host.editorUndoManager.groupsByEvent = false
        host.editorUndoManager.beginUndoGrouping()
        table.perform(NSSelectorFromString("addRow"))
        host.editorUndoManager.endUndoGrouping()
        #expect(table.model.rows.count == 3)
        let added = buffer.value
        host.setSelectedRange(NSRange(location: 0, length: 0))
        host.editorUndoManager.beginUndoGrouping()
        host.insertText("正文编辑", replacementRange: host.selectedRange())
        host.editorUndoManager.endUndoGrouping()
        host.editorUndoManager.undo()
        #expect(buffer.value == added)
        host.editorUndoManager.undo()
        #expect(buffer.value == source)
        #expect(try currentTable().model.rows.count == 2)
        host.editorUndoManager.redo()
        #expect(buffer.value == added)
    }

    @Test func compositionRepairsResetTypingParagraphGeometry() async throws {
        let (_, coordinator) = make("正文")
        defer { coordinator.stop() }
        let view = coordinator.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.contentView = nil }
        view.setSelectedRange(NSRange(location: view.mdTextStorage.length, length: 0))
        view.insertNewline(nil)
        await Task.yield()
        let before = try #require(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(before.firstLineHeadIndent > 0)
        // Input contexts can supply a default typing paragraph before marked-text updates.
        var resetAttributes = view.typingAttributes
        resetAttributes[.paragraphStyle] = NSParagraphStyle.default
        view.typingAttributes = resetAttributes
        let marked = NSAttributedString(string: "dd", attributes: [.paragraphStyle: NSParagraphStyle.default, .underlineStyle: 1])
        view.setMarkedText(marked, selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await Task.yield()
        view.setMarkedText("ddd", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let during = try #require(view.mdTextStorage.attribute(.paragraphStyle, at: view.markedRange().location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(during.firstLineHeadIndent == before.firstLineHeadIndent)
        #expect(during.headIndent == before.headIndent)
        #expect(view.hasMarkedText())
        let layout = view.mdLayoutManager
        layout.ensureLayout(for: view.mdTextContainer)
        let markedX = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: view.markedRange(), actualCharacterRange: nil), in: view.mdTextContainer).minX
        view.insertText("迭代", replacementRange: NSRange(location: NSNotFound, length: 0))
        let after = try #require(view.mdTextStorage.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)
        #expect(after.firstLineHeadIndent == during.firstLineHeadIndent)
        layout.ensureLayout(for: view.mdTextContainer)
        let committedX = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 3, length: 2), actualCharacterRange: nil), in: view.mdTextContainer).minX
        #expect(abs(markedX - committedX) < 1)
    }

    @Test func compositionPreservesTableAlignmentAcrossUpdates() throws {
        let (buffer, coordinator) = make("| 项目 |\n| :---: |\n| 内容 |\n")
        defer { coordinator.stop() }
        let table = try #require((coordinator.view.mdTextStorage.textAttachment(at: 0) as? MDTableTextAttachment)?.attachmentViewController as? MDTableAttachmentViewController)
        table.beginEditing(at: (1, 0))
        let cell = try #require(table.activeCellEditor)
        cell.setSelectedRange(NSRange(location: 0, length: 2))
        let source = buffer.value
        let original = try #require(cell.mdTextStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        for text in ["n", "ni", "nihao"] {
            cell.typingAttributes[.paragraphStyle] = NSParagraphStyle.default
            cell.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let style = try #require(cell.mdTextStorage.attribute(.paragraphStyle, at: cell.markedRange().location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.alignment == original.alignment)
            #expect(style.firstLineHeadIndent == original.firstLineHeadIndent)
            #expect(cell.hasMarkedText())
            #expect(buffer.value == source)
        }
        cell.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(buffer.value.contains("你好"))
        coordinator.view.editorUndoManager.undo()
        #expect(buffer.value == source)
    }

    @Test func imageArrivalPreservesGeometrySelectionAndScroll() throws {
        let path = "https://example.com/image.png"
        let source = "![图片](\(path))\n\n" + String(repeating: "后续中文正文\n", count: 80)
        let (buffer, coordinator) = make(source)
        defer { coordinator.stop() }
        let view = coordinator.view
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        scroll.documentView = view
        view.setFrameSize(view.measuredSize(width: 340))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 450))
        let size = view.measuredSize(width: 340), selection = view.selectedRange(), offset = scroll.contentView.bounds.origin
        var images: [MDImageTextAttachment] = []
        view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage!.length)) { value, _, _ in
            if let image = value as? MDImageTextAttachment { images.append(image) }
        }
        let attachment = try #require(images.first)
        let reserved = attachment.attachmentSize
        #expect(reserved == CGSize(width: 560, height: 420))
        for dimensions in [NSSize(width: 20, height: 200), NSSize(width: 300, height: 20)] {
            let image = NSImage(size: dimensions, flipped: false) { rect in NSColor.systemGreen.setFill(); rect.fill(); return true }
            coordinator.receiveImage(try #require(image.tiffRepresentation), path: path)
            view.invalidateMeasurement() // Confirm stable layout even if a later pass remeasures.
            #expect(attachment.temporaryImage != nil)
            #expect(attachment.attachmentSize == reserved)
            #expect(view.measuredSize(width: 340) == size)
            #expect(view.selectedRange() == selection)
            #expect(scroll.contentView.bounds.origin == offset)
            #expect(buffer.value == source)
        }
        #expect(attachment.copyAttachment().reservedImageSize == reserved)
    }

}
#endif
