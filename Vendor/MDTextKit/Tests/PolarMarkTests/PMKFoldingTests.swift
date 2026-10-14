import XCTest
@testable import PolarMark

final class PMKFoldingTests: XCTestCase {
    let marker = "<!-- {\"fold\":true} -->"

    func testFoldAttributesOnFoldedHeading() {
        let ast = PMKAST(markdown: "# Title\n## A\(marker)\ntext\n\n## B")
        let s = ast.annotatedString()
        let ns = s.string as NSString
        let m = ns.range(of: marker)
        XCTAssertNotNil(s.attribute(.pmkFoldMarker, at: m.location, effectiveRange: nil))
        var fold = NSRange()
        XCTAssertNotNil(s.attribute(.pmkFold, at: m.location, longestEffectiveRange: &fold, in: NSRange(location: 0, length: s.length)))
        // marker + "\ntext\n" (the blank line's newline stays visible)
        XCTAssertEqual(ns.substring(with: fold), marker + "\ntext\n")
        XCTAssertNotNil(s.attribute(.pmkFoldable, at: ns.range(of: "## A").location, effectiveRange: nil))
        XCTAssertNil(s.attribute(.pmkFoldable, at: ns.range(of: "## B").location, effectiveRange: nil), "last heading has no content to fold")
    }

    func testToggleFoldInsertsAndRemovesMarker() {
        let ast = PMKAST(markdown: "# Title\n## A\ntext\n## B\nmore")
        let headA = ("# Title\n" as NSString).length
        let fold = ast.toggleFold(in: NSRange(location: headA + 1, length: 0), selectionRange: NSRange(location: headA + 1, length: 0))
        XCTAssertEqual(fold.count, 1)
        XCTAssertEqual(fold[0].replacementString, marker)
        XCTAssertEqual(fold[0].replacementRange.location, headA + 4)   // before "\n" of "## A"
        let folded = PMKAST(markdown: "# Title\n## A\(marker)\ntext\n## B\nmore")
        let unfold = folded.toggleFold(in: NSRange(location: headA + 1, length: 0), selectionRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(unfold.count, 1)
        XCTAssertEqual(unfold[0].replacementString, "")
        XCTAssertEqual(unfold[0].replacementRange, NSRange(location: headA + 4, length: (marker as NSString).length))
        // caret landing inside the hidden text unfolds
        let edge = folded.unfoldAtRangeEdges(NSRange(location: headA + 4 + (marker as NSString).length + 3, length: 0), selectionRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edge.count, 1)
        XCTAssertEqual(folded.unfoldAllHeading(selectionRange: NSRange(location: 0, length: 0)).count, 1)
    }

    func testStrayMarkerIsRemoved() {
        let ast = PMKAST(markdown: "para \(marker)\nmore")
        let r = ast.removeStrayMetaComment(in: NSRange(location: 0, length: ast.markdownLength), selectionRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(r.count, 1)
    }
}
