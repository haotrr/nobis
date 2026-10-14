import AppKit
import PolarMark

/// Owns the 35 stylers and runs them in a fixed order
/// over an annotated attributed string. Each styler may replace text (attachments), and the
/// replacement block keeps the styled range (and the proposed selection) in sync.
@MainActor public final class MDAttributedStringRenderer: NSObject {
    public var ast = PMKAST(markdown: "")
    public var styleInlinesOnly = false {
        didSet { ast.parseInlinesOnly = styleInlinesOnly }
    }

    public let bodyStyler = MDBodyTextStyler()
    public let bidiStyler = MDBidiTextStyler()
    public let headingStyler = MDHeadingTextStyler()
    public let orderedListStyler = MDOrderedListTextStyler()
    public let unorderedListStyler = MDUnorderedListTextStyler()
    public let blockQuoteStyler = MDBlockQuoteTextStyler()
    public let fencedCodeStyler = MDFencedCodeTextStyler()
    public let indentedCodeStyler = MDIndentedCodeTextStyler()
    public let strongStyler = MDStrongTextStyler()
    public let emphasisStyler = MDEmphasisTextStyler()
    public let strikethroughStyler = MDStrikethroughTextStyler()
    public let underlineStyler = MDUnderlineTextStyler()
    public let highlighterStyler = MDHighlighterTextStyler()
    public let codeStyler = MDCodeTextStyler()
    public let linkStyler = MDLinkTextStyler()
    public let imageStyler = MDImageTextStyler()
    public let thematicBreakStyler = MDThematicBreakTextStyler()
    public let colorStyler = MDColorTextStyler()
    public let arrowStyler = MDArrowTextStyler()
    public let escapeStyler = MDEscapeTextStyler()
    public let hashtagStyler = MDHashtagTextStyler()
    public let autoLinkStyler = MDAutoLinkTextStyler()
    public let htmlStyler = MDHTMLTextStyler()
    public let syntaxHighlightStyler = MDSyntaxHighlightTextStyler()
    public let referenceStyler = MDReferenceTextStyler()
    public let fileStyler = MDFileTextStyler()
    public let footnoteStyler = MDFootnoteTextStyler()
    public let wikiLinkStyler = MDWikiLinkTextStyler()
    public let tableStyler = MDTableTextStyler()
    public let foldTextStyler = MDFoldTextStyler()
    public let metadataTextStyler = MDMetadataTextStyler()
    public let hardLineBreakTextStyler = MDHardLineBreakTextStyler()
    public let indentSpaceTextStyler = MDIndentSpaceTextStyler()
    public let mathTextStyler = MDMathTextStyler()
    public let mathBlockTextStyler = MDMathBlockTextStyler()
    public let mermaidFencedCodeStyler = MDMermaidFencedCodeTextStyler()

    private var _textStylers: [MDBaseTextStyler]?

    /// Lazily built in the exact order of the decompiled getter.
    public var textStylers: [MDBaseTextStyler] {
        get {
            if let s = _textStylers { return s }
            let s: [MDBaseTextStyler] = [
                bodyStyler, bidiStyler, headingStyler, orderedListStyler, unorderedListStyler, blockQuoteStyler,
                indentSpaceTextStyler, fencedCodeStyler, mathBlockTextStyler, mermaidFencedCodeStyler, indentedCodeStyler,
                strongStyler, emphasisStyler, strikethroughStyler, underlineStyler, codeStyler, linkStyler, imageStyler,
                thematicBreakStyler, colorStyler, arrowStyler, /* hashtagStyler removed: tag styling disabled */ autoLinkStyler, htmlStyler, syntaxHighlightStyler,
                referenceStyler, fileStyler, footnoteStyler, wikiLinkStyler, escapeStyler, highlighterStyler, mathTextStyler,
                tableStyler, metadataTextStyler, foldTextStyler,
            ]
            _textStylers = s
            return s
        }
        set { _textStylers = newValue }
    }

    /// Annotated but unstyled.
    public func attributedString(fromPolarMarkString string: String) -> NSAttributedString {
        ast.replaceAll(withMarkdown: string)
        return ast.annotatedString()
    }

    public func styledAttributedString(fromString string: String) -> NSMutableAttributedString {
        ast.replaceAll(withMarkdown: string)
        let s = ast.annotatedString().mutableCopy() as! NSMutableAttributedString
        return styleAttributedString(s, in: NSRange(location: 0, length: s.length))
    }

    /// The replacement block only grows/shrinks the range.
    @discardableResult
    public func styleAttributedString(_ s: NSMutableAttributedString, in range: NSRange) -> NSMutableAttributedString {
        var r = range
        for styler in textStylers {
            styler.styleText(in: s, range: r) { replaced, replacement in
                r.length += replacement.length - replaced.length
            }
        }
        s.fixAttributes(in: r)
        return s
    }

    ///
    /// the selection-aware variant used while editing; `selectionLocationOffset` is where the styled substring
    /// starts inside the full text storage. Hashtag spacers that wrap the caret are skipped so the caret stays
    /// inside the tag being typed.
    @discardableResult
    public func styleAttributedString(_ s: NSMutableAttributedString, proposedSelectionRange selection: inout NSRange, selectionLocationOffset offset: Int) -> NSMutableAttributedString {
        var r = NSRange(location: 0, length: s.length)
        var sel = selection
        for styler in textStylers {
            styler.styleText(in: s, range: r) { replaced, replacement in
                r.length += replacement.length - replaced.length
                let absolute = NSRange(location: offset + replaced.location, length: replaced.length)
                if styler === self.hashtagStyler, absolute == sel, replacement.hasClosingSpacer(at: 0) { return }
                if absolute == sel, replacement.hasOpeningSpacer(at: 0) { return }
                sel = NSAttributedString.offsetSelectionRange(sel, forReplacementRange: absolute, replacementAttributedString: replacement)
            }
        }
        selection = sel
        s.fixAttributes(in: r)
        return s
    }
}
