import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI
import SFThemeKit

/// The surface a host uses without `MDEditorViewController`: a bare text view, the formatting
/// query and the link hook.
@MainActor final class MDHostAPITests: XCTestCase {
    private func makeTextView(_ md: String) -> (MDTextView, NSWindow) {
        let controller = MDEditorController()
        controller.autoHideMarkdown = true
        let tv = MDTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), editorController: controller)
        tv.applyTheme(TestTheme.makeManager())
        let scroll = NSScrollView(frame: tv.frame)
        scroll.documentView = tv
        let win = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = scroll
        controller.loadString(md, into: tv)
        return (tv, win)
    }

    func testBareTextViewStylesAndRoundTrips() {
        let md = "# Title\n\n- [ ] task\n\n**bold** text\n"
        let (tv, _) = makeTextView(md)
        XCTAssertEqual(tv.markdown, md)
        XCTAssertTrue(tv.mdTextStorage.textAttachment(at: 0) is MDATXHeadingAttachment)
        XCTAssertGreaterThan(tv.mdLayoutManager.basePointSize, 0, "applyTheme reached the layout manager")
        XCTAssertNotNil(tv.typingAttributes[.font])
    }

    func testCaretNeverStandsBeforeAHeadingMarker() {
        let (tv, _) = makeTextView("intro\n# Title\n")
        let ts = tv.mdTextStorage
        guard let marker = (0..<ts.length).first(where: { ts.textAttachment(at: $0) is MDATXHeadingAttachment }) else {
            return XCTFail("no heading marker")
        }
        tv.setSelectedRange(NSRange(location: marker, length: 0))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: marker + 1, length: 0), "a click before the marker lands after it")
        tv.moveLeft(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: marker - 1, length: 0), "stepping back skips to the line above")
        tv.moveRight(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: marker + 1, length: 0), "stepping forward skips the marker")

        let (top, _) = makeTextView("# Title\n")
        top.setSelectedRange(NSRange(location: 1, length: 0))
        top.moveLeft(nil)
        XCTAssertEqual(top.selectedRange(), NSRange(location: 1, length: 0), "the first heading keeps the caret after its marker")
    }

    func testFormattingFollowsTheSelection() {
        let (tv, _) = makeTextView("# Title\n\n**bold** plain\n\n- [ ] task\n\n> quote\n\n```\ncode\n```\n")
        let ts = tv.mdTextStorage
        func formatting(at markdownOffset: Int) -> MDFormatting {
            tv.setSelectedRange(ts.attributedStringRange(fromStringRange: NSRange(location: markdownOffset, length: 0)))
            return tv.editorController.formatting(in: tv)
        }
        XCTAssertEqual(formatting(at: 3).headingLevel, 1)
        let bold = formatting(at: 12)
        XCTAssertEqual(bold.headingLevel, 0)
        XCTAssertTrue(bold.inline.contains(.strong))
        XCTAssertFalse(formatting(at: 18).inline.contains(.strong))
        XCTAssertEqual(formatting(at: 26).list, .task)
        XCTAssertTrue(formatting(at: 39).isBlockquote)
        XCTAssertTrue(formatting(at: 51).isCodeBlock)
        tv.setSelectedRange(NSRange(location: 0, length: ts.length))
        XCTAssertNil(tv.editorController.formatting(in: tv).headingLevel, "mixed paragraphs report no level")
    }

    func testFormattingLightsWhatTheToggleUndoes() {
        let (tv, _) = makeTextView("plain\n")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.editorController.toggleStrong(in: tv)
        XCTAssertEqual(tv.markdown, "**plain**\n")
        XCTAssertTrue(tv.editorController.formatting(in: tv).inline.contains(.strong))
        tv.editorController.toggleStrong(in: tv)
        XCTAssertEqual(tv.markdown, "plain\n")
        XCTAssertFalse(tv.editorController.formatting(in: tv).inline.contains(.strong))
        tv.editorController.toggleHeading(in: tv, headingLevel: 2)
        XCTAssertEqual(tv.editorController.formatting(in: tv).headingLevel, 2)
    }

    func testOpenURLHookReceivesTheClickedLink() {
        let (tv, _) = makeTextView("[label](https://example.com/x)\n")
        var opened: [URL] = []
        tv.openURL = { opened.append($0) }
        let ts = tv.mdTextStorage
        var index: Int?
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: []) { v, r, stop in
            if v is MDLinkTextAttachment { index = r.location; stop.pointee = true }
        }
        let i = try! XCTUnwrap(index)
        let cell = try! XCTUnwrap(ts.textAttachment(at: i)?.attachmentCell)
        tv.textView(tv, clickedOn: cell, in: .zero, at: i)
        XCTAssertEqual(opened, [URL(string: "https://example.com/x")!])
    }

    func testHighlightBoxIsCentredOnTheInk() {
        for (md, probe) in [("plain ==完成笔记== text\n", "国"), ("plain ==highlighted== text\n", "hg")] {
            let (tv, _) = makeTextView(md)
            let lm = tv.mdLayoutManager
            lm.ensureLayout(for: tv.textContainer!)
            let ts = tv.mdTextStorage
            let run = ts.attributedStringRange(fromStringRange: NSRange(location: 8, length: 4))
            let glyphs = lm.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rect = lm.rectArrayForInlineDrawing(atGlyphRange: glyphs, in: tv.textContainer!, at: .zero)[0]
            let baseline = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY + lm.location(forGlyphAt: glyphs.location).y
            var font: NSFont?
            ts.enumerateAttribute(.font, in: run) { value, _, stop in
                if let f = value as? NSFont, f.pointSize >= 1 { font = f; stop.pointee = true }
            }
            let ink = font!.inkExtents(probing: probe)
            let inkMiddle = baseline - (ink.above - ink.below) / 2
            XCTAssertEqual(rect.midY, inkMiddle, accuracy: 0.01, md)
            XCTAssertEqual(rect.height, lm.expectedLineHeight(at: run.location), accuracy: 0.01, md)
        }
    }

    func testThemeColorsMayBeDynamicNSColors() {
        let dynamic = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black }
        let theme = SFTheme(name: "Host", jsonObject: ["editor": ["text color": dynamic, "cursor color": "$editor.text color"]])
        let manager = SFThemeManager(theme: theme)
        XCTAssertTrue(manager.color(forKey: "editor.text color") === dynamic)
        XCTAssertTrue(manager.color(forKey: "editor.cursor color") === dynamic, "$ references resolve to the same object")
    }

    func testCJKFamilyJoinsTheCascade() {
        let manager = TestTheme.makeManager()
        manager.overrides["editor.text font cjk"] = "PingFang SC"
        let font = manager.font(forKey: "editor.text font", size: 15)
        let cascade = font.fontDescriptor.fontAttributes[.cascadeList] as? [NSFontDescriptor]
        XCTAssertEqual(cascade?.first?.fontAttributes[.family] as? String, "PingFang SC")
    }
}
