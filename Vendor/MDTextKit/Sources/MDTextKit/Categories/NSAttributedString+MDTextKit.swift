import AppKit
import PolarMark

// Ported 1:1 from the decompiled MDTextKit categories:
//   NSAttributedString(Attachments) / (Spacers) / (Ranges) / (TemporaryAttributes) / (AttributesUtils)
//   NSMutableAttributedString(Fonts) / NSString(Ranges) / NSTextAttachment(AttachmentKind)
//   NSFont(Metrics) / NSFont(FontVariants) / NSMutableParagraphStyle(CenteredLineHeight)

// MARK: - Attribute names MDTextKit adds

public extension NSAttributedString.Key {
    static let mdOriginalAttributes = NSAttributedString.Key("MDOriginalAttributes")
    static let mdSpacer = NSAttributedString.Key("MDSpacer")
    static let mdPreventMarkdownHiding = NSAttributedString.Key("MDPreventMarkdownHiding")
    static let mdSearchResultBackgroundColor = NSAttributedString.Key("MDSearchResultBackgroundColor")
    static let mdAsyncStylingIdentifier = NSAttributedString.Key("MDAsyncStylingIdentifier")
    static let mdSyntaxHighlightLanguage = NSAttributedString.Key("MDSyntaxHighlightLanguage")
    static let mdCodeBackgroundColor = NSAttributedString.Key("MDCodeBackgroundColor")
    static let mdCodeBorderColor = NSAttributedString.Key("MDCodeBorderColor")
    static let mdBlockQuoteBackgroundColor = NSAttributedString.Key("MDBlockQuoteBackgroundColor")
    static let mdHighlighterBackgroundColor = NSAttributedString.Key("MDHighlighterBackgroundColor")
    static let mdTagBackgroundColor = NSAttributedString.Key("MDTagBackgroundColor")
    static let mdCalloutColors = NSAttributedString.Key("MDCalloutColors")
    static let mdMermaidCode = NSAttributedString.Key("MDMermaidCode")
    static let mdMermaidCodeContent = NSAttributedString.Key("MDMermaidCodeContent")
    /// Adds then immediately removes @"TMP" to force an attribute-change notification for attachments.
    static let mdTMP = NSAttributedString.Key("TMP")
}

public let NSNotFoundRange = NSRange(location: NSNotFound, length: 0)

// MARK: - NSAttributedString(Attachments)

public extension NSAttributedString {
    /// A text storage walks its backing string, so no run pays Swift's attribute bridging.
    var walkable: NSAttributedString { (self as? MDTextStorage)?.backing ?? self }

    var stringByExpandingTextAttachments: String {
        if let storage = self as? MDTextStorage { return storage.markdown }
        return stringByExpandingTextAttachments(in: NSRange(location: 0, length: length))
    }

    func stringByExpandingTextAttachments(in range: NSRange) -> String {
        stringByExpandingTextAttachments(in: range, selectionToOffset: nil)
    }

    /// Replaces every
    /// SFTextAttachment with its represented markdown and shifts `selection` accordingly.
    func stringByExpandingTextAttachments(in range: NSRange, selectionToOffset selection: UnsafeMutablePointer<NSRange>?) -> String {
        let result = NSMutableString(capacity: range.length)
        let source = walkable
        let ns = source.string as NSString
        source.enumerateAttribute(.attachment, in: range, options: []) { value, r, _ in
            if let att = value as? SFTextAttachment {
                let text = att.representedText
                result.append(text)
                if let sel = selection {
                    sel.pointee = NSAttributedString.offsetSelectionRange(sel.pointee,
                        forReplacementRange: NSRange(location: range.location + r.location, length: r.length),
                        replacementLength: (text as NSString).length)
                }
            } else {
                result.append(ns.substring(with: r))
            }
        }
        return result as String
    }

    /// Centers an attachment on the
    /// font's cap height: (capHeight - height) / 2.
    func baselineOffsetForAttachment(at index: Int, attachmentHeight height: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        let i = min(index, length - 1)
        let font = (attributes(at: i, effectiveRange: nil)[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return (font.capHeight - height) / 2
    }

    /// Centres the attachment in the line box: the minimum line height, or the font's own height.
    func baselineOffsetCentringAttachmentInLineBox(at index: Int, attachmentHeight height: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        let i = min(index, length - 1)
        let attributes = attributes(at: i, effectiveRange: nil)
        let font = (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let descent = ceil(-font.descender)
        let minimum = (attributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0
        let lineBox = max(minimum, ceil(font.ascender) + descent)
        return lineBox / 2 - descent - height / 2
    }

    func range(ofTextAttachment attachment: NSTextAttachment) -> NSRange {
        range(ofTextAttachment: attachment, foldRange: nil)
    }

    /// Also looks inside fold attachments.
    func range(ofTextAttachment attachment: NSTextAttachment, foldRange: UnsafeMutablePointer<NSRange>?) -> NSRange {
        foldRange?.pointee = NSNotFoundRange
        var result = NSNotFoundRange
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: .longestEffectiveRangeNotRequired) { value, r, stop in
            guard let a = value as? NSTextAttachment else { return }
            if a === attachment {
                result = r
                stop.pointee = true
            } else if foldRange != nil, a.isFold, let fold = a as? SFTextAttachment {
                let inner = fold.representedAttributedText.range(ofTextAttachment: attachment)
                if inner.location != NSNotFound {
                    result = inner
                    foldRange?.pointee = r
                    stop.pointee = true
                }
            }
        }
        return result
    }

    func textAttachment(at index: Int) -> NSTextAttachment? {
        guard index < length else { return nil }
        return attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
    }

    func containsFileBackedAttachments(in range: NSRange) -> Bool {
        var found = false
        enumerateFileBackedAttachment(in: range, options: []) { _, _, stop in
            found = true
            stop.pointee = true
        }
        return found
    }

    /// `enumerateFileBackedAttachmentInRange:options:usingBlock:` (descends into folds).
    func enumerateFileBackedAttachment(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                                       using block: (SFTextAttachmentFileBackedView, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.attachment, in: range, options: []) { value, r, stop in
            guard let a = value as? NSTextAttachment else { return }
            if let fb = a as? SFTextAttachmentFileBackedView { block(fb, r, stop) }
            if a.isFold, let fold = a as? SFTextAttachment {
                let inner = fold.representedAttributedText
                inner.enumerateAttribute(.attachment, in: NSRange(location: 0, length: inner.length), options: []) { v, _, innerStop in
                    if let fb = v as? SFTextAttachmentFileBackedView {
                        block(fb, NSNotFoundRange, innerStop)
                        if innerStop.pointee.boolValue { stop.pointee = true }
                    }
                }
            }
        }
    }
}

// MARK: - NSAttributedString(Spacers)

public extension NSAttributedString {
    func hasSpacer(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        return attribute(.mdSpacer, at: index, effectiveRange: nil) != nil
    }

    func hasOpeningSpacer(at index: Int) -> Bool {
        guard index >= 0, index < length, let v = attribute(.mdSpacer, at: index, effectiveRange: nil) as? NSNumber else { return false }
        return v.intValue == PMKMarkerValue.open.rawValue
    }

    func hasClosingSpacer(at index: Int) -> Bool {
        guard index >= 0, index < length, let v = attribute(.mdSpacer, at: index, effectiveRange: nil) as? NSNumber else { return false }
        return v.intValue == PMKMarkerValue.close.rawValue
    }

    /// Keeps the caret from
    /// landing between an attachment and its boundary spacers.
    func spacersAdjustedSelection(forProposedSelection proposed: NSRange, currentSelection current: NSRange) -> NSRange {
        var loc = proposed.location
        let len = proposed.length
        var outLen = len
        if proposed.location == 0 && proposed.length == 0 { return proposed }
        let end = loc + len
        guard end <= length, loc < length else { return NSRange(location: loc, length: outLen) }
        let dLoc = Int(loc) - Int(current.location)
        guard dLoc != 0 || len != current.length else { return NSRange(location: loc, length: outLen) }
        let dLen = Int(len) - Int(current.length)
        var stepOfOne: Bool
        if abs(dLoc) == 1 {
            stepOfOne = true
        } else {
            stepOfOne = loc == current.location && abs(dLen) == 1
            if !stepOfOne && len != 0 {
                return rangeByExtending(proposed, toIncludeAttribute: .mdSpacer)
            }
        }
        var idx: Int
        if loc == current.location {
            idx = len != current.length ? end : 0
            if dLen > 0 && length <= end { return NSRange(location: loc, length: outLen) }
        } else {
            idx = loc
            if loc == 0 && dLoc < 0 { return NSRange(location: 0, length: outLen) }
        }
        guard idx > 0 else { return NSRange(location: loc, length: outLen) }
        var prevRange = NSRange()
        var curRange = NSRange()
        let whole = NSRange(location: 0, length: length)
        let prev = attribute(.mdSpacer, at: idx - 1, effectiveRange: nil) as? NSNumber
        if prev != nil { _ = attribute(.mdSpacer, at: idx - 1, longestEffectiveRange: &prevRange, in: whole) }
        guard idx < length, let cur = attribute(.mdSpacer, at: idx, effectiveRange: nil) as? NSNumber else {
            return NSRange(location: loc, length: outLen)
        }
        _ = attribute(.mdSpacer, at: idx, longestEffectiveRange: &curRange, in: whole)
        guard let prevValue = prev, prevValue.intValue == cur.intValue else { return NSRange(location: loc, length: outLen) }
        if stepOfOne {
            if dLoc >= 0 {
                if dLoc < 1 {
                    if dLen < 0 && loc == current.location {
                        outLen = (end + len) - NSMaxRange(prevRange)
                    } else if dLen > 0 && loc == current.location {
                        outLen = (curRange.location - loc) + curRange.length
                    }
                    return NSRange(location: loc, length: outLen)
                }
                prevRange.location = NSMaxRange(curRange)
            }
            outLen = 0
            loc = prevRange.location
            if len != 0 { outLen = end - prevRange.location }
        } else {
            loc = prevValue.intValue == 1 ? prevRange.location : NSMaxRange(curRange)
        }
        return NSRange(location: loc, length: outLen)
    }
}

// MARK: - NSAttributedString(Ranges)

public extension NSAttributedString {
    static func offsetSelectionRange(_ selection: NSRange, forReplacementRange replacement: NSRange, replacementAttributedString s: NSAttributedString) -> NSRange {
        offsetSelectionRange(selection, forReplacementRange: replacement, replacementLength: s.length)
    }

    /// `+offsetSelectionRange:forReplacementRange:replacementLenght:` (sic).
    static func offsetSelectionRange(_ selection: NSRange, forReplacementRange rep: NSRange, replacementLength newLen: Int) -> NSRange {
        var loc = selection.location
        let len = selection.length
        if len == 0 {
            if rep.location < loc {
                if loc < rep.location + rep.length { return NSRange(location: rep.location + newLen, length: 0) }
            } else {
                if rep.location != loc || rep.length != 0 { return NSRange(location: loc, length: 0) }
            }
            return NSRange(location: loc - rep.length + newLen, length: 0)
        }
        let inter = NSIntersectionRange(selection, rep)
        var outLen = len
        // unsigned compare in the original: (rep.location - loc) < len
        if rep.location >= loc && rep.location - loc < len { outLen = len - rep.length + newLen }
        var anchor = loc
        if rep.location <= loc {
            anchor = rep.location
            outLen = len
            loc = loc - rep.length + newLen
        }
        if inter.length != 0 {
            outLen = newLen + len - inter.length
            loc = anchor
        }
        return NSRange(location: loc, length: outLen)
    }

    func rangeByExtending(_ range: NSRange, toIncludeAttribute key: NSAttributedString.Key) -> NSRange {
        guard range.length != 0, length > 0 else { return range }
        var out = range
        let whole = NSRange(location: 0, length: length)
        var r1 = NSRange(), r2 = NSRange()
        let a = attribute(key, at: min(range.location, length - 1), longestEffectiveRange: &r1, in: whole)
        let b = attribute(key, at: min(NSMaxRange(range) - 1, length - 1), longestEffectiveRange: &r2, in: whole)
        if a != nil { out = NSUnionRange(out, r1) }
        if b != nil { out = NSUnionRange(out, r2) }
        return out
    }

    /// Converts a range in this (attachment-bearing)
    /// string to the markdown string's coordinates.
    func stringRange(fromAttributedStringRange range: NSRange) -> NSRange {
        if let storage = self as? MDTextStorage { return storage.markdownRange(fromAttributedRange: range) }
        var before = 0
        var inside = 0
        let limit = min(NSMaxRange(range), length)
        walkable.enumerateAttribute(.attachment, in: NSRange(location: 0, length: limit), options: []) { value, r, _ in
            guard let att = value as? SFTextAttachment else { return }
            let delta = (att.representedText as NSString).length - r.length
            if NSMaxRange(r) - 1 < range.location { before += delta } else { inside += delta }
        }
        return NSRange(location: range.location + before, length: range.length + inside)
    }

    func attributedStringRange(fromStringRange range: NSRange) -> NSRange {
        let start = (self as? MDTextStorage)?.walkStart(forMarkdownOffset: range.location)
        return MDStringToAttributedStringIndexMap.attributedStringRange(forStringRange: range, in: walkable, from: start)
    }

    func offsetSelection(_ selection: NSRange, byReplacingTextAttachmentIn range: NSRange) -> NSRange {
        var sel = selection
        walkable.enumerateAttribute(.attachment, in: range, options: .reverse) { value, r, _ in
            guard let att = value as? SFTextAttachment else { return }
            sel = NSAttributedString.offsetSelectionRange(sel, forReplacementRange: r, replacementLength: (att.representedText as NSString).length)
        }
        return sel
    }
}

// MARK: - NSAttributedString(TemporaryAttributes)

public extension NSAttributedString {
    /// The attributes stashed by `addTemporaryAttribute`.
    func nonTemporaryAttributes(at index: Int) -> [NSAttributedString.Key: Any]? {
        guard index < length else { return nil }
        return attribute(.mdOriginalAttributes, at: index, effectiveRange: nil) as? [NSAttributedString.Key: Any]
    }
}

public extension NSMutableAttributedString {
    /// Restores the stashed attributes. Returns YES when something changed.
    @discardableResult
    func removeTemporaryAttributes(in range: NSRange) -> Bool {
        var changed = false
        let r = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard r.length > 0 else { return false }
        enumerateAttribute(.mdOriginalAttributes, in: r, options: []) { value, rr, _ in
            guard let dict = value as? [NSAttributedString.Key: Any] else { return }
            addAttributes(dict, range: rr)
            changed = true
            removeAttribute(.mdOriginalAttributes, range: rr)
        }
        return changed
    }

    /// Stashes the current value of `key` under
    /// `MDOriginalAttributes` (only where the key currently has a value and is not stashed yet),
    /// then sets (or, for nil, removes) the attribute.
    func addTemporaryAttribute(_ key: NSAttributedString.Key, value: Any?, in range: NSRange) {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard r.length > 0 else { return }
        enumerateAttribute(key, in: r, options: []) { current, rr, _ in
            guard let current = current else { return }
            enumerateAttribute(.mdOriginalAttributes, in: rr, options: []) { orig, r2, _ in
                let dict = orig as? [NSAttributedString.Key: Any]
                if dict?[key] == nil {
                    var m = dict ?? [:]
                    m[key] = current
                    addAttribute(.mdOriginalAttributes, value: m, range: r2)
                }
            }
        }
        if let v = value { addAttribute(key, value: v, range: r) } else { removeAttribute(key, range: r) }
    }
}

// MARK: - NSAttributedString(AttributesUtils)

public extension NSAttributedString {
    func font(at index: Int) -> NSFont? {
        guard index < length else { return nil }
        return attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    /// The font before the hider replaced it.
    func nonHiddenFont(at index: Int) -> NSFont? {
        (nonTemporaryAttributes(at: index)?[.font] as? NSFont) ?? font(at: index)
    }

    /// The glyph box every visible font in `range` needs, as distances from the baseline.
    func inkExtents(in range: NSRange) -> MDInkExtents? {
        var out: MDInkExtents?
        let ns = string as NSString
        enumerateAttribute(.font, in: range, options: []) { value, run, _ in
            guard let font = value as? NSFont, font.pointSize >= 1 else { return }
            var ideographic = false
            var other = false
            for scalar in ns.substring(with: run).unicodeScalars where !scalar.properties.isWhitespace {
                if scalar.isEastAsianWide { ideographic = true } else { other = true }
            }
            if other { out = MDInkExtents.union(out, font.inkExtents(probing: "hg")) }
            if ideographic { out = MDInkExtents.union(out, font.inkExtents(probing: "国")) }
        }
        return out
    }

    func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        guard index < length else { return nil }
        return attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    func fontColor(at index: Int) -> NSColor? {
        guard index < length else { return nil }
        return attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    /// Callout colors win over the highlighter background.
    func backgroundColor(at index: Int) -> NSColor? {
        guard index < length else { return nil }
        let quote = extendRangeToFullyContainBlockquote(NSRange(location: index, length: 1))
        if quote.location != NSNotFound, quote.location < length,
           let colors = attribute(.mdCalloutColors, at: quote.location, effectiveRange: nil) as? [String: NSColor],
           let bg = colors["background"] {
            return bg
        }
        return attribute(.mdHighlighterBackgroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func isRangeInsideMermaid(_ range: NSRange) -> Bool { isRange(range, insideAttribute: .mdMermaidCode) }
}

// MARK: - NSMutableAttributedString(Fonts)

public extension NSMutableAttributedString {
    func addFontTraits(_ traits: NSFontDescriptor.SymbolicTraits, in range: NSRange) {
        enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            guard let f = value as? NSFont, let v = f.fontVariant(ofSize: f.pointSize, byAddingTraits: traits) else { return }
            addAttribute(.font, value: v, range: r)
        }
    }

    func addFontWeight(_ weight: CGFloat, in range: NSRange) {
        enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            guard let f = value as? NSFont, let v = f.fontVariant(ofSize: f.pointSize, weight: weight) else { return }
            addAttribute(.font, value: v, range: r)
        }
    }
}

// MARK: - NSString(Ranges)

public extension NSString {
    /// Selection expressed relative to a substring.
    static func convertSelectionRange(fromSelection sel: NSRange, toSubstringRange sub: NSRange) -> NSRange {
        if sel.length == 0 {
            var loc = NSNotFound
            if sel.location <= sub.location + sub.length { loc = sel.location - sub.location }
            if sub.location > sel.location { loc = NSNotFound }
            return NSRange(location: loc, length: 0)
        }
        let inter = NSIntersectionRange(sel, sub)
        if inter.length == 0 { return NSNotFoundRange }
        return NSRange(location: inter.location - sub.location, length: inter.length)
    }

    func previousParagraph(for range: NSRange) -> NSRange {
        let p = paragraphRange(for: range)
        if p.location == 0 { return NSNotFoundRange }
        return paragraphRange(for: NSRange(location: p.location - 1, length: 1))
    }

    func nextParagraph(for range: NSRange) -> NSRange {
        let p = paragraphRange(for: range)
        if NSMaxRange(p) >= length { return NSNotFoundRange }
        return paragraphRange(for: NSRange(location: NSMaxRange(p), length: 1))
    }

    /// NSNotFound location when nothing remains.
    func rangeByTrimmingCharacters(in set: CharacterSet, from range: NSRange) -> NSRange {
        var loc = range.location
        var len = range.length
        while loc < length, len > 0 {
            if !set.contains(UnicodeScalar(character(at: loc)) ?? " ") { break }
            loc += 1
            len -= 1
        }
        while len > 0 {
            if !set.contains(UnicodeScalar(character(at: loc + len - 1)) ?? " ") { break }
            len -= 1
        }
        if len == 0 { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: loc, length: len)
    }

    func hasOnlyWhitespaceCharacters(in range: NSRange) -> Bool {
        rangeByTrimmingCharacters(in: .whitespaces, from: range).length == 0
    }

    func hasNewLineBefore(_ range: NSRange) -> Bool {
        guard range.location != 0, range.location <= length else { return false }
        return character(at: range.location - 1) == 0x0A
    }

    func hasNewLineAfter(_ range: NSRange) -> Bool {
        let end = NSMaxRange(range)
        guard end < length else { return false }
        return character(at: end) == 0x0A
    }
}

// MARK: - NSTextAttachment(AttachmentKind)

public extension NSTextAttachment {
    var isHeader: Bool { self is MDATXHeadingAttachment || self is MDSETEXTHeadingAttachment }
    var isATXHeader: Bool { self is MDATXHeadingAttachment }
    var isList: Bool { self is MDUnorderedListTextAttachment || self is MDOrderedListTextAttachment || self is MDTaskTextAttachment }
    var isOrderedList: Bool { self is MDOrderedListTextAttachment }
    var isUnorderedList: Bool { self is MDUnorderedListTextAttachment }
    var isTask: Bool { self is MDTaskTextAttachment }
    var isThematicBreak: Bool { self is MDThematicBreakTextAttachment }
    var isLink: Bool { self is MDLinkTextAttachment }
    var isBlockquote: Bool { self is MDBlockQuoteTextAttachment }
    var isFold: Bool { self is MDFoldTextAttachment }
    var isViewAttachment: Bool { self is SFTextAttachmentView }
    var isFileBacked: Bool { self is SFTextAttachmentFileBackedView }
    var isHardLineBreak: Bool { self is MDHardLineBreakTextAttachment }
    var isHighlighter: Bool { self is MDHighlighterTextAttachment }
    var isIndentSpace: Bool { self is MDIndentSpaceTextAttachment }
    // Not ported (math / mermaid / table / image / color / arrow / footnote / callout): always false.
    var isInlineMathSpacer: Bool { false }
    var isMath: Bool { false }
    var isMermaid: Bool { false }
    var isTable: Bool { false }
    var isImage: Bool { false }
}

// MARK: - NSFont(Metrics) / NSFont(FontVariants)

public extension NSFont {
    /// `+basePointSizeForFontSize:` = floor(size * 0.05). Used as the stroke unit for markers.
    /// `roundsd $0xA` in the binary, i.e. ceil(size * 0.05).
    static func basePointSize(forFontSize size: CGFloat) -> CGFloat { ceil(size * 0.05) }

    /// The ink box of `sample`'s glyphs; the font's ascender and descender when the font lacks them.
    func inkExtents(probing sample: String) -> MDInkExtents {
        var characters = Array(sample.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(self, &characters, &glyphs, characters.count) else {
            return MDInkExtents(above: ascender, below: -descender)
        }
        let box = glyphs.reduce(CGRect.null) { $0.union(boundingRect(forCGGlyph: $1)) }
        return MDInkExtents(above: box.maxY, below: -box.minY)
    }

    var basePointSize: CGFloat { NSFont.basePointSize(forFontSize: pointSize) }

    /// `calculatedLineHeight` = ascent + descent + leading from CoreText (UI font variant for the system family).
    var calculatedLineHeight: CGFloat {
        let ct: CTFont
        if familyName == NSFont.systemFont(ofSize: 10).familyName {
            ct = CTFontCreateUIFontForLanguage(.system, pointSize, nil) ?? (self as CTFont)
        } else {
            ct = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        }
        return CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
    }

    /// Same face at another size.
    func fontVariant(ofSize size: CGFloat) -> NSFont? {
        fontVariant(ofSize: size, byAddingTraits: nil)
    }

    /// Rebuilds the font from family + symbolic traits
    /// so bold/italic come from the real family members. `nil` traits keeps the exact face.
    func fontVariant(ofSize size: CGFloat, byAddingTraits traits: NSFontDescriptor.SymbolicTraits?) -> NSFont? {
        guard let variant = faceVariant(ofSize: size, byAddingTraits: traits) else { return nil }
        // The cascade travels with the face, and its entries take the traits the face gains.
        guard let cascade = fontDescriptor.fontAttributes[.cascadeList] as? [NSFontDescriptor] else { return variant }
        let traited = cascade.map { traits.map($0.withSymbolicTraits) ?? $0 }
        return NSFont(descriptor: variant.fontDescriptor.addingAttributes([.cascadeList: traited]), size: size) ?? variant
    }

    private func faceVariant(ofSize size: CGFloat, byAddingTraits traits: NSFontDescriptor.SymbolicTraits?) -> NSFont? {
        let descriptor = fontDescriptor
        var attrs: [NSFontDescriptor.AttributeName: Any] = [:]
        attrs[.family] = familyName
        let existingTraits = descriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = existingTraits?[.weight]
        if let traits = traits {
            if traits == .bold, let weight = weight {
                attrs[.traits] = [NSFontDescriptor.TraitKey.symbolic: NSFontDescriptor.SymbolicTraits.bold.rawValue,
                                  NSFontDescriptor.TraitKey.weight: weight]
            } else {
                attrs[.traits] = [NSFontDescriptor.TraitKey.symbolic: descriptor.symbolicTraits.union(traits).rawValue]
            }
        } else {
            attrs[.name] = fontName
        }
        let wanted = traits ?? []
        if let f = NSFont(descriptor: NSFontDescriptor(fontAttributes: attrs), size: size), f.fontDescriptor.symbolicTraits.isSuperset(of: wanted) {
            return f
        }
        // The hidden system family (".AppleSystemUIFont") does not resolve reliably through a family lookup;
        // derive the face from the descriptor instead.
        if let f = NSFont(descriptor: descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(wanted)), size: size), f.fontDescriptor.symbolicTraits.isSuperset(of: wanted) {
            return f
        }
        return NSFont(descriptor: descriptor, size: size)
    }

    func fontVariant(ofSize size: CGFloat, weight: CGFloat) -> NSFont? {
        var attrs: [NSFontDescriptor.AttributeName: Any] = [:]
        attrs[.family] = familyName
        attrs[.traits] = [NSFontDescriptor.TraitKey.weight: weight,
                          NSFontDescriptor.TraitKey.symbolic: fontDescriptor.symbolicTraits.rawValue]
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: attrs), size: size)
    }
}

// MARK: - NSMutableParagraphStyle(CenteredLineHeight)

public extension NSMutableParagraphStyle {
    /// MinimumLineHeight = max(floor(mult * pointSize),
    /// font.calculatedLineHeight); lineSpacing = floor(lineSpacingForLineHeight(minimumLineHeight, font)).
    func setCenteredLineHeightMultiplier(_ multiplier: CGFloat, for font: NSFont) {
        // Round half away from zero, not floor.
        let target = (multiplier * font.pointSize).rounded(.toNearestOrAwayFromZero)
        minimumLineHeight = max(target, font.calculatedLineHeight)
        lineSpacing = lineSpacing(forLineHeight: minimumLineHeight, font: font).rounded(.toNearestOrAwayFromZero)
    }

    /// `lineSpacingForLineHeight:font:` = lineHeight − (ascender + |descender| + leading)
    /// (x86: `andpd` clears the sign of `descender` before the additions).
    func lineSpacing(forLineHeight lineHeight: CGFloat, font: NSFont) -> CGFloat {
        lineHeight - (font.ascender + abs(font.descender) + font.leading)
    }
}

/// Vertical glyph extents measured from the baseline, in points.
public struct MDInkExtents: Sendable {
    public var above: CGFloat
    public var below: CGFloat

    public init(above: CGFloat, below: CGFloat) {
        self.above = above
        self.below = below
    }

    static func union(_ a: MDInkExtents?, _ b: MDInkExtents) -> MDInkExtents {
        guard let a else { return b }
        return MDInkExtents(above: max(a.above, b.above), below: max(a.below, b.below))
    }
}

extension Unicode.Scalar {
    /// Han, kana, hangul and the CJK punctuation and full-width forms that share their box.
    var isEastAsianWide: Bool {
        if properties.isIdeographic { return true }
        switch value {
        case 0x1100...0x11FF, 0x3000...0x30FF, 0x3130...0x318F, 0xAC00...0xD7AF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
