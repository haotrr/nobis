import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI
@testable import SFThemeKit

/// Programmatic changes (AST operations, task toggles, folding) are undoable through the
/// editor's own undo manager; undo restores the previous attributed text and selection.
@MainActor final class MDUndoTests: XCTestCase {
    private func makeEditor(_ md: String) -> (MDEditorViewController, NSWindow) {
        let vc = MDEditorViewController(themeManager: TestTheme.makeManager())
        vc.loadView(); vc.viewDidLoad()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 708, height: 748), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentViewController = vc
        vc.load(markdown: md)
        return (vc, win)
    }

    func testToggleTaskIsUndoable() {
        let (vc, win) = makeEditor("- [ ] task\n")
        _ = win
        let tv = vc.textView!
        XCTAssertNil(tv.undoManager, "AppKit records no typing of its own")
        XCTAssertFalse(tv.editorUndoManager.canUndo, "loading clears the undo stack")
        vc.editorController.toggleTask(in: tv, range: NSRange(location: 0, length: 0), style: 0)
        XCTAssertEqual(vc.markdown, "- [x] task\n")
        XCTAssertTrue(tv.editorUndoManager.canUndo)
        tv.editorUndoManager.undo()
        XCTAssertEqual(vc.markdown, "- [ ] task\n")
        XCTAssertTrue(tv.editorUndoManager.canRedo)
        tv.editorUndoManager.redo()
        XCTAssertEqual(vc.markdown, "- [x] task\n")
    }

    func testFoldAndUnfoldAreUndoableAndRestoreSelection() {
        let (vc, win) = makeEditor("# T\n## A\ntext\n## B\n")
        _ = win
        let tv = vc.textView!
        tv.setSelectedRange(NSRange(location: 9, length: 0))   // inside "text"
        vc.editorController.toggleFolding(at: 5, in: tv)        // "## A" line
        XCTAssertTrue(vc.markdown.contains("<!-- {\"fold\":true} -->"))
        tv.editorUndoManager.undo()
        XCTAssertFalse(vc.markdown.contains("fold"))
        XCTAssertEqual(tv.selectedRange().location, 9, "undo restores the selection from before the change")
    }

    func testTypingThenUndoRestoresText() {
        let (vc, win) = makeEditor("hello\n")
        _ = win
        let tv = vc.textView!
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText(" world", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(vc.markdown, "hello world\n")
        tv.editorUndoManager.undo()
        XCTAssertEqual(vc.markdown, "hello\n")
    }
}
