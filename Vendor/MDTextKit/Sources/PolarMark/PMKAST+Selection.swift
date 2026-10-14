import Foundation

/// `PMK::Correction::SelectionCorrection` and `PMK::Operation::SelectAllText`.
extension PMKAST {
    private struct Marker { let node: PMKASTNode; let range: NSRange; let opening: Bool; let pair: NSRange? }

    /// Inline marker runs (open/close pairs) in document order.
    private func inlineMarkers() -> [Marker] {
        var out: [Marker] = []
        rootNode.walk { n in
            guard !isBlock(n.type), n.markerRanges.count >= 2 else { return }
            let first = n.markerRanges.first!, last = n.markerRanges.last!
            out.append(Marker(node: n, range: first, opening: true, pair: last))
            out.append(Marker(node: n, range: last, opening: false, pair: first))
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// A selection whose ends leave the block of
    /// the current selection never splits a pair of inline markers: paired markers are taken whole or left out.
    public func selectionCorrection(in current: NSRange, replacementString: String?, selectionRange proposed: NSRange) -> [PMKASTOperationResult] {
        guard proposed.length > 0, (replacementString ?? "").isEmpty else { return [] }
        let cur = clamp(current), prop = clamp(proposed)
        let blockStart = blockNode(at: cur.location)?.range.location ?? 0
        let blockEnd = blockNode(at: max(0, NSMaxRange(cur) - (cur.length > 0 ? 1 : 0))).map { NSMaxRange($0.range) } ?? utf16.count
        var S = prop.location, E = NSMaxRange(prop)
        let markers = inlineMarkers()
        func inside(_ r: NSRange?) -> Bool { guard let r = r else { return false }; return r.location >= S && NSMaxRange(r) <= E }
        let sOutside = S < blockStart || S >= blockEnd
        let eOutside = E < blockStart || E > blockEnd
        if sOutside {
            // move S forward past markers whose partner is not inside [S, E]
            while let m = markers.first(where: { $0.range.location == S }), !inside(m.pair) { S = NSMaxRange(m.range) }
        }
        if eOutside {
            while let m = markers.first(where: { NSMaxRange($0.range) == E }), !inside(m.pair) { E = m.range.location }
        }
        if S <= E {
            if sOutside {
                // extend S backward over opening markers whose closing partner ends before E
                while let m = markers.first(where: { NSMaxRange($0.range) == S && $0.opening }), let pair = m.pair, NSMaxRange(pair) <= E { S = m.range.location }
            }
            if eOutside {
                while let m = markers.first(where: { $0.range.location == E && !$0.opening }), let pair = m.pair, pair.location >= S { E = NSMaxRange(m.range) }
            }
        }
        let fixed = NSRange(location: S, length: max(0, E - S))
        guard fixed != prop else { return [] }
        return [PMKASTOperationResult(replacementRange: NSRange(location: fixed.location, length: 0), replacementString: "", proposedSelection: fixed)]
    }

    /// Inside a fenced code (or math) block ⌘A first selects the block
    /// content; otherwise everything.
    public func selectAllText(in range: NSRange, selectionRange sel: NSRange) -> [PMKASTOperationResult] {
        let s = clamp(sel)
        let all = NSRange(location: 0, length: utf16.count)
        if s.location == utf16.count { return [PMKASTOperationResult(replacementRange: NSRange(location: 0, length: 0), replacementString: "", proposedSelection: all)] }
        if let a = node(ofType: .fencedCode, at: s.location), let b = node(ofType: .fencedCode, at: NSMaxRange(s)), a === b {
            var content = a.contentRange
            while content.length > 0, utf16[NSMaxRange(content) - 1] == CU.newline { content.length -= 1 }
            if content != s { return [PMKASTOperationResult(replacementRange: NSRange(location: 0, length: 0), replacementString: "", proposedSelection: content)] }
        }
        return [PMKASTOperationResult(replacementRange: NSRange(location: 0, length: 0), replacementString: "", proposedSelection: all)]
    }
}
