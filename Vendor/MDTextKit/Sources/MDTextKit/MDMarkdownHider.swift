import AppKit
import PolarMark

/// `MDMarkdownHider`. Ported 1:1 from the decompilation. Markers are hidden by
/// stashing their font/kern under `MDOriginalAttributes` and applying a 0.01pt
/// placeholder font with zero kerning; attachments that stand for markers are
/// hidden through `SFTextAttachment.setHidden`. Showing restores the stash.
@MainActor public final class MDMarkdownHider: NSObject {

    /// `+placeholderFont` = `[NSFont systemFontOfSize:0.01]`
    public static let placeholderFont: NSFont = NSFont.systemFont(ofSize: 0.01)

    /// `attributesToHide` (22 keys, decompiled order).
    public static let attributesToHide: [NSAttributedString.Key] = [
        .pmkStrongMarker, .pmkEmphasisMarker, .pmkCodeMarker, .pmkMathSpanFormula, .pmkMathSpanMarker,
        .pmkMathBlockFormula, .pmkMathBlockMarker, .pmkFencedCodeLanguage, .pmkHighlighterMarker, .pmkLinkMarker,
        .pmkAutoLinkMarker, .pmkStrikethroughMarker, .pmkUnderlineMarker, .pmkFencedCodeMarker, .pmkFootNoteMarker,
        .pmkEscape, .pmkReferenceMarker, .pmkReferenceLabel, .pmkWikiLinkMarker, .pmkWikiLinkAliasSeparator,
        .pmkHashtagMarker, .mdMermaidCodeContent,
    ]

    /// `attributesToSearchForHiding` (20 keys) — constructs whose full extent decides visibility.
    public static let attributesToSearchForHiding: [NSAttributedString.Key] = [
        .pmkStrong, .pmkEmphasis, .pmkCode, .pmkMathSpan, .pmkMathBlock, .pmkHighlighter, .pmkLink, .pmkAutoLinkURL,
        .pmkAutoLinkEmail, .pmkStrikethrough, .pmkUnderline, .pmkFencedCode, .pmkFootNote, .pmkReference,
        .pmkReferenceDefinition, .pmkWikiLink, .pmkHeading, .pmkEscape, .pmkHardLinebreak, .pmkHashtag,
    ]

    public static let attributesPreventingHiding: [NSAttributedString.Key] = [.mdPreventMarkdownHiding, .mdSearchResultBackgroundColor]

    public override init() { super.init() }

    // MARK: Entry points

    public func showHideMarkdown(in textView: NSTextView, oldSelectionRange old: NSRange, newSelectionRange new: NSRange) {
        guard let storage = textView.textStorage else { return }
        let hideRanges = rangesToCheckForMarkdownHiding(for: old, in: storage)
        let showRange = rangeToCheckForMarkdownShowing(for: new, in: storage)
        storage.beginEditing()
        var changed = false
        for r in hideRanges { changed = hideMarkdown(in: r, in: storage) || changed }
        if showRange.location != NSNotFound { changed = showMarkdown(in: showRange, in: storage) || changed }
        storage.endEditing()
        if changed { textView.needsDisplay = true }
    }

    /// Returns YES when something changed.
    @discardableResult
    public func hideMarkdown(in range: NSRange, in s: NSMutableAttributedString) -> Bool {
        var changed = false
        let r = NSIntersectionRange(range, NSRange(location: 0, length: s.length))
        guard r.length > 0 else { return false }
        let placeholder = MDMarkdownHider.placeholderFont
        let ns = s.string as NSString
        s.enumerateAttributes(in: r, options: []) { attrs, runRange, _ in
            // ---- marker characters
            for key in MDMarkdownHider.attributesToHide where attrs[key] != nil {
                if MDMarkdownHider.attributesPreventingHiding.contains(where: { attrs[$0] != nil }) { break }
                var hr = runRange
                if key == .pmkFootNoteMarker || key == .pmkReferenceMarker {
                    if ns.character(at: NSMaxRange(hr) - 1) == 0x3A /* ':' */ { hr.length -= 1 }
                } else if key == .pmkReferenceLabel, (attrs[.pmkReferenceLabel] as? NSNumber)?.intValue == 2 {
                    break
                } else if key == .pmkWikiLinkAliasSeparator {
                    let wiki = s.longestRange(forAttribute: .pmkWikiLink, at: hr.location)
                    if wiki.location != NSNotFound, NSMaxRange(hr) < NSMaxRange(wiki) - 2 {
                        hr = NSRange(location: wiki.location, length: NSMaxRange(hr) - wiki.location)
                    }
                }
                if hr.length > 0 {
                    s.addTemporaryAttribute(.font, value: placeholder, in: hr)
                    s.addTemporaryAttribute(.kern, value: 0, in: hr)
                    changed = true
                }
                break
            }
            // ---- attachments standing for markers
            guard let att = attrs[.attachment] as? SFTextAttachment else { return }
            if MDMarkdownHider.attributesPreventingHiding.contains(where: { attrs[$0] != nil }) { return }
            if att.isATXHeader {
                var keepBounds = false
                if !s.isRangeInsideList(runRange) && !s.isRangeInsideBlockquote(runRange) {
                    keepBounds = (s.paragraphStyle(at: runRange.location)?.headIndent ?? 0) != 0
                }
                att.setHidden(true, keepBounds: keepBounds)
            } else if att.isHardLineBreak || att.isHighlighter || att.isInlineMathSpacer {
                att.isHidden = true
            } else if att.isBlockquote || att.isIndentSpace {
                let end = NSMaxRange(runRange)
                guard end < s.length, s.isRangeInsideBlockMath(NSRange(location: end, length: 1)) || s.isRangeInsideMermaid(NSRange(location: end, length: 1)) else { return }
                att.isHidden = true
            } else {
                return
            }
            att.updateAttachmentImage()
            // Add then remove a dummy attribute to force layout to notice the attachment change.
            s.addAttribute(.mdTMP, value: 1, range: runRange)
            s.removeAttribute(.mdTMP, range: runRange)
            changed = true
        }
        return changed
    }

    @discardableResult
    public func showMarkdown(in range: NSRange, in s: NSMutableAttributedString) -> Bool {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: s.length))
        guard r.length > 0 else { return false }
        var changed = s.removeTemporaryAttributes(in: r)
        s.enumerateAttribute(.attachment, in: r, options: []) { value, ar, _ in
            guard let att = value as? SFTextAttachment else { return }
            if att.isATXHeader || att.isHardLineBreak || att.isHighlighter || att.isInlineMathSpacer || att.isBlockquote || att.isIndentSpace {
                att.isHidden = false
                att.updateAttachmentImage()
                s.addAttribute(.mdTMP, value: 1, range: ar)
                s.removeAttribute(.mdTMP, range: ar)
                changed = true
            }
        }
        return changed
    }

    /// Deletes marker characters
    /// (used when exporting "plain" text).
    public func removeHidableMarkdown(in range: NSRange, in s: NSMutableAttributedString) {
        let ns = s.string as NSString
        s.enumerateAttributes(in: range, options: [.reverse]) { attrs, runRange, _ in
            for key in MDMarkdownHider.attributesToHide where attrs[key] != nil {
                if MDMarkdownHider.attributesPreventingHiding.contains(where: { attrs[$0] != nil }) { break }
                var hr = runRange
                if key == .pmkFootNoteMarker || key == .pmkReferenceMarker {
                    if ns.character(at: NSMaxRange(hr) - 1) == 0x3A { hr.length -= 1 }
                } else if key == .pmkReferenceLabel, (attrs[.pmkReferenceLabel] as? NSNumber)?.intValue == 2 {
                    break
                } else if key == .pmkFencedCodeMarker {
                    hr = ns.paragraphRange(for: hr)
                }
                s.replaceCharacters(in: hr, with: "")
                return
            }
            if let att = attrs[.attachment] as? NSTextAttachment,
               !MDMarkdownHider.attributesPreventingHiding.contains(where: { attrs[$0] != nil }),
               att.isATXHeader || att.isLink || att.isHardLineBreak {
                s.replaceCharacters(in: runRange, with: "")
            }
        }
    }

    // MARK: Range helpers

    public func rangeToCheckForMarkdownShowing(for range: NSRange, in s: NSAttributedString) -> NSRange {
        guard s.length != 0, range.location != NSNotFound else { return NSNotFoundRange }
        return extendedRange(for: normalizedRange(for: range, in: s), in: s)
    }

    /// The extended range minus
    /// the parts that must stay visible (search results, explicit prevention).
    public func rangesToCheckForMarkdownHiding(for range: NSRange, in s: NSAttributedString) -> [NSRange] {
        guard s.length != 0, range.location != NSNotFound else { return [] }
        let extended = extendedRange(for: normalizedRange(for: range, in: s), in: s)
        if extended.length == 0 { return [extended] }
        var preventing: [NSRange] = []
        s.enumerateAttributes(in: extended, options: []) { attrs, r, _ in
            if MDMarkdownHider.attributesPreventingHiding.contains(where: { attrs[$0] != nil }) {
                preventing.append(self.extendedRange(for: r, in: s))
            }
        }
        if preventing.isEmpty { return [extended] }
        return rangesRemoving(preventing, from: extended)
    }

    /// Merges overlapping/adjacent ranges, sorted.
    public func normalizedRanges(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for r in ranges {
            var merged = false
            for (i, existing) in result.enumerated() {
                let touches = (existing.location <= r.location && r.location <= NSMaxRange(existing))
                    || (existing.location <= NSMaxRange(r) && NSMaxRange(r) <= NSMaxRange(existing))
                if touches {
                    result[i] = NSUnionRange(existing, r)
                    merged = true
                    break
                }
            }
            if !merged { result.append(r) }
        }
        return result.sorted { $0.location < $1.location }
    }

    public func rangesRemoving(_ ranges: [NSRange], from range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var loc = range.location
        var len = range.length
        for r in normalizedRanges(ranges) {
            if r.location == loc {
                loc += r.length
                len -= r.length
            } else {
                out.append(NSRange(location: loc, length: r.location - loc))
                let newLoc = NSMaxRange(r)
                len = (loc + len) - newLoc
                loc = newLoc
            }
        }
        if len != 0 { out.append(NSRange(location: loc, length: len)) }
        return out
    }

    public func normalizedRange(for range: NSRange, in s: NSAttributedString) -> NSRange {
        if range.length == 0 && range.location == s.length { return range }
        return NSIntersectionRange(range, NSRange(location: 0, length: s.length))
    }

    /// Grows the range to the full extent of
    /// every construct touching its ends (except across a newline outside code/math), then to the
    /// paragraphs of enclosing math blocks and mermaid code.
    public func extendedRange(for range: NSRange, in s: NSAttributedString) -> NSRange {
        var result = range
        let ns = s.string as NSString
        let length = s.length
        for key in MDMarkdownHider.attributesToSearchForHiding {
            var i = result.location
            i -= (i == length ? 1 : 0)
            if i >= 0, i < length {
                let c = ns.character(at: i)
                if c != 0x0A || s.isRangeInsideCode(NSRange(location: i, length: 1)) || s.isRangeInsideMath(NSRange(location: i, length: 1)) {
                    let lr = s.longestRange(forAttribute: key, at: i)
                    if lr.location != NSNotFound { result = NSUnionRange(result, lr) }
                }
            }
            var j = NSMaxRange(result)
            j = j == 0 ? 0 : j - 1
            j -= (j == length ? 1 : 0)
            if j >= 0, j < length {
                let c = ns.character(at: j)
                if c != 0x0A || s.isRangeInsideCode(NSRange(location: j, length: 1)) || s.isRangeInsideMath(NSRange(location: j, length: 1)) {
                    let lr = s.longestRange(forAttribute: key, at: j)
                    if lr.location != NSNotFound { result = NSUnionRange(result, lr) }
                }
            }
        }
        let paragraph = ns.paragraphRange(for: NSIntersectionRange(result, NSRange(location: 0, length: length)))
        s.enumerateAttribute(.pmkMathBlock, in: paragraph, options: []) { value, r, stop in
            guard value != nil else { return }
            let lr = s.longestRange(forAttribute: .pmkMathBlock, at: r.location)
            result = NSUnionRange(result, ns.paragraphRange(for: lr))
            stop.pointee = true
        }
        s.enumerateAttribute(.mdMermaidCodeContent, in: paragraph, options: []) { value, r, stop in
            guard value != nil else { return }
            let lr = s.longestRange(forAttribute: .pmkFencedCode, at: r.location)
            if lr.location != NSNotFound {
                result = NSUnionRange(result, ns.paragraphRange(for: lr))
                stop.pointee = true
            }
        }
        return result
    }
}
