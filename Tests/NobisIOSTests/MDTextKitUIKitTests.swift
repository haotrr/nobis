import XCTest
import UIKit
@testable import MDTextKitUIKit
import SwiftUI
@testable import NobisUI

@MainActor final class MDTextKitUIKitTests: XCTestCase {
    private var window: UIWindow!
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        }
    }
    override func tearDown() async throws {
        await MainActor.run { window.isHidden = true; window = nil }
        try await super.tearDown()
    }
    private func editor(_ source: String, inline: Bool = false) -> MDMarkdownTextView {
        let view = MDMarkdownTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        view.inlineOnly = inline
        window.rootViewController!.view.addSubview(view)
        view.load(markdown: source)
        view.becomeFirstResponder()
        return view
    }

    func testSearchHighlightsPreserveCompositionAndUndo() {
        let view = editor("前😀目标目标")
        let source = view.markdown
        view.searchRanges = [NSRange(location: 3, length: 2), NSRange(location: 5, length: 2)]
        XCTAssertNotNil(view.textStorage.attribute(.backgroundColor, at: 3, effectiveRange: nil))
        XCTAssertEqual(view.markdown, source)
        view.selectedRange = NSRange(location: source.utf16.count, length: 0)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.searchRanges = []
        XCTAssertNotNil(view.markedTextRange)
        view.insertText("你"); view.unmarkText(); view.renderMarkdown()
        XCTAssertNil(view.textStorage.attribute(.backgroundColor, at: 3, effectiveRange: nil))
        XCTAssertTrue(view.markdown.hasSuffix("你"))
    }

    func testClosingSearchDoesNotReplayEarlierFormattingCommand() async throws {
        let search = NoteSearchSession(); search.query = "目标"; search.isPresented = true
        let commands = NoteSearchCommands()
        let host = UIHostingController(rootView: NoteSearchFixture(source: "目标", search: search, commands: commands))
        window.rootViewController = host; window.makeKeyAndVisible()
        func editors(_ view: UIView) -> [MDMarkdownTextView] {
            (view as? MDMarkdownTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        try await Task.sleep(for: .milliseconds(150))
        let view = try XCTUnwrap(editors(host.view).first)
        view.becomeFirstResponder(); view.selectedRange = NSRange(location: 0, length: 2)
        try await Task.sleep(for: .milliseconds(100))
        commands.request = RichEditRequest(action: "bold")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(view.markdown, "**目标**")
        search.navigate(1, in: view.markdown)
        try await Task.sleep(for: .milliseconds(150))
        search.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(view.markdown, "**目标**")
    }

    func testReplaceAllAcrossNativeEditorsAndUndo() async throws {
        let source = "正文目标\n\n| 名称 |\n| --- |\n| 表格目标 |\n\n```swift\n代码目标\n```\n"
        let search = NoteSearchSession(); search.query = "目标"; search.isPresented = true
        let host = UIHostingController(rootView: NoteSearchFixture(source: source, search: search))
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        func editors(_ view: UIView) -> [MDMarkdownTextView] {
            (view as? MDMarkdownTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        XCTAssertEqual(search.matches.count, 3)
        search.replacement = "新的😀"; search.replace(all: true, in: source)
        try await Task.sleep(for: .milliseconds(200))
        let views = editors(host.view)
        XCTAssertEqual(views.filter { $0.markdown.contains("新的😀") }.count, 3)
        XCTAssertTrue(search.matches.isEmpty)
        let manager = try XCTUnwrap(views.first?.undoManager)
        manager.undo()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(editors(host.view).filter { $0.markdown.contains("目标") }.count, 3)
        XCTAssertEqual(search.matches.count, 3)
        manager.redo()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(editors(host.view).filter { $0.markdown.contains("新的😀") }.count, 3)
    }

    func testNativeImageZoomAndResizeReset() {
        let scroll = NoteImageScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        window.rootViewController!.view.addSubview(scroll)
        scroll.layoutIfNeeded()
        scroll.setZoomScale(3, animated: false)
        XCTAssertEqual(scroll.zoomScale, 3, accuracy: 0.01)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        scroll.setContentOffset(CGPoint(x: 100, y: 60), animated: false)
        XCTAssertEqual(scroll.contentOffset.x, 100, accuracy: 0.01)
        scroll.frame.size = CGSize(width: 600, height: 200)
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, 1, accuracy: 0.01)
    }

    func testImageInspectorLayoutsDoNotModifyDocument() async throws {
        let pixels = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let data = try XCTUnwrap(pixels.jpegData(compressionQuality: 0.8))
        let content = NoteImageContent(alt: "示例图片", address: NoteEmbeddedImage.prefix + data.base64EncodedString(), title: "")
        var applied = false
        let root = NoteImageInspector(content: content, apply: { _ in applied = true }, close: {})
            .environment(\.dynamicTypeSize, .xxxLarge)
        let host = UIHostingController(rootView: AnyView(root))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for (name, size, style) in [("image-portrait-light", CGSize(width: 390, height: 844), UIUserInterfaceStyle.light),
                                  ("image-landscape-dark", CGSize(width: 844, height: 390), UIUserInterfaceStyle.dark)] {
            window.frame.size = size
            host.overrideUserInterfaceStyle = style
            host.rootView = AnyView(root.environment(\.colorScheme, style == .dark ? .dark : .light))
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { context in
                host.view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertFalse(applied)
    }

    func testWholeDocumentSearchReachesTableAndCodeAcrossLayouts() async throws {
        let source = "# 标题\n正文目标\n\n| 名称 |\n| --- |\n| 表格目标 |\n\n```swift\n代码目标\n```\n"
        let search = NoteSearchSession()
        search.query = "目标"
        search.isPresented = true
        let root = NoteSearchFixture(source: source, search: search)
        let host = UIHostingController(rootView: AnyView(root.environment(\.colorScheme, .light)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(150))
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        for expected in ["正文目标", "表格目标", "代码目标"] {
            search.navigate(1, in: source)
            try await Task.sleep(for: .milliseconds(150))
            let active = try XCTUnwrap(textViews(host.view).first(where: \.isFirstResponder))
            XCTAssertTrue(active.text.contains(expected))
            XCTAssertEqual((active.text as NSString).substring(with: active.selectedRange), "目标")
        }
        search.showsReplacement = true
        search.replacement = "替换内容"
        for (name, size, style) in [("portrait-light", CGSize(width: 390, height: 844), UIUserInterfaceStyle.light),
                                     ("landscape-dark", CGSize(width: 844, height: 390), UIUserInterfaceStyle.dark)] {
            window.frame.size = size
            host.overrideUserInterfaceStyle = style
            host.rootView = AnyView(root.environment(\.colorScheme, style == .dark ? .dark : .light))
            host.view.frame = window.bounds
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.layer.render(in: UIGraphicsGetCurrentContext()!)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testExtendedFormattingAndClearPreserveMarkedText() {
        let view = editor("中文😀")
        view.selectedRange = NSRange(location: 0, length: view.markdown.utf16.count)
        view.performMarkdownAction("strike")
        XCTAssertEqual(view.markdown, "~~中文😀~~")
        view.performMarkdownAction("clear")
        XCTAssertEqual(view.markdown, "中文😀")
        view.selectedRange = NSRange(location: view.markdown.utf16.count, length: 0)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let composing = view.markdown
        for action in ["clear", "heading:1", "ordered", "quote", "inline-code"] { view.performMarkdownAction(action) }
        XCTAssertEqual(view.markdown, composing)
        XCTAssertNotNil(view.markedTextRange)
    }

    func testChecklistReturnExitAndToggleUndoAfterChineseComposition() {
        let view = editor("- [ ] ")
        view.undoManager?.groupsByEvent = false
        view.undoManager?.removeAllActions()
        view.selectedRange = NSRange(location: 6, length: 0)
        view.rememberSelection()
        view.undoManager?.beginUndoGrouping()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        view.performMarkdownAction("toggle")
        XCTAssertTrue(view.markdown.hasPrefix("- [ ] "))
        XCTAssertNotNil(view.markedTextRange)
        view.insertText("你好")
        view.unmarkText()
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.markdown, "- [ ] 你好")
        view.undoManager?.beginUndoGrouping()
        view.performMarkdownAction("toggle")
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.markdown, "- [x] 你好")
        view.undoManager?.undo()
        XCTAssertEqual(view.markdown, "- [ ] 你好")
        view.undoManager?.redo()
        XCTAssertEqual(view.markdown, "- [x] 你好")
        view.undoManager?.beginUndoGrouping()
        view.insertText("\n")
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.markdown, "- [x] 你好\n- [ ] ")
        view.undoManager?.beginUndoGrouping()
        view.insertText("\n")
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.markdown, "- [x] 你好\n")
        view.undoManager?.undo()
        XCTAssertEqual(view.markdown, "- [x] 你好\n- [ ] ")
        view.undoManager?.redo()
        XCTAssertEqual(view.markdown, "- [x] 你好\n")
        view.undoManager?.beginUndoGrouping()
        view.insertText("普通正文")
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.markdown, "- [x] 你好\n普通正文")
        XCTAssertFalse(view.formattingState().selected.contains("checklist"))
    }

    func testNewlineDoesNotCreateListsInCellsOrCode() {
        for plain in [false, true] {
            let view = editor("- [ ] 中文", inline: !plain)
            view.plainText = plain
            view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            view.insertText("\n")
            XCTAssertEqual(view.markdown, "- [ ] 中文\n")
        }
    }

    func testMarkdownRoundtripStylingAndEmojiFormattingUndo() {
        let source = "## 中文\n\n**粗体** 与 👨‍👩‍👧，保留 `code` 和 [链接](https://example.com)"
        let view = editor(source)
        XCTAssertEqual(view.markdown, source)
        view.renderMarkdown()
        XCTAssertEqual(view.markdown, source)
        let emoji = (source as NSString).range(of: "👨‍👩‍👧")
        view.selectedRange = emoji
        view.undoManager?.removeAllActions()
        view.undoManager?.beginUndoGrouping()
        view.performMarkdownAction("bold")
        view.undoManager?.endUndoGrouping()
        XCTAssertTrue(view.markdown.contains("**👨‍👩‍👧**"))
        view.undoManager?.undo()
        XCTAssertEqual(view.markdown, source)
        XCTAssertEqual(view.selectedRange, emoji)
        view.undoManager?.redo()
        XCTAssertTrue(view.markdown.contains("**👨‍👩‍👧**"))
    }

    func testCompositionNeverReplacesBufferOrPublishesPinyin() {
        for inline in [false, true] {
            var stored = "原文\n"
            let binding = Binding(get: { stored }, set: { stored = $0 })
            let coordinator = MarkdownTextEditor.Coordinator(text: binding, onFocus: nil, plainText: false)
            let view = editor(stored, inline: inline)
            view.delegate = coordinator
            view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            view.undoManager?.removeAllActions()
            view.undoManager?.beginUndoGrouping()
            view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
            coordinator.textViewDidChange(view)
            XCTAssertNotNil(view.markedTextRange)
            XCTAssertEqual(stored, "原文\n")
            let composing = view.markdown
            view.renderMarkdown()
            view.load(markdown: "外部回显")
            view.performMarkdownAction("bold")
            XCTAssertEqual(view.markdown, composing)
            XCTAssertNotNil(view.markedTextRange)
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
            view.unmarkText()
            XCTAssertNil(view.markedTextRange)
            XCTAssertEqual(stored, "原文\n中文")
            XCTAssertEqual(view.markdown, stored)
            view.undoManager?.endUndoGrouping()
            view.undoManager?.undo()
            XCTAssertEqual(stored, "原文\n")
            view.undoManager?.redo()
            XCTAssertEqual(stored, "原文\n中文")
        }
    }

    func testCellInputSaveEchoUndoAndRedo() {
        var stored = "单元格"
        let coordinator = MarkdownTextEditor.Coordinator(text: Binding(get: { stored }, set: { stored = $0 }), onFocus: nil, plainText: false)
        let view = editor(stored, inline: true)
        view.delegate = coordinator
        view.documentUndoManager = UndoManager()
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        view.undoManager?.beginUndoGrouping()
        view.insertText("你好")
        coordinator.textViewDidChange(view)
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(stored, "单元格你好")
        view.load(markdown: stored) // Saving echoes the binding; this must not reset undo.
        view.undoManager?.undo()
        coordinator.textViewDidChange(view)
        XCTAssertEqual(stored, "单元格")
        view.undoManager?.redo()
        coordinator.textViewDidChange(view)
        XCTAssertEqual(stored, "单元格你好")
        view.performMarkdownAction("heading")
        XCTAssertEqual(stored, "单元格你好")
    }
    func testSharedCellHistoryAndTableStructure() {
        let manager = UndoManager()
        let first = editor("甲", inline: true), second = editor("乙", inline: true)
        first.documentUndoManager = manager; second.documentUndoManager = manager
        manager.beginUndoGrouping()
        first.selectedRange = NSRange(location: 1, length: 0)
        first.rememberSelection(); first.insertText("你好")
        manager.endUndoGrouping()
        let buffer = DocumentBlockBuffer("| A | B |\n| --- | --- |\n| 甲 | 乙 |\n")
        let original = buffer.blocks
        var expanded = original
        guard case .table(var rows, let alignment) = expanded[0].content else { return XCTFail("Missing table") }
        rows.append(["", ""]); expanded[0].content = .table(rows: rows, alignment: alignment)
        manager.beginUndoGrouping(); buffer.replace(expanded, undo: manager); manager.endUndoGrouping()
        manager.beginUndoGrouping()
        second.selectedRange = NSRange(location: 1, length: 0)
        second.rememberSelection(); second.insertText("中文")
        manager.endUndoGrouping()
        manager.undo(); XCTAssertEqual(second.markdown, "乙")
        manager.undo(); XCTAssertEqual(buffer.blocks, original)
        manager.undo(); XCTAssertEqual(first.markdown, "甲"); XCTAssertEqual(first.selectedRange.location, 1)
        manager.redo(); XCTAssertEqual(first.markdown, "甲你好")
        manager.redo(); XCTAssertEqual(buffer.blocks, expanded)
        manager.redo(); XCTAssertEqual(second.markdown, "乙中文")
    }

    func testFormattingAndNarrowLargeTextKeepSourceAndSelection() {
        let source = "## 标题\n**粗体** 普通\n- [ ] 清单"
        let view = editor(source)
        view.selectedRange = (source as NSString).range(of: "粗体")
        XCTAssertTrue(view.formattingState().selected.contains("bold"))
        view.selectedRange = (source as NSString).range(of: "粗体** 普通")
        XCTAssertTrue(view.formattingState().mixed.contains("bold"))
        let selection = view.selectedRange
        for width in [CGFloat(280), 700] {
            view.frame.size.width = width
            view.overrideUserInterfaceStyle = width == 280 ? .dark : .light
            view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            view.renderMarkdown(); view.layoutIfNeeded()
            XCTAssertEqual(view.markdown, source); XCTAssertEqual(view.selectedRange, selection)
        }
    }

    func testLinkRemovalAndTableEscaping() {
        let view = editor("[中文](https://example.com)", inline: true)
        view.selectedRange = NSRange(location: 1, length: 2)
        view.performMarkdownAction("link:")
        XCTAssertEqual(view.markdown, "中文")
        view.selectedRange = NSRange(location: 0, length: 2)
        view.performMarkdownAction("link:javascript:alert(1)")
        XCTAssertEqual(view.markdown, "中文")
        var table = DocumentBlock(.table(rows: [["A", "B"], [view.markdown + " | 你好\n下一行", "乙"]], alignment: ["---", "---"]))
        let serialized = table.markdown
        guard case .table(let rows, _) = DocumentBlocks.parse(serialized).first?.content else { return XCTFail("Table did not roundtrip") }
        XCTAssertEqual(rows[1][0], "中文 | 你好\n下一行")
        table.content = .table(rows: rows, alignment: ["---", "---"])
        XCTAssertEqual(table.markdown, serialized)
    }

    func testTableCaretRevealsThroughHorizontalContainer() async {
        let outer = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        outer.contentSize = CGSize(width: 320, height: 1000)
        let horizontal = UIScrollView(frame: CGRect(x: 0, y: 600, width: 320, height: 80))
        horizontal.contentSize = CGSize(width: 600, height: 80)
        let view = MDMarkdownTextView(frame: CGRect(x: 0, y: 0, width: 180, height: 60))
        view.load(markdown: "中文单元格")
        window.rootViewController!.view.addSubview(outer)
        outer.addSubview(horizontal); horizontal.addSubview(view)
        view.becomeFirstResponder()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.markdown), onFocus: nil, plainText: false)
        coordinator.revealCaret(view)
        let rendered = expectation(description: "caret reveal layout")
        DispatchQueue.main.async { rendered.fulfill() }
        await fulfillment(of: [rendered], timeout: 2)
        XCTAssertGreaterThan(outer.contentOffset.y, 0)
        XCTAssertEqual(view.markdown, "中文单元格")
    }

    func testLongDocumentReusesParseAcrossSelectionAndStyling() {
        let source = String(repeating: "**中文** 正文 👨‍👩‍👧\n", count: 800)
        let view = editor(source)
        let parsed = view.parseCount
        let start = CFAbsoluteTimeGetCurrent()
        for location in 0..<100 {
            view.selectedRange = NSRange(location: location, length: 0)
            _ = view.formattingState()
            view.renderMarkdown()
        }
        print("Note cached selection/style 100 updates: \(CFAbsoluteTimeGetCurrent() - start)s, UTF16=\(source.utf16.count)")
        XCTAssertEqual(view.parseCount, parsed)
        view.selectedRange = NSRange(location: source.utf16.count, length: 0)
        view.insertText("新内容")
        view.renderMarkdown()
        _ = view.formattingState()
        XCTAssertEqual(view.parseCount, parsed + 1)
        let afterEdit = view.parseCount
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        view.renderMarkdown(); _ = view.formattingState()
        XCTAssertEqual(view.parseCount, afterEdit)
        XCTAssertNotNil(view.markedTextRange)
        view.insertText("你好"); view.unmarkText()
        view.renderMarkdown(); _ = view.formattingState()
        XCTAssertEqual(view.parseCount, afterEdit + 1)
        XCTAssertTrue(view.markdown.hasSuffix("新内容你好"))
    }

    private func settleLayout() async {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        window.rootViewController?.view.layoutIfNeeded()
    }
    private func textViews(in view: UIView) -> [MDMarkdownTextView] {
        (view as? MDMarkdownTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    func testBodyUsesMeasuredHeightAcrossWidthsAndComposition() async {
        let source = String(repeating: "长文中文 👨‍👩‍👧 **排版** 换行内容\n", count: 100)
        let host = UIHostingController(rootView: ScrollView {
            MarkdownTextEditor(text: .constant(source), expandsToContent: true)
        })
        window.rootViewController = host
        await settleLayout()
        guard let view = textViews(in: host.view).first else { return XCTFail("正文控件未创建") }
        XCTAssertFalse(view.isScrollEnabled)
        XCTAssertGreaterThan(view.bounds.height, 620)
        var narrowHeight: CGFloat = 0
        for width in [CGFloat(280), 700] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 500)
            view.overrideUserInterfaceStyle = width == 280 ? .dark : .light
            await settleLayout()
            XCTAssertEqual(view.markdown, source)
            XCTAssertGreaterThanOrEqual(view.bounds.height + 2, view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height)
            if width == 280 { narrowHeight = view.bounds.height }
            else { XCTAssertLessThanOrEqual(view.bounds.height, narrowHeight) }
        }
        view.becomeFirstResponder()
        view.selectedRange = NSRange(location: 10, length: 0)
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        host.view.frame.size.width = 320
        await settleLayout()
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertTrue(view.markdown.contains("zhong"))
    }

    @MainActor @Observable final class EditorHarness {
        var source = "前半👨‍👩‍👧后半\n继续"
        var request: RichEditRequest?
    }
    private struct HarnessView: View {
        @Bindable var state: EditorHarness
        var body: some View {
            ScrollView { BlockDocumentEditor(text: $state.source, request: state.request) }
        }
    }

    func testInsertAtCaretFocusesCellAndUndoRestoresWholeBody() async {
        let state = EditorHarness()
        let original = state.source
        let host = UIHostingController(rootView: HarnessView(state: state))
        window.rootViewController = host
        await settleLayout()
        guard let body = textViews(in: host.view).first else { return XCTFail("正文控件未创建") }
        body.becomeFirstResponder()
        let selection = (original as NSString).range(of: "👨‍👩‍👧")
        body.selectedRange = selection
        await settleLayout()
        state.request = RichEditRequest(action: "insert-table")
        await settleLayout()
        XCTAssertTrue(state.source.hasPrefix("前半👨‍👩‍👧\n| 列一 | 列二 |"))
        XCTAssertTrue(state.source.hasSuffix("后半\n继续"))
        guard let cell = textViews(in: host.view).first(where: { $0.isFirstResponder }) else { return XCTFail("插入后未聚焦") }
        XCTAssertTrue(cell.inlineOnly)
        XCTAssertEqual(cell.markdown, "列一")
        // Native text edits and structural undo must remain in one history.
        cell.insertText("新")
        await settleLayout()
        cell.undoManager?.undo()
        await settleLayout()
        XCTAssertEqual(cell.markdown, "列一")
        cell.undoManager?.undo()
        await settleLayout()
        XCTAssertEqual(state.source, original)
        XCTAssertTrue(body.isFirstResponder)
        XCTAssertEqual(body.selectedRange, selection)
        body.undoManager?.redo()
        await settleLayout()
        XCTAssertTrue(state.source.contains("| 列一 | 列二 |"))
    }

    func testKeyboardRevealKeepsLongBodyCaretVisibleWithoutDelayedJump() async {
        let outer = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        outer.contentSize = CGSize(width: 320, height: 4000)
        let view = MDMarkdownTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 3500))
        view.isScrollEnabled = false
        view.load(markdown: String(repeating: "中文正文\n", count: 100))
        window.rootViewController!.view.addSubview(outer)
        outer.addSubview(view)
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.markdown), onFocus: nil, plainText: false)
        view.delegate = coordinator
        view.becomeFirstResponder()
        view.selectedRange = NSRange(location: 250, length: 0)
        let keyboard = CGRect(x: 0, y: 400, width: 390, height: 444)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard)])
        await settleLayout()
        let caret = view.convert(view.caretRect(for: view.selectedTextRange!.end), to: window)
        XCTAssertLessThanOrEqual(caret.maxY, keyboard.minY)
        XCTAssertGreaterThanOrEqual(caret.minY, 0)
        XCTAssertGreaterThan(outer.contentOffset.y, 0)
        let offset = outer.contentOffset
        await settleLayout()
        XCTAssertEqual(outer.contentOffset, offset)
        XCTAssertEqual(view.selectedRange.location, 250)
    }

    @MainActor @Observable final class ImageHarness {
        var phase = AsyncImagePhase.empty
    }
    private struct ImageMarker: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
    private struct ImageHarnessView: View {
        @Bindable var state: ImageHarness
        let marker: UIView
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    NoteImageViewport(phase: state.phase, label: "测试图片")
                    ImageMarker(view: marker).frame(height: 40)
                    Color.clear.frame(height: 1200)
                }
            }
        }
    }
    func testImagePhasesKeepFollowingContentAndScrollPosition() async {
        let state = ImageHarness(), marker = UIView()
        let host = UIHostingController(rootView: ImageHarnessView(state: state, marker: marker))
        window.rootViewController = host
        await settleLayout()
        var ancestor = marker.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        guard let scroll = ancestor as? UIScrollView else { return XCTFail("缺少页面滚动容器") }
        for width in [CGFloat(280), 700] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 500)
            await settleLayout()
            scroll.setContentOffset(CGPoint(x: 0, y: 150), animated: false)
            XCTAssertGreaterThan(marker.convert(CGPoint.zero, to: scroll).y, 100)
            let origin = marker.convert(CGPoint.zero, to: window)
            let size = scroll.contentSize, offset = scroll.contentOffset
            for dimensions in [CGSize(width: 20, height: 300), CGSize(width: 300, height: 20)] {
                let image = UIGraphicsImageRenderer(size: dimensions).image { context in
                    UIColor.systemGreen.setFill(); context.fill(CGRect(origin: .zero, size: dimensions))
                }
                for phase in [AsyncImagePhase.success(Image(uiImage: image)), .failure(URLError(.timedOut)), .empty] {
                    state.phase = phase
                    await settleLayout()
                    XCTAssertEqual(marker.convert(CGPoint.zero, to: window).y, origin.y, accuracy: 0.5)
                    XCTAssertEqual(scroll.contentSize.height, size.height, accuracy: 0.5)
                    XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 0.5)
                }
            }
        }
    }

}

@MainActor @Observable private final class NoteSearchCommands { var request: RichEditRequest? }

private struct NoteSearchFixture: View {
    @State var source: String
    let search: NoteSearchSession
    var commands: NoteSearchCommands? = nil
    var body: some View {
        ScrollView {
            VisualDocumentEditor(text: $source, request: commands?.request, search: search).padding(16)
        }
        .safeAreaInset(edge: .top) { NoteDocumentSearchBar(session: search, text: source).padding(8).background(.regularMaterial) }
        .dynamicTypeSize(.xxxLarge)
    }
}
