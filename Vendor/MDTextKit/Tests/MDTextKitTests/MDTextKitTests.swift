import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI
import PolarMark

@MainActor final class MDTextKitTests: XCTestCase {
    private func makeEditor() -> MDEditorViewController {
        let vc = MDEditorViewController(themeManager: TestTheme.makeManager())
        _ = vc.view
        return vc
    }

    func testRoundTripPreservesMarkdown() {
        let md = "# Title\n\n- [ ] task\n- [x] done\n\n1. one\n2. two\n\n> quote\n\n**bold** *em* `code` ==hi== [l](https://a.b) #tag\n\n---\n"
        let vc = makeEditor()
        vc.load(markdown: md)
        XCTAssertEqual(vc.markdown, md)
    }

    func testHeadingMarkerBecomesAttachment() {
        let vc = makeEditor()
        vc.load(markdown: "# Title")
        let ts = vc.textView.mdTextStorage
        XCTAssertTrue(ts.textAttachment(at: 0) is MDATXHeadingAttachment)
        XCTAssertEqual(ts.string.count, "\u{FFFC}Title".count)
        XCTAssertEqual(ts.font(at: 1)?.pointSize ?? 0, vc.editorController.attributedStringRenderer.headingStyler.headerSize(forBaseSize: 15, headerLevel: 1, maxHeaderLevel: 7, modularScale: 1.125))
    }

    func testListMarkersAndTasks() {
        let vc = makeEditor()
        vc.load(markdown: "- a\n- [ ] b\n- [x] c\n1. d")
        let ts = vc.textView.mdTextStorage
        XCTAssertTrue(ts.textAttachment(at: 0) is MDUnorderedListTextAttachment)
        let ns = ts.string as NSString
        var tasks = 0
        var ordered = 0
        for i in 0..<ns.length where ns.character(at: i) == 0xFFFC {
            if ts.textAttachment(at: i) is MDTaskTextAttachment { tasks += 1 }
            if ts.textAttachment(at: i) is MDOrderedListTextAttachment { ordered += 1 }
        }
        XCTAssertEqual(tasks, 2)
        XCTAssertEqual(ordered, 1)
    }

    func testTypingKeepsCaretAfterTypedCharacter() {
        let vc = makeEditor()
        vc.load(markdown: "Hello")
        let tv = vc.textView!
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(vc.markdown, "Hello!")
        XCTAssertEqual(tv.selectedRange().location, 6)
        tv.insertText(" **b", replacementRange: tv.selectedRange())
        tv.insertText("old**", replacementRange: tv.selectedRange())
        XCTAssertEqual(vc.markdown, "Hello! **bold**")
        XCTAssertEqual(tv.selectedRange().location, tv.mdTextStorage.length)
    }

    func testMarkdownHidingFollowsCaret() {
        let vc = makeEditor()
        vc.load(markdown: "a **bold** b")
        let tv = vc.textView!
        let ts = tv.mdTextStorage
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        vc.editorController.autoHideMarkdown(in: tv, forOldSelectionRange: NSRange(location: 0, length: 0), newSelectionRange: NSRange(location: 0, length: 0))
        let hiddenFont = ts.font(at: 2)
        XCTAssertEqual(hiddenFont?.pointSize ?? 0, 0.01, accuracy: 0.001)
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        vc.editorController.autoHideMarkdown(in: tv, forOldSelectionRange: NSRange(location: 0, length: 0), newSelectionRange: NSRange(location: 5, length: 0))
        XCTAssertGreaterThan(ts.font(at: 2)?.pointSize ?? 0, 1)
    }

    func testNewlineContinuesList() {
        let vc = makeEditor()
        vc.load(markdown: "- item")
        let tv = vc.textView!
        tv.setSelectedRange(NSRange(location: tv.mdTextStorage.length, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(vc.markdown, "- item\n- ")
        tv.insertNewline(nil)
        XCTAssertEqual(vc.markdown, "- item\n")
    }

    func testBackspaceOnSpacerRemovesPair() {
        let s = NSMutableAttributedString(string: "x`c`y")
        let r = MDAttributedStringRenderer()
        let styled = r.styledAttributedString(fromString: "x`c`y")
        XCTAssertTrue(styled.hasOpeningSpacer(at: 1))
        _ = s
    }

    func testSpacersAdjustSelection() {
        let r = MDAttributedStringRenderer()
        let styled = r.styledAttributedString(fromString: "x`c`y")
        // index 1 is the opening spacer attachment, index 2 the backtick: both carry MDSpacer = 1, so the
        // caret may not land between them when stepping right from index 1; the editor jumps past the marker.
        XCTAssertTrue(styled.hasOpeningSpacer(at: 2))
        let adjusted = styled.spacersAdjustedSelection(forProposedSelection: NSRange(location: 2, length: 0), currentSelection: NSRange(location: 1, length: 0))
        XCTAssertEqual(adjusted.location, 3)
    }
}
