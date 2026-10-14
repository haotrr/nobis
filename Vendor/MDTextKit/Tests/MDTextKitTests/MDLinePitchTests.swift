import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI

/// Body line metrics with the default theme at 15pt: minimum line height = max(round(1.5 × 15), font line height),
/// line spacing = round(minimum − (ascender + |descender| + leading)), tab 33, column 22, gutter 11, line width 720.
@MainActor final class MDLinePitchTests: XCTestCase {
    func testBodyLineMetrics() {
        let vc = MDEditorViewController(themeManager: TestTheme.makeManager())
        _ = vc.view
        vc.load(markdown: "Welcome to a Swift Markdown editor PolarMark MDTextKit MDTextKitUI and more words to wrap the line for sure yes.\nMarkers like\n\n- A bullet\n- Another\n")
        let tv = vc.textView!
        tv.frame = NSRect(x: 0, y: 0, width: 708, height: 748)
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let p = tv.mdTextStorage.paragraphStyle(at: 0)!
        let font = tv.mdTextStorage.font(at: 0)!
        let natural = font.ascender + abs(font.descender) + font.leading
        let expectedMin = max(23, ceil(natural))
        XCTAssertEqual(p.minimumLineHeight, expectedMin)
        XCTAssertEqual(p.lineSpacing, (expectedMin - natural).rounded())
        let pitch = p.minimumLineHeight + p.lineSpacing
        var ys: [CGFloat] = []
        tv.layoutManager!.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: tv.layoutManager!.numberOfGlyphs)) { rect, _, _, _, _ in ys.append(rect.minY) }
        for i in 1..<ys.count { XCTAssertEqual(ys[i] - ys[i - 1], pitch, "line \(i)") }
        XCTAssertEqual(p.headIndent, 33)
        let r = vc.editorController.attributedStringRenderer
        XCTAssertEqual(r.tabSize, 33)
        XCTAssertEqual(r.columnSize, 22)
        XCTAssertEqual(r.gutterSize, 11)
        XCTAssertEqual(r.textContainerMaxWidth, 720)
        XCTAssertEqual(tv.mdTextContainer.lineFragmentPadding, 23)
    }
}
