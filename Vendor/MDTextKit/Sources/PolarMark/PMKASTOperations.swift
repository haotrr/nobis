import Foundation

/// A replacement the editor should apply plus
/// the selection to set afterwards. Operations never mutate the AST directly;
/// the text storage applies the result and the AST is updated through the
/// normal edit path.
public struct PMKASTOperationResult: Equatable {
    public var replacementRange: NSRange
    public var replacementString: String
    public var proposedSelection: NSRange

    public init(replacementRange: NSRange, replacementString: String, proposedSelection: NSRange) {
        self.replacementRange = replacementRange
        self.replacementString = replacementString
        self.proposedSelection = proposedSelection
    }
}

/// `PMK::Operation*` (OperationToggleInlineStyle, OperationToggleFold, ...).
extension PMKAST {

    // MARK: Line inspection helpers

    struct LineInfo {
        let start: Int
        let end: Int            // offset of "\n" or text end
        let quote: BlockParser.LinePrefix
        let indentEnd: Int      // after quote markers + leading whitespace
        let markerEnd: Int      // after heading/list marker (== indentEnd when none)
        let kind: BlockParser.Kind
    }

    func lineInfo(at index: Int, parser: BlockParser) -> LineInfo {
        let s = lineStart(at: index)
        let e = lineEnd(at: index)
        let line = Line(index: 0, start: s, end: e, nextStart: e)
        let qp = parser.quotePrefix(of: line)
        var indentEnd = qp.contentStart
        while indentEnd < e, CU.isSpaceOrTab(utf16[indentEnd]) { indentEnd += 1 }
        let kind = parser.classify(line, from: qp.contentStart)
        var markerEnd = indentEnd
        switch kind {
        case .heading(_, _, let me): markerEnd = me
        case .listItem(_, _, _, _, _, let me): markerEnd = me
        default: break
        }
        return LineInfo(start: s, end: e, quote: qp, indentEnd: indentEnd, markerEnd: markerEnd, kind: kind)
    }

    private func makeParser() -> BlockParser { BlockParser(text: utf16, rules: rules) }

    // MARK: Inline styles

    public func toggleInlineStyle(_ style: PMKInlineStyleKind, selection: NSRange) -> PMKASTOperationResult? {
        let sel = clamp(selection)
        let type: PMKNodeType = {
            switch style {
            case .strong: return .strong
            case .emphasis: return .emphasis
            case .strikethrough: return .strikethrough
            case .underline: return .underline
            case .highlighter: return .highlighter
            case .code: return .code
            }
        }()

        // Already inside a span of this kind -> remove its markers.
        if let node = enclosingInline(ofType: type, selection: sel), node.markerRanges.count == 2 {
            let open = node.markerRanges[0], close = node.markerRanges[1]
            let inner = substring(NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
            var newLoc = sel.location - open.length
            if sel.location < NSMaxRange(open) { newLoc = open.location }
            newLoc = max(open.location, min(newLoc, open.location + inner.utf16.count))
            var newLen = sel.length
            if NSMaxRange(sel) > close.location { newLen = max(0, open.location + inner.utf16.count - newLoc) }
            return PMKASTOperationResult(replacementRange: node.range, replacementString: inner,
                                         proposedSelection: NSRange(location: newLoc, length: newLen))
        }

        let d = style.delimiter
        if sel.length == 0 {
            // Empty selection: insert a pair and place the caret inside.
            return PMKASTOperationResult(replacementRange: sel, replacementString: d + d,
                                         proposedSelection: NSRange(location: sel.location + d.utf16.count, length: 0))
        }
        // Trim whitespace at the edges so markers hug the words.
        var r = sel
        while r.length > 0, CU.isWhitespace(utf16[r.location]) { r.location += 1; r.length -= 1 }
        while r.length > 0, CU.isWhitespace(utf16[NSMaxRange(r) - 1]) { r.length -= 1 }
        guard r.length > 0 else { return nil }
        let wrapped = d + substring(r) + d
        return PMKASTOperationResult(replacementRange: r, replacementString: wrapped,
                                     proposedSelection: NSRange(location: r.location + d.utf16.count, length: r.length))
    }

    private func enclosingInline(ofType type: PMKNodeType, selection: NSRange) -> PMKASTNode? {
        var found: PMKASTNode?
        rootNode.walk { n in
            guard n.type == type else { return }
            let contains = selection.location >= n.range.location && NSMaxRange(selection) <= NSMaxRange(n.range)
            if contains, found == nil || n.range.length < found!.range.length { found = n }
        }
        return found
    }

    // MARK: Block styles

    public func toggleBlockStyle(_ style: PMKBlockStyleKind, selection: NSRange) -> PMKASTOperationResult? {
        let sel = clamp(selection)
        let lastIndex = sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location
        let start = lineStart(at: sel.location)
        let end = lineEnd(at: (sel.length > 0 && utf16.at(lastIndex) == CU.newline) ? max(sel.location, lastIndex - 1) : lastIndex)
        let region = NSRange(location: start, length: max(0, end - start))

        if case .fencedCode = style { return toggleFencedCode(region: region, selection: sel) }

        let parser = makeParser()
        var lineStarts: [Int] = []
        var ls = start
        while true {
            lineStarts.append(ls)
            let le = lineEnd(at: ls)
            if le >= end { break }
            ls = le + 1
        }
        let infos = lineStarts.map { lineInfo(at: $0, parser: parser) }
        let allAlready = infos.allSatisfy { lineHasStyle(style, info: $0) }

        var outLines: [String] = []
        var caretDelta = 0
        var totalDelta = 0
        for (i, info) in infos.enumerated() {
            let oldLine = substring(NSRange(location: info.start, length: info.end - info.start))
            let newLine: String
            if case .blockquote = style {
                if allAlready, let first = info.quote.quoteMarkers.first {
                    newLine = substring(NSRange(location: info.start, length: first.location - info.start))
                        + substring(NSRange(location: NSMaxRange(first), length: info.end - NSMaxRange(first)))
                } else {
                    newLine = "> " + oldLine
                }
            } else {
                let quoteStr = substring(NSRange(location: info.start, length: info.quote.contentStart - info.start))
                let indentStr = substring(NSRange(location: info.quote.contentStart, length: info.indentEnd - info.quote.contentStart))
                let body = substring(NSRange(location: info.markerEnd, length: info.end - info.markerEnd))
                let prefix = allAlready ? "" : blockPrefix(for: style, lineIndex: i, info: info)
                newLine = quoteStr + indentStr + prefix + body
            }
            let delta = newLine.utf16.count - oldLine.utf16.count
            if i == 0 { caretDelta = delta }
            totalDelta += delta
            outLines.append(newLine)
        }
        let replacement = outLines.joined(separator: "\n")
        var newSel = sel
        newSel.location = max(start, min(sel.location + caretDelta, start + replacement.utf16.count))
        if sel.length > 0 { newSel.length = max(0, sel.length + totalDelta - caretDelta) }
        return PMKASTOperationResult(replacementRange: region, replacementString: replacement, proposedSelection: newSel)
    }

    private func lineHasStyle(_ style: PMKBlockStyleKind, info: LineInfo) -> Bool {
        switch style {
        case .heading(let lvl): if case .heading(let l, _, _) = info.kind { return l == lvl }; return false
        case .unorderedList: if case .listItem(let o, _, let t, _, _, _) = info.kind { return !o && t == .notTask }; return false
        case .orderedList: if case .listItem(let o, _, _, _, _, _) = info.kind { return o }; return false
        case .taskList: if case .listItem(_, _, let t, _, _, _) = info.kind { return t != .notTask }; return false
        case .blockquote: return info.quote.quoteLevel > 0
        case .fencedCode: return false
        }
    }

    private func blockPrefix(for style: PMKBlockStyleKind, lineIndex: Int, info: LineInfo) -> String {
        switch style {
        case .heading(let l): return String(repeating: "#", count: max(1, min(6, l))) + " "
        case .unorderedList: return "- "
        case .orderedList: return "\(lineIndex + 1). "
        case .taskList:
            if case .listItem(_, _, let t, _, _, _) = info.kind, t == .completed { return "- [x] " }
            return "- [ ] "
        case .blockquote: return "> "
        case .fencedCode: return ""
        }
    }

    private func toggleFencedCode(region: NSRange, selection: NSRange) -> PMKASTOperationResult? {
        if let code = node(ofType: .fencedCode, at: selection.location), code.markerRanges.count == 2 {
            let openLine = lineRange(at: code.markerRanges[0].location)
            let closeLineStart = lineStart(at: code.markerRanges[1].location)
            let closeLineEnd = lineEnd(at: code.markerRanges[1].location)
            var inner = substring(NSRange(location: NSMaxRange(openLine), length: max(0, closeLineStart - NSMaxRange(openLine))))
            if inner.hasSuffix("\n") { inner.removeLast() }
            let whole = NSRange(location: openLine.location, length: closeLineEnd - openLine.location)
            let newLoc = max(openLine.location, min(selection.location - openLine.length, openLine.location + inner.utf16.count))
            return PMKASTOperationResult(replacementRange: whole, replacementString: inner,
                                         proposedSelection: NSRange(location: newLoc, length: 0))
        }
        let body = substring(region)
        let replacement = "```\n" + body + "\n```"
        return PMKASTOperationResult(replacementRange: region, replacementString: replacement,
                                     proposedSelection: NSRange(location: selection.location + 4, length: selection.length))
    }

    // MARK: Tasks

    public func toggleTask(at index: Int) -> PMKASTOperationResult? {
        let info = lineInfo(at: index, parser: makeParser())
        guard case .listItem(_, _, let task, _, let ms, _) = info.kind, task != .notTask else { return nil }
        let bracketStart = ms + 2
        guard utf16.at(bracketStart) == CU.lbracket else { return nil }
        let inner = NSRange(location: bracketStart + 1, length: 1)
        let newChar = task == .open ? "x" : " "
        return PMKASTOperationResult(replacementRange: inner, replacementString: newChar, proposedSelection: NSRange(location: index, length: 0))
    }

    // MARK: Newline / indentation behaviour

    /// Continues lists and quotes,
    /// exits an empty item, keeps indentation in code blocks.
    public func insertNewline(selection: NSRange) -> PMKASTOperationResult {
        let sel = clamp(selection)
        let info = lineInfo(at: sel.location, parser: makeParser())
        let quotePrefixString = substring(NSRange(location: info.start, length: info.quote.contentStart - info.start))

        if let code = node(ofType: .fencedCode, at: sel.location),
           sel.location >= code.contentRange.location, sel.location <= NSMaxRange(code.contentRange) {
            let indent = substring(NSRange(location: info.start, length: info.indentEnd - info.start))
            return PMKASTOperationResult(replacementRange: sel, replacementString: "\n" + indent,
                                         proposedSelection: NSRange(location: sel.location + 1 + indent.utf16.count, length: 0))
        }

        switch info.kind {
        case .listItem(let ordered, let number, let task, _, let ms, let me):
            if me >= info.end && sel.location >= me {
                // Empty item: return removes the marker (exits the list).
                let r = NSRange(location: info.start, length: info.end - info.start)
                let kept = substring(NSRange(location: info.start, length: ms - info.start))
                return PMKASTOperationResult(replacementRange: r, replacementString: kept,
                                             proposedSelection: NSRange(location: info.start + kept.utf16.count, length: 0))
            }
            let indent = substring(NSRange(location: info.quote.contentStart, length: ms - info.quote.contentStart))
            let marker: String
            if ordered { marker = "\(number + 1). " }
            else if task != .notTask { marker = "- [ ] " }
            else { marker = substring(NSRange(location: ms, length: min(2, me - ms))) }
            let ins = "\n" + quotePrefixString + indent + marker
            return PMKASTOperationResult(replacementRange: sel, replacementString: ins,
                                         proposedSelection: NSRange(location: sel.location + ins.utf16.count, length: 0))
        case .blank where info.quote.quoteLevel > 0:
            return PMKASTOperationResult(replacementRange: NSRange(location: info.start, length: info.end - info.start), replacementString: "",
                                         proposedSelection: NSRange(location: info.start, length: 0))
        default:
            let ins = "\n" + quotePrefixString
            return PMKASTOperationResult(replacementRange: sel, replacementString: ins,
                                         proposedSelection: NSRange(location: sel.location + ins.utf16.count, length: 0))
        }
    }

    /// `-[PMKAST indent:selectionRange:]`. Adds one tab to every line of the selection.
    public func indent(selection: NSRange) -> PMKASTOperationResult {
        let sel = clamp(selection)
        let s = lineStart(at: sel.location)
        let e = lineEnd(at: max(sel.location, NSMaxRange(sel) - (sel.length > 0 ? 1 : 0)))
        let region = NSRange(location: s, length: e - s)
        let lines = substring(region).components(separatedBy: "\n")
        let out = lines.map { "\t" + $0 }.joined(separator: "\n")
        return PMKASTOperationResult(replacementRange: region, replacementString: out,
                                     proposedSelection: NSRange(location: sel.location + 1, length: sel.length == 0 ? 0 : sel.length + lines.count - 1))
    }

    /// `-[PMKAST outdent:selectionRange:]`. Removes one tab (or up to 4 spaces) from every line.
    public func outdent(selection: NSRange) -> PMKASTOperationResult? {
        let sel = clamp(selection)
        let s = lineStart(at: sel.location)
        let e = lineEnd(at: max(sel.location, NSMaxRange(sel) - (sel.length > 0 ? 1 : 0)))
        let region = NSRange(location: s, length: e - s)
        let lines = substring(region).components(separatedBy: "\n")
        var removedFirst = 0
        var removedTotal = 0
        let out: [String] = lines.enumerated().map { (i, l) in
            var removed = 0
            var t = Substring(l)
            if t.hasPrefix("\t") { t = t.dropFirst(); removed = 1 }
            else { while removed < 4, t.hasPrefix(" ") { t = t.dropFirst(); removed += 1 } }
            if i == 0 { removedFirst = removed }
            removedTotal += removed
            return String(t)
        }
        guard removedTotal > 0 else { return nil }
        let newLoc = max(s, sel.location - removedFirst)
        return PMKASTOperationResult(replacementRange: region, replacementString: out.joined(separator: "\n"),
                                     proposedSelection: NSRange(location: newLoc, length: sel.length == 0 ? 0 : max(0, sel.length - (removedTotal - removedFirst))))
    }

    /// Backspace right after a list/quote/heading
    /// marker removes the whole marker instead of one character.
    public func deletePrevious(selection: NSRange) -> PMKASTOperationResult? {
        let sel = clamp(selection)
        guard sel.length == 0, sel.location > 0 else { return nil }
        let info = lineInfo(at: sel.location, parser: makeParser())
        switch info.kind {
        case .listItem(_, _, _, _, let ms, let me) where sel.location == me:
            return PMKASTOperationResult(replacementRange: NSRange(location: ms, length: me - ms), replacementString: "",
                                         proposedSelection: NSRange(location: ms, length: 0))
        case .heading(_, let ms, let me) where sel.location == me:
            return PMKASTOperationResult(replacementRange: NSRange(location: ms, length: me - ms), replacementString: "",
                                         proposedSelection: NSRange(location: ms, length: 0))
        default: break
        }
        if info.quote.quoteLevel > 0, sel.location == info.quote.contentStart, let last = info.quote.quoteMarkers.last {
            return PMKASTOperationResult(replacementRange: last, replacementString: "", proposedSelection: NSRange(location: last.location, length: 0))
        }
        return nil
    }

    public func insertThematicBreak(selection: NSRange) -> PMKASTOperationResult {
        let sel = clamp(selection)
        let atLineStart = sel.location == lineStart(at: sel.location)
        let ins = (atLineStart ? "" : "\n") + "---\n"
        return PMKASTOperationResult(replacementRange: sel, replacementString: ins, proposedSelection: NSRange(location: sel.location + ins.utf16.count, length: 0))
    }

    /// `-[PMKAST renumberOrderedListInRange:selectionRange:]`. Results are ordered bottom-up
    /// so they can be applied sequentially.
    public func renumberOrderedList(at index: Int) -> [PMKASTOperationResult] {
        guard let item = listItem(at: index), item.ordered, let list = item.parent, list.type == .list else { return [] }
        var results: [PMKASTOperationResult] = []
        var expected = max(1, list.children.first?.number ?? 1)
        for it in list.children {
            guard let m = it.markerRanges.first else { continue }
            var digits = 0
            while digits < m.length, CU.isDigit(utf16[m.location + digits]) { digits += 1 }
            let current = Int(substring(NSRange(location: m.location, length: digits))) ?? expected
            if current != expected {
                results.append(PMKASTOperationResult(replacementRange: NSRange(location: m.location, length: digits), replacementString: "\(expected)", proposedSelection: NSRange(location: index, length: 0)))
            }
            expected += 1
        }
        return results.reversed()
    }

    // MARK: Summary

    /// First heading text (or first non-empty line) — used for the note title.
    public func title() -> String {
        if let h = rootNode.children.first(where: { $0.type == .heading }) {
            return substring(h.contentRange).trimmingCharacters(in: .whitespaces)
        }
        return markdown.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
