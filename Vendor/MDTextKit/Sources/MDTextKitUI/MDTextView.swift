import AppKit
import MDTextKit
import PolarMark
import SFThemeKit

/// `MDTextView : NSTextView` (MDTextKitUI, Swift). Routes every edit, key command and selection
/// change through `MDEditorController`.
@MainActor open class MDTextView: NSTextView, NSTextViewDelegate, MDUndoHost, MDTextStorageDelegate {
    public let editorController: MDEditorController
    private var trackingArea: NSTrackingArea?
    private var lastSelection = NSRange(location: 0, length: 0)

    /// Builds the TextKit 1 stack (`MDTextStorage` + `MDLayoutManager` + `MDTextContainer`).
    public init(frame: NSRect, editorController: MDEditorController) {
        self.editorController = editorController
        let storage = MDTextStorage()
        let layoutManager = MDLayoutManager()
        let container = MDTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        super.init(frame: frame, textContainer: container)
        storage.mdDelegate = self
        setup()
    }

    /// A table's grid is as wide as the column, so a new width lays every table out again.
    open override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged, !attachmentControllers.isEmpty else { return }
        for (_, entry) in attachmentControllers {
            (entry.controller as? MDTableAttachmentViewController)?.relayout(needsLayout: true)
        }
    }

    /// A table that left the storage takes its cell editor and view with it; nothing scans for them.
    nonisolated public func textStorage(_ storage: MDTextStorage, didRemoveAttachment attachment: NSTextAttachment) {
        guard let view = attachment as? SFTextAttachmentView else { return }
        let key = ObjectIdentifier(view)
        // The storage is edited on the main thread, which is where the views live.
        MainActor.assumeIsolated {
            attachmentControllers[key]?.controller.view.removeFromSuperview()
            attachmentControllers.removeValue(forKey: key)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        isRichText = false
        importsGraphics = false
        // The view registers its own undo: AppKit's typing records go stale once styling rewrites text.
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false   // spell checking is a host setting; off by default
        isAutomaticLinkDetectionEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        textContainerInset = .zero   // the host adds its own inset
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        linkTextAttributes = [:]
        smartInsertDeleteEnabled = false
        delegate = self
    }

    public var mdLayoutManager: MDLayoutManager { layoutManager as! MDLayoutManager }
    public var mdTextStorage: MDTextStorage { textStorage as! MDTextStorage }
    public var mdTextContainer: MDTextContainer { textContainer as! MDTextContainer }

    /// The markdown behind the attributed string (attachments expanded).
    public var markdown: String { mdTextStorage.stringByExpandingTextAttachments }

    // MARK: Host hooks

    /// Opens a clicked link. A host filters schemes here, or records the URL instead.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Resolves a relative image path. Nil shows the placeholder.
    public var imageFileResolver: ((String) -> URL?)? {
        get { editorController.attributedStringRenderer.imageStyler.fileResolver }
        set { editorController.attributedStringRenderer.imageStyler.fileResolver = newValue }
    }

    public let tableRenderer = MDTableAttachmentRenderer()
    /// The live cell editors; `attachmentViewController` is weak, so the view keeps them alive.
    private var attachmentControllers: [ObjectIdentifier: (controller: NSViewController, attachment: SFTextAttachment)] = [:]

    /// Pushes the theme into the stylers, the container, the layout manager and the view's own colours.
    public func applyTheme(_ themeManager: SFThemeManager) {
        let r = editorController.attributedStringRenderer
        r.styleObject(with: themeManager)
        tableRenderer.style(with: themeManager)
        mdTextContainer.style(with: r, themeManager: themeManager)
        mdLayoutManager.style(with: r, themeManager: themeManager)
        typingAttributes = r.defaultTextAttributes
        backgroundColor = themeManager.color(forKey: "base.background color", default: .white)
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        insertionPointColor = themeManager.color(forKey: "editor.cursor color", default: .textColor)
        let selection = themeManager.color(forKey: "editor.selection color", default: .selectedTextBackgroundColor)
        selectedTextAttributes = [
            .backgroundColor: selection.withAlphaComponent(0.7),
            .foregroundColor: themeManager.color(forKey: "editor.text color", default: .textColor)
        ]
    }

    /// Renders each table as a grid and gives it a live cell editor.
    public func installTableEditing(themeManager: SFThemeManager) {
        tableRenderer.editorController = editorController
        tableRenderer.maxAvailableWidth = { [weak self] in
            guard let self else { return 500 }
            let r = self.editorController.attributedStringRenderer
            let column = r.textContainerMaxWidth > 0 ? r.textContainerMaxWidth : self.mdTextContainer.currentColumnWidth
            // A view not yet laid out has no width; the first resize renders the tables again.
            return column > 0 ? column - 2 * r.defaultParagraphIndent : 500
        }
        editorController.attributedStringRenderer.tableStyler.attachmentRenderer = { [weak self] att in
            guard let self else { return }
            self.tableRenderer.render(att)
            guard self.isEditable else { return }
            let vc = MDTableAttachmentViewController(
                attachment: att, hostTextView: self, editorController: self.editorController,
                gridRenderer: self.tableRenderer, themeManager: themeManager)
            att.attachmentViewController = vc
            _ = vc.view
            self.attachmentControllers[ObjectIdentifier(att)] = (vc, att)
        }
    }

    // MARK: Editing hooks

    /// The editor's dedicated undo manager; AppKit's own is nil, so it records no typing.
    public let editorUndoManager = UndoManager()

    @objc open func undo(_ sender: Any?) { editorUndoManager.undo() }
    @objc open func redo(_ sender: Any?) { editorUndoManager.redo() }

    /// Super, then after an undo/redo the delegate's `textViewDidUndoOrRedo` runs
    /// asynchronously (the host makes the text view first responder again).
    open override func didChangeText() {
        super.didChangeText()
        if editorUndoManager.isUndoing || editorUndoManager.isRedoing {
            typingRun = nil
            Task { @MainActor [weak self] in
                guard let self, let window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    /// Restyle after every change, including undo/redo.
    public func textDidChange(_ notification: Notification) {
        guard compositionDepth == 0, !hasMarkedText() else { return }
        editorController.performStyling(in: self)
        editorController.fixTypingAttributes(in: self)
        editorController.notifyTextChanges(in: self)
    }

    open override func shouldChangeText(inRanges ranges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: ranges, replacementStrings: replacementStrings) else { return false }
        guard ranges.count == 1, let range = ranges.first?.rangeValue else {
            typingRun = nil
            return true
        }
        let replacement = replacementStrings?.first
        if compositionDepth > 0 || hasMarkedText() { typingRun = nil; return true }
        guard editorController.textView(self, shouldChangeTextIn: range, replacementString: replacement) else { return false }
        if let replacement, !hasMarkedText() { recordEdit(in: range, replacement: replacement) } else { typingRun = nil }
        return true
    }

    // Nobis: keep IME edits intact until the input method commits. Styling can replace
    // attachments and must never run inside a marked-text transaction.
    private var compositionDepth = 0
    private var compositionParagraphStyle: NSParagraphStyle?
    private var compositionBefore: (text: NSAttributedString, selection: NSRange)?

    open override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if compositionBefore == nil {
            breakUndoCoalescing()
            compositionBefore = (NSAttributedString(attributedString: mdTextStorage), self.selectedRange())
            // Resolve geometry from the document, not transient input-method typing attributes.
            editorController.fixTypingAttributes(in: self)
            let location = self.selectedRange().location
            let length = mdTextStorage.length
            let endsInNewline = length > 0 && [UInt16(10), UInt16(13)].contains((mdTextStorage.string as NSString).character(at: length - 1))
            let index = location < length ? location : (length > 0 && !endsInNewline ? length - 1 : NSNotFound)
            compositionParagraphStyle = (index != NSNotFound ? mdTextStorage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle : nil)
                ?? typingAttributes[.paragraphStyle] as? NSParagraphStyle
        }
        if let style = compositionParagraphStyle { typingAttributes[.paragraphStyle] = style }
        compositionDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // AppKit may reset the paragraph on each marked-text replacement. Restore only
        // layout attributes; do not parse Markdown, replace characters, or end composition.
        let marked = markedRange()
        if let style = compositionParagraphStyle, marked.location != NSNotFound, NSMaxRange(marked) <= mdTextStorage.length {
            mdTextStorage.addAttribute(.paragraphStyle, value: style, range: marked)
            typingAttributes[.paragraphStyle] = style
        }
        compositionDepth -= 1
        finishComposition()
        editorController.notifyTextSelectionChanges(in: self)
    }

    open override func insertText(_ string: Any, replacementRange: NSRange) {
        let composing = compositionBefore != nil
        if composing { compositionDepth += 1 }
        super.insertText(string, replacementRange: replacementRange)
        if composing { compositionDepth -= 1; finishComposition() }
    }

    open override func unmarkText() {
        compositionDepth += 1
        super.unmarkText()
        compositionDepth -= 1
        finishComposition()
    }

    private func finishComposition() {
        guard compositionDepth == 0, !hasMarkedText(), let before = compositionBefore else { return }
        compositionBefore = nil
        compositionParagraphStyle = nil
        editorUndoManager.disableUndoRegistration()
        editorController.performStyling(in: self)
        editorController.fixTypingAttributes(in: self)
        editorUndoManager.enableUndoRegistration()
        let range = NSRange(location: 0, length: mdTextStorage.length)
        editorUndoManager.registerUndo(withTarget: self) { view in
            view.editorController.replaceCharacters(in: range, with: before.text, selectRange: before.selection, in: view)
        }
        editorController.notifyTextChanges(in: self)
    }

    // MARK: Undo

    /// One undo step of consecutive typing; the closure reads the run, so later keystrokes extend it.
    private final class TypingRun {
        var range: NSRange
        let old: NSAttributedString
        let selection: NSRange

        init(range: NSRange, old: NSAttributedString, selection: NSRange) {
            self.range = range
            self.old = old
            self.selection = selection
        }
    }

    private var typingRun: TypingRun?

    /// Registers the inverse of a native edit, coalescing typing at the run's end and deletions of it.
    private func recordEdit(in range: NSRange, replacement: String) {
        let newLength = (replacement as NSString).length
        if let run = typingRun {
            if range.length == 0, range.location == NSMaxRange(run.range), newLength > 0, !replacement.contains("\n") {
                run.range.length += newLength
                return
            }
            if newLength == 0, range.length > 0, NSMaxRange(range) == NSMaxRange(run.range), range.length <= run.range.length {
                run.range.length -= range.length
                return
            }
        }
        let run = TypingRun(range: NSRange(location: range.location, length: newLength),
                            old: mdTextStorage.attributedSubstring(from: range), selection: selectedRange())
        typingRun = run
        editorUndoManager.registerUndo(withTarget: self) { textView in
            textView.editorController.replaceCharacters(in: run.range, with: run.old, selectRange: run.selection, in: textView)
        }
    }

    open override func breakUndoCoalescing() {
        super.breakUndoCoalescing()
        typingRun = nil
    }

    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
        editorController.adjustedSelection(for: self, currentSelection: old, proposedSelection: new)
    }

    /// Selection change handling (host textViewDidChangeSelection + adjustMarkdownHiding(for selection:)):
    /// typing attributes first, then an asynchronous show/hide pass — only while the view is first responder.
    public func textViewDidChangeSelection(_ notification: Notification) {
        guard compositionDepth == 0, !hasMarkedText() else { return }
        editorController.fixTypingAttributes(in: self)
        if window?.firstResponder === self {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sel = self.selectedRange()
                if self.editorController.autoHideMarkdown, !self.hasMarkedText() {
                    self.editorController.autoHideMarkdown(in: self, forOldSelectionRange: self.lastSelection, newSelectionRange: sel)
                }
                self.lastSelection = sel
            }
        }
        editorController.notifyTextSelectionChanges(in: self)
    }

    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { editorController.autodisableLinks(in: self); editorController.notifyTextSelectionChanges(in: self) }
        return ok
    }

    open override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { editorController.autodisableLinks(in: self); editorController.notifyTextSelectionChanges(in: self) }
        return ok
    }

    // Shared with table cells, so native font changes cannot bypass Markdown operations.
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", flags == .command || flags == [.command, .shift] {
            if flags.contains(.shift) { if editorUndoManager.canRedo { editorUndoManager.redo() } }
            else if editorUndoManager.canUndo { editorUndoManager.undo() }
            return true
        }
        if flags == .command, key == "b" || key == "i" {
            breakUndoCoalescing()
            if key == "b" { editorController.toggleStrong(in: self) }
            else { editorController.toggleEmphasis(in: self) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Key commands (forwarded to the controller before NSTextView handles them)

    open override func insertNewline(_ sender: Any?) {
        // Shift-Return bypasses the AST newline handling (plain line break).
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { super.insertNewline(sender); return }
        if editorController.textViewShouldInsertNewLine(self) { super.insertNewline(sender) }
    }

    /// The arrow keys enter a table from either side.
    open override func moveLeft(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location >= 1, let vc = tableController(at: sel.location - 1) {
            vc.enter(fromRight: true); return
        }
        super.moveLeft(sender)
    }

    open override func moveRight(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location < mdTextStorage.length, let vc = tableController(at: sel.location) {
            vc.enter(fromRight: false); return
        }
        super.moveRight(sender)
    }

    private func tableController(at index: Int) -> MDTableAttachmentViewController? {
        (mdTextStorage.textAttachment(at: index) as? MDTableTextAttachment)?.attachmentViewController as? MDTableAttachmentViewController
    }

    /// Inside a fenced code / math block the first ⌘A selects the
    /// block content, the second selects everything.
    open override func selectAll(_ sender: Any?) {
        let ts = mdTextStorage
        let sel = ts.stringRange(fromAttributedStringRange: selectedRange())
        if let r = ts.ast.selectAllText(in: sel, selectionRange: sel).last {
            setSelectedRange(ts.attributedStringRange(fromStringRange: r.proposedSelection))
        } else {
            super.selectAll(sender)
        }
    }

    open override func insertTab(_ sender: Any?) {
        if editorController.textViewShouldInsertTab(self) { super.insertTab(sender) }
    }

    open override func insertBacktab(_ sender: Any?) {
        if editorController.textViewShouldRemoveTab(self) { super.insertBacktab(sender) }
    }

    open override func deleteBackward(_ sender: Any?) {
        if editorController.textViewShouldDeleteBackward(self) { super.deleteBackward(sender) }
    }

    open override func deleteForward(_ sender: Any?) {
        if editorController.textViewShouldDeleteForward(self) { super.deleteForward(sender) }
    }

    open override func moveToLeftEndOfLine(_ sender: Any?) {
        if !editorController.handleMoveToLeftEndOfLine(in: self, extendSelection: false) { super.moveToLeftEndOfLine(sender) }
    }

    open override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        if !editorController.handleMoveToLeftEndOfLine(in: self, extendSelection: true) { super.moveToLeftEndOfLineAndModifySelection(sender) }
    }

    open override func deleteToBeginningOfLine(_ sender: Any?) {
        if !editorController.handleDeleteToBeginningOfLine(in: self) { super.deleteToBeginningOfLine(sender) }
    }

    // MARK: Mouse (checkbox toggling, link pointer)

    /// Character index of the attachment under `point` (view coordinates).
    public func attachmentIndex(at point: NSPoint) -> Int? {
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let r = mdLayoutManager.rangeOfTextAttachment(near: local, withDelta: 2)
        return r.location == NSNotFound ? nil : r.location
    }

    // MDTextView.mouseDown only calls super; attachment clicks arrive through the cell tracking →
    // `textView(_:clickedOn:in:at:)` → `didInteract(with:at:)`.
    public func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let att = cell.attachment as? SFTextAttachment else { return }
        guard isEditable, !hasMarkedText() else {
            if let url = linkURL(at: charIndex) { openURL(url) }
            return
        }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if att is MDUnorderedListTextAttachment || att is MDOrderedListTextAttachment || att is MDATXHeadingAttachment {
                editorController.toggleFolding(at: charIndex, in: self)
            }
            return
        }
        if att is MDATXHeadingAttachment {
            showHeadingLevelMenu(at: charIndex, cellFrame: cellFrame)
        } else if att is MDLinkTextAttachment, let url = linkURL(at: charIndex) {
            openURL(url)
        } else if att is MDHighlighterTextAttachment || att is MDCalloutTextAttachment {
            setSelectedRange(NSRange(location: charIndex, length: 1))   // the host pops the highlighter / callout menu here
        } else if !didInteract(with: att, at: charIndex) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: charIndex, length: 1))
        }
    }

    public func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        self.textView(textView, clickedOn: cell, in: cellFrame, at: charIndex)
    }

    /// A click on link text goes through the same hook as the link icon.
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) else { return false }
        openURL(url)
        return true
    }

    /// Tasks toggle, fold pills unfold.
    public func didInteract(with attachment: SFTextAttachment, at index: Int) -> Bool {
        if attachment is MDTaskTextAttachment, isEditable {
            editorController.toggleTask(in: self, range: NSRange(location: index, length: 1), style: 0)
            return true
        }
        if attachment is MDFoldTextAttachment, isEditable {
            editorController.toggleFolding(at: index, in: self)
            needsDisplay = true
            return true
        }
        return false
    }

    private func linkURL(at index: Int) -> URL? {
        guard index < mdTextStorage.length else { return nil }
        if let u = mdTextStorage.attribute(.link, at: index, effectiveRange: nil) { return (u as? URL) ?? (u as? String).flatMap { URL(string: $0) } }
        if let u = mdTextStorage.attribute(.pmkLinkURL, at: index, effectiveRange: nil) as? String { return URL(string: u) }
        return nil
    }

    /// Heading-level popup when the `#` attachment is clicked (NoteEditorViewController headingMenu).
    private func showHeadingLevelMenu(at index: Int, cellFrame: NSRect) {
        let level = mdTextStorage.headerLevel(at: index)
        let menu = NSMenu()
        for l in 1...6 {
            let item = NSMenuItem(title: "Heading \(l)", action: #selector(headingMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = l
            item.state = l == level ? .on : .off
            menu.addItem(item)
        }
        setSelectedRange(NSRange(location: index, length: 0))
        menu.popUp(positioning: nil, at: NSPoint(x: cellFrame.minX, y: cellFrame.maxY + 5), in: self)
    }

    @objc private func headingMenuItemSelected(_ sender: NSMenuItem) {
        editorController.toggleHeading(in: self, headingLevel: sender.tag)
    }

    open override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = attachmentIndex(at: p), mdTextStorage.textAttachment(at: idx) is MDTaskTextAttachment {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: Pasteboard

    public static let attributedStringPboardType = NSPasteboard.PasteboardType("MDTextViewAttributedStringPboardType")

    open override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.rtfd, MDTextView.attributedStringPboardType, .string]
        let sel = selectedRange()
        let ns = mdTextStorage.string as NSString
        let singleObject = sel.length == 1 || (sel.length == 2 && sel.location + 1 < ns.length && ns.character(at: sel.location + 1) == 0x0A)
        if singleObject, sel.location < mdTextStorage.length, let a = mdTextStorage.attribute(.attachment, at: sel.location, effectiveRange: nil) as? MDImageTextAttachment, a.resolvedFileURL != nil {
            types.append(.fileURL)
        }
        return types
    }

    public var onFind: (() -> Void)?
    open override func performFindPanelAction(_ sender: Any?) {
        if let onFind, (sender as? NSMenuItem)?.tag == NSTextFinder.Action.showFindInterface.rawValue {
            guard !hasMarkedText() else { return }; onFind()
        } else { super.performFindPanelAction(sender) }
    }

    open override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [MDTextView.attributedStringPboardType, .fileURL, .pdf, .tiff, .png, NSPasteboard.PasteboardType("com.apple.drawing")] + super.readablePasteboardTypes
    }

    open override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let sel = selectedRange()
        guard NSMaxRange(sel) <= mdTextStorage.length else { return false }
        switch type {
        case MDTextView.attributedStringPboardType:
            if let data = mdTextStorage.attributedSubstring(from: sel).dataFromPolarRepresentation() { pboard.setData(data, forType: type); return true }
            return false
        case .string:
            pboard.setString(mdTextStorage.stringByExpandingTextAttachments(in: sel), forType: .string)
            return true
        case .fileURL:
            if let a = mdTextStorage.textAttachment(at: sel.location) as? MDImageTextAttachment, let url = a.resolvedFileURL {
                pboard.setData(url.dataRepresentation, forType: .fileURL); return true
            }
            return false
        case .rtfd:
            // MDRTFExporter renders the markdown to rich text; here the styled text with attachments expanded.
            let rich = MDRTFImporter.richText(fromStyled: mdTextStorage.attributedSubstring(from: sel))
            if let data = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                pboard.setData(data, forType: .rtfd); return true
            }
            return false
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    open override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // The delegate ignores `type` and reads the whole pasteboard itself; false → AppKit's plain-string paste.
        if readPasteboard(pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    /// NoteEditorViewController.textView(_:shouldReadSelectionFrom:type:) + MDPasteboardReader.
    private func readPasteboard(_ pb: NSPasteboard) -> Bool {
        let dest = rangeForUserTextChange
        if internalDraggingRange.location != NSNotFound {
            _ = editorController.dragRange(internalDraggingRange, toRange: dest, in: self, dropAsNewLine: singleLineDragging)
            return true
        }
        // URL over a selection → markdown link
        if let url = pb.string(forType: .URL).flatMap(URL.init(string:)) ?? (pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL), !url.isFileURL {
            let sel = selectedRange()
            let selected = (mdTextStorage.string as NSString).substring(with: sel)
            if sel.length > 0, !mdTextStorage.isRangeInsideLink(sel), !selected.trimmingCharacters(in: .whitespaces).isEmpty, !selected.contains("\n") {
                let md = mdTextStorage.isRangeInsideCode(sel) ? url.absoluteString : MDEditorController.markdownLink(label: selected, url: url.absoluteString)
                editorController.replaceCharacters(in: sel, with: NSAttributedString(string: md), in: self)
                return true
            }
        }
        let reader = MDPasteboardReader()
        reader.pasteDestinationInsideCode = mdTextStorage.isRangeInsideCode(dest)
        reader.markdownRenderer = editorController.attributedStringRenderer
        reader.readURLsBlock = { [weak self] urls in
            guard let self = self else { return }
            let md = urls.map { MDEditorController.markdownLink(label: $0.lastPathComponent.isEmpty ? $0.absoluteString : $0.lastPathComponent, url: $0.absoluteString) }.joined(separator: "\n")
            self.editorController.replaceCharacters(in: self.rangeForUserTextChange, with: NSAttributedString(string: md), in: self)
        }
        reader.readFilesBlock = { [weak self] urls in self?.addFilesBlock?(urls, self?.rangeForUserTextChange ?? dest) }
        reader.readAttributedStringBlock = { [weak self] a in self?.insertPasted(a, at: dest) }
        return reader.read(from: pb, withAttachments: addFilesBlock != nil)
    }

    /// Host hook (addFiles(from:in:)) — copies files into the note's assets and
    /// inserts `![name](assets/name)`.
    public var addFilesBlock: (([URL], NSRange) -> Void)?

    /// NoteEditorViewController readAttributedStringBlock.
    private func insertPasted(_ pasted: NSAttributedString, at dest: NSRange) {
        guard pasted.length > 0 else { return }
        let full = NSRange(location: 0, length: pasted.length)
        if singleLineDragging {
            let m = NSMutableAttributedString(attributedString: pasted)
            let ns = mdTextStorage.string as NSString
            if dest.location > 0, ns.character(at: dest.location - 1) != 0x0A { m.insert(NSAttributedString(string: "\n"), at: 0) }
            if dest.location < ns.length, !m.string.hasSuffix("\n") { m.append(NSAttributedString(string: "\n")) }
            editorController.replaceCharacters(in: dest, with: m, in: self)
            return
        }
        let sel = selectedRange()
        let selected = (mdTextStorage.string as NSString).substring(with: sel)
        let selectable = sel.length >= 1 && !mdTextStorage.isRangeInsideLink(sel) && !selected.trimmingCharacters(in: .whitespaces).isEmpty && !selected.contains("\n")
        var linkRange = NSRange()
        if let u = pasted.attribute(.pmkLinkURL, at: 0, longestEffectiveRange: &linkRange, in: full) as? String, linkRange == full, let url = URL(string: u), selectable {
            editorController.replaceCharacters(in: sel, with: editorController.styledAttributedString(fromString: MDEditorController.markdownLink(label: selected, url: url.absoluteString)), in: self)
            return
        }
        let lower = pasted.string.lowercased()
        if ["http://", "https://", "omnifocus://", "readdle-spark://", "things:/"].contains(where: { lower.hasPrefix($0) }), selectable {
            editorController.replaceCharacters(in: sel, with: editorController.styledAttributedString(fromString: MDEditorController.markdownLink(label: selected, url: pasted.string)), in: self)
            return
        }
        if !pasted.containsFileBackedAttachments(in: full) {
            let md = pasted.stringByExpandingTextAttachments
            if editorController.pasteCorrection(forReplacementString: md, range: dest, in: self) { return }
        }
        let m = NSMutableAttributedString(attributedString: pasted)
        m.enumerateAttribute(.attachment, in: full, options: [.reverse]) { v, r, _ in
            if let a = v as? SFTextAttachment { m.replaceCharacters(in: r, with: NSAttributedString(string: a.representedText)) }
        }
        m.removeAttribute(.mdSpacer, range: NSRange(location: 0, length: m.length))
        editorController.replaceCharacters(in: dest, with: m, in: self)
    }

    private func acceptsImageDrop(_ pasteboard: NSPasteboard) -> Bool {
        isEditable && !hasMarkedText() && addFilesBlock != nil && internalDraggingRange.location == NSNotFound &&
            pasteboard.availableType(from: [.fileURL, .tiff, .png]) != nil
    }

    // MARK: Drag & drop

    public var internalDraggingRange = NSRange(location: NSNotFound, length: 0)
    public private(set) var singleLineDragging = false
    private var selectionRectDuringDrag = CGRect.zero
    private var lineInsertionPointRect = CGRect.zero

    open override var rangeForUserTextChange: NSRange {
        singleLineDragging ? NSRange(location: lineInsertionIndex(), length: 0) : super.rangeForUserTextChange
    }

    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        internalDraggingRange = (sender.draggingSource as? NSObject) === self ? selectedRange() : NSRange(location: NSNotFound, length: 0)
        if shouldSingleLineDrag(for: sender.draggingPasteboard) {
            singleLineDragging = true
            let g = mdLayoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
            selectionRectDuringDrag = mdLayoutManager.boundingRect(forGlyphRange: g, in: mdTextContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        if acceptsImageDrop(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    open override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsImageDrop(sender.draggingPasteboard) { return .copy }
        guard singleLineDragging else { return super.draggingUpdated(sender) }
        let old = lineInsertionPointRect
        lineInsertionPointRect = lineInsertionPointRect(for: sender.draggingLocation)
        if !old.equalTo(lineInsertionPointRect) {
            if selectionRectDuringDrag.contains(convert(sender.draggingLocation, from: nil)) {
                lineInsertionPointRect = .zero
                setNeedsDisplay(old, avoidAdditionalLayout: true)
            } else {
                setNeedsDisplay(old.union(lineInsertionPointRect), avoidAdditionalLayout: true)
            }
        }
        return .generic
    }

    open override func draggingEnded(_ sender: NSDraggingInfo) {
        internalDraggingRange = NSRange(location: NSNotFound, length: 0)
        singleLineDragging = false
        setNeedsDisplay(lineInsertionPointRect, avoidAdditionalLayout: true)
        super.draggingEnded(sender)
    }

    open override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsImageDrop(sender.draggingPasteboard) || super.prepareForDragOperation(sender) || !lineInsertionPointRect.equalTo(.zero)
    }

    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if acceptsImageDrop(sender.draggingPasteboard) {
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
            return readPasteboard(sender.draggingPasteboard)
        }
        if super.performDragOperation(sender) { return true }
        if lineInsertionPointRect.equalTo(.zero) { return false }
        _ = readSelection(from: sender.draggingPasteboard, type: MDTextView.attributedStringPboardType)
        return true
    }

    /// Block-level drags (list items, headings, tables, rules, quotes) drop as whole lines.
    private func shouldSingleLineDrag(for pb: NSPasteboard) -> Bool {
        guard let data = pb.data(forType: MDTextView.attributedStringPboardType), let a = NSMutableAttributedString.attributedString(fromPolarData: data), a.length > 0 else { return false }
        var i = 0
        if a.textAttachment(at: 0) is MDIndentSpaceTextAttachment, a.length > 1 { i = 1 }
        let att = a.textAttachment(at: i)
        return att is MDUnorderedListTextAttachment || att is MDOrderedListTextAttachment || att is MDTaskTextAttachment || att is MDATXHeadingAttachment
            || att is MDTableTextAttachment || att is MDThematicBreakTextAttachment || att is MDBlockQuoteTextAttachment
    }

    public func lineInsertionIndex() -> Int {
        let r = lineInsertionPointRect
        let probe = CGRect(x: r.minX, y: r.minY + r.height * 0.5, width: r.width, height: 1)
        let g = mdLayoutManager.glyphRange(forBoundingRect: probe, in: mdTextContainer)
        let c = mdLayoutManager.characterRange(forGlyphRange: g, actualGlyphRange: nil)
        return c.length == 0 ? mdTextStorage.length : c.location
    }

    public func lineInsertionPointRect(for windowPoint: NSPoint) -> CGRect {
        let p = convert(windowPoint, from: nil)
        let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let idx = mdLayoutManager.characterIndex(for: local, in: mdTextContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let ns = mdTextStorage.string as NSString
        guard ns.length > 0 else { return .zero }
        let i = min(idx, ns.length - 1)
        var range = ns.paragraphRange(for: NSRange(location: i, length: 0))
        if mdTextStorage.isRangeInsideList(NSRange(location: i, length: 0)) { range = mdTextStorage.rangeOfListItem(at: i) }
        let glyphs = mdLayoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = CGRect.null
        mdLayoutManager.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, _, _ in rect = rect.union(frag) }
        if rect.isNull { rect = mdLayoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil) }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x += mdTextContainer.lineFragmentPadding
        rect.size.width -= 2 * mdTextContainer.lineFragmentPadding
        if p.y >= rect.minY + rect.height / 2 { rect.origin.y += rect.height }
        rect.size.height = max(mdLayoutManager.basePointSize, 1)
        return rect
    }

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if singleLineDragging { drawLineInsertionPoint(lineInsertionPointRect) }
    }

    /// Chevron plus a bar in the insertion point colour.
    private func drawLineInsertionPoint(_ rect: CGRect) {
        guard !rect.equalTo(.zero) else { return }
        let lw = max(mdLayoutManager.basePointSize, 1), h = rect.height
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: rect.minX + 0.21429 * h, y: rect.minY + 0.92857 * h))
        chevron.line(to: NSPoint(x: rect.minX + 0.78571 * h, y: rect.minY + 0.5 * h))
        chevron.line(to: NSPoint(x: rect.minX + 0.21429 * h, y: rect.minY + 0.07143 * h))
        chevron.lineWidth = lw; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
        insertionPointColor.setStroke(); chevron.stroke()
        insertionPointColor.withAlphaComponent(0.66).setFill()
        NSBezierPath(rect: CGRect(x: floor(rect.minX + 10 * lw), y: floor(rect.minY + h / 2 - lw / 2), width: rect.width, height: lw)).fill()
    }
}
