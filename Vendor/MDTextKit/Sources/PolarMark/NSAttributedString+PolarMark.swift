import Foundation

// Ported 1:1 from PolarMark's ObjC categories:
//   NSAttributedString(PolarMark), (PMKLists), (PMKBlockquotes), (PMKUtils)
// These are the queries MDTextKit's stylers, hider and editor controller use to
// navigate the annotated string.

public extension NSAttributedString {

    // MARK: - PMKUtils

    /// NSNotFound range when the attribute is absent.
    func longestRange(forAttribute key: NSAttributedString.Key, at index: Int) -> NSRange {
        guard index >= 0, index < length, attribute(key, at: index, effectiveRange: nil) != nil else { return NSRange(location: NSNotFound, length: 0) }
        var r = NSRange()
        _ = attribute(key, at: index, longestEffectiveRange: &r, in: NSRange(location: 0, length: length))
        return r
    }

    // MARK: - Range predicates (PolarMark)

    /// True when either end of the range carries the attribute.
    func isRange(_ range: NSRange, insideAttribute key: NSAttributedString.Key) -> Bool {
        guard range.location != NSNotFound else { return false }
        let last = range.length == 0 ? 0 : range.length - 1
        guard range.location + last < length else { return false }
        return attribute(key, at: range.location, effectiveRange: nil) != nil || attribute(key, at: range.location + last, effectiveRange: nil) != nil
    }

    func isRangeInsideBlockCode(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkFencedCode) || isRange(r, insideAttribute: .pmkIndentedCode) }
    func isRangeInsideInlineCode(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkCode) }
    func isRangeInsideCode(_ r: NSRange) -> Bool { isRangeInsideBlockCode(r) || isRangeInsideInlineCode(r) }
    func isRangeInsideBlockMath(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkMathBlock) }
    func isRangeInsideMath(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkMathBlock) || isRange(r, insideAttribute: .pmkMathSpan) }
    func isRangeInsideList(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkList) }
    func isRangeInsideTaskList(_ r: NSRange) -> Bool {
        guard r.location != NSNotFound, r.location < length, let info = attribute(.pmkListItem, at: r.location, effectiveRange: nil) as? PMKListInfo else { return false }
        return info.isTaskList
    }
    func isRangeInsideBlockquote(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkBlockquote) }
    func isRangeInsideHeader(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkHeading) }
    func isRangeInsideHashtag(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkHashtag) }
    func isRangeInsideLink(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkLink) }
    func isRangeInsideImage(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkImage) }
    func isRangeInsideAutoLinkURL(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkAutoLinkURL) }
    func isRangeInsideAutoLinkEmail(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkAutoLinkEmail) }
    func isRangeInsideAutoLink(_ r: NSRange) -> Bool { isRangeInsideAutoLinkURL(r) || isRangeInsideAutoLinkEmail(r) }
    func isRangeInsideWikiLink(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkWikiLink) }
    func isRangeInsideFootnote(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkFootNote) }
    func isRangeInsideHTML(_ r: NSRange) -> Bool { isRange(r, insideAttribute: .pmkHTMLBlock) || isRange(r, insideAttribute: .pmkHTMLInline) }

    func hasMarker(at index: Int) -> Bool {
        guard index < length else { return false }
        let keys = Set(attributes(at: index, effectiveRange: nil).keys)
        return PMKAttributes.markerAttributes.contains { keys.contains($0) }
    }
    func hasOpeningMarker(at index: Int) -> Bool {
        guard index < length else { return false }
        let attrs = attributes(at: index, effectiveRange: nil)
        return PMKAttributes.markerAttributes.contains { (attrs[$0] as? NSNumber)?.intValue == PMKMarkerValue.open.rawValue }
    }
    func hasClosingMarker(at index: Int) -> Bool {
        guard index < length else { return false }
        let attrs = attributes(at: index, effectiveRange: nil)
        return PMKAttributes.markerAttributes.contains { (attrs[$0] as? NSNumber)?.intValue == PMKMarkerValue.close.rawValue }
    }
    func hasHeaderMarker(at index: Int) -> Bool { index < length && attribute(.pmkHeadingMarker, at: index, effectiveRange: nil) != nil }
    func hasListMarker(at index: Int) -> Bool { index < length && attribute(.pmkListMarker, at: index, effectiveRange: nil) != nil }
    func hasBlockquoteMarker(at index: Int) -> Bool { index < length && attribute(.pmkBlockquoteMarker, at: index, effectiveRange: nil) != nil }
    func hasIndentSpace(at index: Int) -> Bool { index < length && attribute(.pmkIndentSpace, at: index, effectiveRange: nil) != nil }
    func hasTaskListMarker(at index: Int) -> Bool {
        guard index < length, attribute(.pmkListMarker, at: index, effectiveRange: nil) != nil,
              let info = attribute(.pmkListItem, at: index, effectiveRange: nil) as? PMKListInfo else { return false }
        return info.isTaskList
    }

    /// `headerLevelAtIndex:` (0 when not in a heading).
    func headerLevel(at index: Int) -> Int {
        guard index < length else { return 0 }
        return (attribute(.pmkHeading, at: index, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
    }

    /// 0 = LTR, 1 = RTL, -1 = natural/unknown.
    func writingDirection(at index: Int) -> Int {
        guard index < length, let v = attribute(.pmkDirection, at: index, effectiveRange: nil) as? NSNumber else { return -1 }
        if v.intValue == PMKDirectionValue.ltr.rawValue { return 0 }
        if v.intValue == PMKDirectionValue.rtl.rawValue { return 1 }
        return -1
    }

    func hashTagRange(at index: Int) -> NSRange { longestRange(forAttribute: .pmkHashtag, at: index) }
    func headerRange(at index: Int) -> NSRange { headerRange(at: index, markerRange: nil) }
    func linkRange(at index: Int) -> NSRange { longestRange(forAttribute: .pmkLink, at: index) }
    func codeRange(at index: Int) -> NSRange { longestRange(forAttribute: .pmkCode, at: index) }
    func codeBlockRange(at index: Int) -> NSRange { longestRange(forAttribute: .pmkFencedCode, at: index) }
    func highlighterRange(at index: Int) -> NSRange { longestRange(forAttribute: .pmkHighlighter, at: index) }

    /// The heading line containing `index`.
    func headerRange(at index: Int, markerRange: UnsafeMutablePointer<NSRange>?) -> NSRange {
        let whole = longestRange(forAttribute: .pmkHeading, at: index)
        guard whole.location != NSNotFound else { return whole }
        var result = NSRange(location: NSNotFound, length: 0)
        enumerateHeading(in: whole, options: []) { _, atx, setext, heading, _, stop in
            if index >= heading.location && index - heading.location < heading.length {
                result = heading
                markerRange?.pointee = atx.location != NSNotFound ? atx : setext
                stop.pointee = true
            }
        }
        return result
    }

    /// The closing marker run at `index`, if any.
    func inlineClosingMarkerRange(at index: Int) -> NSRange {
        guard index != 0, index < length else { return NSRange(location: NSNotFound, length: 0) }
        let keys: [NSAttributedString.Key] = [.pmkStrongMarker, .pmkEmphasisMarker, .pmkStrikethroughMarker, .pmkUnderlineMarker,
                                              .pmkHighlighterMarker, .pmkHashtagMarker, .pmkCodeMarker, .pmkWikiLinkMarker, .pmkMathSpanMarker]
        let attrs = attributes(at: index, effectiveRange: nil)
        for k in keys where (attrs[k] as? NSNumber)?.intValue == PMKMarkerValue.close.rawValue {
            return longestRange(forAttribute: k, at: index)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func extendRange(_ range: NSRange, toFullyContainAttributes keys: [NSAttributedString.Key]) -> NSRange {
        var out = range
        let whole = NSRange(location: 0, length: length)
        for key in keys {
            var i = out.location
            while i >= 0 && i < length {
                var r = NSRange()
                guard attribute(key, at: i, longestEffectiveRange: &r, in: whole) != nil else { break }
                out = NSUnionRange(out, r)
                if i == 0 { break }
                i -= 1
            }
            var j = NSMaxRange(out) == 0 ? 0 : NSMaxRange(out) - 1
            while j < length {
                var r = NSRange()
                guard attribute(key, at: j, longestEffectiveRange: &r, in: whole) != nil else { break }
                out = NSUnionRange(out, r)
                j += 1
            }
        }
        return out
    }

    // MARK: - Enumerations (PolarMark)

    /// Block: (contentRange, atxMarkerRange, setextMarkerRange, headingRange, level, stop).
    func enumerateHeading(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                          using block: (NSRange, NSRange, NSRange, NSRange, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let ns = string as NSString
        let whole = NSRange(location: 0, length: length)
        let notFound = NSRange(location: NSNotFound, length: 0)
        withoutActuallyEscaping(block) { block in
        enumerateAttribute(.pmkHeading, in: range, options: options) { value, run, stop in
            guard let level = (value as? NSNumber)?.intValue else { return }
            var pending = notFound
            var stopped = false
            ns.enumerateSubstrings(in: run, options: .byLines) { _, lineRange, enclosing, lineStop in
                guard lineRange.length != 0 else { return }
                var marker = NSRange()
                var markerValue = self.attribute(.pmkHeadingMarker, at: lineRange.location, longestEffectiveRange: &marker, in: lineRange) as? NSNumber
                if markerValue == nil {
                    markerValue = self.attribute(.pmkHeadingMarker, at: NSMaxRange(lineRange) - 1, longestEffectiveRange: &marker, in: lineRange) as? NSNumber
                }
                let kind = markerValue?.intValue ?? 0
                var innerStop: ObjCBool = false
                if kind == PMKHeadingMarkerValue.atx.rawValue {
                    let content = NSRange(location: enclosing.location + marker.length, length: enclosing.length - marker.length)
                    block(content, marker, notFound, enclosing, level, &innerStop)
                } else if kind == PMKHeadingMarkerValue.setext.rawValue {
                    let heading = pending.location == NSNotFound ? enclosing : NSUnionRange(pending, enclosing)
                    block(pending.location == NSNotFound ? NSRange(location: enclosing.location, length: 0) : pending, notFound, marker, heading, level, &innerStop)
                    pending = notFound
                } else {
                    pending = pending.location == NSNotFound ? enclosing : NSUnionRange(pending, enclosing)
                }
                if innerStop.boolValue { stopped = true; lineStop.pointee = true }
            }
            _ = whole
            if stopped { stop.pointee = true }
        }
        }
    }

    /// Block: (contentRange, openingMarkerRange, closingMarkerRange, stop). A marker run that ends
    /// where the construct ends is the closing marker (so partial ranges still work).
    func enumerateWrappingAttribute(_ key: NSAttributedString.Key, marker: NSAttributedString.Key, in range: NSRange,
                                    options: NSAttributedString.EnumerationOptions,
                                    using block: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let notFound = NSRange(location: NSNotFound, length: 0)
        enumerateAttribute(key, in: range, options: options) { value, run, stop in
            guard value != nil else { return }
            var opening = notFound
            var closing = notFound
            self.enumerateAttribute(marker, in: run, options: []) { mv, mr, _ in
                guard mv != nil else { return }
                if opening.location == NSNotFound {
                    if NSMaxRange(mr) != NSMaxRange(run) || mr == run {
                        opening = mr
                        return
                    }
                }
                closing = mr
            }
            var content = run
            let openLength = opening.location == NSNotFound ? 0 : opening.length
            if closing.location != NSNotFound {
                content.length = closing.location - (opening.location == NSNotFound ? run.location : opening.location) - openLength
            } else {
                content.length = run.length - openLength
            }
            content.location += openLength
            block(content, opening, closing, stop)
        }
    }

    func enumerateStrong(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkStrong, marker: .pmkStrongMarker, in: r, options: o, using: b) }
    func enumerateEmphasis(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkEmphasis, marker: .pmkEmphasisMarker, in: r, options: o, using: b) }
    func enumerateStrikethrough(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkStrikethrough, marker: .pmkStrikethroughMarker, in: r, options: o, using: b) }
    func enumerateUnderline(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkUnderline, marker: .pmkUnderlineMarker, in: r, options: o, using: b) }
    func enumerateCode(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkCode, marker: .pmkCodeMarker, in: r, options: o, using: b) }
    func enumerateHashtag(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkHashtag, marker: .pmkHashtagMarker, in: r, options: o, using: b) }
    func enumerateWikiLink(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkWikiLink, marker: .pmkWikiLinkMarker, in: r, options: o, using: b) }
    func enumerateInlineMath(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateWrappingAttribute(.pmkMathSpan, marker: .pmkMathSpanMarker, in: r, options: o, using: b) }

    /// Block: (contentRange, openingFenceRange, closingFenceRange, languageRange, language, stop).
    func enumerateFencedCode(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                             using block: (NSRange, NSRange, NSRange, NSRange, String?, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let ns = string as NSString
        enumerateWrappingAttribute(.pmkFencedCode, marker: .pmkFencedCodeMarker, in: range, options: options) { content, opening, closing, stop in
            var language: String? = nil
            var languageRange = NSRange(location: NSNotFound, length: 0)
            let paragraph = ns.paragraphRange(for: opening.location == NSNotFound ? NSRange(location: content.location, length: 0) : opening)
            self.enumerateAttribute(.pmkFencedCodeLanguage, in: paragraph, options: []) { v, r, s in
                guard let v = v else { return }
                language = v as? String ?? ns.substring(with: r)
                languageRange = r
                s.pointee = true
            }
            block(content, opening, closing, languageRange, language, stop)
        }
    }

    func hasTable(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        return attribute(.pmkTable, at: index, effectiveRange: nil) != nil
    }

    func isRangeInsideTable(_ r: NSRange) -> Bool {
        guard r.location != NSNotFound, NSMaxRange(r) <= length else { return false }
        return hasTable(at: r.location) || hasTable(at: r.location + max(r.length - 1, 0))
    }

    /// TableBlock(range, rows, columns, stop),
    /// cellBlock(contentRange, row, column, alignment, stop); row 1 is the delimiter row.
    func enumerateTable(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                        tableBlock: ((NSRange, Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void)?,
                        cellBlock: ((NSRange, Int, Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void)?) {
        enumerateAttribute(.pmkTable, in: range, options: options) { v, tRange, stop in
            guard let dict = v as? NSDictionary else { return }
            let rows = (dict["RowCount"] as? NSNumber)?.intValue ?? 0
            let columns = (dict["ColumnCount"] as? NSNumber)?.intValue ?? 0
            tableBlock?(tRange, rows, columns, stop)
            guard let cellBlock = cellBlock, !stop.pointee.boolValue, columns > 0 else { return }
            var row = 0, col = 0, cellStart = NSNotFound
            self.enumerateAttribute(.pmkTableMarker, in: tRange, options: []) { mv, mRange, mstop in
                guard mv != nil else { return }
                for idx in mRange.location..<NSMaxRange(mRange) {
                    if cellStart == NSNotFound { cellStart = idx + 1; continue }
                    let cellRange = NSRange(location: cellStart, length: max(0, idx - cellStart))
                    var content = NSRange(location: cellStart, length: 0)
                    var align = 4
                    if cellRange.length > 0 {
                        self.enumerateAttribute(.pmkTableCellContent, in: cellRange, options: []) { cv, cr, _ in
                            if let n = cv as? NSNumber { content = cr; align = n.intValue }
                        }
                    }
                    cellBlock(content, row, col, align, stop)
                    if stop.pointee.boolValue { mstop.pointee = true; return }
                    if col + 1 < columns { cellStart = idx; col += 1 } else { cellStart = NSNotFound; col = 0; row += 1 }
                }
            }
        }
    }

    func hasFold(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        return attribute(.pmkFold, at: index, effectiveRange: nil) != nil
    }

    /// Block(markerRange, foldedRange, stop).
    func enumerateFold(in range: NSRange, options: NSAttributedString.EnumerationOptions, using block: (NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkFold, in: range, options: options) { v, r, stop in
            guard v != nil else { return }
            let marker = self.longestRange(forAttribute: .pmkFoldMarker, at: r.location)
            guard marker.location != NSNotFound else { return }
            block(marker, NSRange(location: NSMaxRange(marker), length: r.length - marker.length), stop)
        }
    }

    func enumerateThematicBreak(in range: NSRange, options: NSAttributedString.EnumerationOptions, using block: (NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkThematicBreak, in: range, options: options) { v, r, stop in if v != nil { block(r, stop) } }
    }
    func enumerateHardLinebreak(in range: NSRange, options: NSAttributedString.EnumerationOptions, using block: (NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkHardLinebreak, in: range, options: []) { v, r, stop in if v != nil { block(r, stop) } }
    }
    func enumerateEscape(in range: NSRange, options: NSAttributedString.EnumerationOptions, using block: (NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkEscape, in: range, options: options) { v, r, stop in if v != nil { block(r, stop) } }
    }
    func enumerateIndentedCode(in range: NSRange, options: NSAttributedString.EnumerationOptions, using block: (NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkIndentedCode, in: range, options: options) { v, r, stop in if v != nil { block(r, stop) } }
    }

    /// Markers come as four runs: "[" open, "]" close, "(" open, ")" close.
    /// Block: (labelRange, urlRange, titleRange, openBracket, closeBracket, openParen, closeParen, stop).
    func enumerateLinkAttribute(_ key: NSAttributedString.Key, marker: NSAttributedString.Key, url urlKey: NSAttributedString.Key,
                                title titleKey: NSAttributedString.Key, label labelKey: NSAttributedString.Key,
                                in range: NSRange, options: NSAttributedString.EnumerationOptions,
                                using block: (NSRange, NSRange, NSRange, NSRange, NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let notFound = NSRange(location: NSNotFound, length: 0)
        enumerateAttribute(key, in: range, options: options) { value, run, stop in
            guard value != nil else { return }
            var count = 0
            var whole = NSRange(location: run.location, length: 0)
            var open1 = notFound, close1 = notFound, open2 = notFound, close2 = notFound
            self.enumerateAttribute(marker, in: run, options: []) { mv, mr, mstop in
                guard let v = (mv as? NSNumber)?.intValue else { return }
                if v == PMKMarkerValue.open.rawValue {
                    count += 1
                    if count == 1 { whole.location = mr.location; open1 = mr } else { open2 = mr }
                }
                if v == PMKMarkerValue.close.rawValue {
                    count += 1
                    if count == 2 { close1 = mr } else { close2 = mr }
                    if count == 4 {
                        count = 0
                        whole.length = NSMaxRange(mr) - whole.location
                        var label = notFound, url = notFound, title = notFound
                        self.enumerateAttribute(labelKey, in: whole, options: []) { v, r, _ in if v != nil { label = r } }
                        self.enumerateAttribute(urlKey, in: whole, options: []) { v, r, _ in if v != nil { url = r } }
                        self.enumerateAttribute(titleKey, in: whole, options: []) { v, r, _ in if v != nil { title = r } }
                        if label.location == NSNotFound { label = NSRange(location: NSMaxRange(open1), length: 0) }
                        if url.location == NSNotFound { url = NSRange(location: NSMaxRange(open2), length: 0) }
                        block(label, url, title, open1, close1, open2, close2, mstop)
                        if mstop.pointee.boolValue { stop.pointee = true }
                    }
                }
            }
        }
    }

    func enumerateLink(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                       using block: (NSRange, NSRange, NSRange, NSRange, NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateLinkAttribute(.pmkLink, marker: .pmkLinkMarker, url: .pmkLinkURL, title: .pmkLinkTitle, label: .pmkLinkLabel, in: range, options: options, using: block)
    }

    func enumerateImage(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                        using block: (NSRange, NSRange, NSRange, NSRange, NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateLinkAttribute(.pmkImage, marker: .pmkImageMarker, url: .pmkImageURL, title: .pmkImageTitle, label: .pmkImageLabel, in: range, options: options, using: block)
    }

    /// Block: (urlRange, openMarker "<", closeMarker ">", stop); markers are NSNotFound for bare links.
    func enumerateAutoLink(in range: NSRange, attributeName key: NSAttributedString.Key, options: NSAttributedString.EnumerationOptions,
                           using block: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let notFound = NSRange(location: NSNotFound, length: 0)
        enumerateAttribute(key, in: range, options: options) { value, run, stop in
            guard value != nil else { return }
            var cursor = run.location
            var open = notFound
            self.enumerateAttribute(.pmkAutoLinkMarker, in: run, options: []) { mv, mr, mstop in
                guard let v = (mv as? NSNumber)?.intValue else { return }
                if v == PMKMarkerValue.open.rawValue {
                    open = mr
                    if mr.location > cursor { block(NSRange(location: cursor, length: mr.location - cursor), notFound, notFound, mstop) }
                } else if v == PMKMarkerValue.close.rawValue {
                    let u = NSUnionRange(open, mr)
                    block(NSRange(location: u.location + open.length, length: u.length - open.length - mr.length), open, mr, mstop)
                    cursor = NSMaxRange(mr)
                }
                if mstop.pointee.boolValue { stop.pointee = true }
            }
            if cursor <= NSMaxRange(run), NSMaxRange(run) - cursor != 0 {
                block(NSRange(location: cursor, length: NSMaxRange(run) - cursor), notFound, notFound, stop)
            }
        }
    }
    func enumerateAutoLinkURL(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateAutoLink(in: r, attributeName: .pmkAutoLinkURL, options: o, using: b) }
    func enumerateAutoLinkEmail(in r: NSRange, options o: NSAttributedString.EnumerationOptions, using b: (NSRange, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) { enumerateAutoLink(in: r, attributeName: .pmkAutoLinkEmail, options: o, using: b) }

    func enumerateHighlighter(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                              highlighterBlock: (NSRange, UnsafeMutablePointer<ObjCBool>) -> Void,
                              colorBlock: (NSRange, Int, UnsafeMutablePointer<ObjCBool>) -> Void,
                              markerBlock: (NSRange, Bool, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkHighlighter, in: range, options: []) { value, run, stop in
            guard value != nil else { return }
            highlighterBlock(run, stop)
            self.enumerateAttribute(.pmkHighlighterColor, in: run, options: []) { v, r, s in
                if let n = v as? NSNumber { colorBlock(r, n.intValue, s) }
            }
            self.enumerateAttribute(.pmkHighlighterMarker, in: run, options: []) { v, r, s in
                guard let n = v as? NSNumber else { return }
                let isOpen = n.intValue == PMKMarkerValue.open.rawValue
                let color = (self.attribute(.pmkHighlighterColor, at: r.location, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
                markerBlock(r, isOpen, color, s)
            }
        }
    }

    // MARK: - PMKLists

    func listItemInfo(at index: Int, longestEffectiveRange: UnsafeMutablePointer<NSRange>? = nil) -> PMKListInfo? {
        guard index < length else { return nil }
        let info = attribute(.pmkListItem, at: index, effectiveRange: nil) as? PMKListInfo
        longestEffectiveRange?.pointee = rangeOfListItem(at: index)
        return info
    }

    func rangeOfListItem(at index: Int) -> NSRange { rangeOfListItem(at: index, markerRange: nil) }

    /// The item plus its sublists / continuation
    /// paragraphs (runs of deeper level, or the same level without a marker).
    func rangeOfListItem(at index: Int, markerRange: UnsafeMutablePointer<NSRange>?) -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: 0)
        guard index < length else { return notFound }
        var r = NSRange()
        let whole = NSRange(location: 0, length: length)
        guard let info = attribute(.pmkListItem, at: index, longestEffectiveRange: &r, in: whole) as? PMKListInfo else {
            markerRange?.pointee = notFound
            return notFound
        }
        let level = info.listLevel
        var cursor = NSMaxRange(r)
        while cursor < length {
            var next = NSRange()
            guard let nextInfo = attribute(.pmkListItem, at: cursor, longestEffectiveRange: &next, in: whole) as? PMKListInfo else { break }
            if nextInfo.listLevel < level { break }
            if nextInfo.listLevel == level, rangeOfListMarker(forListItemRange: next).location != NSNotFound { break }
            r = NSUnionRange(r, next)
            cursor = NSMaxRange(r)
        }
        markerRange?.pointee = rangeOfListMarker(forListItemRange: r)
        return r
    }

    /// First marker run; an indent-space run first means "no marker".
    func rangeOfListMarker(forListItemRange range: NSRange) -> NSRange {
        var result = NSRange(location: NSNotFound, length: 0)
        enumerateAttribute(.pmkListMarker, in: range, options: []) { v, r, stop in
            if v == nil {
                if self.attribute(.pmkIndentSpace, at: r.location, effectiveRange: nil) != nil { return }
            } else {
                result = r
            }
            stop.pointee = true
        }
        return result
    }

    /// The item's own run only.
    func rangeOfListItemWithoutSublists(at index: Int) -> NSRange {
        guard index < length else { return NSRange(location: NSNotFound, length: 0) }
        var r = NSRange()
        guard attribute(.pmkListItem, at: index, longestEffectiveRange: &r, in: NSRange(location: 0, length: length)) != nil else { return NSRange(location: NSNotFound, length: 0) }
        return r
    }

    func rangeOfIndentForListItem(at index: Int) -> NSRange {
        let item = rangeOfListItem(at: index)
        guard item.location != NSNotFound else { return item }
        var r = NSRange()
        if attribute(.pmkIndentSpace, at: item.location, effectiveRange: &r) != nil { return r }
        return NSRange(location: item.location, length: 0)
    }

    func rangeOfSublistsForListItem(at index: Int) -> NSRange {
        let item = rangeOfListItem(at: index)
        guard item.location != NSNotFound else { return item }
        var own = NSRange()
        _ = attribute(.pmkListItem, at: index, longestEffectiveRange: &own, in: item)
        let rest = item.length - own.length
        return rest == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: NSMaxRange(own), length: rest)
    }

    /// `rangeOfParentListItemOfType:atIndex:` (type 0 = any).
    func rangeOfParentListItem(ofType type: Int, at index: Int) -> NSRange {
        var own = NSRange()
        var result = NSRange(location: NSNotFound, length: 0)
        guard let info = listItemInfo(at: index, longestEffectiveRange: &own), info.listLevel != 0 else { return result }
        var i = own.location - 1
        while i >= 0 {
            var r = NSRange()
            guard let candidate = listItemInfo(at: i, longestEffectiveRange: &r) else { break }
            result = r
            if candidate.listLevel == info.listLevel - 1 && (type == 0 || candidate.listType == type) { return r }
            i = r.location - 1
        }
        return result
    }

    func rangeOfNextSiblingListItem(at index: Int) -> NSRange {
        var own = NSRange()
        guard let info = listItemInfo(at: index, longestEffectiveRange: &own), NSMaxRange(own) < length else { return NSRange(location: NSNotFound, length: 0) }
        var r = NSRange()
        guard let next = listItemInfo(at: NSMaxRange(own), longestEffectiveRange: &r),
              next.listLevel == info.listLevel, next.listType == info.listType, next.listSubType == info.listSubType else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return r
    }

    /// The contiguous run of items at `level` (or deeper) around `index`.
    func rangeOfListLevel(_ level: Int, at index: Int) -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: 0)
        guard index < length else { return notFound }
        var itemRange = NSRange()
        guard var info = listItemInfo(at: index, longestEffectiveRange: &itemRange) else { return notFound }
        var result = notFound
        var previous: PMKListInfo? = nil
        // forward
        while true {
            if info.listLevel < level { break }
            var base = itemRange
            if result.location != NSNotFound { base = result }
            if let p = previous, info.listLevel == p.listLevel, info.listLevel == level {
                if info.listType != p.listType || info.listSubType != p.listSubType { result = base; break }
            }
            result = NSUnionRange(base, itemRange)
            guard NSMaxRange(result) < length, let next = listItemInfo(at: NSMaxRange(result), longestEffectiveRange: &itemRange) else { break }
            previous = info
            info = next
        }
        guard result.location != NSNotFound else { return result }
        // backward
        var cursor = Int(result.location) - 1
        var last: PMKListInfo? = nil
        while cursor >= 0 {
            var r = NSRange()
            guard let cur = listItemInfo(at: cursor, longestEffectiveRange: &r) else { break }
            if cur.listLevel < level { break }
            if let l = last {
                if cur.listLevel == l.listLevel, cur.listLevel == level, cur.listType != l.listType || cur.listSubType != l.listSubType { break }
                if l.listLevel < cur.listLevel {
                    let parent = rangeOfParentListItem(ofType: 0, at: cursor)
                    if parent.location != NSNotFound, let pi = listItemInfo(at: parent.location), pi.listType != l.listType { break }
                }
            }
            result = NSUnionRange(result, r)
            cursor = Int(result.location) - 1
            last = cur
        }
        return result
    }

    /// `enumerateListType:inRange:options:listBlock:listItemBlock:` (type 0 = any, 1 unordered, 2 ordered)
    func enumerateListType(_ type: Int, in range: NSRange, options: NSAttributedString.EnumerationOptions,
                           listBlock: ((NSRange, Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void)?,
                           listItemBlock: ((NSRange, NSRange, PMKListInfo, UnsafeMutablePointer<ObjCBool>) -> Void)?) {
        enumerateAttribute(.pmkList, in: range, options: options) { listValue, listRun, stop in
            guard listValue != nil else { return }
            self.enumerateAttribute(.pmkListItem, in: listRun, options: options) { itemValue, itemRun, itemStop in
                guard itemValue != nil else { return }
                var markerRange = NSRange(location: NSNotFound, length: 0)
                var itemRange = itemRun
                var info: PMKListInfo? = nil
                self.enumerateAttribute(.pmkListMarker, in: itemRun, options: []) { mv, mr, mstop in
                    guard let markerType = (mv as? NSNumber)?.intValue else { return }
                    markerRange = mr
                    info = self.listItemInfo(at: mr.location, longestEffectiveRange: &itemRange)
                    guard let info = info else { return }
                    if info.itemIndex == 0, info.listType == markerType, let listBlock = listBlock, type == 0 || type == info.listType {
                        let levelRange = self.rangeOfListLevel(info.listLevel, at: mr.location)
                        listBlock(levelRange, info.listLevel, info.listType, mstop)
                    }
                    if info.listType == markerType { mstop.pointee = true }
                }
                if let info = info, let listItemBlock = listItemBlock, type == 0 || type == info.listType {
                    listItemBlock(itemRange, markerRange, info, itemStop)
                }
                if itemStop.pointee.boolValue { stop.pointee = true }
            }
        }
    }

    func enumerateUnorderedList(in r: NSRange, options o: NSAttributedString.EnumerationOptions,
                                listBlock: ((NSRange, Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void)?,
                                listItemBlock: ((NSRange, NSRange, PMKListInfo, UnsafeMutablePointer<ObjCBool>) -> Void)?) {
        enumerateListType(1, in: r, options: o, listBlock: listBlock, listItemBlock: listItemBlock)
    }

    func enumerateOrderedList(in r: NSRange, options o: NSAttributedString.EnumerationOptions,
                              listBlock: ((NSRange, Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void)?,
                              listItemBlock: ((NSRange, NSRange, PMKListInfo, UnsafeMutablePointer<ObjCBool>) -> Void)?) {
        enumerateListType(2, in: r, options: o, listBlock: listBlock, listItemBlock: listItemBlock)
    }

    func extendRangeToFullyContainListItems(_ range: NSRange) -> NSRange {
        var out = range
        let a = rangeOfListItem(at: range.location)
        let b = rangeOfListItem(at: max(0, NSMaxRange(range) - 1))
        if a.location != NSNotFound { out = NSUnionRange(a, out) }
        if b.location != NSNotFound { out = NSUnionRange(b, out) }
        return out
    }

    func extendRangeToFullyContainLists(_ range: NSRange) -> NSRange {
        var out = range
        let a = rangeOfListLevel(0, at: range.location)
        let b = rangeOfListLevel(0, at: max(0, NSMaxRange(range) - 1))
        if a.location != NSNotFound { out = NSUnionRange(a, out) }
        if b.location != NSNotFound { out = NSUnionRange(b, out) }
        return out
    }

    // MARK: - PMKBlockquotes

    func blockquoteItemInfo(at index: Int, longestEffectiveRange: UnsafeMutablePointer<NSRange>? = nil) -> PMKListInfo? {
        guard index < length else { return nil }
        let info = attribute(.pmkBlockquoteItem, at: index, effectiveRange: nil) as? PMKListInfo
        longestEffectiveRange?.pointee = rangeOfBlockquoteItem(at: index)
        return info
    }

    func rangeOfBlockquoteItem(at index: Int) -> NSRange { rangeOfBlockquoteItem(at: index, markerRange: nil) }

    /// The item plus following deeper items.
    func rangeOfBlockquoteItem(at index: Int, markerRange: UnsafeMutablePointer<NSRange>?) -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: 0)
        guard index < length else { return notFound }
        var r = NSRange()
        guard let info = attribute(.pmkBlockquoteItem, at: index, longestEffectiveRange: &r, in: NSRange(location: 0, length: length)) as? PMKListInfo else {
            markerRange?.pointee = notFound
            return notFound
        }
        let level = info.listLevel
        enumerateAttribute(.pmkBlockquoteItem, in: NSRange(location: NSMaxRange(r), length: length - NSMaxRange(r)), options: []) { v, run, stop in
            guard let next = v as? PMKListInfo, next.listLevel > level else { stop.pointee = true; return }
            r = NSUnionRange(r, run)
        }
        if let mr = markerRange {
            mr.pointee = notFound
            enumerateAttribute(.pmkBlockquoteMarker, in: r, options: []) { v, run, stop in
                if v != nil { mr.pointee = run; stop.pointee = true }
            }
        }
        return r
    }

    func rangeOfBlockquoteLevel(_ level: Int, at index: Int) -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: 0)
        guard index < length else { return notFound }
        var result = notFound
        var previous: PMKListInfo? = nil
        var cursor = index
        var itemRange = NSRange()
        while cursor >= 0 {
            guard let info = blockquoteItemInfo(at: cursor, longestEffectiveRange: &itemRange), info.listLevel >= level else {
                if previous == nil { return result }
                break
            }
            if let p = previous, p.relativeListLevel == info.relativeListLevel, p.listLevel == level, p.itemIndex == 0 { break }
            result = result.location == NSNotFound ? itemRange : NSUnionRange(result, itemRange)
            cursor = Int(result.location) - 1
            previous = info
        }
        guard let p = previous, p.listLevel <= level, result.location != NSNotFound else { return result }
        let ns = string as NSString
        while true {
            let para = ns.paragraphRange(for: result)
            guard NSMaxRange(para) < ns.length else { return result }
            let nextPara = ns.paragraphRange(for: NSRange(location: NSMaxRange(para), length: 1))
            guard blockquoteItemInfo(at: nextPara.location) != nil else { return result }
            var r = NSRange()
            guard let last = blockquoteItemInfo(at: NSMaxRange(nextPara) - 1, longestEffectiveRange: &r), last.listLevel >= level else { return result }
            result = NSUnionRange(result, r)
        }
    }

    func enumerateBlockquote(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                             listBlock: ((NSRange, Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void)?,
                             listItemBlock: ((NSRange, NSRange, PMKListInfo, UnsafeMutablePointer<ObjCBool>) -> Void)?) {
        enumerateAttribute(.pmkBlockquote, in: range, options: options) { quoteValue, quoteRun, stop in
            guard quoteValue != nil else { return }
            self.enumerateAttribute(.pmkBlockquoteItem, in: quoteRun, options: options) { itemValue, itemRun, itemStop in
                guard itemValue != nil else { return }
                var markerRange = NSRange(location: NSNotFound, length: 0)
                var itemRange = itemRun
                var info: PMKListInfo? = nil
                self.enumerateAttribute(.pmkBlockquoteMarker, in: itemRun, options: []) { mv, mr, mstop in
                    guard let markerType = (mv as? NSNumber)?.intValue else { return }
                    markerRange = mr
                    info = self.blockquoteItemInfo(at: mr.location, longestEffectiveRange: &itemRange)
                    guard let info = info else { return }
                    if info.itemIndex == 0, info.listType == markerType, let listBlock = listBlock {
                        listBlock(self.rangeOfBlockquoteLevel(info.listLevel, at: mr.location), info.listLevel, info.listType, mstop)
                    }
                    if info.listType == markerType { mstop.pointee = true }
                }
                if let info = info { listItemBlock?(itemRange, markerRange, info, itemStop) }
                if itemStop.pointee.boolValue { stop.pointee = true }
            }
        }
    }

    /// Block(calloutRange, markerRange, titleRange, type, stop);
    /// a missing title has location NSNotFound.
    func enumerateCallout(in range: NSRange, options: NSAttributedString.EnumerationOptions,
                          using block: (NSRange, NSRange, NSRange, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerateAttribute(.pmkCallout, in: range, options: options) { v, r, stop in
            guard let type = (v as? NSNumber)?.intValue else { return }
            var marker = NSRange(location: NSNotFound, length: 0), title = NSRange(location: NSNotFound, length: 0)
            self.enumerateAttribute(.pmkCalloutMarker, in: r, options: []) { mv, mr, ms in if mv != nil { marker = mr; ms.pointee = true } }
            self.enumerateAttribute(.pmkCalloutTitle, in: r, options: []) { tv, tr, ts in if tv != nil { title = tr; ts.pointee = true } }
            block(r, marker, title, type, stop)
        }
    }

    func extendRangeToFullyContainBlockquote(_ range: NSRange) -> NSRange {
        guard length != 0 else { return range }
        var out = range
        let a = longestRange(forAttribute: .pmkBlockquote, at: range.location)
        if a.location != NSNotFound { out = NSUnionRange(out, a) }
        let b = longestRange(forAttribute: .pmkBlockquote, at: max(0, NSMaxRange(range) - 1))
        if b.location != NSNotFound { out = NSUnionRange(out, b) }
        return out
    }

    /// The innermost of the two.
    func listOrBlockquoteItemInfo(at index: Int, itemRange: UnsafeMutablePointer<NSRange>? = nil, markerRange: UnsafeMutablePointer<NSRange>? = nil) -> PMKListInfo? {
        var listMarker = NSRange(), quoteMarker = NSRange()
        let list = rangeOfListItem(at: index, markerRange: &listMarker)
        let quote = rangeOfBlockquoteItem(at: index, markerRange: &quoteMarker)
        var info: PMKListInfo? = nil
        var item = NSRange(location: NSNotFound, length: 0)
        var marker = NSRange(location: NSNotFound, length: 0)
        if listMarker.location == NSNotFound {
            if quoteMarker.location != NSNotFound {
                info = blockquoteItemInfo(at: index); item = quote; marker = quoteMarker
            }
        } else if quoteMarker.location != NSNotFound && listMarker.location <= quoteMarker.location {
            info = blockquoteItemInfo(at: index); item = quote; marker = quoteMarker
        } else {
            info = listItemInfo(at: index); item = list; marker = listMarker
        }
        itemRange?.pointee = item
        markerRange?.pointee = marker
        return info
    }

    /// The paragraph holds only its marker.
    func isListOrBlockquoteParagraphEmpty(at index: Int) -> Bool {
        let ns = string as NSString
        guard index <= ns.length else { return true }
        let para = ns.paragraphRange(for: NSRange(location: index, length: 0))
        guard para.length != 0 else { return true }
        let lastChar = ns.character(at: NSMaxRange(para) - 1)
        if para.length == 1 && lastChar == 0x0A { return true }
        let offset = lastChar == 0x0A ? -2 : -1
        let i = NSMaxRange(para) + offset
        guard i >= 0 else { return true }
        return hasListMarker(at: i) || hasBlockquoteMarker(at: i)
    }

    func calloutNestLevel(at index: Int) -> Int {
        let ns = string as NSString
        guard index < ns.length else { return 0 }
        var level = 0
        enumerateAttribute(.pmkBlockquoteItem, in: ns.paragraphRange(for: NSRange(location: index, length: 1)), options: []) { v, _, _ in
            if let info = v as? PMKListInfo, info.isCallout { level += 1 }
        }
        return level
    }
}
