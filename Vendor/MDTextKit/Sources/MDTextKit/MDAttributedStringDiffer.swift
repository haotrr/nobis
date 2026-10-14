import AppKit
import PolarMark

/// `MDAttributedStringDiffer`. Finds the sub-range of a freshly styled string
/// that differs from what the text storage already holds, so only that part is written
/// back (and view-backed attachments survive restyling).
@MainActor public final class MDAttributedStringDiffer: NSObject {
    public var ignoreAttachments = false
    public var ignoreColorInCodeBlocks = false

    /// Returns the differing range of `inner` (NSNotFound when equal); `secondDiffRange` receives
    /// the matching range of `outer` (which starts as `range`).
    public func diffRange(between inner: NSAttributedString, and outer: NSAttributedString, in range: NSRange, secondDiffRange: inout NSRange) -> NSRange {
        var remaining = inner.length
        secondDiffRange = range
        var prefix = 0
        let innerString = inner.string as NSString
        let outerString = outer.string as NSString
        if inner.length != 0 {
            while prefix < inner.length {
                let o = range.location + prefix
                if o >= NSMaxRange(range) || o >= outer.length { break }
                if innerString.character(at: prefix) != outerString.character(at: o) { break }
                if !areAttributes(inner.attributes(at: prefix, effectiveRange: nil), equalTo: outer.attributes(at: o, effectiveRange: nil)) { break }
                remaining -= 1
                prefix += 1
                secondDiffRange.length -= 1
                secondDiffRange.location += 1
            }
        }
        if remaining == 0 {
            if prefix < outer.length { return NSRange(location: prefix, length: 0) }
            secondDiffRange.location = NSNotFound
            return NSNotFoundRange
        }
        var suffix = 0
        var outerEnd = NSMaxRange(range)
        if inner.length > 1 {
            while suffix + 1 < inner.length {
                let i = inner.length - 1 - suffix
                if i <= prefix || outerEnd <= secondDiffRange.location { break }
                outerEnd -= 1
                guard outerEnd < outer.length else { break }
                if innerString.character(at: i) != outerString.character(at: outerEnd) { break }
                if !areAttributes(inner.attributes(at: i, effectiveRange: nil), equalTo: outer.attributes(at: outerEnd, effectiveRange: nil)) { break }
                remaining -= 1
                secondDiffRange.length -= 1
                suffix += 1
            }
        }
        return NSRange(location: prefix, length: remaining)
    }

    public func areAttributes(_ a: [NSAttributedString.Key: Any], equalTo b: [NSAttributedString.Key: Any]) -> Bool {
        var a = a, b = b
        if a[.mdOriginalAttributes] != nil || b[.mdOriginalAttributes] != nil {
            // Compare the real (stashed) attributes, not the hider's placeholder.
            if let orig = a[.mdOriginalAttributes] as? [NSAttributedString.Key: Any] { for (k, v) in orig { a[k] = v } }
            if let orig = b[.mdOriginalAttributes] as? [NSAttributedString.Key: Any] { for (k, v) in orig { b[k] = v } }
        }
        if NSDictionary(dictionary: a).isEqual(to: b) { return true }
        if ignoreAttachments, let aa = a[.attachment] as? SFTextAttachment, let ba = b[.attachment] as? SFTextAttachment {
            var a2 = a, b2 = b
            a2[.attachment] = nil; b2[.attachment] = nil
            a2[.font] = nil; b2[.font] = nil
            if NSDictionary(dictionary: a2).isEqual(to: b2), isAttachment(aa, equalTo: ba) { return true }
        }
        if ignoreColorInCodeBlocks {
            let noAttachments = a[.attachment] == nil && b[.attachment] == nil
            var codeLike = false
            if noAttachments, a[.pmkFencedCode] != nil, b[.pmkFencedCode] != nil,
               a[.pmkFencedCodeMarker] == nil, b[.pmkFencedCodeMarker] == nil,
               a[.pmkFencedCodeLanguage] == nil, b[.pmkFencedCodeLanguage] == nil {
                codeLike = true
            } else if (a[.pmkHTMLInline] != nil && b[.pmkHTMLInline] != nil) || (a[.pmkHTMLBlock] != nil && b[.pmkHTMLBlock] != nil) {
                codeLike = true
            } else if a[.pmkMathSpan] != nil, b[.pmkMathSpan] != nil, a[.attachment] == nil {
                codeLike = true
            }
            if codeLike, let fa = a[.font] as? NSFont, let fb = b[.font] as? NSFont, fa == fb {
                if a[.mdSyntaxHighlightLanguage] != nil || b[.mdSyntaxHighlightLanguage] != nil {
                    return (a[.mdSyntaxHighlightLanguage] as? String) == (b[.mdSyntaxHighlightLanguage] as? String)
                }
                return true
            }
        }
        return false
    }

    public func isAttachment(_ a: SFTextAttachment, equalTo b: SFTextAttachment) -> Bool {
        if a.isViewAttachment && b.isViewAttachment { return a.representedText == b.representedText }
        if a.representedText == b.representedText { return a.attachmentBaselineOffset == b.attachmentBaselineOffset }
        return false
    }

    /// Writes the styled
    /// attributes into the storage, keeping an existing equal view attachment instance alive.
    public func setAttributesPreservingViewAttachments(_ attrs: [NSAttributedString.Key: Any], range: NSRange, in s: NSMutableAttributedString) {
        if let new = attrs[.attachment] as? SFTextAttachmentView, range.location < s.length,
           let existing = s.attribute(.attachment, at: range.location, effectiveRange: nil) as? SFTextAttachmentView,
           isAttachment(new, equalTo: existing) {
            var kept = attrs
            kept[.attachment] = existing
            s.setAttributes(kept, range: range)
            return
        }
        if attrs[.mdAsyncStylingIdentifier] == nil {
            s.setAttributes(attrs, range: range)
        } else {
            // Keep the asynchronously computed syntax colors that are already in place.
            var colors: [(NSRange, NSColor)] = []
            s.enumerateAttribute(.foregroundColor, in: range, options: []) { value, r, _ in
                if let c = value as? NSColor { colors.append((r, c)) }
            }
            s.setAttributes(attrs, range: range)
            for (r, c) in colors { s.addAttribute(.foregroundColor, value: c, range: r) }
        }
    }
}
