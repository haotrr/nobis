import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI

@MainActor final class MDFontTests: XCTestCase {
    func testInlineStylesUseRealFacesAtBodySize() {
        let vc = MDEditorViewController(themeManager: TestTheme.makeManager())
        _ = vc.view
        vc.load(markdown: "a *b* c **d** `e`")
        let ts = vc.textView.mdTextStorage
        let ns = ts.string as NSString
        for i in 0..<ns.length {
            XCTAssertLessThanOrEqual(ts.font(at: i)?.pointSize ?? 0, 16, "index \(i)")
        }
        XCTAssertTrue(ts.font(at: 3)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertTrue(ts.font(at: 10)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(ts.font(at: 16)?.isFixedPitch ?? false, "inline code uses the theme's monospaced font")
    }
}
