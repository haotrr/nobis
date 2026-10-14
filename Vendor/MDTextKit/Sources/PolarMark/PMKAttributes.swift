import Foundation

/// Attribute keys carried by the "annotated string" that PolarMark produces.
/// Raw values are the `PMK*AttributeName` constants:
/// the content attribute covers the whole construct (markers included) and the
/// `*Marker` attribute covers only the syntax characters.
///
/// Value conventions recovered from the decompilation:
///   PMKHeading        -> NSNumber(level)
///   PMKHeadingMarker  -> NSNumber(1 = ATX, 2 = SETEXT)
///   PMK*Marker        -> NSNumber(1 = open, 2 = close) for inline styles
///   PMKList           -> NSNumber(listType)          (1 unordered, 2 ordered)
///   PMKListItem       -> PMKListInfo
///   PMKListMarker     -> NSNumber(listType)
///   PMKIndentSpace    -> NSNumber(indent units)
///   PMKBlockquote     -> NSNumber(level)
public extension NSAttributedString.Key {
    // Block level
    static let pmkHeading = NSAttributedString.Key("PMKHeading")
    static let pmkHeadingMarker = NSAttributedString.Key("PMKHeadingMarker")
    static let pmkList = NSAttributedString.Key("PMKList")
    static let pmkListItem = NSAttributedString.Key("PMKListItem")
    static let pmkListMarker = NSAttributedString.Key("PMKListMarker")
    static let pmkIndentSpace = NSAttributedString.Key("PMKIndentSpace")
    static let pmkBlockquote = NSAttributedString.Key("PMKBlockquote")
    static let pmkBlockquoteItem = NSAttributedString.Key("PMKBlockquoteItem")
    static let pmkBlockquoteMarker = NSAttributedString.Key("PMKBlockquoteMarker")
    static let pmkFencedCode = NSAttributedString.Key("PMKFencedCode")
    static let pmkFencedCodeMarker = NSAttributedString.Key("PMKFencedCodeMarker")
    static let pmkFencedCodeLanguage = NSAttributedString.Key("PMKFencedCodeLanguage")
    static let pmkIndentedCode = NSAttributedString.Key("PMKIndentedCode")
    static let pmkThematicBreak = NSAttributedString.Key("PMKThematicBreak")
    static let pmkHardLinebreak = NSAttributedString.Key("PMKHardLinebreak")
    static let pmkMathBlock = NSAttributedString.Key("PMKMathBlock")
    static let pmkMathSpan = NSAttributedString.Key("PMKMathSpan")
    static let pmkMetadata = NSAttributedString.Key("PMKMetadata")
    static let pmkYaml = NSAttributedString.Key("PMKYaml")
    static let pmkTable = NSAttributedString.Key("PMKTable")
    static let pmkTableCellContent = NSAttributedString.Key("PMKTableCellContent")
    static let pmkTableCell = NSAttributedString.Key("PMKTableCell")
    static let pmkTableMarker = NSAttributedString.Key("PMKTableMarker")
    static let pmkHTMLBlock = NSAttributedString.Key("PMKHTMLBlock")
    static let pmkHTMLInline = NSAttributedString.Key("PMKHTMLInline")
    static let pmkHTMLEntity = NSAttributedString.Key("PMKHTMLEntity")
    static let pmkDirection = NSAttributedString.Key("PMKDirection")
    static let pmkFold = NSAttributedString.Key("PMKFold")
    static let pmkFoldMarker = NSAttributedString.Key("PMKFoldMarker")
    static let pmkFoldable = NSAttributedString.Key("PMKFoldable")

    // Inline
    static let pmkStrong = NSAttributedString.Key("PMKStrong")
    static let pmkStrongMarker = NSAttributedString.Key("PMKStrongMarker")
    static let pmkEmphasis = NSAttributedString.Key("PMKEmphasis")
    static let pmkEmphasisMarker = NSAttributedString.Key("PMKEmphasisMarker")
    static let pmkStrikethrough = NSAttributedString.Key("PMKStrikethrough")
    static let pmkStrikethroughMarker = NSAttributedString.Key("PMKStrikethroughMarker")
    static let pmkUnderline = NSAttributedString.Key("PMKUnderline")
    static let pmkUnderlineMarker = NSAttributedString.Key("PMKUnderlineMarker")
    static let pmkHighlighter = NSAttributedString.Key("PMKHighlighter")
    static let pmkHighlighterMarker = NSAttributedString.Key("PMKHighlighterMarker")
    static let pmkHighlighterColor = NSAttributedString.Key("PMKHighlighterColor")
    static let pmkCode = NSAttributedString.Key("PMKCode")
    static let pmkCodeMarker = NSAttributedString.Key("PMKCodeMarker")
    static let pmkLink = NSAttributedString.Key("PMKLink")
    static let pmkLinkMarker = NSAttributedString.Key("PMKLinkMarker")
    static let pmkLinkLabel = NSAttributedString.Key("PMKLinkLabel")
    static let pmkLinkURL = NSAttributedString.Key("PMKLinkURL")
    static let pmkLinkTitle = NSAttributedString.Key("PMKLinkTitle")
    static let pmkImage = NSAttributedString.Key("PMKImage")
    static let pmkImageMarker = NSAttributedString.Key("PMKImageMarker")
    static let pmkImageLabel = NSAttributedString.Key("PMKImageLabel")
    static let pmkImageURL = NSAttributedString.Key("PMKImageURL")
    static let pmkImageTitle = NSAttributedString.Key("PMKImageTitle")
    static let pmkHashtag = NSAttributedString.Key("PMKHashtag")
    static let pmkHashtagMarker = NSAttributedString.Key("PMKHashtagMarker")
    static let pmkHashtagSegment = NSAttributedString.Key("PMKHashtagSegment")
    static let pmkHashtagSeparator = NSAttributedString.Key("PMKHashtagSeparator")
    static let pmkAutoLinkURL = NSAttributedString.Key("PMKAutoLinkURL")
    static let pmkAutoLinkEmail = NSAttributedString.Key("PMKAutoLinkEmail")
    static let pmkAutoLinkMarker = NSAttributedString.Key("PMKAutoLinkMarker")
    static let pmkEscape = NSAttributedString.Key("PMKEscape")
    static let pmkEscapeMarker = NSAttributedString.Key("PMKEscapeMarker")
    static let pmkColor = NSAttributedString.Key("PMKColor")
    static let pmkArrow = NSAttributedString.Key("PMKArrow")
    static let pmkFootNote = NSAttributedString.Key("PMKFootNote")
    static let pmkFootNoteMarker = NSAttributedString.Key("PMKFootNoteMarker")
    static let pmkFootNoteLabel = NSAttributedString.Key("PMKFootNoteLabel")
    static let pmkReference = NSAttributedString.Key("PMKReference")
    static let pmkReferenceMarker = NSAttributedString.Key("PMKReferenceMarker")
    static let pmkReferenceLabel = NSAttributedString.Key("PMKReferenceLabel")
    static let pmkReferenceDefinition = NSAttributedString.Key("PMKReferenceDefinition")
    static let pmkWikiLink = NSAttributedString.Key("PMKWikiLink")
    static let pmkWikiLinkMarker = NSAttributedString.Key("PMKWikiLinkMarker")
    static let pmkWikiLinkAnchor = NSAttributedString.Key("PMKWikiLinkAnchor")
    static let pmkWikiLinkAliasSeparator = NSAttributedString.Key("PMKWikiLinkAliasSeparator")
    static let pmkMathSpanFormula = NSAttributedString.Key("PMKMathSpanFormula")
    static let pmkMathSpanMarker = NSAttributedString.Key("PMKMathSpanMarker")
    static let pmkMathBlockFormula = NSAttributedString.Key("PMKMathBlockFormula")
    static let pmkMathBlockMarker = NSAttributedString.Key("PMKMathBlockMarker")
    static let pmkCallout = NSAttributedString.Key("PMKCallout")
    static let pmkCalloutMarker = NSAttributedString.Key("PMKCalloutMarker")
    static let pmkCalloutTitle = NSAttributedString.Key("PMKCalloutTitle")
}

/// `PMKOpenMarkerValue` / `PMKCloseMarkerValue` (NSNumber 1 / 2).
public enum PMKMarkerValue: Int {
    case open = 1
    case close = 2
}

public enum PMKHeadingMarkerValue: Int {
    case atx = 1
    case setext = 2
}

public enum PMKTaskState: Int {
    case notTask = 0
    case open = 1
    case completed = 2
}

public enum PMKDirectionValue: Int {
    case natural = 0
    case ltr = 1
    case rtl = 2
}

/// Which inline style an operation toggles (`toggleInlineStyle:selectionRange:style:`).
public enum PMKInlineStyleKind: CaseIterable {
    case strong, emphasis, strikethrough, underline, highlighter, code

    public var delimiter: String {
        switch self {
        case .strong: return "**"
        case .emphasis: return "*"
        case .strikethrough: return "~~"
        case .underline: return "~"
        case .highlighter: return "=="
        case .code: return "`"
        }
    }
}

/// Which block style an operation toggles (`toggleBlockStyle:selectionRange:style:`).
public enum PMKBlockStyleKind: Equatable {
    case heading(Int)
    case unorderedList
    case orderedList
    case taskList
    case blockquote
    case fencedCode
}

/// Every `*Marker` key.
public enum PMKAttributes {
    public static let markerAttributes: [NSAttributedString.Key] = [
        .pmkHeadingMarker, .pmkListMarker, .pmkBlockquoteMarker, .pmkFencedCodeMarker, .pmkStrongMarker,
        .pmkEmphasisMarker, .pmkStrikethroughMarker, .pmkUnderlineMarker, .pmkHighlighterMarker, .pmkCodeMarker,
        .pmkLinkMarker, .pmkImageMarker, .pmkHashtagMarker, .pmkAutoLinkMarker, .pmkEscapeMarker, .pmkFootNoteMarker,
        .pmkReferenceMarker, .pmkWikiLinkMarker, .pmkMathSpanMarker, .pmkMathBlockMarker, .pmkCalloutMarker, .pmkFoldMarker,
    ]
}
