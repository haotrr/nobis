import Foundation
import PolarMark

/// What the selection is inside, for a toolbar that lights the toggle that would undo it.
public struct MDFormatting: Equatable, Sendable {
    public enum InlineStyle: Sendable, Hashable, CaseIterable { case strong, emphasis, strikethrough, underline, highlighter, code }
    public enum ListKind: Sendable { case bullet, ordered, task }

    /// 1 to 6 when every selected paragraph is that heading, 0 when none is a heading, nil when mixed.
    public var headingLevel: Int?
    public var inline: Set<InlineStyle>
    public var isLink: Bool
    public var isCodeBlock: Bool
    public var isBlockquote: Bool
    /// The kind every selected paragraph is an item of, nil when mixed or none.
    public var list: ListKind?

    public static let plain = MDFormatting(headingLevel: 0, inline: [], isLink: false, isCodeBlock: false, isBlockquote: false, list: nil)

    public init(headingLevel: Int?, inline: Set<InlineStyle>, isLink: Bool, isCodeBlock: Bool, isBlockquote: Bool, list: ListKind?) {
        self.headingLevel = headingLevel
        self.inline = inline
        self.isLink = isLink
        self.isCodeBlock = isCodeBlock
        self.isBlockquote = isBlockquote
        self.list = list
    }
}

public extension NSAttributedString {
    /// Reads the PMK annotations under `selection`; the same rules the toggles use.
    func formatting(in selection: NSRange) -> MDFormatting {
        guard length > 0, selection.location != NSNotFound, selection.location <= length else { return .plain }
        var inline: Set<MDFormatting.InlineStyle> = []
        let pairs: [(NSAttributedString.Key, MDFormatting.InlineStyle)] = [
            (.pmkStrong, .strong), (.pmkEmphasis, .emphasis), (.pmkStrikethrough, .strikethrough),
            (.pmkUnderline, .underline), (.pmkHighlighter, .highlighter), (.pmkCode, .code)
        ]
        for (key, style) in pairs where isRange(selection, insideAttribute: key) { inline.insert(style) }
        let ns = string as NSString
        var heading: Int?
        var list: MDFormatting.ListKind?
        var mixedList = false
        var location = min(selection.location, length - 1)
        let end = min(NSMaxRange(selection), length)
        var first = true
        while first || location < end {
            first = false
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let level = headerLevel(at: paragraph.location)
            heading = heading == nil || heading == level ? level : -1
            let kind = listKind(at: paragraph.location)
            if list == nil, !mixedList { list = kind } else if list != kind { mixedList = true }
            location = NSMaxRange(paragraph)
            if paragraph.length == 0 { break }
        }
        return MDFormatting(
            headingLevel: heading == -1 ? nil : heading,
            inline: inline,
            isLink: isRange(selection, insideAttribute: .pmkLink),
            isCodeBlock: isRangeInsideBlockCode(selection),
            isBlockquote: isRange(selection, insideAttribute: .pmkBlockquote),
            list: mixedList ? nil : list)
    }

    private func listKind(at index: Int) -> MDFormatting.ListKind? {
        guard index < length, let info = attribute(.pmkListItem, at: index, effectiveRange: nil) as? PMKListInfo else { return nil }
        if info.isTaskList { return .task }
        return info.listType == PMKListInfo.orderedType ? .ordered : info.listType == PMKListInfo.unorderedType ? .bullet : nil
    }
}
