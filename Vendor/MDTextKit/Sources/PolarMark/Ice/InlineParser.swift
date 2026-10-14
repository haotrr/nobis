import Foundation

/// `Ice::InlineParser` + `Ice::InlineRuleMap`.
/// Produces flat inline child nodes (strong, emphasis, code, link, ...) for a
/// block. Nesting is expressed by overlapping ranges, which is all the
/// attributed-string annotation needs.
struct InlineParser {
    let text: [UInt16]
    let rules: RuleConfig

    private struct Delim {
        let char: UInt16
        var start: Int
        var length: Int
        let canOpen: Bool
        let canClose: Bool
        var active = true
    }

    func parseInlines(in range: NSRange, into node: PMKASTNode, excluding: [NSRange] = []) {
        guard range.length > 0 else { return }
        var spans: [PMKASTNode] = []
        let start = range.location
        let end = NSMaxRange(range)
        let excluded = excluding.sorted { $0.location < $1.location }

        func excludedRangeContaining(_ i: Int) -> NSRange? {
            for r in excluded where i >= r.location && i < NSMaxRange(r) { return r }
            return nil
        }
        /// Character at `i`, treating out-of-range and excluded positions as whitespace (nil).
        func ch(_ i: Int) -> UInt16? {
            guard i >= start, i < end, excludedRangeContaining(i) == nil else { return nil }
            return text[i]
        }

        var delims: [Delim] = []
        var i = start
        while i < end {
            if let ex = excludedRangeContaining(i) { i = NSMaxRange(ex); continue }
            let c = text[i]

            // Hard line break: two+ spaces before newline
            if c == CU.newline && rules.hardLineBreaks && i >= start + 2 && text[i - 1] == CU.space && text[i - 2] == CU.space {
                var s = i - 2
                while s > start && text[s - 1] == CU.space { s -= 1 }
                let n = PMKASTNode(type: .hardLineBreak, range: NSRange(location: s, length: i - s + 1))
                n.markerRanges = [n.range]
                spans.append(n)
                i += 1
                continue
            }

            // Backslash escape
            if c == CU.backslash && rules.escapes, let next = ch(i + 1), CU.isPunctuation(next) {
                let n = PMKASTNode(type: .escape, range: NSRange(location: i, length: 2))
                n.markerRanges = [NSRange(location: i, length: 1)]
                n.contentRange = NSRange(location: i + 1, length: 1)
                spans.append(n)
                i += 2
                continue
            }

            // Code span
            if c == CU.backtick && rules.code {
                var j = i
                while j < end && text[j] == CU.backtick { j += 1 }
                let runLen = j - i
                var k = j
                var found = -1
                while k < end {
                    if text[k] == CU.backtick {
                        var m = k
                        while m < end && text[m] == CU.backtick { m += 1 }
                        if m - k == runLen { found = k; break }
                        k = m
                    } else { k += 1 }
                }
                if found >= 0 {
                    let n = PMKASTNode(type: .code, range: NSRange(location: i, length: found + runLen - i))
                    n.markerRanges = [NSRange(location: i, length: runLen), NSRange(location: found, length: runLen)]
                    n.contentRange = NSRange(location: j, length: found - j)
                    spans.append(n)
                    i = found + runLen
                } else {
                    i = j
                }
                continue
            }

            // Image / link
            if c == CU.bang && rules.images, ch(i + 1) == CU.lbracket, let n = parseLink(at: i + 1, bangAt: i, end: end, ch: ch) {
                spans.append(n); i = NSMaxRange(n.range); continue
            }
            if c == CU.lbracket && rules.links, let n = parseLink(at: i, bangAt: nil, end: end, ch: ch) {
                spans.append(n); i = NSMaxRange(n.range); continue
            }

            // Hashtag: `#tag`, `#tag/sub`, must be preceded by whitespace/start and followed by a word char
            if c == CU.hash && rules.hashtags, CU.isWhitespace(ch(i - 1)), let next = ch(i + 1), CU.isAlphaNum(next) || next == CU.underscore {
                var j = i + 1
                while let cj = ch(j), !CU.isWhitespace(cj), cj != CU.hash { j += 1 }
                // strip trailing punctuation like "," or "."
                while j > i + 1, let cj = ch(j - 1), CU.isPunctuation(cj), cj != CU.slash, cj != CU.underscore { j -= 1 }
                if j > i + 1 {
                    let n = PMKASTNode(type: .hashtag, range: NSRange(location: i, length: j - i))
                    n.markerRanges = [NSRange(location: i, length: 1)]
                    n.contentRange = NSRange(location: i + 1, length: j - i - 1)
                    n.label = String(utf16CodeUnits: Array(text[(i + 1)..<j]), count: j - i - 1)
                    spans.append(n)
                    i = j
                    continue
                }
            }

            // Autolink: http:// https:// www.
            if rules.autolinks, (c == 0x68 /* h */ || c == 0x77 /* w */), !CU.isAlphaNum(ch(i - 1) ?? CU.space), let n = parseAutolink(at: i, end: end, ch: ch) {
                spans.append(n); i = NSMaxRange(n.range); continue
            }

            // Emphasis-style delimiters
            if c == CU.star || c == CU.underscore || c == CU.tilde || c == CU.equal {
                var j = i
                while j < end && text[j] == c { j += 1 }
                let len = j - i
                let enabled: Bool
                switch c {
                case CU.star, CU.underscore: enabled = rules.strong || rules.emphasis
                case CU.tilde: enabled = rules.strikethrough || rules.underline
                default: enabled = rules.highlighter && len >= 2
                }
                if enabled {
                    let prev = ch(i - 1)
                    let next = ch(j)
                    let leftFlanking = !CU.isWhitespace(next) && (!CU.isPunctuation(next) || CU.isWhitespace(prev) || CU.isPunctuation(prev))
                    let rightFlanking = !CU.isWhitespace(prev) && (!CU.isPunctuation(prev) || CU.isWhitespace(next) || CU.isPunctuation(next))
                    var canOpen = leftFlanking
                    var canClose = rightFlanking
                    if c == CU.underscore {
                        canOpen = leftFlanking && (!rightFlanking || CU.isPunctuation(prev))
                        canClose = rightFlanking && (!leftFlanking || CU.isPunctuation(next))
                    }
                    delims.append(Delim(char: c, start: i, length: len, canOpen: canOpen, canClose: canClose))
                }
                i = j
                continue
            }

            i += 1
        }

        spans.append(contentsOf: processDelimiters(&delims))
        spans.sort { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.range.length > $1.range.length) }
        for s in spans { node.add(s) }
    }

    // MARK: - Delimiter processing (CommonMark "process emphasis", simplified)

    private func processDelimiters(_ delims: inout [Delim]) -> [PMKASTNode] {
        var out: [PMKASTNode] = []
        var ci = 0
        while ci < delims.count {
            let closer = delims[ci]
            guard closer.active, closer.canClose, closer.length > 0 else { ci += 1; continue }
            var oi = ci - 1
            var matched = false
            while oi >= 0 {
                let opener = delims[oi]
                if opener.active && opener.canOpen && opener.char == closer.char && opener.length > 0 {
                    // closer must be able to close given lengths (highlighter needs 2 on both sides)
                    if closer.char == CU.equal && (opener.length < 2 || closer.length < 2) { oi -= 1; continue }
                    // "multiple of 3" rule for * and _
                    if (closer.char == CU.star || closer.char == CU.underscore), (opener.canClose || closer.canOpen),
                       (opener.length + closer.length) % 3 == 0, !(opener.length % 3 == 0 && closer.length % 3 == 0) {
                        oi -= 1; continue
                    }
                    matched = true
                    break
                }
                oi -= 1
            }
            if !matched {
                if !closer.canOpen { delims[ci].active = false }
                ci += 1
                continue
            }

            var opener = delims[oi]
            var closerVar = delims[ci]
            let use: Int
            let type: PMKNodeType
            switch closer.char {
            case CU.star, CU.underscore:
                let strongOK = rules.strong && opener.length >= 2 && closerVar.length >= 2
                use = strongOK ? 2 : 1
                type = strongOK ? .strong : .emphasis
                if !strongOK && !rules.emphasis { delims[ci].active = false; ci += 1; continue }
            case CU.tilde:
                let strikeOK = rules.strikethrough && opener.length >= 2 && closerVar.length >= 2
                use = strikeOK ? 2 : 1
                type = strikeOK ? .strikethrough : .underline
                if !strikeOK && !rules.underline { delims[ci].active = false; ci += 1; continue }
            default:
                use = 2
                type = .highlighter
            }

            let openMarker = NSRange(location: opener.start + opener.length - use, length: use)
            let closeMarker = NSRange(location: closerVar.start, length: use)
            let n = PMKASTNode(type: type, range: NSRange(location: openMarker.location, length: NSMaxRange(closeMarker) - openMarker.location))
            n.markerRanges = [openMarker, closeMarker]
            n.contentRange = NSRange(location: NSMaxRange(openMarker), length: closeMarker.location - NSMaxRange(openMarker))
            out.append(n)

            // deactivate delimiters between opener and closer
            if oi + 1 < ci { for k in (oi + 1)..<ci { delims[k].active = false } }
            opener.length -= use
            if opener.length == 0 { opener.active = false }
            delims[oi] = opener
            closerVar.length -= use
            closerVar.start += use
            if closerVar.length == 0 { closerVar.active = false }
            delims[ci] = closerVar
            if closerVar.length == 0 { ci += 1 }
        }
        return out
    }

    // MARK: - Links

    /// `[label](url "title")` or `![label](url)`. Returns nil if not well-formed.
    private func parseLink(at bracket: Int, bangAt: Int?, end: Int, ch: (Int) -> UInt16?) -> PMKASTNode? {
        var depth = 0
        var j = bracket
        var closeBracket = -1
        while j < end, let c = ch(j) ?? (j < end ? Optional(text[j]) : nil) {
            if c == CU.backslash { j += 2; continue }
            if c == CU.newline { break }
            if c == CU.lbracket { depth += 1 }
            if c == CU.rbracket { depth -= 1; if depth == 0 { closeBracket = j; break } }
            j += 1
        }
        guard closeBracket > 0, ch(closeBracket + 1) == CU.lparen else { return nil }
        var k = closeBracket + 2
        var parenDepth = 1
        while k < end {
            guard let c = ch(k) else { break }
            if c == CU.backslash { k += 2; continue }
            if c == CU.newline { return nil }
            if c == CU.lparen { parenDepth += 1 }
            if c == CU.rparen { parenDepth -= 1; if parenDepth == 0 { break } }
            k += 1
        }
        guard k < end, ch(k) == CU.rparen else { return nil }
        let startIndex = bangAt ?? bracket
        let n = PMKASTNode(type: bangAt == nil ? .link : .image, range: NSRange(location: startIndex, length: k + 1 - startIndex))
        n.contentRange = NSRange(location: bracket + 1, length: closeBracket - bracket - 1)
        // destination: up to first whitespace inside the parens (title ignored but kept in marker)
        var urlStart = closeBracket + 2
        while urlStart < k && CU.isSpaceOrTab(text[urlStart]) { urlStart += 1 }
        var urlEnd = urlStart
        while urlEnd < k && !CU.isWhitespace(text[urlEnd]) { urlEnd += 1 }
        n.url = String(utf16CodeUnits: Array(text[urlStart..<urlEnd]), count: urlEnd - urlStart)
        n.label = String(utf16CodeUnits: Array(text[(bracket + 1)..<closeBracket]), count: closeBracket - bracket - 1)
        n.markerRanges = [
            NSRange(location: startIndex, length: bracket + 1 - startIndex),            // "[" or "!["
            NSRange(location: closeBracket, length: k + 1 - closeBracket),             // "](url)"
        ]
        if bangAt == nil, n.contentRange.length > 0 {
            parseInlines(in: n.contentRange, into: n)
        }
        return n
    }

    private func parseAutolink(at i: Int, end: Int, ch: (Int) -> UInt16?) -> PMKASTNode? {
        let candidates: [[UInt16]] = [Array("https://".utf16), Array("http://".utf16), Array("www.".utf16)]
        var prefixLen = 0
        for p in candidates {
            var ok = true
            for (off, cu) in p.enumerated() { if ch(i + off) != cu { ok = false; break } }
            if ok { prefixLen = p.count; break }
        }
        guard prefixLen > 0 else { return nil }
        var j = i + prefixLen
        while let c = ch(j), !CU.isWhitespace(c), c != 0x3C, c != 0x3E { j += 1 } // < >
        // trailing punctuation is not part of the URL
        while j > i + prefixLen, let c = ch(j - 1), [CU.dot, 0x2C, 0x3B, CU.colon, CU.bang, 0x3F, CU.rparen, 0x27, 0x22].contains(c) {
            if c == CU.rparen {
                // keep balanced parens
                let slice = text[i..<j]
                let opens = slice.filter { $0 == CU.lparen }.count
                let closes = slice.filter { $0 == CU.rparen }.count
                if closes <= opens { break }
            }
            j -= 1
        }
        guard j > i + prefixLen else { return nil }
        let n = PMKASTNode(type: .autolink, range: NSRange(location: i, length: j - i))
        n.contentRange = n.range
        n.url = String(utf16CodeUnits: Array(text[i..<j]), count: j - i)
        return n
    }
}
