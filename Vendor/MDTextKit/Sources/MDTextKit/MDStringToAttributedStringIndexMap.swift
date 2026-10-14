import AppKit

/// `MDStringToAttributedStringIndexMap`. Maps indexes of the plain markdown
/// string to indexes of the attributed string in which SFTextAttachments replace
/// runs of markdown characters (one attachment character stands for N markdown
/// characters, and zero-length "spacer" attachments stand for none).
public final class MDStringToAttributedStringIndexMap: NSObject {
    /// `indexes[i]` = attributed-string range of markdown character `i` (built lazily).
    public private(set) var indexes: [NSRange] = []
    public private(set) weak var attributedString: NSAttributedString?

    public init(attributedString: NSAttributedString) {
        self.attributedString = attributedString
        super.init()
    }

    public override var description: String {
        super.description + indexes.map { " " + NSStringFromRange($0) }.joined()
    }

    // MARK: Enumeration primitives

    /// Calls `block(stringIndex, attributedIndex)` once per markdown character.
    public static func enumerateStringAndAttributedStringIndexes(in source: NSAttributedString,
                                                                 from start: (location: Int, markdownStart: Int)? = nil,
                                                                 using block: (Int, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let s = source.walkable
        // Counters as they stand just before `start`, so the walk continues exactly as from 0.
        var attrIndex = (start?.location ?? 0) - 1
        var stringIndex = (start?.markdownStart ?? 0) - 1
        let from = start?.location ?? 0
        s.enumerateAttribute(.attachment, in: NSRange(location: from, length: s.length - from), options: []) { value, r, stop in
            if value is SFTextAttachment {
                guard r.length != 0 else { return }
                for j in 0..<r.length {
                    let att = s.textAttachment(at: r.location + j) as? SFTextAttachment
                    attrIndex += 1
                    let textLength = ((att?.representedText ?? "") as NSString).length
                    if textLength == 0 {
                        let closing = s.hasClosingSpacer(at: r.location + j)
                        var reported = stringIndex >= 0 ? stringIndex + j : 0
                        if !closing { reported = stringIndex + 1 }
                        block(reported, attrIndex, stop)
                    } else {
                        for _ in 0..<textLength {
                            stringIndex += 1
                            block(stringIndex, attrIndex, stop)
                            if stop.pointee.boolValue { break }
                        }
                    }
                    if stop.pointee.boolValue { return }
                }
            } else {
                var remaining = r.length
                while remaining > 0 {
                    remaining -= 1
                    stringIndex += 1
                    attrIndex += 1
                    block(stringIndex, attrIndex, stop)
                    if stop.pointee.boolValue { return }
                }
            }
        }
    }

    /// Calls `block(stringIndex, 1, attributedRange)` once per markdown character.
    public static func enumerateStringAndAttributedStringRanges(in s: NSAttributedString,
                                                                using block: (Int, Int, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var lastString = -1
        var lastAttr = -1
        var stringRange = NSRange(location: 0, length: 0)
        var attrRange = NSRange(location: 0, length: 0)
        var stopped = false
        enumerateStringAndAttributedStringIndexes(in: s) { stringIndex, attrIndex, stop in
            if stringIndex != lastString {
                if attrIndex != lastAttr {
                    // both advanced: flush the pending run
                    if stringRange.length > 0 {
                        for k in 0..<stringRange.length {
                            block(stringRange.location + k, 1, attrRange, stop)
                            if stop.pointee.boolValue { break }
                        }
                    }
                    stringRange.location += stringRange.length
                    stringRange.length = 1
                    attrRange.location += attrRange.length
                    attrRange.length = 1
                    if stop.pointee.boolValue { stopped = true; return }
                    lastString = stringIndex
                    lastAttr = attrIndex
                    return
                }
                stringRange.length += 1
            }
            if attrIndex != lastAttr { attrRange.length += 1 }
            lastString = stringIndex
            lastAttr = attrIndex
        }
        if s.length != 0, !stopped, stringRange.length != 0 {
            var stop: ObjCBool = false
            for k in 0..<stringRange.length {
                block(stringRange.location + k, 1, attrRange, &stop)
                if stop.boolValue { break }
            }
        }
    }

    /// One-shot conversion
    /// without building the index table.
    public static func attributedStringRange(forStringRange range: NSRange, in s: NSAttributedString,
                                             from start: (location: Int, markdownStart: Int)? = nil) -> NSRange {
        if s.length == 0 && range.location != 0 { return NSNotFoundRange }
        if s.length == 0 && range.location == 0 && range.length == 0 { return NSRange(location: 0, length: 0) }
        guard range.location != NSNotFound else { return NSNotFoundRange }

        var resultLoc = NSNotFound
        var resultEnd = 0
        var sameAttrAsPrevious = false
        var lastAttrIndex = NSNotFound
        var lastStringIndex = NSNotFound
        enumerateStringAndAttributedStringIndexes(in: s, from: start) { stringIndex, attrIndex, stop in
            if stringIndex == range.location && resultLoc == NSNotFound { resultLoc = attrIndex }
            let end = range.location + range.length
            if end == 0 || stringIndex == end - 1 { resultEnd = attrIndex + 1 }
            sameAttrAsPrevious = lastAttrIndex == attrIndex
            lastAttrIndex = attrIndex
            lastStringIndex = stringIndex
            if stringIndex >= range.location + range.length { stop.pointee = true }
        }

        var start = resultLoc
        var loc = 0
        var len = 0
        func hashtagAdjust() {
            // A short (≤ 2 chars) hashtag icon attachment sits in front of the tag.
            if start != 0 && start != NSNotFound && start - 1 < s.length {
                let hr = s.longestRange(forAttribute: .pmkHashtag, at: start - 1)
                let h = (hr.location == NSNotFound || hr.length > 2) ? 0 : hr.length
                loc = start - h
                len = h + len
            } else {
                loc = 0
            }
        }
        if start == NSNotFound && range.length == 0 {
            if lastStringIndex != NSNotFound && lastStringIndex == range.location - 1 {
                start = lastAttrIndex + 1
            } else {
                start = NSNotFound
            }
            len = start == NSNotFound ? 0 : resultEnd &- start
            if !sameAttrAsPrevious { len = 0 }
            loc = 0
            if start != 0 && start != NSNotFound { hashtagAdjust() }
        } else if start != NSNotFound {
            len = resultEnd - start
            if range.length == 0 {
                if !sameAttrAsPrevious { len = 0 }
                loc = 0
                if start != 0 { hashtagAdjust() }
            } else if start != 0 {
                hashtagAdjust()
            } else {
                loc = 0
            }
        } else {
            return NSNotFoundRange
        }
        if loc + len < s.length, loc + len < s.length {
            let hr = s.longestRange(forAttribute: .pmkHashtag, at: loc + len)
            let h = (hr.location == NSNotFound || hr.length > 2) ? 0 : hr.length
            len += h
        }
        return NSRange(location: loc, length: max(0, len))
    }

    // MARK: Instance API

    public func buildRange(forStringRange range: NSRange) {
        guard indexes.isEmpty, let s = attributedString else { return }
        MDStringToAttributedStringIndexMap.enumerateStringAndAttributedStringRanges(in: s) { _, _, attrRange, _ in
            self.indexes.append(attrRange)
        }
    }

    public func attributedStringRange(forStringRange range: NSRange) -> NSRange {
        buildRange(forStringRange: range)
        let count = indexes.count
        if count == 1 && range.location + range.length == 0 { return indexes[0] }
        if range.location == 0 && range.length == 0 { return NSRange(location: 0, length: 0) }
        guard range.location <= count, range.location &+ range.length &- 1 <= count else { return NSNotFoundRange }
        if range.location == count {
            let last = indexes.last ?? NSRange(location: 0, length: 0)
            return NSRange(location: NSMaxRange(last), length: 0)
        }
        if range.length == 0 {
            let a = indexes[range.location]
            let b = range.location > 0 ? indexes[range.location - 1] : NSRange(location: NSNotFound, length: 0)
            if a.location != b.location || a.length != b.length { return NSRange(location: a.location, length: 0) }
        }
        let endIndex = min(count - 1, range.location &+ range.length &- 1)
        return NSUnionRange(indexes[range.location], indexes[max(0, endIndex)])
    }
}
