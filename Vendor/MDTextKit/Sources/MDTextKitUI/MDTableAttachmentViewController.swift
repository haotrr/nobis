import AppKit
import MDTextKit
import PolarMark
import SFThemeKit

/// Rows of cells (header first, no delimiter row) plus column alignments.
@MainActor public final class MDTableDataModel {
    public typealias Cell = MDTableAttachmentRenderer.Cell
    public var rows: [[Cell]]
    public var alignments: [Int]
    public var separatorAttributes: [NSAttributedString.Key: Any]
    public var columns: Int { alignments.count }

    public init(rows: [[Cell]], columns: Int, separatorAttributes: [NSAttributedString.Key: Any]) {
        self.rows = rows
        self.alignments = (0..<columns).map { c in rows.first.map { c < $0.count ? $0[c].alignment : 4 } ?? 4 }
        self.separatorAttributes = separatorAttributes
    }

    /// Pipe table with 3…60-wide padded columns and alignment colons.
    public func markdown() -> String {
        func count(_ c: Cell) -> Int { c.text.stringByExpandingTextAttachments.count }
        var widths = [Int](repeating: 0, count: columns)
        for r in rows { for (c, cell) in r.enumerated() where c < columns { widths[c] = max(widths[c], count(cell)) } }
        var out = ""
        for (ri, r) in rows.enumerated() {
            var line = ""
            for c in 0..<columns {
                let text = Self.escapePipes(c < r.count ? r[c].text.stringByExpandingTextAttachments : "")
                let w = min(max(widths[c], 3), 60)
                let pad = w - (c < r.count ? count(r[c]) : 0)
                line += "| " + text + String(repeating: " ", count: max(pad, 0)) + " "
            }
            line += "|"
            out += line
            if ri == 0 {
                out += "\n"
                for c in 0..<columns {
                    let w = min(max(widths[c], 3), 60)
                    let a = alignments[c]
                    let L = a == 1 || a == 0 && false ? ":" : (a == 1 ? ":" : "")
                    let R = (a == 1 || a == 2) ? ":" : ""
                    out += "|" + L + String(repeating: "-", count: max(1, w - L.count - R.count + 2)) + R
                }
                out += "|"
            }
            if ri != rows.count - 1 { out += "\n" }
        }
        return out
    }

    private static func escapePipes(_ text: String) -> String {
        var result = ""
        var backslashes = 0
        for character in text {
            if character == "|", backslashes.isMultiple(of: 2) { result.append("\\") }
            result.append(character)
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        return result
    }

    public func csv() -> String {
        rows.map { r in r.map { c in
            let t = c.text.stringByExpandingTextAttachments.replacingOccurrences(of: "\"", with: "\"\"")
            return t.contains(",") || t.contains("\"") || t.contains("\n") ? "\"\(t)\"" : t
        }.joined(separator: ",") }.joined(separator: "\n")
    }

    public func html() -> String {
        var h = "<table style=\"border-collapse: collapse;\">\n"
        for (ri, r) in rows.enumerated() {
            let tag = ri == 0 ? "th" : "td"
            h += "<tr>" + r.map { "<\(tag)>\($0.text.stringByExpandingTextAttachments)</\(tag)>" }.joined() + "</tr>\n"
        }
        return h + "</table>"
    }

    private func emptyCell(_ alignment: Int) -> Cell { Cell(text: NSAttributedString(string: "", attributes: separatorAttributes), alignment: alignment) }

    public func update(row: Int, column: Int, text: NSAttributedString) {
        guard row < rows.count, column < rows[row].count else { return }
        rows[row][column].text = text
    }
    public func insertRow(at index: Int) { rows.insert((0..<columns).map { emptyCell(alignments[$0]) }, at: min(max(index, 1), rows.count)) }
    public func deleteRow(at index: Int) { guard rows.count > 1, index > 0, index < rows.count else { return }; rows.remove(at: index) }
    public func moveRow(from a: Int, to b: Int) { guard a > 0, b > 0, a < rows.count, b < rows.count else { return }; rows.swapAt(a, b) }
    public func insertColumn(at index: Int) {
        let i = min(max(index, 0), columns)
        alignments.insert(4, at: i)
        for r in 0..<rows.count { rows[r].insert(emptyCell(4), at: min(i, rows[r].count)) }
    }
    public func deleteColumn(at index: Int) {
        guard columns > 1, index < columns else { return }
        alignments.remove(at: index)
        for r in 0..<rows.count where index < rows[r].count { rows[r].remove(at: index) }
    }
    public func moveColumn(from a: Int, to b: Int) {
        guard a < columns, b < columns, a >= 0, b >= 0 else { return }
        alignments.swapAt(a, b)
        for r in 0..<rows.count where a < rows[r].count && b < rows[r].count { rows[r].swapAt(a, b) }
    }
    public func setAlignment(_ a: Int, forColumn c: Int) {
        guard c < columns else { return }
        alignments[c] = a
        for r in 0..<rows.count where c < rows[r].count { rows[r][c].alignment = a }
    }
}

/// The per-cell editor (inline-only parsing).
@MainActor final class MDTableCellTextView: MDTextView {
    weak var controller: MDTableAttachmentViewController?
    var indexPath = (row: 0, column: 0)

    override func insertTab(_ sender: Any?) { controller?.selectCell(dRow: 0, dColumn: 1, from: indexPath, caretAtEnd: false) }
    override func insertBacktab(_ sender: Any?) { controller?.selectCell(dRow: 0, dColumn: -1, from: indexPath, caretAtEnd: true) }
    override func moveUp(_ sender: Any?) {
        if isOnFirstLine { controller?.selectCell(dRow: -1, dColumn: 0, from: indexPath, caretAtEnd: true) } else { super.moveUp(sender) }
    }
    override func moveDown(_ sender: Any?) {
        if isOnLastLine { controller?.selectCell(dRow: 1, dColumn: 0, from: indexPath, caretAtEnd: false) } else { super.moveDown(sender) }
    }
    override func moveLeft(_ sender: Any?) {
        if selectedRange().location == 0, selectedRange().length == 0 { controller?.selectCell(dRow: 0, dColumn: -1, from: indexPath, caretAtEnd: true) } else { super.moveLeft(sender) }
    }
    override func moveRight(_ sender: Any?) {
        if NSMaxRange(selectedRange()) == string.utf16.count { controller?.selectCell(dRow: 0, dColumn: 1, from: indexPath, caretAtEnd: false) } else { super.moveRight(sender) }
    }
    override func cancelOperation(_ sender: Any?) { controller?.endEditing(returnFocus: true) }

    private var isOnFirstLine: Bool {
        guard let lm = layoutManager, let tc = textContainer else { return true }
        let g = lm.glyphIndexForCharacter(at: min(selectedRange().location, max(0, string.utf16.count - 1)))
        let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        return r.minY <= lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + 1
    }
    private var isOnLastLine: Bool {
        guard let lm = layoutManager, let tc = textContainer, string.utf16.count > 0 else { return true }
        let g = lm.glyphIndexForCharacter(at: min(selectedRange().location, string.utf16.count - 1))
        let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        let last = lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
        return r.maxY >= last.maxY - 1
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        Task { @MainActor [weak self] in
            guard let self, self.window?.firstResponder !== self else { return }
            if !(self.window?.firstResponder is MDTableCellTextView) { self.controller?.endEditing(returnFocus: false) }
        }
        return ok
    }
}

/// The cell editor's scroll view hands wheel events to the note.
@MainActor final class MDTableCellScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// The grid image plus hover "more" button and cell hit-testing.
@MainActor final class MDTableAttachmentView: NSView {
    weak var controller: MDTableAttachmentViewController?
    var image: NSImage? { didSet { needsDisplay = true } }
    let moreButton = NSButton(image: MDTableAttachmentView.verticalEllipsis, target: nil, action: nil)

    /// Three dots in a column; SF Symbols has no vertical ellipsis. A template, so it takes the button's tint.
    static let verticalEllipsis: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setFill()
            for y in [4.5, 9.5, 14.5] { NSBezierPath(ovalIn: NSRect(x: 8.75, y: y - 1.25, width: 2.5, height: 2.5)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Table options"
        return image
    }()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        moreButton.isBordered = false
        moreButton.isHidden = true
        moreButton.setFrameSize(NSSize(width: 20, height: 20))
        addSubview(moreButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Table")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { image?.draw(in: bounds) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    override func mouseEntered(with event: NSEvent) { moreButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { moreButton.isHidden = true }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let c = controller, let ip = c.layout?.indexPath(for: p), let rect = c.layout?.rects[ip.row][ip.column] else { return }
        c.moreButtonIndexPath = ip
        moreButton.setFrameOrigin(NSPoint(x: rect.maxX - moreButton.frame.width - 2, y: rect.midY - moreButton.frame.height / 2))
    }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let c = controller, let ip = c.layout?.indexPath(for: p) else { super.mouseDown(with: event); return }
        c.beginEditing(at: ip, clickPoint: p)
    }
}

/// `TableAttachmentViewController` (+ core) — owns the model, the grid view, the cell editor and the
/// debounced write-back of the markdown into the attachment.
@MainActor public final class MDTableAttachmentViewController: NSViewController {
    public weak var textAttachment: MDTableTextAttachment?
    public weak var hostTextView: MDTextView?
    public weak var hostEditorController: MDEditorController?
    public let themeManager: SFThemeManager
    public let gridRenderer: MDTableAttachmentRenderer
    public private(set) var model: MDTableDataModel
    public private(set) var layout: MDTableAttachmentRenderer.Layout?
    var moreButtonIndexPath: (row: Int, column: Int)?

    private let cellEditorController = MDEditorController()
    private var cellScrollView: NSScrollView?
    private var cellTextView: MDTableCellTextView?
    private var saveTask: Task<Void, Never>?
    private var tableView: MDTableAttachmentView { view as! MDTableAttachmentView }

    public init(attachment: MDTableTextAttachment, hostTextView: MDTextView, editorController: MDEditorController, gridRenderer: MDTableAttachmentRenderer, themeManager: SFThemeManager) {
        self.textAttachment = attachment
        self.hostTextView = hostTextView
        self.hostEditorController = editorController
        self.gridRenderer = gridRenderer
        self.themeManager = themeManager
        let (rows, columns) = gridRenderer.model(from: attachment.representedAttributedText)
        let attrs = attachment.representedAttributedText.length > 0 ? attachment.representedAttributedText.attributes(at: 0, effectiveRange: nil) : [:]
        self.model = MDTableDataModel(rows: rows, columns: columns, separatorAttributes: attrs)
        super.init(nibName: nil, bundle: nil)
        // SetupEditorController — inline-only cell editor without the table styler.
        cellEditorController.attributedStringRenderer.styleInlinesOnly = true
        cellEditorController.attributedStringRenderer.tableStyler.isEnabled = false
        cellEditorController.autoHideMarkdown = editorController.autoHideMarkdown
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let v = MDTableAttachmentView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))
        v.controller = self
        v.moreButton.target = self
        v.moreButton.action = #selector(showTableMenu(_:))
        view = v
        relayout(needsLayout: false)
    }

    // MARK: Layout / rendering

    public func relayout(needsLayout: Bool) {
        guard let att = textAttachment, let l = gridRenderer.layout(rows: model.rows, columns: model.columns) else { return }
        layout = l
        let image = gridRenderer.image(for: l, blanking: cellTextView?.indexPath)
        tableView.image = image
        att.temporaryImage = image
        // Border + corner radius live on the view's layer, so they
        // composite above the cell editors and the corners clip them.
        if let layer = tableView.layer {
            layer.cornerRadius = l.cornerRadius
            layer.borderWidth = l.borderWidth
            layer.borderColor = gridRenderer.borderColor.cgColor
            layer.masksToBounds = true
            layer.backgroundColor = gridRenderer.rowColor.cgColor
        }
        let sizeChanged = att.attachmentSize != l.contentSize
        att.attachmentSize = l.contentSize
        view.setFrameSize(l.contentSize)
        if let tv = cellTextView, let sv = cellScrollView { sv.frame = l.rects[tv.indexPath.row][tv.indexPath.column] }
        if needsLayout || sizeChanged { hostNeedsLayout() }
    }

    /// The host re-lays out the attachment character.
    private func hostNeedsLayout() {
        guard let host = hostTextView, let att = textAttachment else { return }
        let ts = host.mdTextStorage
        let r = ts.range(ofTextAttachment: att)
        guard r.location != NSNotFound else { return }
        host.mdLayoutManager.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        host.mdLayoutManager.ensureLayout(forCharacterRange: r)
        host.needsDisplay = true
        host.mdLayoutManager.rearrangeAttachmentsViews(forCharacterRange: r, at: host.textContainerOrigin)
    }

    /// Debug/self-test: edits a cell programmatically (used by `--debug-table-edit`).
    public func debugEdit(row: Int, column: Int, insert text: String) -> String {
        beginEditing(at: (row, column))
        guard let tv = cellTextView else { return "no editor" }
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText(text, replacementRange: tv.selectedRange())
        endEditing(returnFocus: true)
        return textAttachment?.representedText ?? "nil"
    }

    /// Enter the table at the last cell (caret at end) or the first cell.
    public func enter(fromRight: Bool) {
        guard !model.rows.isEmpty else { return }
        if fromRight {
            let row = model.rows.count - 1, col = max(0, model.columns - 1)
            beginEditing(at: (row, col))
            if let tv = cellTextView { tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0)) }
        } else {
            beginEditing(at: (0, 0))
            cellTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    // MARK: Cell editing

    public func beginEditing(at ip: (row: Int, column: Int), clickPoint: CGPoint? = nil) {
        guard let l = layout, ip.row < l.rects.count, ip.column < l.rects[ip.row].count else { return }
        if let tv = cellTextView, tv.indexPath == ip { tv.window?.makeFirstResponder(tv); return }
        endEditing(returnFocus: false)
        let rect = l.rects[ip.row][ip.column]
        let tv = MDTableCellTextView(frame: NSRect(origin: .zero, size: rect.size), editorController: cellEditorController)
        tv.controller = self
        tv.indexPath = ip
        tv.autoresizingMask = [.width, .height]
        tv.allowsUndo = true
        let sv = MDTableCellScrollView(frame: rect)
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller = false
        // Configure — theme, cell paddings, zero paragraph indent, alternating background.
        let r = cellEditorController.attributedStringRenderer
        r.styleObject(with: themeManager)
        r.setBodyParagraphIndent(0)   // the cell editor has no body paragraph indent
        tv.mdTextContainer.style(with: r, themeManager: themeManager)
        tv.mdLayoutManager.style(with: r, themeManager: themeManager)
        tv.typingAttributes = r.defaultTextAttributes
        tv.textContainerInset = NSSize(width: 0, height: l.pad.height)
        tv.mdTextContainer.lineFragmentPadding = l.pad.width
        tv.mdTextContainer.minInset = l.pad.width
        // The grid keeps the cell's fill and leaves its text out; the editor draws only the text.
        tv.drawsBackground = false
        tv.insertionPointColor = themeManager.color(forKey: "editor.cursor color", default: .textColor)
        let cell = model.rows[ip.row][ip.column]
        var md = cell.text.stringByExpandingTextAttachments
        while let br = md.range(of: "<br ?/?>", options: .regularExpression) { md.replaceSubrange(br, with: "\n") }
        cellEditorController.loadString(md, into: tv)
        align(tv, cell.alignment)
        if ip.row == 0 { tv.mdTextStorage.addFontWeight(NSFont.Weight.semibold.rawValue, in: NSRange(location: 0, length: tv.mdTextStorage.length)) }
        tableView.addSubview(sv, positioned: .below, relativeTo: tableView.moreButton)
        cellScrollView = sv
        cellTextView = tv
        relayout(needsLayout: false)
        _ = tv.window?.makeFirstResponder(tv)
        if let p = clickPoint {
            let local = tv.convert(p, from: tableView)
            let idx = tv.characterIndexForInsertion(at: local)
            tv.setSelectedRange(NSRange(location: min(idx, tv.string.utf16.count), length: 0))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cellTextDidChange(_:)), name: MDTextViewTextDidChangeNotification, object: tv)
    }

    public func endEditing(returnFocus: Bool) {
        guard let tv = cellTextView else { return }
        NotificationCenter.default.removeObserver(self, name: MDTextViewTextDidChangeNotification, object: tv)
        commitCell(tv)
        cellScrollView?.removeFromSuperview()
        cellScrollView = nil
        cellTextView = nil
        relayout(needsLayout: false)
        writeBack(debounce: false)
        if returnFocus, let host = hostTextView { host.window?.makeFirstResponder(host) }
    }

    func selectCell(dRow: Int, dColumn: Int, from ip: (row: Int, column: Int), caretAtEnd: Bool) {
        var row = ip.row, col = ip.column + dColumn
        if col >= model.columns { col = 0; row += 1 } else if col < 0 { col = model.columns - 1; row -= 1 }
        row += dRow
        guard row >= 0, row < model.rows.count else {
            // leaving the table: caret goes before / after the attachment in the host editor
            if let host = hostTextView, let att = textAttachment {
                let r = host.mdTextStorage.range(ofTextAttachment: att)
                endEditing(returnFocus: true)
                if r.location != NSNotFound { host.setSelectedRange(NSRange(location: row < 0 ? r.location : NSMaxRange(r), length: 0)) }
            }
            return
        }
        beginEditing(at: (row, col))
        if let tv = cellTextView { tv.setSelectedRange(NSRange(location: caretAtEnd ? tv.string.utf16.count : 0, length: 0)) }
    }

    @objc private func cellTextDidChange(_ note: Notification) {
        guard let tv = cellTextView, !tv.hasMarkedText() else { return }
        // Styling ran first and reset the paragraph style, so the column's alignment goes back on.
        align(tv, model.rows[tv.indexPath.row][tv.indexPath.column].alignment)
        commitCell(tv)
        relayout(needsLayout: true)
        writeBack(debounce: false)
    }

    private func align(_ tv: MDTableCellTextView, _ alignment: Int) {
        let textAlignment = cellAlignment(alignment)
        tv.setAlignment(textAlignment, range: NSRange(location: 0, length: tv.string.utf16.count))
        let style = (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.alignment = textAlignment
        tv.typingAttributes[.paragraphStyle] = style
    }

    /// Newlines become `<br>`.
    private func commitCell(_ tv: MDTableCellTextView) {
        let m = NSMutableAttributedString(attributedString: tv.mdTextStorage)
        let md = m.string.stringByExpandingTextAttachmentsPlain(m)
        let text = md.replacingOccurrences(of: "\n", with: "<br>")
        let ip = tv.indexPath
        guard ip.row < model.rows.count, ip.column < model.rows[ip.row].count else { return }
        // Styled like a loaded cell, so the grid hides the markers again once the editor leaves.
        let styled = cellEditorController.attributedStringRenderer.styledAttributedString(fromString: text)
        styled.addAttributes(model.separatorAttributes.filter { $0.key == .paragraphStyle }, range: NSRange(location: 0, length: styled.length))
        model.update(row: ip.row, column: ip.column, text: styled)
    }

    private func cellAlignment(_ a: Int) -> NSTextAlignment { [0: .left, 1: .center, 2: .right][a] ?? .natural }

    // MARK: Write-back

    func writeBack(debounce: Bool) {
        saveTask?.cancel(); saveTask = nil
        if debounce {
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.writeBack(debounce: false)
            }
            return
        }
        guard let att = textAttachment, let host = hostTextView, let ec = hostEditorController else { return }
        let prev = att.representedText
        let md = model.markdown()
        guard prev != md else { return }
        let previousSource = host.markdown
        let replacementRange = NSRange(location: 0, length: host.mdTextStorage.length)
        host.editorUndoManager.registerUndo(withTarget: host) { view in
            view.editorController.replaceCharacters(in: replacementRange, with: NSAttributedString(string: previousSource),
                                                    selectRange: NSRange(location: 0, length: 0), in: view)
        }
        let styled = cellEditorController.attributedStringRenderer.styledAttributedString(fromString: md)
        att.representedAttributedText = styled
        ec.textView(host, didChangeAttachmentTextRepresentation: att, previousRepresentedText: prev)
    }

    // MARK: Menu

    @objc private func showTableMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) { menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add("Add Row", #selector(addRow)); add("Add Row Above", #selector(addRowAbove)); add("Delete Row", #selector(deleteRow))
        add("Move Row Up", #selector(moveRowUp)); add("Move Row Down", #selector(moveRowDown))
        menu.addItem(.separator())
        add("Add Column", #selector(addColumn)); add("Add Column Before", #selector(addColumnBefore)); add("Delete Column", #selector(deleteColumn))
        add("Move Column Left", #selector(moveColumnLeft)); add("Move Column Right", #selector(moveColumnRight))
        menu.addItem(.separator())
        let align = NSMenu()
        for (t, sel) in [("Left", #selector(alignLeft)), ("Center", #selector(alignCenter)), ("Right", #selector(alignRight))] { align.addItem(withTitle: t, action: sel, keyEquivalent: "").target = self }
        let alignItem = NSMenuItem(title: "Align Column", action: nil, keyEquivalent: ""); alignItem.submenu = align; menu.addItem(alignItem)
        menu.addItem(.separator())
        let copy = NSMenu()
        for (t, sel) in [("Markdown", #selector(copyMarkdown)), ("CSV", #selector(copyCSV)), ("HTML", #selector(copyHTML))] { copy.addItem(withTitle: t, action: sel, keyEquivalent: "").target = self }
        let copyItem = NSMenuItem(title: "Copy Table As", action: nil, keyEquivalent: ""); copyItem.submenu = copy; menu.addItem(copyItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    private var targetIP: (row: Int, column: Int) { cellTextView?.indexPath ?? moreButtonIndexPath ?? (0, 0) }
    private func mutate(_ body: () -> Void) { endEditing(returnFocus: false); body(); relayout(needsLayout: true); writeBack(debounce: false) }
    @objc private func addRow() { mutate { model.insertRow(at: targetIP.row + 1) } }
    @objc private func addRowAbove() { mutate { model.insertRow(at: targetIP.row) } }
    @objc private func deleteRow() { mutate { model.deleteRow(at: targetIP.row) } }
    @objc private func moveRowUp() { mutate { model.moveRow(from: targetIP.row, to: targetIP.row - 1) } }
    @objc private func moveRowDown() { mutate { model.moveRow(from: targetIP.row, to: targetIP.row + 1) } }
    @objc private func addColumn() { mutate { model.insertColumn(at: targetIP.column + 1) } }
    @objc private func addColumnBefore() { mutate { model.insertColumn(at: targetIP.column) } }
    @objc private func deleteColumn() { mutate { model.deleteColumn(at: targetIP.column) } }
    @objc private func moveColumnLeft() { mutate { model.moveColumn(from: targetIP.column, to: targetIP.column - 1) } }
    @objc private func moveColumnRight() { mutate { model.moveColumn(from: targetIP.column, to: targetIP.column + 1) } }
    @objc private func alignLeft() { mutate { model.setAlignment(0, forColumn: targetIP.column) } }
    @objc private func alignCenter() { mutate { model.setAlignment(1, forColumn: targetIP.column) } }
    @objc private func alignRight() { mutate { model.setAlignment(2, forColumn: targetIP.column) } }
    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
    @objc private func copyMarkdown() { copy(model.markdown()) }
    @objc private func copyCSV() { copy(model.csv()) }
    @objc private func copyHTML() { copy(model.html()) }
}

private extension String {
    func stringByExpandingTextAttachmentsPlain(_ s: NSAttributedString) -> String { s.stringByExpandingTextAttachments }
}
