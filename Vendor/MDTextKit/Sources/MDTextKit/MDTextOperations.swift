import AppKit
import PolarMark

public final class MDTextOperationResult: NSObject {
    public var replacementAttributedString: NSAttributedString?
    public var replacementRange = NSNotFoundRange
    public var proposedSelectionRange = NSNotFoundRange
    public var needStyling = true

    public override var description: String {
        "replacementRange: \(NSStringFromRange(replacementRange)) proposedSelection: \(NSStringFromRange(proposedSelectionRange)) replacementString: \(replacementAttributedString?.string ?? "nil")"
    }
}

/// Operations triggered by commands.
@MainActor open class MDBaseTextOperation: NSObject {
    open func result(forAttributedString s: NSAttributedString, in range: NSRange, selectionRange: NSRange) -> MDTextOperationResult? { nil }
    open func results(forAttributedString s: NSAttributedString, in range: NSRange, selectionRange: NSRange) -> [MDTextOperationResult] {
        guard let r = result(forAttributedString: s, in: range, selectionRange: selectionRange) else { return [] }
        return [r]
    }
}

/// Operations consulted on every keystroke.
@MainActor open class MDBaseEditTextOperation: NSObject {
    open func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? { nil }
}

/// Backspace on a spacer removes the whole spacer pair.
@MainActor public final class MDDeleteSpacerTextOperation: MDBaseEditTextOperation {
    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        guard range.length == 1, replacementString == "", range.location < s.length,
              s.attribute(.mdSpacer, at: range.location, effectiveRange: nil) != nil else { return nil }
        let extended = s.rangeByExtending(NSRange(location: range.location, length: 1), toIncludeAttribute: .mdSpacer)
        guard extended != NSRange(location: range.location, length: 1) else { return nil }
        let r = MDTextOperationResult()
        r.replacementAttributedString = NSAttributedString(string: "")
        r.replacementRange = extended
        r.proposedSelectionRange = NSRange(location: extended.location, length: 0)
        return [r]
    }
}

/// Backspace on a tag spacer selects the whole tag.
@MainActor public final class MDDeleteTagSpacerTextOperation: MDBaseEditTextOperation {
    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        guard range.length == 1, replacementString == "", range.location < s.length,
              s.attribute(.mdSpacer, at: range.location, effectiveRange: nil) != nil,
              s.attribute(.pmkHashtag, at: range.location, effectiveRange: nil) != nil else { return nil }
        var tag = NSRange()
        _ = s.attribute(.pmkHashtag, at: range.location, longestEffectiveRange: &tag, in: NSRange(location: 0, length: s.length))
        let r = MDTextOperationResult()
        r.proposedSelectionRange = tag
        return [r]
    }
}

/// Typing a space/newline on the tag's closing spacer inserts after the spacer.
@MainActor public final class MDExitTagTextOperation: MDBaseEditTextOperation {
    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        guard range.length == 0, range.location < s.length, replacementString == " " || replacementString == "\n",
              s.attribute(.mdSpacer, at: range.location, effectiveRange: nil) != nil,
              s.attribute(.pmkHashtagMarker, at: range.location, effectiveRange: nil) != nil else { return nil }
        let r = MDTextOperationResult()
        r.replacementAttributedString = NSAttributedString(string: replacementString)
        r.replacementRange = NSRange(location: range.location + 1, length: 0)
        r.proposedSelectionRange = NSRange(location: range.location + 2, length: 0)
        return [r]
    }
}

/// A space typed right before a closing inline marker
/// is inserted with the marker's own attributes (minus the attachment) and without re-styling.
@MainActor public final class MDPreventInlineStyleInvalidationTextOperation: MDBaseEditTextOperation {
    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        guard range.location != 0, range.length == 0, range.location < s.length, replacementString == " ",
              s.inlineClosingMarkerRange(at: range.location).location == range.location,
              !s.isRangeInsideCode(NSRange(location: range.location, length: 0)) else { return nil }
        var attrs = s.attributes(at: range.location - 1, effectiveRange: nil)
        attrs.removeValue(forKey: .attachment)
        let r = MDTextOperationResult()
        r.replacementAttributedString = NSAttributedString(string: replacementString, attributes: attrs)
        r.replacementRange = NSRange(location: range.location, length: 0)
        r.proposedSelectionRange = NSRange(location: range.location + 1, length: 0)
        r.needStyling = false
        return [r]
    }
}

/// A straight quote typed right after an opening marker/attachment stays straight.
@MainActor public final class MDFixSmartQuoteTextOperation: MDBaseEditTextOperation {
    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        guard range.location != 0, NSMaxRange(range) < s.length, replacementString == "\u{201C}" || replacementString == "\u{201D}" else { return nil }
        let ns = s.string as NSString
        guard ns.character(at: range.location) == 0x22 else { return nil }
        guard s.hasOpeningMarker(at: range.location - 1) || s.textAttachment(at: range.location - 1) != nil else { return nil }
        let r = MDTextOperationResult()
        r.replacementAttributedString = NSAttributedString(string: "\"", attributes: nil)
        r.replacementRange = range
        r.proposedSelectionRange = selectionRange
        return [r]
    }
}

/// Typing a delimiter with a selection wraps the selection.
@MainActor public final class MDWrapSelectionTextOperation: MDBaseEditTextOperation {
    public func closingDelimiter(forOpeningDelimiter opening: String) -> String? {
        switch opening {
        case "*": return "*"
        case "_": return "_"
        case "~": return "~"
        case "`": return "`"
        case "=": return "="
        case "$": return "$"
        case "\"": return "\""
        case "'": return "'"
        case "\u{201C}": return "\u{201D}"
        case "\u{2018}": return "\u{2019}"
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        case "<": return ">"
        case "\u{AB}": return "\u{BB}"
        case "\u{300C}": return "\u{300D}"
        default: return nil
        }
    }

    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        guard selectionRange.length != 0, (replacementString as NSString).length == 1,
              let closing = closingDelimiter(forOpeningDelimiter: replacementString) else { return nil }
        let selected = s.attributedSubstring(from: selectionRange).string
        let r = MDTextOperationResult()
        r.replacementAttributedString = NSAttributedString(string: [replacementString, selected, closing].joined())
        r.replacementRange = selectionRange
        r.proposedSelectionRange = NSRange(location: selectionRange.location + 1, length: selectionRange.length)
        return [r]
    }
}

/// Typing next to a table keeps it on its own lines.
@MainActor public final class MDPreventTableInvalidationTextOperation: MDBaseEditTextOperation {
    public override func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        let end = NSMaxRange(range)
        let ns = s.string as NSString
        func hasTable(at i: Int) -> Bool { i < s.length && s.attribute(.pmkTable, at: i, effectiveRange: nil) != nil }
        if end < s.length, hasTable(at: end), !replacementString.hasSuffix("\n") {
            if replacementString != "" {
                let text = NSAttributedString(string: replacementString + "\n")
                let r = MDTextOperationResult()
                r.replacementRange = range
                r.proposedSelectionRange = NSRange(location: end + text.length - 1, length: 0)
                r.replacementAttributedString = text
                return [r]
            }
            if range.location != 0, ns.character(at: range.location - 1) != 0x0A {
                let r = MDTextOperationResult()
                r.proposedSelectionRange = NSRange(location: end - 1, length: 0)
                return [r]
            }
        } else if range.location != 0, hasTable(at: range.location - 1), !replacementString.hasPrefix("\n") {
            if replacementString != "" || end >= s.length {
                if replacementString != "" {
                    let text = NSAttributedString(string: "\n" + replacementString)
                    let r = MDTextOperationResult()
                    r.replacementRange = range
                    r.proposedSelectionRange = NSRange(location: text.length + end, length: 0)
                    r.replacementAttributedString = text
                    return [r]
                }
            } else if ns.character(at: range.location + 1) != 0x0A {
                let r = MDTextOperationResult()
                r.proposedSelectionRange = NSRange(location: end - 1, length: 0)
                return [r]
            }
        }
        return nil
    }
}

/// Moves completed tasks below the open ones, level by level.
@MainActor public final class MDOrderTaskListTextOperation: MDBaseTextOperation {
    public override func result(forAttributedString s: NSAttributedString, in range: NSRange, selectionRange: NSRange) -> MDTextOperationResult? {
        let region = range.length == 0 ? NSRange(location: 0, length: s.length) : s.extendRangeToFullyContainLists(range)
        let source = s.attributedSubstring(from: region)
        let output = source.mutableCopy() as! NSMutableAttributedString
        var maxLevel = 1
        var level = 0
        var current = source
        repeat {
            var insertAt = -1
            var firstLevel = -1
            current.enumerateUnorderedList(in: NSRange(location: 0, length: current.length), options: [], listBlock: { levelRange, lvl, _, _ in
                if firstLevel == -1 { firstLevel = lvl }
                if lvl == firstLevel { insertAt = levelRange.location }
            }) { itemRange, _, info, _ in
                if info.listLevel == level {
                    guard info.isTaskList else { return }
                    if info.taskType != 1 {
                        // completed: keep in place, open tasks move above it
                        return
                    }
                    if itemRange.location != insertAt {
                        let moved = current.attributedSubstring(from: itemRange).mutableCopy() as! NSMutableAttributedString
                        output.replaceCharacters(in: itemRange, with: "")
                        output.insert(moved, at: insertAt)
                        if (current.string as NSString).character(at: NSMaxRange(itemRange) - 1) != 0x0A {
                            output.replaceCharacters(in: NSRange(location: NSMaxRange(itemRange) - 1, length: 1), with: "")
                            output.insert(NSAttributedString(string: "\n"), at: insertAt + moved.length)
                        }
                    }
                    insertAt += itemRange.length
                } else if info.listLevel + 1 > maxLevel {
                    maxLevel = info.listLevel + 1
                }
            }
            level += 1
            current = output.copy() as! NSAttributedString
        } while level < maxLevel
        let r = MDTextOperationResult()
        r.replacementAttributedString = output
        r.replacementRange = region
        r.proposedSelectionRange = selectionRange
        return r
    }
}

/// Moves `dragRange` to `destinationRange`, optionally as its own line and
/// re-indented to the destination list level.
@MainActor public final class MDDragTextOperation: NSObject {
    public func result(forAttributedString s: NSAttributedString, dragRange: NSRange, destinationRange: NSRange, selectionRange: NSRange, dropAsNewLine: Bool) -> MDTextOperationResult? {
        let union = NSUnionRange(dragRange, destinationRange)
        let dragOffset = dragRange.location - union.location
        let destOffset = destinationRange.location - union.location
        let work = s.attributedSubstring(from: union).mutableCopy() as! NSMutableAttributedString
        let dragged = work.attributedSubstring(from: NSRange(location: dragOffset, length: dragRange.length))
        var piece: NSAttributedString = dragged
        var selectionLocation = destinationRange.location
        let ns = s.string as NSString
        if dropAsNewLine {
            let newline = NSAttributedString(string: "\n")
            let m = NSMutableAttributedString(attributedString: dragged)
            if !dragged.string.hasPrefix("\n"), destinationRange.location != 0, ns.character(at: destinationRange.location - 1) != 0x0A {
                m.insert(newline, at: 0)
                selectionLocation = destinationRange.location + 1
            }
            if !dragged.string.hasSuffix("\n"), NSMaxRange(destinationRange) < s.length, ns.character(at: NSMaxRange(destinationRange)) != 0x0A {
                m.append(newline)
            }
            if let sourceInfo = s.listItemInfo(at: dragRange.location) {
                let destInfo = s.listItemInfo(at: destinationRange.location)
                let destLevel = destInfo?.listLevel ?? -1
                if destLevel + 1 < sourceInfo.listLevel {
                    let indent = m.rangeOfIndentForListItem(at: 0)
                    if indent.location != NSNotFound { m.replaceCharacters(in: indent, with: "") }
                    if destLevel != -1 {
                        for _ in 0..<(destLevel + 1) { m.insert(NSAttributedString(string: "\t"), at: 0) }
                    }
                }
            }
            piece = m
        }
        if dragOffset < destOffset {
            work.replaceCharacters(in: NSRange(location: destOffset, length: destinationRange.length), with: piece)
            work.replaceCharacters(in: NSRange(location: dragOffset, length: dragRange.length), with: "")
            selectionLocation -= dragRange.length
        } else {
            work.replaceCharacters(in: NSRange(location: dragOffset, length: dragRange.length), with: "")
            work.replaceCharacters(in: NSRange(location: destOffset, length: destinationRange.length), with: piece)
        }
        let r = MDTextOperationResult()
        r.replacementAttributedString = work
        r.replacementRange = union
        r.proposedSelectionRange = NSRange(location: selectionLocation, length: dragRange.length)
        return r
    }
}

/// Runs the edit operations in order; the first one that answers wins.
@MainActor public final class MDEditorBehaviourController: NSObject {
    public var processInlinesOnly = false { didSet { setupEditOperations() } }
    public private(set) var editOperations: [MDBaseEditTextOperation] = []

    public override init() {
        super.init()
        setupEditOperations()
    }

    private func setupEditOperations() {
        editOperations = [
            MDDeleteSpacerTextOperation(), MDDeleteTagSpacerTextOperation(), MDExitTagTextOperation(),
            MDPreventInlineStyleInvalidationTextOperation(), MDWrapSelectionTextOperation(), MDFixSmartQuoteTextOperation(),
        ]
        if !processInlinesOnly { editOperations.append(MDPreventTableInvalidationTextOperation()) }
    }

    public func results(forEditIn range: NSRange, replacementString: String, attributedString s: NSAttributedString, selectionRange: NSRange) -> [MDTextOperationResult]? {
        for op in editOperations {
            if let r = op.results(forEditIn: range, replacementString: replacementString, attributedString: s, selectionRange: selectionRange) { return r }
        }
        return nil
    }
}
