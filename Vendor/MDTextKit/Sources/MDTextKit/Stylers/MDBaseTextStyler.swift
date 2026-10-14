import AppKit
import PolarMark

/// The `replacementBlock` every styler receives. Called after the styler replaced
/// `range` of the attributed string with `replacement` so the caller can keep the styled
/// range and the selection in sync.
public typealias MDStylerReplacementBlock = (_ range: NSRange, _ replacement: NSAttributedString) -> Void

/// `MDBaseTextStyler`. Holds the metrics shared by every styler and the
/// `ListUtils` category helpers (spacers, indentation, writing direction).
@MainActor open class MDBaseTextStyler: NSObject {
    public var cache = NSCache<AnyObject, AnyObject>()
    public var markerColor: NSColor = .black
    public var baseTextColor: NSColor = .black
    public var baseFontSize: CGFloat = 0
    public var baseTabSize: CGFloat = 0
    public var basePointSize: CGFloat = 0
    public var defaultParagraphIndent: CGFloat = 0
    public var columnSize: CGFloat = 0
    public var gutterSize: CGFloat = 0
    public var maxTextContainerWidth: CGFloat = 0
    /// A rule's requested width; the cell clamps it to the line, so 0 (no column) asks for the whole line.
    var fullLineWidth: CGFloat { maxTextContainerWidth > 0 ? maxTextContainerWidth : 10_000 }

    public override init() {
        super.init()
    }

    /// Base does nothing.
    open func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {}

    open var canStyleAsync: Bool { false }

    // MARK: - ListUtils

    /// Inserts a copy of
    /// `attachment` before and after `range`, both marked `MDSpacer`, and tags the neighbouring
    /// character as part of the spacer pair (the right spacer is inserted first so indexes stay valid).
    public func addBoundarySpacerAttachment(_ attachment: SFTextAttachment, in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        var leftAttrs = s.attributes(at: range.location, effectiveRange: nil)
        let end = NSMaxRange(range)
        var rightAttrs = s.attributes(at: end - 1, effectiveRange: nil)
        leftAttrs[.mdSpacer] = NSNumber(value: 1)
        rightAttrs[.mdSpacer] = NSNumber(value: 2)
        let left = attachment.attachmentAttributedString(with: leftAttrs)
        let right = attachment.copyAttachment().attachmentAttributedString(with: rightAttrs)
        s.insert(right, at: end)
        replacementBlock(NSRange(location: end, length: 0), right)
        s.addAttribute(.mdSpacer, value: NSNumber(value: 2), range: NSRange(location: end - 1, length: 2))
        s.insert(left, at: range.location)
        replacementBlock(NSRange(location: range.location, length: 0), left)
        s.addAttribute(.mdSpacer, value: NSNumber(value: 1), range: NSRange(location: range.location, length: 2))
    }

    public func addLeftBoundarySpacerAttachment(_ attachment: SFTextAttachment, in s: NSMutableAttributedString, at index: Int, replacementBlock: @escaping MDStylerReplacementBlock) {
        var attrs = s.attributes(at: index, effectiveRange: nil)
        attrs[.mdSpacer] = NSNumber(value: 1)
        let a = attachment.attachmentAttributedString(with: attrs)
        s.insert(a, at: index)
        replacementBlock(NSRange(location: index, length: 0), a)
        s.addAttribute(.mdSpacer, value: NSNumber(value: 1), range: NSRange(location: index, length: 2))
    }

    public func addRightBoundarySpacerAttachment(_ attachment: SFTextAttachment, in s: NSMutableAttributedString, at index: Int, replacementBlock: @escaping MDStylerReplacementBlock) {
        var attrs = s.attributes(at: index - 1, effectiveRange: nil)
        attrs[.mdSpacer] = NSNumber(value: 2)
        let a = attachment.attachmentAttributedString(with: attrs)
        s.insert(a, at: index)
        replacementBlock(NSRange(location: index, length: 0), a)
        s.addAttribute(.mdSpacer, value: NSNumber(value: 2), range: NSRange(location: index - 1, length: 2))
    }

    public func isAttributedString(_ s: NSAttributedString, RTLAt index: Int) -> Bool {
        s.writingDirection(at: index) == 1
    }

    public func forceWritingDirectionToMatchParagraph(in range: NSRange, in s: NSMutableAttributedString) {
        let dir = s.writingDirection(at: range.location)
        s.addAttribute(.writingDirection, value: [NSNumber(value: dir)], range: range)
    }

    public func forceWritingDirectionToLTR(in range: NSRange, in s: NSMutableAttributedString) {
        s.addAttribute(.writingDirection, value: [NSNumber(value: 0)], range: range)
    }

    /// `indentListItemRange:indentWidth:inAttributedString:replacementBlock:` (an alias of
    /// `indentParagraphsForListItemRange:…` in the binary) — every paragraph of the item gets
    /// `headIndent += indentWidth`, `firstLineHeadIndent = defaultParagraphIndent`.
    public func indentListItemRange(_ range: NSRange, indentWidth: CGFloat, in s: NSMutableAttributedString, replacementBlock: @escaping MDStylerReplacementBlock) {
        indentParagraphsForListItemRange(range, indentWidth: indentWidth, in: s, replacementBlock: replacementBlock)
    }

    public func indentParagraphsForListItemRange(_ range: NSRange, indentWidth: CGFloat, in s: NSMutableAttributedString, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        let paragraphs = ns.paragraphRange(for: range)
        ns.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let p = (s.paragraphStyle(at: enclosing.location) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
            p.headIndent += indentWidth
            p.firstLineHeadIndent = self.defaultParagraphIndent
            s.addAttribute(.paragraphStyle, value: p, range: enclosing)
        }
    }

    /// `indentBlockQuoteItemRange:indentWidth:inAttributedString:replacementBlock:` (alias of
    /// `indentParagraphsForBlockquoteItemRange:…`).
    public func indentBlockQuoteItemRange(_ range: NSRange, indentWidth: CGFloat, in s: NSMutableAttributedString, replacementBlock: @escaping MDStylerReplacementBlock) {
        indentParagraphsForBlockquoteItemRange(range, indentWidth: indentWidth, in: s, replacementBlock: replacementBlock)
    }

    public func indentParagraphsForBlockquoteItemRange(_ range: NSRange, indentWidth: CGFloat, in s: NSMutableAttributedString, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let p = (s.paragraphStyle(at: enclosing.location) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
            p.headIndent += indentWidth
            p.firstLineHeadIndent = self.defaultParagraphIndent
            s.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: enclosing))
        }
    }

    /// When the item ends with
    /// a newline followed by another newline (an empty paragraph after it), the empty paragraph keeps the
    /// item's indentation so the caret does not jump left.
    public func matchIndentOnNewline(forListItemRange range: NSRange, indentWidth: CGFloat, in s: NSMutableAttributedString) {
        let ns = s.string as NSString
        let end = NSMaxRange(range)
        let last = end - 1
        guard last >= 0, end < s.length else { return }
        let newlines = CharacterSet.newlines
        guard let c1 = Unicode.Scalar(ns.character(at: last)), newlines.contains(c1),
              let c2 = Unicode.Scalar(ns.character(at: end)), newlines.contains(c2) else { return }
        let empty = s.isListOrBlockquoteParagraphEmpty(at: last)
        let p = (s.paragraphStyle(at: last) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
        let info = s.listOrBlockquoteItemInfo(at: last)
        // Assumes the side margin is no wider than one list indent (a tab).
        if p.firstLineHeadIndent <= indentWidth {
            let level = CGFloat(info?.listLevel ?? 0)
            let full = indentWidth + level * indentWidth
            let indent = empty ? full - indentWidth : full
            p.headIndent += indent
            p.firstLineHeadIndent += indent
        }
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: end, length: 1))
    }

    /// `attachmentForRange:inAttributedString:` (ListUtils) — the indent-space attachment for a run of
    /// leading whitespace, sized with this styler's metrics.
    public func attachmentForRange(_ range: NSRange, in s: NSAttributedString) -> MDIndentSpaceTextAttachment {
        MDIndentSpaceTextStyler.attachment(forRange: range, in: s, tabSize: baseTabSize, paragraphIndent: defaultParagraphIndent, fontSize: baseFontSize)
    }
}

public extension NSURL {
    /// Tolerant URL construction, defaulting to https.
    @objc static func validURL(fromString string: String?) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        var url: URL? = nil
        if let components = URLComponents(string: string) {
            var c = components
            c.percentEncodedPath = (c.percentEncodedPath).replacingOccurrences(of: "%3B", with: ";")
            url = c.url
        }
        if url == nil {
            var components = URLComponents(string: string)
            if components == nil, let escaped = string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                components = URLComponents(string: escaped)
            }
            url = components?.url
        }
        guard let result = url else { return nil }
        if result.scheme == nil { return URL(string: "https://" + result.absoluteString) }
        return result
    }
}

public extension NSMutableAttributedString {
    /// Fonts without an italic
    /// face get a −14° skew transform (emoji excluded).
    func fixItalicAttribute(in range: NSRange) {
        fixFontAttribute(in: range)
        enumerateAttribute(.font, in: range, options: []) { value, run, _ in
            guard let font = value as? NSFont, font.fontName != "AppleColorEmoji" else { return }
            guard !font.fontDescriptor.symbolicTraits.contains(.italic) else { return }
            // The transform is the whole font matrix: the size scales it, and the skew leans 14 degrees.
            let radians = Double(acosf(0)) * -14.0 / 90.0
            var transform = AffineTransform(scale: font.pointSize)
            transform.m21 = -CGFloat(tanf(Float(radians))) * font.pointSize
            if let italic = NSFont(descriptor: font.fontDescriptor, textTransform: transform) {
                self.addAttribute(.font, value: italic, range: run)
            }
        }
    }
}
