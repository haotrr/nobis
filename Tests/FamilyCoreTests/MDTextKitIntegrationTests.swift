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
}
#endif
