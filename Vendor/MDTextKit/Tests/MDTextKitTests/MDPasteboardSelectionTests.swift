import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI
@testable import PolarMark

@MainActor final class MDPasteboardSelectionTests: XCTestCase {
    private func makeEditor(_ md: String) -> (MDEditorViewController, NSWindow) {
        let vc = MDEditorViewController(themeManager: TestTheme.makeManager())
        vc.loadView(); vc.viewDidLoad()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 708, height: 748), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentViewController = vc
        vc.load(markdown: md)
        return (vc, win)
    }

    func testCopyWritesMarkdownAndArchivedAttributedString() {
        let (vc, win) = makeEditor("- [ ] **task** one\n")
        _ = win
        let tv = vc.textView!
        tv.setSelectedRange(NSRange(location: 0, length: tv.mdTextStorage.length))
        let pb = NSPasteboard(name: NSPasteboard.Name("mdtextkit.test.\(UUID().uuidString)"))
        pb.clearContents()
        XCTAssertTrue(tv.writablePasteboardTypes.contains(MDTextView.attributedStringPboardType))
        XCTAssertTrue(tv.writablePasteboardTypes.contains(.rtfd))
        XCTAssertTrue(tv.writeSelection(to: pb, type: .string))
        XCTAssertEqual(pb.string(forType: .string), "- [ ] **task** one\n", "copy writes the markdown source, not placeholder characters")
        XCTAssertTrue(tv.writeSelection(to: pb, type: MDTextView.attributedStringPboardType))
        let data = pb.data(forType: MDTextView.attributedStringPboardType)!
        let back = NSMutableAttributedString.attributedString(fromPolarData: data)!
        XCTAssertEqual(back.stringByExpandingTextAttachments, "- [ ] **task** one\n")
        XCTAssertTrue(back.textAttachment(at: 0) is MDTaskTextAttachment, "attachments survive the archive round trip")
        XCTAssertTrue(tv.writeSelection(to: pb, type: .rtfd))
        XCTAssertNotNil(pb.data(forType: .rtfd))
    }

    func testPasteDeduplicatesListMarkerAndContinuesQuote() {
        let ast = PMKAST(markdown: "- \n")
        let r = ast.pasteCorrection(in: NSRange(location: 2, length: 0), replacementString: "- item", selectionRange: NSRange(location: 8, length: 0))
        XCTAssertEqual(r.first?.replacementString, "item")
        let quote = PMKAST(markdown: "> a \n")
        let q = quote.pasteCorrection(in: NSRange(location: 4, length: 0), replacementString: "x\ny", selectionRange: NSRange(location: 7, length: 0))
        XCTAssertEqual(q.first?.replacementString, "x\n> y", "multi-line paste inside a quote continues the container")
    }

    func testPasteWhitespaceCorrectionAddsSpaceBetweenWords() {
        let ast = PMKAST(markdown: "ab\n")
        let r = ast.pasteCorrection(in: NSRange(location: 1, length: 0), replacementString: "X", selectionRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(r.first?.replacementString, " X ")
    }

    func testSelectAllInsideCodeBlockSelectsContentFirst() {
        let ast = PMKAST(markdown: "p\n```\ncode\n```\n")
        let inside = NSRange(location: 7, length: 0)
        let first = ast.selectAllText(in: inside, selectionRange: inside).last!.proposedSelection
        XCTAssertEqual(first, NSRange(location: 6, length: 4))
        let second = ast.selectAllText(in: first, selectionRange: first).last!.proposedSelection
        XCTAssertEqual(second, NSRange(location: 0, length: ast.markdownLength))
    }

    func testSelectionCorrectionTakesMarkerPairsWhole() {
        let ast = PMKAST(markdown: "one\n\n**bold** two\n")
        // selection starting in the first block and ending right after the opening "**" of the second
        let current = NSRange(location: 0, length: 3)
        let proposed = NSRange(location: 0, length: 7)   // "one\n\n**"
        var dump = ""
        ast.rootNode.walk { n in dump += "\(n.type) \(n.range) markers=\(n.markerRanges)\n" }
        let r = ast.selectionCorrection(in: current, replacementString: nil, selectionRange: proposed)
        XCTAssertEqual(r.last?.proposedSelection, NSRange(location: 0, length: 5), "a half-selected inline marker is left out\n" + dump)
    }

    func testRichTextImportProducesMarkdown() {
        let rich = NSMutableAttributedString(string: "Title\nplain bold link\n")
        rich.addAttribute(.font, value: NSFont.systemFont(ofSize: 26), range: NSRange(location: 0, length: 5))
        rich.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 6, length: 15))
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 12, length: 4))
        rich.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 17, length: 4))
        let md = MDRTFImporter.markdown(from: rich)
        XCTAssertEqual(md, "# Title\nplain **bold** [link](https://example.com)\n")
    }
}
