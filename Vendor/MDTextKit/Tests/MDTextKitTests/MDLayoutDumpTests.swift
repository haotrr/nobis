import XCTest
import AppKit
@testable import MDTextKit
@testable import MDTextKitUI
@testable import SFThemeKit

/// Debug helper: dumps line fragments of the sample note so they can be compared with reference captures.
@MainActor final class MDLayoutDumpTests: XCTestCase {
    func testDumpSampleLayout() throws {
        guard ProcessInfo.processInfo.environment["MD_DUMP"] != nil else { return }
        TestTheme.makeManager().overrides["editor.text size"] = 16.0
        let vc = MDEditorViewController(themeManager: TestTheme.makeManager())
        vc.loadView()
        vc.viewDidLoad()
        vc.view.frame = NSRect(x: 0, y: 0, width: 708, height: 748)
        vc.textView.frame = NSRect(x: 0, y: 0, width: 708, height: 748)
        let md = """
        Inline `code spans` and ==highlighted text== work too, so does \\*escaping\\*.

        > A quote with a [link](https://example.com) and https://autolink.example/path
        > > nested quote level two

        ---

        Final paragraph after a thematic break.
        """
        vc.load(markdown: md)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 708, height: 748), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentViewController = vc
        win.layoutIfNeeded()
        print("scrollerStyle=\(vc.scrollView.scrollerStyle.rawValue) preferred=\(NSScroller.preferredScrollerStyle.rawValue) contentSize=\(vc.scrollView.contentSize) textView=\(vc.textView.frame.size)")
        if let w = ProcessInfo.processInfo.environment["MD_HR_WIDTH"].flatMap(Double.init) {
            let st = vc.textView.textStorage!
            st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length), options: []) { v, _, _ in
                if let a = v as? MDThematicBreakTextAttachment {
                    switch ProcessInfo.processInfo.environment["MD_HR_EXP"] ?? "" {
                    case "zero": a.bounds = .zero
                    case "boundsy": a.bounds = CGRect(x: 0, y: a.attachmentBaselineOffset, width: a.bounds.width, height: a.bounds.height)
                    case "offset0": a.attachmentBaselineOffset = 0
                    default: a.attachmentSize.width = CGFloat(w)
                    }
                    print("HR exp applied")
                }
            }
            vc.textView.layoutManager!.invalidateLayout(forCharacterRange: NSRange(location: 0, length: st.length), actualCharacterRange: nil)
        }
        if let tb = ProcessInfo.processInfo.environment["MD_TYPESETTER"].flatMap(Int.init), let b = NSLayoutManager.TypesetterBehavior(rawValue: tb) {
            vc.textView.layoutManager!.typesetterBehavior = b
            vc.textView.layoutManager!.invalidateLayout(forCharacterRange: NSRange(location: 0, length: vc.textView.textStorage!.length), actualCharacterRange: nil)
            print("typesetterBehavior=\(b.rawValue) usesFontLeading=\(vc.textView.layoutManager!.usesFontLeading)")
        }
        if let exp = ProcessInfo.processInfo.environment["MD_HR_EXP2"] {
            let st = vc.textView.textStorage!
            var hrIndex = NSNotFound
            st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length), options: []) { v, r, _ in if v is MDThematicBreakTextAttachment { hrIndex = r.location } }
            if hrIndex != NSNotFound {
                st.beginEditing()
                switch exp {
                case "nofont": st.removeAttribute(.font, range: NSRange(location: hrIndex, length: 1))
                case "bigNL": st.addAttribute(.font, value: st.font(at: 0)!.withSize(40), range: NSRange(location: hrIndex + 1, length: 1))
                case "bigAtt": st.addAttribute(.font, value: st.font(at: 0)!.withSize(40), range: NSRange(location: hrIndex, length: 1))
                case "nofontNL": st.removeAttribute(.font, range: NSRange(location: hrIndex + 1, length: 1))
                case "zwsp": st.replaceCharacters(in: NSRange(location: hrIndex + 1, length: 0), with: NSAttributedString(string: "\u{200B}", attributes: st.attributes(at: hrIndex + 1, effectiveRange: nil)))
                case "cellY0": (st.attribute(.attachment, at: hrIndex, effectiveRange: nil) as? SFTextAttachment)?.attachmentBaselineOffset = 0
                default: break
                }
                st.endEditing()
                print("EXP2 \(exp) at \(hrIndex)")
            }
        }
        if ProcessInfo.processInfo.environment["MD_NOLEADING"] != nil {
            vc.textView.layoutManager!.usesFontLeading = false
            vc.textView.layoutManager!.invalidateLayout(forCharacterRange: NSRange(location: 0, length: vc.textView.textStorage!.length), actualCharacterRange: nil)
        }
        let lm = vc.textView.layoutManager!
        let tc = vc.textView.textContainer!
        lm.ensureLayout(for: tc)
        let s = vc.textView.string as NSString
        let full = vc.textView.textStorage!
        full.enumerateAttributes(in: NSRange(location: 0, length: full.length), options: []) { attrs, r, _ in
            let sub = (full.string as NSString).substring(with: r).replacingOccurrences(of: "\n", with: "⏎")
            if sub.contains("\u{FFFC}") || sub.hasPrefix("⏎") || r.location > 165 {
                let keys = attrs.keys.map { $0.rawValue }.sorted().joined(separator: ",")
                let f = attrs[.font] as? NSFont
                print("ATTR \(r) '\(sub.prefix(12))' font=\(f?.fontName ?? "-") \(f?.pointSize ?? 0) keys=\(keys)")
            }
        }
        do {
            let tv = vc.textView!
            tv.layoutManager!.ensureLayout(for: tv.textContainer!)
            let rectAll = NSRect(x: 0, y: 0, width: tv.bounds.width, height: max(tv.bounds.height, 300))
            if let rep = tv.bitmapImageRepForCachingDisplay(in: rectAll) {
                tv.cacheDisplay(in: rectAll, to: rep)
                let scale = CGFloat(rep.pixelsWide) / rectAll.width
                var hrLineTop: CGFloat = -1
                lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { r, _, _, g, _ in
                    let c = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
                    if (tv.string as NSString).substring(with: c).hasPrefix("\u{FFFC}"), (tv.string as NSString).substring(with: c).count <= 3 { hrLineTop = r.minY }
                }
                if hrLineTop >= 0 {
                    var rows: [Int] = []
                    for py in Int(hrLineTop * scale)..<Int((hrLineTop + 27) * scale) {
                        var dark = 0
                        for px in stride(from: Int(200 * scale), to: Int(400 * scale), by: 2) {
                            if let c = rep.colorAt(x: px, y: py), c.brightnessComponent < 0.97 { dark += 1 }
                        }
                        if dark > 40 { rows.append(py) }
                    }
                    print(String(format: "RULE rows (px, scale %.0f) relative to hr line top: %@", scale, rows.map { String(format: "%.2f", CGFloat($0) / scale - hrLineTop) }.joined(separator: ",")))
                }
            }
        }
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, used, _, glyphRange, _ in
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var text = s.substring(with: chars).replacingOccurrences(of: "\n", with: "⏎")
            if text.count > 28 { text = String(text.prefix(28)) + "…" }
            let p = vc.textView.textStorage!.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle
            let font = vc.textView.textStorage!.attribute(.font, at: chars.location, effectiveRange: nil) as? NSFont
            let loc = lm.location(forGlyphAt: glyphRange.location)
            var cell = ""
            if let att = vc.textView.textStorage!.attribute(.attachment, at: chars.location, effectiveRange: nil) as? NSTextAttachment, let c = att.attachmentCell as? NSTextAttachmentCell {
                let f = c.cellFrame(for: tc, proposedLineFragment: rect, glyphPosition: loc, characterIndex: chars.location)
                let asz = lm.attachmentSize(forGlyphAt: glyphRange.location)
                let br = lm.boundingRect(forGlyphRange: NSRange(location: glyphRange.location, length: 1), in: tc)
                print(String(format: "  ATTBOUNDS top=%.2f (line top %.2f) h=%.2f", br.minY - rect.minY, rect.minY, br.height))
                cell = String(format: " cell=(%.2f,%.2f %.0fx%.2f) cellClass=%@ attClass=%@ lmSize=%.0fx%.2f bounds.y=%.2f cellBaseline=%.2f", f.origin.x, f.origin.y, f.width, f.height, String(describing: type(of: c)), String(describing: type(of: att)), asz.width, asz.height, att.bounds.origin.y, c.cellBaselineOffset().y)
            }
            print(String(format: "  baseline=%.2f font=%@ %.1f asc=%.2f desc=%.2f%@", loc.y, font?.fontName ?? "-", font?.pointSize ?? 0, font?.ascender ?? 0, font?.descender ?? 0, cell))
            print(String(format: "y=%7.2f h=%6.2f usedH=%6.2f  minLH=%5.1f ls=%4.1f psb=%4.1f ps=%4.1f  %@", rect.minY, rect.height, used.height, p?.minimumLineHeight ?? 0, p?.lineSpacing ?? 0, p?.paragraphSpacingBefore ?? 0, p?.paragraphSpacing ?? 0, text))
        }
    }
}
