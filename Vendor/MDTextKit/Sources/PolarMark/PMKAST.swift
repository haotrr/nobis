import Foundation

/// `PMKAST`. Owns the markdown text, the parse tree, and produces the
/// annotated string. `replaceRange(_:withMarkdown:)` is incremental in the
/// sense `Ice::ReparseRanges` is: the text is re-parsed, and the range
/// of blocks whose structure actually changed is reported so MDTextKit only
/// re-styles that region.
public final class PMKAST {
    public private(set) var utf16: [UInt16]
    public private(set) var rootNode: PMKASTNode
    public private(set) var currentReparsedRange: NSRange
    public var rules: RuleConfig { didSet { if rules != oldValue { reparseAll() } } }
    private var annotatedCache: NSAttributedString?
    private let lock = NSLock()

    public static func fromMarkdown(_ markdown: String) -> PMKAST { PMKAST(markdown: markdown) }

    public init(markdown: String, rules: RuleConfig = .standard) {
        self.utf16 = Array(markdown.utf16)
        self.rules = rules
        self.rootNode = BlockParser(text: utf16, rules: rules).parse()
        self.currentReparsedRange = NSRange(location: 0, length: utf16.count)
    }

    /// Set by `MDAttributedStringRenderer.setStyleInlinesOnly:`.
    public var parseInlinesOnly = false

    public var markdown: String { String(utf16CodeUnits: utf16, count: utf16.count) }
    public var markdownLength: Int { utf16.count }

    public func markdown(for node: PMKASTNode) -> String { substring(node.range) }

    public func substring(_ range: NSRange) -> String {
        let r = clamp(range)
        return String(utf16CodeUnits: Array(utf16[r.location..<NSMaxRange(r)]), count: r.length)
    }

    func clamp(_ r: NSRange) -> NSRange {
        let loc = max(0, min(r.location, utf16.count))
        let end = max(loc, min(NSMaxRange(r), utf16.count))
        return NSRange(location: loc, length: end - loc)
    }

    // MARK: - Editing

    public func replaceAll(withMarkdown markdown: String) {
        utf16 = Array(markdown.utf16)
        reparseAll()
    }

    /// Empties the document.
    public func reset() { replaceAll(withMarkdown: "") }

    /// Percent-escapes a link destination the way the
    /// parser accepts it (spaces and non-URL characters), leaving existing escapes alone.
    public static func percentEscapedURL(_ string: String) -> String {
        if string.removingPercentEncoding != string { return string }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func reparseAll() {
        rootNode = BlockParser(text: utf16, rules: rules).parse()
        currentReparsedRange = NSRange(location: 0, length: utf16.count)
        annotatedCache = nil
    }

    /// Replaces `range` with `markdown` and re-parses the blocks the edit can reach: from the block
    /// before the one holding it, forward until a parsed block matches an old block again. Returns the
    /// range (in the new text) that must be re-styled.
    @discardableResult
    public func replaceRange(_ range: NSRange, withMarkdown markdown: String) -> NSRange {
        let r = clamp(range)
        let insert = Array(markdown.utf16)
        let oldBlocks = rootNode.children
        utf16.replaceSubrange(r.location..<NSMaxRange(r), with: insert)
        lock.withLock { annotatedCache = nil }
        let delta = insert.count - r.length
        let editEnd = r.location + insert.count

        guard !oldBlocks.isEmpty else {
            rootNode = BlockParser(text: utf16, rules: rules).parse()
            currentReparsedRange = NSRange(location: 0, length: utf16.count)
            return currentReparsedRange
        }
        // An edit can join its block to the previous one, so the window opens one block early.
        var startIndex = oldBlocks.firstIndex { NSMaxRange($0.range) > r.location } ?? oldBlocks.count - 1
        startIndex = max(0, startIndex - 1)
        let windowStart = oldBlocks[startIndex].range.location

        // Old blocks after the edit, by where they end once shifted: the parse stops at the first match.
        var candidates: [Int: Int] = [:]
        for (i, block) in oldBlocks.enumerated() where block.range.location >= NSMaxRange(r) {
            candidates[NSMaxRange(block.range) + delta] = i
        }
        let parser = BlockParser(text: utf16, rules: rules)
        let root = PMKASTNode(type: .document, range: NSRange(location: 0, length: utf16.count))
        for block in oldBlocks[..<startIndex] { root.add(block) }
        var resumeIndex: Int?
        parser.parseBlocks(from: parser.lineIndex(at: windowStart), into: root) { block in
            guard NSMaxRange(block.range) >= editEnd, let i = candidates[NSMaxRange(block.range)] else { return false }
            let old = oldBlocks[i]
            guard old.range.length == block.range.length,
                  old.signature(relativeTo: old.range.location) == block.signature(relativeTo: block.range.location)
            else { return false }
            resumeIndex = i
            return true
        }
        var end = utf16.count
        if let i = resumeIndex {
            end = root.children.last.map { $0.range.location } ?? end
            for block in oldBlocks[(i + 1)...] {
                block.shift(by: delta)
                root.add(block)
            }
        }
        rootNode = root

        // The first window block is often unchanged; styling starts after it then.
        var start = windowStart
        if root.children.count > startIndex {
            let first = root.children[startIndex]
            let old = oldBlocks[startIndex]
            if first.range == old.range, NSMaxRange(first.range) <= r.location,
               first.signature(relativeTo: first.range.location) == old.signature(relativeTo: old.range.location) {
                start = NSMaxRange(first.range)
            }
        }
        start = min(start, r.location)
        end = max(end, min(editEnd, utf16.count))
        currentReparsedRange = NSRange(location: start, length: end - start)
        return currentReparsedRange
    }

    // MARK: - Queries

    public func lineStart(at index: Int) -> Int {
        var i = min(index, utf16.count)
        while i > 0 && utf16[i - 1] != CU.newline { i -= 1 }
        return i
    }

    public func lineEnd(at index: Int) -> Int {
        var i = min(index, utf16.count)
        while i < utf16.count && utf16[i] != CU.newline { i += 1 }
        return i
    }

    /// Range of the line containing `index`, including the trailing newline when present.
    public func lineRange(at index: Int) -> NSRange {
        let s = lineStart(at: index)
        var e = lineEnd(at: index)
        if e < utf16.count { e += 1 }
        return NSRange(location: s, length: e - s)
    }

    /// Deepest block-level node containing `index` (the document node is never returned).
    public func blockNode(at index: Int) -> PMKASTNode? {
        var best: PMKASTNode?
        func visit(_ n: PMKASTNode) {
            for c in n.children where isBlock(c.type) {
                if index >= c.range.location && (index < NSMaxRange(c.range) || (index == NSMaxRange(c.range) && index == utf16.count)) {
                    best = c
                    visit(c)
                    return
                }
            }
        }
        visit(rootNode)
        return best
    }

    /// Nearest enclosing node of `type` around `index`.
    public func node(ofType type: PMKNodeType, at index: Int) -> PMKASTNode? {
        var found: PMKASTNode?
        rootNode.walk { n in
            if n.type == type, index >= n.range.location, index <= NSMaxRange(n.range) {
                if found == nil || n.range.length <= found!.range.length { found = n }
            }
        }
        return found
    }

    public func nodes(ofType type: PMKNodeType, in range: NSRange) -> [PMKASTNode] {
        var out: [PMKASTNode] = []
        rootNode.walk { n in
            if n.type == type, NSIntersectionRange(n.range, range).length > 0 || (range.length == 0 && NSLocationInRange(range.location, n.range)) {
                out.append(n)
            }
        }
        return out
    }

    public func listItem(at index: Int) -> PMKASTNode? {
        guard let block = blockNode(at: index) else { return nil }
        var n: PMKASTNode? = block
        while let cur = n {
            if cur.type == .listItem, index < NSMaxRange(cur.range) || index == utf16.count {
                // only the item whose first line contains index counts as "the item at index"
                return cur
            }
            n = cur.parent
        }
        return nil
    }

    /// `hasFoldableContentAtIndex:` → `isContentHeadOfFoldable(nodeAtOffset(i).parentBlock)`.
    public func hasFoldableContent(at index: Int) -> Bool {
        guard let b = blockNode(at: index) else { return false }
        return isContentHeadOfFoldable(b)
    }

    func isBlock(_ t: PMKNodeType) -> Bool {
        switch t {
        case .document, .paragraph, .heading, .thematicBreak, .fencedCode, .blockquote, .list, .listItem, .calloutHead, .table, .tableRow: return true
        default: return false
        }
    }

    // MARK: - Annotation

    /// Full annotated string (cached per parse).
    public func annotatedString() -> NSAttributedString {
        lock.lock(); defer { lock.unlock() }
        if let c = annotatedCache { return c }
        let s = Annotator.annotate(ast: self, blocks: rootNode.children, window: NSRange(location: 0, length: utf16.count))
        annotatedCache = s
        return s
    }

    /// Annotates only the top-level blocks the range touches, so an edit costs its own blocks.
    public func annotatedString(forStringRange range: NSRange) -> NSAttributedString {
        let r = clamp(range)
        if let cached = lock.withLock({ annotatedCache }) { return cached.attributedSubstring(from: r) }
        let blocks = rootNode.children
        var firstIndex = blocks.firstIndex { NSMaxRange($0.range) > r.location } ?? blocks.count
        // A folded section above the range carries its fold attribute down into it.
        for (i, block) in blocks[..<firstIndex].enumerated() {
            var reaches = false
            block.walk { n in
                if n.type == .foldMarker, NSMaxRange(foldRange(forMarker: n)) > r.location { reaches = true }
            }
            if reaches { firstIndex = i; break }
        }
        var window = r
        var covered: [PMKASTNode] = []
        for block in blocks[firstIndex...] {
            if block.range.location >= NSMaxRange(r), !covered.isEmpty || block.range.location > NSMaxRange(r) { break }
            covered.append(block)
            window = NSUnionRange(window, block.range)
        }
        let annotated = Annotator.annotate(ast: self, blocks: covered, window: window)
        return annotated.attributedSubstring(from: NSRange(location: r.location - window.location, length: r.length))
    }

    public func annotatedString(forRange range: NSRange) -> NSAttributedString { annotatedString(forStringRange: range) }
}

/// Converts the tree into an NSAttributedString carrying PMK* attributes using the value
/// conventions (recovered from the decompiled `NSAttributedString(PolarMark)` category):
///   PMKHeading = level, PMKHeadingMarker = 1 ATX / 2 SETEXT
///   PMKList / PMKListMarker = NSNumber(listType 1 unordered / 2 ordered / 3 blockquote)
///   PMKListItem / PMKBlockquoteItem = PMKListInfo, PMKIndentSpace = NSNumber(indent units)
///   inline *Marker = 1 opening / 2 closing; link markers "[" 1, "]" 2, "(" 1, ")" 2
///   PMKEscape covers only the backslash.
enum Annotator {
    /// Annotates `blocks` into a string that covers `window`; a run outside the window is clipped.
    static func annotate(ast: PMKAST, blocks: [PMKASTNode], window: NSRange) -> NSAttributedString {
        let ns = ast.markdown as NSString
        let total = ns.length
        let s = NSMutableAttributedString(string: ns.substring(with: window))
        func add(_ key: NSAttributedString.Key, _ value: Any, _ r: NSRange) {
            let c = NSIntersectionRange(r, window)
            if c.length > 0 { s.addAttribute(key, value: value, range: NSRange(location: c.location - window.location, length: c.length)) }
        }
        func openClose(_ key: NSAttributedString.Key, _ n: PMKASTNode) {
            for (i, m) in n.markerRanges.enumerated() {
                add(key, NSNumber(value: i == 0 ? PMKMarkerValue.open.rawValue : PMKMarkerValue.close.rawValue), m)
            }
        }
        /// The four link markers: "[" open, "]" close, "(" open, ")" close. The parser records
        /// two runs ("[" / "![" and "](destination)"), which are split here; returns the destination range.
        func linkMarkers(_ key: NSAttributedString.Key, _ n: PMKASTNode) -> NSRange? {
            guard n.markerRanges.count == 2 else { return nil }
            let open = n.markerRanges[0]
            let tail = n.markerRanges[1]
            guard tail.length >= 3 else { return nil }
            add(key, NSNumber(value: PMKMarkerValue.open.rawValue), open)
            add(key, NSNumber(value: PMKMarkerValue.close.rawValue), NSRange(location: tail.location, length: 1))
            add(key, NSNumber(value: PMKMarkerValue.open.rawValue), NSRange(location: tail.location + 1, length: 1))
            add(key, NSNumber(value: PMKMarkerValue.close.rawValue), NSRange(location: NSMaxRange(tail) - 1, length: 1))
            return NSRange(location: tail.location + 2, length: tail.length - 3)
        }
        func lineRanges(in range: NSRange) -> [NSRange] {
            var out: [NSRange] = []
            ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in out.append(enclosing) }
            return out
        }

        for block in blocks { block.walk { n in
            switch n.type {
            case .document, .paragraph: break

            case .heading:
                add(.pmkHeading, NSNumber(value: n.level), n.range)
                // The block parser only produces ATX headings ("# "), optionally with a closing "#" run.
                for m in n.markerRanges {
                    add(.pmkHeadingMarker, NSNumber(value: PMKHeadingMarkerValue.atx.rawValue), m)
                }
                // PMKFoldable on the ATX marker when the heading is a foldable content head.
                if let m = n.markerRanges.first, ast.isContentHeadOfFoldable(n) { add(.pmkFoldable, NSNumber(value: true), m) }

            case .foldMarker:
                if let head = n.parent, ast.isContentHeadOfFoldable(head) {
                    add(.pmkFoldMarker, NSNumber(value: 1), n.range)
                    add(.pmkFold, NSNumber(value: 1), ast.foldRange(forMarker: n))
                } else {
                    // A fold comment that does not qualify stays raw HTML with PMKMetadata {"fold": true}.
                    add(.pmkHTMLInline, NSNumber(value: 1), n.range)
                }

            case .thematicBreak:
                // The PMKThematicBreak run never includes the paragraph's newline (the hr attachment
                // only replaces the marker characters, so the paragraph keeps its own line).
                var tb = n.range
                while tb.length > 0, ns.character(at: NSMaxRange(tb) - 1) == 0x0A { tb.length -= 1 }
                add(.pmkThematicBreak, NSNumber(value: 1), tb)

            case .fencedCode:
                add(.pmkFencedCode, NSNumber(value: 1), n.range)
                if !n.language.isEmpty, let open = n.markerRanges.first {
                    // the language run follows the opening fence characters on the first line
                    let fenceText = ns.substring(with: open)
                    if let r = fenceText.range(of: n.language) {
                        let loc = open.location + fenceText.utf16.distance(from: fenceText.utf16.startIndex, to: r.lowerBound.samePosition(in: fenceText.utf16)!)
                        add(.pmkFencedCodeLanguage, n.language, NSRange(location: loc, length: n.language.utf16.count))
                    }
                }
                openClose(.pmkFencedCodeMarker, n)

            case .table:
                // PMKTable = {RowCount (without the delimiter row), ColumnCount} over the block
                // minus its trailing line break.
                var tr = n.range
                while tr.length > 0, ns.character(at: NSMaxRange(tr) - 1) == 0x0A { tr.length -= 1 }
                let rows = n.children.filter { $0.type == .tableRow }.count
                add(.pmkTable, ["RowCount": NSNumber(value: max(0, rows - 1)), "ColumnCount": NSNumber(value: n.level)] as NSDictionary, tr)

            case .tableRow:
                for m in n.markerRanges { add(.pmkTableMarker, NSNumber(value: 1), m) }

            case .tableCell:
                add(.pmkTableCell, NSNumber(value: n.level), n.range)
                if n.contentRange.length > 0 { add(.pmkTableCellContent, NSNumber(value: n.level), n.contentRange) }

            case .calloutHead:
                // PMKCallout from the quote's first ">" through the head line,
                // PMKCalloutMarker on "[!TYPE]", PMKCalloutTitle on the trimmed title when present.
                if let quote = n.parent {
                    let start = quote.markerRanges.first?.location ?? n.range.location
                    var end = NSMaxRange(n.range)
                    if end > start, ns.character(at: end - 1) == 0x0A { end -= 1 }
                    add(.pmkCallout, NSNumber(value: n.level), NSRange(location: start, length: end - start))
                }
                if let m = n.markerRanges.first { add(.pmkCalloutMarker, NSNumber(value: 1), m) }
                if n.contentRange.length > 0 { add(.pmkCalloutTitle, NSNumber(value: 1), n.contentRange) }

            case .blockquote:
                if n.level == 1 { add(.pmkBlockquote, NSNumber(value: n.level), n.range) }
                // one PMKBlockquoteItem per line, marker = "> " of this level on that line
                // A nested quote's item starts at its own "> " marker, not at the line start, so the
                // outer marker stays part of the outer item.
                for (idx, line) in lineRanges(in: n.range).enumerated() {
                    let info = PMKListInfo(listType: PMKListInfo.blockquoteType, subType: n.calloutType >= 0 ? 6 : 0, taskType: 0, level: n.level - 1, itemIndex: idx)
                    info.calloutType = max(0, n.calloutType)
                    var item = line
                    if let m = n.markerRanges.first(where: { NSLocationInRange($0.location, line) }) {
                        var mr = m
                        if NSMaxRange(mr) < total, ns.character(at: NSMaxRange(mr)) == 0x20 { mr.length += 1 }
                        if n.level > 1 { item = NSRange(location: mr.location, length: NSMaxRange(line) - mr.location) }
                        add(.pmkBlockquoteItem, info, item)
                        add(.pmkBlockquoteMarker, NSNumber(value: PMKListInfo.blockquoteType), mr)
                    } else {
                        add(.pmkBlockquoteItem, info, item)
                    }
                    if n.level > 1 { add(.pmkBlockquote, NSNumber(value: n.level), item) }
                }

            case .list:
                add(.pmkList, NSNumber(value: n.ordered ? PMKListInfo.orderedType : PMKListInfo.unorderedType), n.range)

            case .listItem:
                let type = n.ordered ? PMKListInfo.orderedType : PMKListInfo.unorderedType
                let siblings = n.parent?.children.filter { $0.type == .listItem } ?? []
                let index = siblings.firstIndex { $0 === n } ?? 0
                let info = PMKListInfo(listType: type, subType: n.ordered ? 4 : 0, taskType: n.task.rawValue, level: max(0, n.level - 1), itemIndex: index)
                info.orderedListItemNumber = n.number
                if n.ordered, let m = n.markerRanges.first, m.length >= 2 {
                    let delimiter = ns.character(at: NSMaxRange(m) - 2)
                    info.listSubType = delimiter == 0x29 ? 5 : 4   // ")" vs "."
                }
                add(.pmkListItem, info, n.range)
                if let m = n.markerRanges.first { add(.pmkListMarker, NSNumber(value: type), m) }
                // PMKFoldable on the list marker when the item's first block is a foldable head.
                if let m = n.markerRanges.first, ast.isContentHeadOfFoldable(n) { add(.pmkFoldable, NSNumber(value: true), m) }
                if let ir = n.indentRange, ir.length > 0 {
                    // indent units: a tab counts as one unit, every two spaces count as one unit (normalizeIndentation)
                    let text = ns.substring(with: ir)
                    let tabs = text.filter { $0 == "\t" }.count
                    let spaces = text.filter { $0 == " " }.count
                    add(.pmkIndentSpace, NSNumber(value: max(1, tabs + spaces / 2)), ir)
                }

            case .strong: add(.pmkStrong, NSNumber(value: 1), n.range); openClose(.pmkStrongMarker, n)
            case .emphasis: add(.pmkEmphasis, NSNumber(value: 1), n.range); openClose(.pmkEmphasisMarker, n)
            case .strikethrough: add(.pmkStrikethrough, NSNumber(value: 1), n.range); openClose(.pmkStrikethroughMarker, n)
            case .underline: add(.pmkUnderline, NSNumber(value: 1), n.range); openClose(.pmkUnderlineMarker, n)
            case .highlighter:
                add(.pmkHighlighter, NSNumber(value: 1), n.range); openClose(.pmkHighlighterMarker, n)
                add(.pmkHighlighterColor, NSNumber(value: 0), n.range)
            case .code: add(.pmkCode, NSNumber(value: 1), n.range); openClose(.pmkCodeMarker, n)

            case .link:
                add(.pmkLink, NSNumber(value: 1), n.range)
                let destination = linkMarkers(.pmkLinkMarker, n)
                add(.pmkLinkLabel, NSNumber(value: 1), n.contentRange)
                if let d = destination, d.length > 0 { add(.pmkLinkURL, n.url, d) }
            case .image:
                add(.pmkImage, NSNumber(value: 1), n.range)
                let destination = linkMarkers(.pmkImageMarker, n)
                add(.pmkImageLabel, NSNumber(value: 1), n.contentRange)
                if let d = destination, d.length > 0 { add(.pmkImageURL, n.url, d) }

            case .hashtag:
                add(.pmkHashtag, n.label, n.range)
                for (i, m) in n.markerRanges.enumerated() {
                    add(.pmkHashtagMarker, NSNumber(value: i == 0 ? PMKMarkerValue.open.rawValue : PMKMarkerValue.close.rawValue), m)
                }
                // "/" separators split the tag into segments
                var segStart = n.contentRange.location
                var segIndex = 0
                for i in n.contentRange.location..<NSMaxRange(n.contentRange) where ns.character(at: i) == 0x2F {
                    add(.pmkHashtagSegment, NSNumber(value: segIndex), NSRange(location: segStart, length: i - segStart))
                    add(.pmkHashtagSeparator, NSNumber(value: 1), NSRange(location: i, length: 1))
                    segStart = i + 1; segIndex += 1
                }
                add(.pmkHashtagSegment, NSNumber(value: segIndex), NSRange(location: segStart, length: NSMaxRange(n.contentRange) - segStart))

            case .autolink:
                let isEmail = n.url.contains("@") && !n.url.lowercased().hasPrefix("http") && !n.url.lowercased().hasPrefix("mailto:")
                add(isEmail ? .pmkAutoLinkEmail : .pmkAutoLinkURL, n.url, n.range)
                if n.markerRanges.count == 2 {
                    add(.pmkAutoLinkMarker, NSNumber(value: PMKMarkerValue.open.rawValue), n.markerRanges[0])
                    add(.pmkAutoLinkMarker, NSNumber(value: PMKMarkerValue.close.rawValue), n.markerRanges[1])
                }

            case .escape:
                // PMKEscape + PMKEscapeMarker only on the backslash
                if let m = n.markerRanges.first {
                    add(.pmkEscape, NSNumber(value: 1), m)
                    add(.pmkEscapeMarker, NSNumber(value: PMKMarkerValue.open.rawValue), m)
                }
            case .hardLineBreak: add(.pmkHardLinebreak, NSNumber(value: 1), n.range)
            }
        } }
        return s
    }
}
