import AppKit
import MDTextKit
import PolarMark
import SFThemeKit

/// `TableAttachmentViewController` + `TableAttachmentViewLayout` + `TableAttachmentView` — builds the cell
/// model from the table markdown, fits the column widths, and renders the grid into the attachment image.
/// (The grid itself is an image; cells are edited through an overlaid text view.)
@MainActor public final class MDTableAttachmentRenderer {
    public struct Cell { public var text: NSAttributedString; public var alignment: Int }

    public weak var editorController: MDEditorController?
    public var maxAvailableWidth: () -> CGFloat = { 500 }
    public var rowColor: NSColor = .white
    public var alternateRowColor: NSColor = .white
    public var borderColor: NSColor = .lightGray

    public init() {}

    // MARK: Model

    public func model(from src: NSAttributedString) -> (rows: [[Cell]], columns: Int) {
        var rows: [[Cell]] = []
        var alignData: [Int] = []
        var columns = 0
        src.enumerateTable(in: NSRange(location: 0, length: src.length), options: [], tableBlock: { _, rowCount, columnCount, _ in
            columns = columnCount
            rows = Array(repeating: Array(repeating: Cell(text: NSAttributedString(string: ""), alignment: 0), count: columnCount), count: max(1, rowCount))
        }, cellBlock: { content, row, col, align, _ in
            guard col < columns, NSMaxRange(content) <= src.length else { return }
            let text = src.attributedSubstring(from: content)
            if row == 0 {
                rows[0][col] = Cell(text: text, alignment: 0)
            } else if row == 1 {
                alignData.append(align)
                if col < rows[0].count { rows[0][col].alignment = align }
            } else if row - 1 < rows.count {
                rows[row - 1][col] = Cell(text: text, alignment: col < alignData.count ? alignData[col] : 4)
            }
        })
        return (rows, columns)
    }

    /// Attachments copied, links stripped, header semibold,
    /// markdown hidden, `<br>` → newline, alignment applied.
    public func displayString(for cell: Cell, row: Int, renderer: MDAttributedStringRenderer) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: cell.text)
        let all = NSRange(location: 0, length: m.length)
        m.removeAttribute(.link, range: all)
        if row == 0 { m.addFontWeight(NSFont.Weight.semibold.rawValue, in: all) }
        if row == 0, m.length > 0, let font = m.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, !font.isBold,
           font.fontName.hasPrefix(".") {
            // The system family answers no descriptor weight; it has its own semibold.
            m.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), range: all)
        }
        if let ec = editorController, m.length > 0 { _ = ec.hideMarkdown(in: NSRange(location: 0, length: m.length), in: m) }
        while let r = m.string.range(of: "<br ?/?>", options: .regularExpression) {
            m.replaceCharacters(in: NSRange(r, in: m.string), with: "\n")
        }
        let ps = NSMutableParagraphStyle()
        ps.alignment = [0: .left, 1: .center, 2: .right][cell.alignment] ?? .natural
        ps.lineSpacing = (renderer.defaultTextAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0
        ps.minimumLineHeight = (renderer.defaultTextAttributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0
        m.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: m.length))
        if m.length == 0 { m.append(NSAttributedString(string: " ", attributes: renderer.defaultTextAttributes.merging([.paragraphStyle: ps]) { $1 })) }
        return m
    }

    // MARK: Layout

    public struct Layout {
        public var rects: [[CGRect]]
        public var widths: [CGFloat]
        public var heights: [CGFloat]
        public var contentSize: CGSize
        public var display: [[NSAttributedString]]
        public var pad: CGSize
        public var borderWidth: CGFloat
        public var cornerRadius: CGFloat
        public func indexPath(for point: CGPoint) -> (row: Int, column: Int)? {
            for (r, row) in rects.enumerated() { for (c, rect) in row.enumerated() where rect.insetBy(dx: -borderWidth, dy: 0).contains(point) { return (r, c) } }
            return nil
        }
    }

    public func render(_ att: MDTableTextAttachment) {
        let (rows, columns) = model(from: att.representedAttributedText)
        guard let layout = layout(rows: rows, columns: columns) else { return }
        att.temporaryImage = image(for: layout)
        att.attachmentSize = layout.contentSize
    }

    /// Column fitting and row heights.
    public func layout(rows: [[Cell]], columns: Int) -> Layout? {
        guard let renderer = editorController?.attributedStringRenderer else { return nil }
        guard columns > 0, !rows.isEmpty else { return nil }
        let F = renderer.defaultFontSize, P = renderer.defaultPointsize
        let pad = CGSize(width: ceil(F), height: ceil(F * 0.4))
        let borderWidth = P
        let cornerRadius = ceil(F * 0.25)
        let columnMinWidth = 2 * pad.width + 2 * F
        let tableMaxWidth = maxAvailableWidth()
        let minVisibleColumns = Int((tableMaxWidth / (2 * pad.width + 16 * F)).rounded())
        let comfortVisibleColumns = max(1, Int((tableMaxWidth / (2 * pad.width + 8 * F)).rounded()))
        let display: [[NSAttributedString]] = rows.enumerated().map { ri, row in row.map { displayString(for: $0, row: ri, renderer: renderer) } }
        let lineSpacing = (renderer.defaultTextAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0
        let rowMinHeight = display[0][0].boundingRect(with: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).integral.height + 2 * pad.height + lineSpacing

        let avail = tableMaxWidth - CGFloat(columns + 1) * borderWidth
        let comfortW = floor(avail / CGFloat(comfortVisibleColumns))
        let maxW = floor(avail / CGFloat(minVisibleColumns > 0 ? minVisibleColumns : comfortVisibleColumns))
        func naturalWidth(_ c: Int) -> CGFloat {
            var w: CGFloat = 0
            for r in display { w = max(w, r[c].boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).integral.width + 2 * pad.width) }
            return w
        }
        var nat: [CGFloat] = [], minW: [CGFloat] = [], comf: [CGFloat] = [], growA: [CGFloat] = [], growB: [CGFloat] = []
        for c in 0..<columns {
            let n = naturalWidth(c)
            let mi = max(columnMinWidth, min(maxW, n))
            let co = max(mi, max(comfortW, min(max(avail, comfortW), n)))
            nat.append(n); minW.append(mi); comf.append(co)
            growA.append(max(min(co, comfortW) - mi, 0))
            growB.append(max(co - max(comfortW, mi), 0))
        }
        var widths = comf
        let eps: CGFloat = 1e-5
        let sumComf = comf.reduce(0, +), sumMin = minW.reduce(0, +), sumGrowB = growB.reduce(0, +)
        if sumComf <= avail + eps {
            // keep comfortable widths
        } else if sumMin + sumGrowB <= avail + eps {
            // shrink: take equally from columns with padding growth, each capped by its growA
            var excess = sumComf - avail
            var room = growA
            while excess > eps {
                let candidates = room.indices.filter { room[$0] > eps }
                if candidates.isEmpty { break }
                let share = excess / CGFloat(candidates.count)
                var taken: CGFloat = 0
                for i in candidates { let t = min(share, room[i]); widths[i] -= t; room[i] -= t; taken += t }
                if taken <= eps { break }
                excess -= taken
            }
        } else if sumMin <= avail + eps {
            widths = minW
            var free = avail - sumMin
            var cap = growB
            while free > eps {
                let candidates = cap.indices.filter { cap[$0] > eps }
                if candidates.isEmpty { break }
                let total = candidates.reduce(CGFloat(0)) { $0 + max(nat[$1] - minW[$1], eps) }
                var given: CGFloat = 0
                for i in candidates {
                    let g = min(free * max(nat[i] - minW[i], eps) / total, cap[i])
                    widths[i] += g; cap[i] -= g; given += g
                }
                if given <= eps { break }
                free -= given
            }
        } else {
            for c in 0..<columns { widths[c] = max(columnMinWidth, min(floor(0.8 * avail), max(nat[c], minW[c]))) }
        }
        // finalize: truncate and distribute a small residue one point at a time
        widths = widths.map { $0.rounded(.towardZero) }
        var d = avail - widths.reduce(0, +)
        if d != 0, abs(d) <= 10 {
            var i = 0
            while d != 0 && columns > 0 { widths[i % columns] += d > 0 ? 1 : -1; d += d > 0 ? -1 : 1; i += 1 }
        }
        var heights: [CGFloat] = []
        for (ri, row) in display.enumerated() {
            var h: CGFloat = 0
            for (c, cell) in row.enumerated() {
                let r = cell.boundingRect(with: CGSize(width: widths[c] - 2 * pad.width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).integral
                h = max(h, r.height + lineSpacing)
            }
            heights.append(max(rowMinHeight, h + 2 * pad.height))
            _ = ri
        }
        var rects: [[CGRect]] = []
        var y: CGFloat = 0
        for h in heights {
            var x: CGFloat = 0
            var rowRects: [CGRect] = []
            for w in widths { rowRects.append(CGRect(x: x, y: y, width: w, height: h)); x += w + borderWidth }
            rects.append(rowRects)
            y += h
        }
        let contentSize = CGSize(width: max(0, (rects.last?.last?.maxX ?? 0)), height: max(0, y))
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        return Layout(rects: rects, widths: widths, heights: heights, contentSize: contentSize, display: display, pad: pad, borderWidth: borderWidth, cornerRadius: cornerRadius)
    }

    /// `TableAttachmentView.tableImage(for:)` / `drawTable` plus the layer border.
    /// `blanking` leaves one cell's text out: the cell editor draws it, over the same fill.
    public func image(for layout: Layout, blanking: (row: Int, column: Int)? = nil) -> NSImage {
        let contentSize = layout.contentSize, rects = layout.rects, display = layout.display
        let pad = layout.pad, borderWidth = layout.borderWidth, cornerRadius = layout.cornerRadius
        let image = NSImage(size: contentSize, flipped: true) { [self] _ in
            let clip = NSBezierPath(roundedRect: CGRect(origin: .zero, size: contentSize), xRadius: cornerRadius, yRadius: cornerRadius)
            clip.addClip()
            // Cells first, then the lines between columns: a translucent cell colour keeps its own tone.
            borderColor.setFill()
            for rect in rects.first ?? [] where rect.maxX < contentSize.width {
                NSBezierPath(rect: CGRect(x: rect.maxX, y: 0, width: borderWidth, height: contentSize.height)).fill()
            }
            let storage = NSTextStorage()
            let lm = NSLayoutManager()
            let tc = NSTextContainer(size: .zero)
            tc.lineFragmentPadding = pad.width
            lm.addTextContainer(tc)
            storage.addLayoutManager(lm)
            for (ri, row) in display.enumerated() {
                for (ci, cell) in row.enumerated() {
                    let rect = rects[ri][ci]
                    (ri.isMultiple(of: 2) ? alternateRowColor : rowColor).setFill()
                    NSBezierPath(rect: rect).fill()
                    if let blanking, blanking.row == ri, blanking.column == ci { continue }
                    storage.setAttributedString(cell)
                    tc.size = CGSize(width: rect.width, height: max(1, rect.height - 2 * pad.height))
                    let glyphs = lm.glyphRange(for: tc)
                    lm.drawBackground(forGlyphRange: glyphs, at: NSPoint(x: rect.minX, y: rect.minY + pad.height))
                    lm.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: rect.minX, y: rect.minY + pad.height))
                }
            }
            let border = NSBezierPath(roundedRect: CGRect(origin: .zero, size: contentSize).insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: cornerRadius, yRadius: cornerRadius)
            borderColor.setStroke()
            border.lineWidth = borderWidth
            border.stroke()
            return true
        }
        return image
    }

    /// Theme keys used by the table.
    public func style(with tm: SFThemeManager) {
        rowColor = tm.color(forKey: "editor.table.cell background color", default: .white)
        alternateRowColor = tm.color(forKey: "editor.table.cell alternate background color", default: .white)
        borderColor = tm.color(forKey: "editor.table.border color", default: .lightGray)
    }
}
