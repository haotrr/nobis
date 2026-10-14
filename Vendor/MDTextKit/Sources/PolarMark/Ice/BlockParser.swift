import Foundation

/// `Ice::BlockParser` + `Ice::BlockRuleMap`.
/// Line-oriented container parser. Supported blocks: ATX headings, thematic
/// breaks, fenced code, blockquotes (nested), ordered / unordered / task lists
/// (nested by indentation), paragraphs.
struct BlockParser {
    let text: [UInt16]
    let lines: [Line]
    let inlineParser: InlineParser
    let tabWidth = 4

    init(text: [UInt16], rules: RuleConfig) {
        self.text = text
        self.lines = Lines.split(text)
        self.inlineParser = InlineParser(text: text, rules: rules)
    }

    // MARK: - Line classification

    struct LinePrefix {
        var quoteLevel = 0
        var quoteMarkers: [NSRange] = []
        var contentStart: Int
    }

    /// Strips `>` markers from the start of a line. Each `>` may be followed by one space.
    func quotePrefix(of line: Line) -> LinePrefix {
        var i = line.start
        var p = LinePrefix(contentStart: line.start)
        while i < line.end {
            var j = i
            var spaces = 0
            while j < line.end && text[j] == CU.space && spaces < 3 { j += 1; spaces += 1 }
            guard j < line.end, text[j] == CU.gt else { break }
            var markerEnd = j + 1
            if markerEnd < line.end && text[markerEnd] == CU.space { markerEnd += 1 }
            p.quoteMarkers.append(NSRange(location: i, length: markerEnd - i))
            p.quoteLevel += 1
            i = markerEnd
        }
        p.contentStart = i
        return p
    }

    enum Kind {
        case blank
        case heading(level: Int, markerStart: Int, markerEnd: Int)
        case thematicBreak
        case fenceOpen(language: String, fenceChar: UInt16, fenceLength: Int)
        case listItem(ordered: Bool, number: Int, task: PMKTaskState, indentColumns: Int, markerStart: Int, markerEnd: Int)
        case text(indentColumns: Int)
    }

    func indentColumns(from start: Int, to end: Int) -> (columns: Int, offset: Int) {
        var cols = 0
        var i = start
        while i < end {
            if text[i] == CU.space { cols += 1 }
            else if text[i] == CU.tab { cols += tabWidth - (cols % tabWidth) }
            else { break }
            i += 1
        }
        return (cols, i)
    }

    func classify(_ line: Line, from contentStart: Int) -> Kind {
        let (cols, i) = indentColumns(from: contentStart, to: line.end)
        if i >= line.end { return .blank }
        let c = text[i]

        // ATX heading: 1-6 '#' followed by space (or end of line)
        if c == CU.hash && cols < 4 {
            var j = i
            while j < line.end && text[j] == CU.hash && j - i < 7 { j += 1 }
            let level = j - i
            if level <= 6 && (j == line.end || CU.isSpaceOrTab(text[j])) {
                var markerEnd = j
                if markerEnd < line.end && CU.isSpaceOrTab(text[markerEnd]) { markerEnd += 1 }
                return .heading(level: level, markerStart: i, markerEnd: markerEnd)
            }
        }

        // Fence
        if (c == CU.backtick || c == CU.tilde) && cols < 4 {
            var j = i
            while j < line.end && text[j] == c { j += 1 }
            let len = j - i
            if len >= 3 {
                var k = j
                while k < line.end && CU.isSpaceOrTab(text[k]) { k += 1 }
                var langEnd = k
                while langEnd < line.end && !CU.isSpaceOrTab(text[langEnd]) { langEnd += 1 }
                let lang = String(utf16CodeUnits: Array(text[k..<langEnd]), count: langEnd - k)
                if !(c == CU.backtick && lang.contains("`")) {
                    return .fenceOpen(language: lang, fenceChar: c, fenceLength: len)
                }
            }
        }

        // Thematic break: 3+ of the same -, *, _ with optional spaces, nothing else
        if (c == CU.dash || c == CU.star || c == CU.underscore) && cols < 4 {
            var j = i
            var count = 0
            var ok = true
            while j < line.end {
                if text[j] == c { count += 1 } else if !CU.isSpaceOrTab(text[j]) { ok = false; break }
                j += 1
            }
            if ok && count >= 3 { return .thematicBreak }
        }

        // Bullet list item
        if c == CU.dash || c == CU.star || c == CU.plus {
            if i + 1 == line.end {
                return .listItem(ordered: false, number: 0, task: .notTask, indentColumns: cols, markerStart: i, markerEnd: line.end)
            }
            if CU.isSpaceOrTab(text[i + 1]) {
                var markerEnd = i + 2
                var task = PMKTaskState.notTask
                // task: "[ ]" / "[x]" followed by space or end of line
                if markerEnd + 2 < line.end, text[markerEnd] == CU.lbracket, text[markerEnd + 2] == CU.rbracket,
                   markerEnd + 3 == line.end || CU.isSpaceOrTab(text[markerEnd + 3]) {
                    let inner = text[markerEnd + 1]
                    if inner == CU.space || inner == CU.x || inner == CU.X {
                        task = inner == CU.space ? .open : .completed
                        markerEnd += (markerEnd + 3 < line.end) ? 4 : 3
                    }
                }
                return .listItem(ordered: false, number: 0, task: task, indentColumns: cols, markerStart: i, markerEnd: markerEnd)
            }
        }
        // Ordered list item
        if CU.isDigit(c) {
            var j = i
            var number = 0
            while j < line.end && CU.isDigit(text[j]) && j - i < 9 { number = number * 10 + Int(text[j] - 0x30); j += 1 }
            if j < line.end && (text[j] == CU.dot || text[j] == CU.rparen) {
                if j + 1 == line.end {
                    return .listItem(ordered: true, number: number, task: .notTask, indentColumns: cols, markerStart: i, markerEnd: line.end)
                }
                if CU.isSpaceOrTab(text[j + 1]) {
                    return .listItem(ordered: true, number: number, task: .notTask, indentColumns: cols, markerStart: i, markerEnd: j + 2)
                }
            }
        }
        return .text(indentColumns: cols)
    }

    private func isBlank(_ li: Int, atQuoteLevel q: Int) -> Bool {
        let p = quotePrefix(of: lines[li])
        guard p.quoteLevel == q else { return false }
        if case .blank = classify(lines[li], from: p.contentStart) { return true }
        return false
    }

    // MARK: - Parsing

    func parse() -> PMKASTNode {
        let root = PMKASTNode(type: .document, range: NSRange(location: 0, length: text.count))
        parseBlocks(into: root, lineRange: 0..<lines.count, quoteLevel: 0, listLevel: 0)
        return root
    }

    /// Parses top-level blocks from `lineIndex` on, and stops once `stopAfter` accepts a finished block.
    func parseBlocks(from lineIndex: Int, into root: PMKASTNode, stopAfter: @escaping (PMKASTNode) -> Bool) {
        parseBlocks(into: root, lineRange: lineIndex..<lines.count, quoteLevel: 0, listLevel: 0, stopAfter: stopAfter)
    }

    /// The line that starts at `offset`, which must be a line start.
    func lineIndex(at offset: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    struct TableCellRange { let cell: NSRange; let content: NSRange }

    /// Pipe positions of a table row (leading / trailing pipes optional, escaped pipes ignored).
    func tablePipeRanges(of line: Line, contentStart: Int) -> [NSRange] {
        var out: [NSRange] = []
        var i = contentStart
        var inCode = false
        while i < line.end {
            let c = text[i]
            if c == CU.backslash { i += 2; continue }
            if c == CU.backtick { inCode.toggle() }
            if c == 0x7C, !inCode { out.append(NSRange(location: i, length: 1)) }
            i += 1
        }
        return out
    }

    /// Cells of a table row, or nil when the line holds no pipe.
    func tableCells(of line: Line, contentStart: Int) -> [TableCellRange]? {
        var s = contentStart
        while s < line.end, CU.isSpaceOrTab(text[s]) { s += 1 }
        var e = line.end
        while e > s, CU.isSpaceOrTab(text[e - 1]) { e -= 1 }
        guard s < e else { return nil }
        let pipes = tablePipeRanges(of: line, contentStart: s).map { $0.location }
        guard !pipes.isEmpty else { return nil }
        var bounds: [Int] = []
        if pipes.first != s { bounds.append(s - 1) }        // virtual leading pipe
        bounds.append(contentsOf: pipes)
        if pipes.last != e - 1 { bounds.append(e) }         // virtual trailing pipe
        var cells: [TableCellRange] = []
        for k in 0..<(bounds.count - 1) {
            let cs = bounds[k] + 1, ce = bounds[k + 1]
            guard ce >= cs else { continue }
            var ts = cs, te = ce
            while ts < te, CU.isSpaceOrTab(text[ts]) { ts += 1 }
            while te > ts, CU.isSpaceOrTab(text[te - 1]) { te -= 1 }
            cells.append(TableCellRange(cell: NSRange(location: cs, length: ce - cs), content: NSRange(location: ts, length: te - ts)))
        }
        return cells.isEmpty ? nil : cells
    }

    /// Delimiter-row cells (`---`, `:--`, `--:`, `:-:`), or nil when any cell is not a delimiter.
    func tableDelimiterCells(of line: Line, contentStart: Int) -> [TableCellRange]? {
        guard let cells = tableCells(of: line, contentStart: contentStart) else { return nil }
        for c in cells {
            guard c.content.length >= 1 else { return nil }
            var dashes = 0
            for i in c.content.location..<NSMaxRange(c.content) {
                let ch = text[i]
                if ch == CU.dash { dashes += 1 } else if ch == CU.colon, i == c.content.location || i == NSMaxRange(c.content) - 1 { continue } else { return nil }
            }
            if dashes == 0 { return nil }
        }
        return cells
    }

    /// Alignment values: left 0, center 1, right 2, natural 4.
    func tableAlignment(ofDelimiter c: TableCellRange) -> Int {
        let left = text[c.content.location] == CU.colon
        let right = text[NSMaxRange(c.content) - 1] == CU.colon && c.content.length > 1
        switch (left, right) {
        case (true, true): return 1
        case (true, false): return 0
        case (false, true): return 2
        default: return 4
        }
    }

    static let calloutTypeNames = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    /// The first line of a blockquote starting with `[!TYPE]` (case-insensitive,
    /// local indent < 4, followed by space / tab / end of line) turns the quote into a callout.
    private func recognizeCallout(in quote: PMKASTNode, firstLine line: Line) {
        let p = quotePrefix(of: line)
        var i = p.contentStart
        var indent = 0
        while i < line.end, CU.isSpaceOrTab(text[i]) { indent += text[i] == CU.tab ? 4 : 1; i += 1 }
        guard indent < 4, i + 2 < line.end, text[i] == CU.lbracket, text[i + 1] == CU.bang else { return }
        var j = i + 2
        while j < line.end, text[j] != CU.rbracket { j += 1 }
        guard j < line.end else { return }
        let name = String(utf16CodeUnits: Array(text[(i + 2)..<j]), count: j - i - 2).uppercased()
        guard let type = BlockParser.calloutTypeNames.firstIndex(of: name) else { return }
        let afterMarker = j + 1
        guard afterMarker == line.end || CU.isSpaceOrTab(text[afterMarker]) else { return }
        // title = rest of the line, trimmed
        var ts = afterMarker, te = line.end
        while ts < te, CU.isSpaceOrTab(text[ts]) { ts += 1 }
        while te > ts, CU.isSpaceOrTab(text[te - 1]) { te -= 1 }
        let head = PMKASTNode(type: .calloutHead, range: NSRange(location: line.start, length: line.nextStart - line.start))
        head.level = type
        head.markerRanges = [NSRange(location: i, length: afterMarker - i)]
        head.contentRange = NSRange(location: ts, length: te - ts)
        quote.calloutType = type
        // the first paragraph now starts after the head line (or disappears when it was only the head line)
        if let first = quote.children.first, first.type == .paragraph {
            if NSMaxRange(first.range) <= line.nextStart {
                quote.children.removeFirst()
            } else {
                let rest = NSRange(location: line.nextStart, length: NSMaxRange(first.range) - line.nextStart)
                let para = PMKASTNode(type: .paragraph, range: rest)
                para.parent = quote
                inlineParser.parseInlines(in: rest, into: para)
                quote.children[0] = para
            }
        }
        head.parent = quote
        quote.children.insert(head, at: 0)
    }

    /// `foldMarkerMarkdown` = `<!-- {"fold":true} -->` (22 UTF-16 units).
    public static let foldMarkerText: [UInt16] = Array("<!-- {\"fold\":true} -->".utf16)

    /// Range of the fold comment when it ends exactly at `lineEnd` and starts at or after `minStart`.
    func foldMarkerRange(lineEnd: Int, minStart: Int) -> NSRange? {
        let m = BlockParser.foldMarkerText
        let start = lineEnd - m.count
        guard start >= minStart, start >= 0 else { return nil }
        for i in 0..<m.count where text[start + i] != m[i] { return nil }
        return NSRange(location: start, length: m.count)
    }

    /// Parses `lines[lineRange]` as a sequence of blocks living at `quoteLevel`.
    /// `listLevel` is the nesting level of the list item we are inside (0 = none).
    private func parseBlocks(into parent: PMKASTNode, lineRange: Range<Int>, quoteLevel: Int, listLevel: Int,
                             stopAfter: ((PMKASTNode) -> Bool)? = nil) {
        var li = lineRange.lowerBound
        let endLine = lineRange.upperBound
        var seen = parent.children.count

        while li < endLine {
            if let stopAfter, parent.children.count > seen {
                seen = parent.children.count
                if stopAfter(parent.children[seen - 1]) { return }
            }
            let line = lines[li]
            let prefix = quotePrefix(of: line)

            // ---- Blockquote: run of lines quoted deeper than our level (+ lazy continuation lines)
            if prefix.quoteLevel > quoteLevel {
                var lj = li
                var last = li
                while lj < endLine {
                    let p = quotePrefix(of: lines[lj])
                    if p.quoteLevel > quoteLevel { last = lj; lj += 1; continue }
                    // lazy continuation: plain text line directly after a quoted paragraph line
                    if p.quoteLevel == quoteLevel, lj == last + 1, case .text = classify(lines[lj], from: p.contentStart) {
                        let prev = quotePrefix(of: lines[last])
                        if case .text = classify(lines[last], from: prev.contentStart) { last = lj; lj += 1; continue }
                    }
                    break
                }
                let quoteLines = li..<(last + 1)
                let node = PMKASTNode(type: .blockquote, range: rangeOf(lines: quoteLines))
                node.level = quoteLevel + 1
                for k in quoteLines {
                    let p = quotePrefix(of: lines[k])
                    if p.quoteMarkers.count > quoteLevel { node.markerRanges.append(p.quoteMarkers[quoteLevel]) }
                }
                parent.add(node)
                parseBlocks(into: node, lineRange: quoteLines, quoteLevel: quoteLevel + 1, listLevel: 0)
                recognizeCallout(in: node, firstLine: lines[li])
                li = last + 1
                continue
            }

            let kind = classify(line, from: prefix.contentStart)
            switch kind {
            case .blank:
                li += 1

            case .heading(let level, let markerStart, let markerEnd):
                let node = PMKASTNode(type: .heading, range: rangeOf(lines: li..<(li + 1)))
                node.level = level
                node.markerRanges = [NSRange(location: markerStart, length: markerEnd - markerStart)]
                var contentEnd = line.end
                // The fold comment must be the last thing before the line ending.
                if let fm = foldMarkerRange(lineEnd: line.end, minStart: markerEnd) {
                    let marker = PMKASTNode(type: .foldMarker, range: fm)
                    node.add(marker)
                    contentEnd = fm.location
                }
                var k = contentEnd
                while k > markerEnd && CU.isSpaceOrTab(text[k - 1]) { k -= 1 }
                var h = k
                while h > markerEnd && text[h - 1] == CU.hash { h -= 1 }
                if h < k && (h == markerEnd || CU.isSpaceOrTab(text[h - 1])) {
                    node.markerRanges.append(NSRange(location: h, length: contentEnd - h))
                    contentEnd = h
                }
                node.contentRange = NSRange(location: markerEnd, length: max(0, contentEnd - markerEnd))
                inlineParser.parseInlines(in: node.contentRange, into: node)
                parent.add(node)
                li += 1

            case .thematicBreak:
                let node = PMKASTNode(type: .thematicBreak, range: rangeOf(lines: li..<(li + 1)))
                node.markerRanges = [NSRange(location: prefix.contentStart, length: line.end - prefix.contentStart)]
                parent.add(node)
                li += 1

            case .fenceOpen(let language, let fenceChar, let fenceLength):
                var lj = li + 1
                var closed = false
                while lj < endLine {
                    let p = quotePrefix(of: lines[lj])
                    if p.quoteLevel != quoteLevel { break }
                    if isClosingFence(lines[lj], from: p.contentStart, char: fenceChar, minLength: fenceLength) { closed = true; break }
                    lj += 1
                }
                let lastLine = closed ? lj : min(lj, endLine) - 1
                let node = PMKASTNode(type: .fencedCode, range: rangeOf(lines: li..<(lastLine + 1)))
                node.language = language
                node.closed = closed
                node.markerRanges = [NSRange(location: prefix.contentStart, length: line.end - prefix.contentStart)]
                if closed {
                    let cl = lines[lj]
                    let cp = quotePrefix(of: cl)
                    node.markerRanges.append(NSRange(location: cp.contentStart, length: cl.end - cp.contentStart))
                    node.contentRange = NSRange(location: line.nextStart, length: max(0, cl.start - line.nextStart))
                } else {
                    node.contentRange = NSRange(location: line.nextStart, length: max(0, NSMaxRange(node.range) - line.nextStart))
                }
                parent.add(node)
                li = lastLine + 1

            case .listItem(let ordered, let firstNumber, _, let cols0, _, _):
                let listNode = PMKASTNode(type: .list, range: NSRange(location: 0, length: 0))
                listNode.ordered = ordered
                listNode.level = listLevel + 1
                var itemNumber = ordered ? firstNumber : 0
                var lj = li
                var listEndLine = li
                while lj < endLine {
                    let l = lines[lj]
                    let p = quotePrefix(of: l)
                    guard p.quoteLevel == quoteLevel,
                          case .listItem(let o, _, let t, let cols, let ms, let me) = classify(l, from: p.contentStart),
                          o == ordered, cols == cols0 else { break }

                    // Continuation lines of this item
                    var lk = lj + 1
                    var lastContent = lj
                    while lk < endLine {
                        let cl = lines[lk]
                        let cp = quotePrefix(of: cl)
                        if cp.quoteLevel < quoteLevel { break }
                        let ck = classify(cl, from: cp.contentStart)
                        if case .blank = ck {
                            var look = lk + 1
                            while look < endLine, isBlank(look, atQuoteLevel: quoteLevel) { look += 1 }
                            if look < endLine {
                                let lp = quotePrefix(of: lines[look])
                                let (lcols, _) = indentColumns(from: lp.contentStart, to: lines[look].end)
                                if lp.quoteLevel == quoteLevel && lcols > cols { lk = look; continue }
                            }
                            break
                        }
                        let (ccols, _) = indentColumns(from: cp.contentStart, to: cl.end)
                        if cp.quoteLevel > quoteLevel {
                            if ccols > cols || lk == lastContent + 1 { lastContent = lk; lk += 1; continue }
                            break
                        }
                        if case .listItem(_, _, _, let ncols, _, _) = ck {
                            if ncols > cols { lastContent = lk; lk += 1; continue }
                            break
                        }
                        if ccols > cols { lastContent = lk; lk += 1; continue }
                        if case .text = ck, lk == lastContent + 1 { lastContent = lk; lk += 1; continue }
                        break
                    }

                    let itemLines = lj..<(lastContent + 1)
                    let item = PMKASTNode(type: .listItem, range: rangeOf(lines: itemLines))
                    item.ordered = ordered
                    item.task = t
                    item.level = listNode.level
                    if ordered { item.number = itemNumber; itemNumber += 1 }
                    item.markerRanges = [NSRange(location: ms, length: me - ms)]
                    if ms > p.contentStart { item.indentRange = NSRange(location: p.contentStart, length: ms - p.contentStart) }
                    item.contentRange = NSRange(location: me, length: NSMaxRange(item.range) - me)
                    var firstLineEnd = l.end
                    if let fm = foldMarkerRange(lineEnd: l.end, minStart: me) {
                        item.add(PMKASTNode(type: .foldMarker, range: fm))
                        firstLineEnd = fm.location
                    }
                    inlineParser.parseInlines(in: NSRange(location: me, length: max(0, firstLineEnd - me)), into: item)
                    if itemLines.count > 1 {
                        parseBlocks(into: item, lineRange: (lj + 1)..<(lastContent + 1), quoteLevel: quoteLevel, listLevel: item.level)
                    }
                    listNode.add(item)
                    listEndLine = lastContent
                    lj = lastContent + 1

                    // Loose list: blank lines followed by a sibling item stay inside the list
                    var blankRun = lj
                    while blankRun < endLine, isBlank(blankRun, atQuoteLevel: quoteLevel) { blankRun += 1 }
                    if blankRun > lj, blankRun < endLine {
                        let np = quotePrefix(of: lines[blankRun])
                        if np.quoteLevel == quoteLevel,
                           case .listItem(let o2, _, _, let c2, _, _) = classify(lines[blankRun], from: np.contentStart),
                           o2 == ordered, c2 == cols0 {
                            lj = blankRun
                        }
                    }
                }
                listNode.range = rangeOf(lines: li..<(listEndLine + 1))
                parent.add(listNode)
                li = listEndLine + 1

            case .text:
                // ---- Table: a header row followed by a delimiter row with the same number of cells.
                // A line joins only once it ends in a newline, so a row still being typed stays text.
                if li + 1 < endLine, let header = tableCells(of: line, contentStart: prefix.contentStart),
                   lines[li + 1].end < text.count,
                   quotePrefix(of: lines[li + 1]).quoteLevel == quoteLevel,
                   let delimiter = tableDelimiterCells(of: lines[li + 1], contentStart: quotePrefix(of: lines[li + 1]).contentStart),
                   header.count == delimiter.count {
                    var lj = li + 2
                    while lj < endLine {
                        let l = lines[lj]
                        let p = quotePrefix(of: l)
                        guard l.end < text.count, p.quoteLevel == quoteLevel, case .text = classify(l, from: p.contentStart), tableCells(of: l, contentStart: p.contentStart) != nil else { break }
                        lj += 1
                    }
                    let table = PMKASTNode(type: .table, range: rangeOf(lines: li..<lj))
                    let alignments = delimiter.map { tableAlignment(ofDelimiter: $0) }
                    for k in li..<lj {
                        let l = lines[k]
                        let p = quotePrefix(of: l)
                        let row = PMKASTNode(type: .tableRow, range: NSRange(location: l.start, length: l.nextStart - l.start))
                        let cells = (k == li + 1 ? delimiter : (tableCells(of: l, contentStart: p.contentStart) ?? []))
                        row.markerRanges = tablePipeRanges(of: l, contentStart: p.contentStart)
                        for (ci, cell) in cells.enumerated() where ci < alignments.count {
                            let c = PMKASTNode(type: .tableCell, range: cell.cell)
                            c.contentRange = cell.content
                            c.level = k == li + 1 ? alignments[ci] : alignments[ci]
                            row.add(c)
                            if k != li + 1, cell.content.length > 0 { inlineParser.parseInlines(in: cell.content, into: c) }
                        }
                        table.add(row)
                    }
                    table.level = alignments.count   // column count
                    parent.add(table)
                    li = lj
                    continue
                }
                var lj = li + 1
                while lj < endLine {
                    let l = lines[lj]
                    let p = quotePrefix(of: l)
                    guard p.quoteLevel == quoteLevel, case .text = classify(l, from: p.contentStart) else { break }
                    lj += 1
                }
                let node = PMKASTNode(type: .paragraph, range: rangeOf(lines: li..<lj))
                let (_, cs) = indentColumns(from: prefix.contentStart, to: line.end)
                node.contentRange = NSRange(location: cs, length: NSMaxRange(node.range) - cs)
                inlineParser.parseInlines(in: node.contentRange, into: node, excluding: quoteMarkerRanges(in: li..<lj, level: quoteLevel))
                parent.add(node)
                li = lj
            }
        }
    }

    private func quoteMarkerRanges(in lineRange: Range<Int>, level: Int) -> [NSRange] {
        guard level > 0 else { return [] }
        var out: [NSRange] = []
        for k in lineRange {
            let p = quotePrefix(of: lines[k])
            if p.contentStart > lines[k].start {
                out.append(NSRange(location: lines[k].start, length: p.contentStart - lines[k].start))
            }
        }
        return out
    }

    private func isClosingFence(_ line: Line, from start: Int, char: UInt16, minLength: Int) -> Bool {
        let (cols, i) = indentColumns(from: start, to: line.end)
        guard cols < 4, i < line.end, text[i] == char else { return false }
        var j = i
        while j < line.end && text[j] == char { j += 1 }
        guard j - i >= minLength else { return false }
        while j < line.end { if !CU.isSpaceOrTab(text[j]) { return false }; j += 1 }
        return true
    }

    /// Range covering the given lines including the newline that terminates the last one (if any).
    private func rangeOf(lines lr: Range<Int>) -> NSRange {
        let first = lines[lr.lowerBound]
        let last = lines[lr.upperBound - 1]
        return NSRange(location: first.start, length: last.nextStart - first.start)
    }
}
