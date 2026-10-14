import Foundation

/// Heading / list folding (`Ice::Inline::Folding`, `PMK::Operation::ToggleFold`,
/// `OperationUnfoldRangeEdges`, `RemoveStrayMetaComments`). The fold state lives in the markdown as the
/// comment `<!-- {"fold":true} -->` at the end of the head line; everything after it up to the end of the
/// section is hidden by `MDFoldTextStyler`.
extension PMKAST {
    static let foldMarkerMarkdown = "<!-- {\"fold\":true} -->"
    static var foldMarkerLength: Int { BlockParser.foldMarkerText.count }

    // MARK: Tree queries (Ice folding engine)

    func isContentHeadOfFoldable(_ n: PMKASTNode) -> Bool {
        guard let parent = n.parent else { return false }
        switch n.type {
        case .heading:
            // headings inside lists / quotes are never foldable
            guard parent.type == .document else { return false }
            guard let next = n.nextSibling else { return false }
            if next.type == .heading, next.level <= n.level { return false }
            return true
        case .listItem:
            // the item's first line is the content head; foldable when a sublist follows it
            return n.children.contains { isBlock($0.type) }
        default:
            return false
        }
    }

    /// Last sibling of the folded section.
    func foldableTail(_ h: PMKASTNode) -> PMKASTNode? {
        switch h.type {
        case .heading:
            var tail: PMKASTNode? = nil
            var cur = h.nextSibling
            while let c = cur {
                if c.type == .heading, c.level <= h.level { break }
                tail = c
                cur = c.nextSibling
            }
            return tail
        case .listItem:
            return h.children.last { isBlock($0.type) }
        default:
            return nil
        }
    }

    /// End offset of the hidden region (`end` node = node before the section's final line ending).
    func foldedRegionEnd(forHead h: PMKASTNode) -> Int {
        var end: Int
        switch h.type {
        case .heading:
            // up to the next heading of the same or higher level (blank lines included), else the document end
            var boundary: PMKASTNode? = nil
            var cur = h.nextSibling
            while let c = cur { if c.type == .heading, c.level <= h.level { boundary = c; break }; cur = c.nextSibling }
            end = boundary.map { $0.range.location } ?? utf16.count
        default:
            end = foldableTail(h).map { NSMaxRange($0.range) } ?? NSMaxRange(h.range)
        }
        let markerEnd = foldMarkerNode(of: h).map { NSMaxRange($0.range) } ?? NSMaxRange(h.range)
        if end > markerEnd, end > 0, utf16[end - 1] == CU.newline { end -= 1 }
        return max(end, markerEnd)
    }

    func foldMarkerNode(of head: PMKASTNode) -> PMKASTNode? { head.children.first { $0.type == .foldMarker } }

    func isContentHeadFolded(_ n: PMKASTNode) -> Bool { foldMarkerNode(of: n) != nil && isContentHeadOfFoldable(n) }

    /// Range covered by PMKFold for a marker node: marker start … end of the hidden region.
    func foldRange(forMarker m: PMKASTNode) -> NSRange {
        guard let head = m.parent else { return m.range }
        return NSRange(location: m.range.location, length: foldedRegionEnd(forHead: head) - m.range.location)
    }

    /// All folded heads (headings and list items) in document order.
    private var foldedHeads: [PMKASTNode] {
        var out: [PMKASTNode] = []
        rootNode.walk { n in if (n.type == .heading || n.type == .listItem), isContentHeadFolded(n) { out.append(n) } }
        return out
    }

    /// Innermost folded head whose hidden region contains `index`
    /// (the head line itself is not hidden). `includeHead` also matches the head's own line (marker included).
    private func foldedHeads(hiding index: Int, includeHead: Bool) -> [PMKASTNode] {
        foldedHeads.filter { h in
            guard let m = foldMarkerNode(of: h) else { return false }
            let hiddenStart = includeHead ? h.range.location : m.range.location
            return index >= hiddenStart && index <= foldedRegionEnd(forHead: h)
        }
    }

    /// The foldable head to fold for a caret at `index`.
    private func firstFoldableHeadBlock(at index: Int) -> PMKASTNode? {
        guard let b = blockNode(at: index) else { return nil }
        // climb from the leaf block: the block itself, then its list item, then previous siblings / parents
        var chain: [PMKASTNode] = []
        var cur: PMKASTNode? = b
        while let c = cur, c.type != .document {
            chain.append(c)
            if let prev = c.previousSibling { cur = prev } else { cur = c.parent }
        }
        for c in chain where isContentHeadOfFoldable(c) {
            if b.type != .heading || isContentHeadOfFoldable(b) || c === b || c.type != .heading || c.level < b.level { return c }
        }
        return nil
    }

    // MARK: Operations

    /// Insert the marker before the head line's newline.
    private func foldHeadBlock(_ h: PMKASTNode, results: inout [PMKASTOperationResult], selection: inout NSRange) {
        let at = lineEnd(at: h.range.location)                      // offset of the head line's "\n"
        let regionEnd = foldedRegionEnd(forHead: h)
        let last = regionEnd < utf16.count && utf16[regionEnd] == CU.newline ? regionEnd + 1 : regionEnd
        let m = PMKAST.foldMarkerLength
        var selLoc = selection.location, selLen = selection.length
        if at < selLoc {
            if selLoc < last { selLoc = at; selLen = 0 } else { selLoc += m }
        }
        if at < selLoc + selLen {
            if selLoc + selLen < last { selLen = 0 } else if !(at < selLoc) { selLen += m }
        }
        let alreadyNewline = results.contains { $0.replacementString == "\n" }
        if at < utf16.count || alreadyNewline {
            results.append(PMKASTOperationResult(replacementRange: NSRange(location: at, length: 0), replacementString: PMKAST.foldMarkerMarkdown, proposedSelection: NSRange(location: selLoc, length: selLen)))
        } else {
            // the section ends at EOF without a newline: add one so the fold has a visible line after it
            if at < selLoc { selLoc += 1 }
            results.append(PMKASTOperationResult(replacementRange: NSRange(location: utf16.count, length: 0), replacementString: "\n", proposedSelection: NSRange(location: selLoc, length: 0)))
            results.append(PMKASTOperationResult(replacementRange: NSRange(location: at, length: 0), replacementString: PMKAST.foldMarkerMarkdown, proposedSelection: NSRange(location: selLoc, length: 0)))
        }
        selection = NSRange(location: selLoc, length: selLen)
    }

    private func removeMarker(of head: PMKASTNode, selection: NSRange) -> PMKASTOperationResult? {
        guard let m = foldMarkerNode(of: head) else { return nil }
        return PMKASTOperationResult(replacementRange: m.range, replacementString: "", proposedSelection: selection)
    }

    /// `toggleFoldInRange:selectionRange:` (ToggleFold type 0).
    public func toggleFold(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        let loc = clamp(range).location
        var selection = clamp(selectionRange)
        // unfold: the topmost folded head hiding `loc` (or whose head line holds `loc`)
        if let top = foldedHeads(hiding: loc, includeHead: true).first, let r = removeMarker(of: top, selection: selection) {
            return [r]
        }
        var results: [PMKASTOperationResult] = []
        if let h = firstFoldableHeadBlock(at: loc) { foldHeadBlock(h, results: &results, selection: &selection) }
        return results.sorted { $0.replacementRange.location > $1.replacementRange.location }
    }

    /// `foldAllHeadingSelectionRange:` (ToggleFold type 1).
    public func foldAllHeading(selectionRange: NSRange) -> [PMKASTOperationResult] {
        var results: [PMKASTOperationResult] = []
        var selection = clamp(selectionRange)
        let headings = rootNode.children.filter { $0.type == .heading }
        for h in headings.reversed() where isContentHeadOfFoldable(h) && !isContentHeadFolded(h) {
            let isDocFirst = h.previousSibling == nil
            if let tail = foldableTail(h), tail.nextSibling == nil, isDocFirst { continue }   // keep the note title open
            foldHeadBlock(h, results: &results, selection: &selection)
        }
        return results.sorted { $0.replacementRange.location > $1.replacementRange.location }
    }

    /// `unfoldAllHeadingSelectionRange:` (ToggleFold type 2) — list-item folds are left alone.
    public func unfoldAllHeading(selectionRange: NSRange) -> [PMKASTOperationResult] {
        let selection = clamp(selectionRange)
        var results: [PMKASTOperationResult] = []
        rootNode.walk { n in
            if n.type == .foldMarker, let head = n.parent, head.type == .heading {
                results.append(PMKASTOperationResult(replacementRange: n.range, replacementString: "", proposedSelection: selection))
            }
        }
        return results.sorted { $0.replacementRange.location > $1.replacementRange.location }
    }

    /// A caret or edit landing inside hidden content unfolds every fold hiding it.
    public func unfoldAtRangeEdges(_ range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        let r = clamp(range)
        let selection = clamp(selectionRange)
        if r.length == 0, r.location == utf16.count { return [] }
        var heads: [PMKASTNode] = []
        for index in Set([r.location, NSMaxRange(r)]) {
            for h in foldedHeads(hiding: index, includeHead: false) where !heads.contains(where: { $0 === h }) {
                // being on the head's own line (marker included) does not unfold
                if let m = foldMarkerNode(of: h), index <= NSMaxRange(m.range) { continue }
                heads.append(h)
            }
        }
        return heads.compactMap { removeMarker(of: $0, selection: selection) }.sorted { $0.replacementRange.location > $1.replacementRange.location }
    }

    /// Delete fold comments that no longer belong to a foldable head.
    public func removeStrayMetaComment(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        let r = clamp(range)
        let selection = clamp(selectionRange)
        let marker = BlockParser.foldMarkerText
        var results: [PMKASTOperationResult] = []
        guard r.length >= marker.count else { return [] }
        var i = NSMaxRange(r) - marker.count
        while i >= r.location {
            var match = true
            for k in 0..<marker.count where utf16[i + k] != marker[k] { match = false; break }
            if match {
                let inCode = node(ofType: .fencedCode, at: i) != nil || node(ofType: .code, at: i) != nil
                let isMarkerNode = node(ofType: .foldMarker, at: i).map { $0.range.location == i } ?? false
                if !isMarkerNode && !inCode {
                    results.append(PMKASTOperationResult(replacementRange: NSRange(location: i, length: marker.count), replacementString: "", proposedSelection: selection))
                }
                i -= marker.count
            } else {
                i -= 1
            }
        }
        return results
    }
}
