import SwiftUI
import FamilyCore

#if os(macOS)
import AppKit
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isActive = true
    var request: RichEditRequest?
    var onFocus: (() -> Void)?
    var sharedUndoManager: UndoManager?
    var onFind: () -> Void = {}
    var plainText = false
    var inlineOnly = false
    var onSelection: (NoteEditorSelection) -> Void = { _ in }
    var expandsToContent = false
    var focusRequest: NoteEditorFocus?
    var searchRanges: [NSRange] = []
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onFocus: onFocus, plainText: plainText) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
        view.documentUndoManager = sharedUndoManager
        view.isRichText = !plainText; view.allowsUndo = true; view.isVerticallyResizable = true
        view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.font = RichMarkdown.font(); view.textColor = .textColor
        view.drawsBackground = false; view.textContainerInset = NSSize(width: 8, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.textStorage?.setAttributedString(plainText ? NSAttributedString(string: text, attributes: [.font: NoteTypography.codeFont, .foregroundColor: NSColor.labelColor]) : RichMarkdown.decode(text)); view.delegate = context.coordinator
        view.typingAttributes = plainText ? [.font: NoteTypography.codeFont] : RichMarkdown.base
        view.setAccessibilityLabel("笔记正文")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocus = onFocus
        guard let view = scroll.documentView as? NSTextView else { return }
        if let request, context.coordinator.lastRequest != request.id {
            context.coordinator.lastRequest = request.id
            DispatchQueue.main.async {
            let selection = view.selectedRange()
            let value = RichMarkdown.applying(request.action, to: view.attributedString(), selection: selection)
            view.insertText(value, replacementRange: NSRange(location: 0, length: view.string.utf16.count))
            view.setSelectedRange(NSRange(location: min(selection.location, value.length), length: min(selection.length, max(0, value.length - selection.location))))
            view.window?.makeFirstResponder(view)
            }
            return
        }
        view.isEditable = isActive
        if context.coordinator.active != isActive {
            context.coordinator.active = isActive
            if isActive { view.window?.makeFirstResponder(view) }
            else if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        }
        guard context.coordinator.lastSource != text, !view.hasMarkedText() else { return }
        context.coordinator.lastSource = text
        // Only external edits (such as file import) replace the buffer.
        view.textStorage?.setAttributedString(plainText ? NSAttributedString(string: text, attributes: [.font: NoteTypography.codeFont, .foregroundColor: NSColor.labelColor]) : RichMarkdown.decode(text)); if sharedUndoManager == nil { view.undoManager?.removeAllActions() }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let plainText: Bool
        var onFocus: (() -> Void)?
        var text: Binding<String>
        var lastSource: String
        var active = true
        var lastRequest: UUID?
        init(text: Binding<String>, onFocus: (() -> Void)?, plainText: Bool) { self.text = text; self.lastSource = text.wrappedValue; self.onFocus = onFocus; self.plainText = plainText }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let view = notification.object as? NSTextView, view.window?.firstResponder === view { onFocus?() }
        }
        func textDidBeginEditing(_ notification: Notification) { onFocus?() }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            lastSource = plainText ? view.string : RichMarkdown.encode(view.attributedString()); text.wrappedValue = lastSource
        }
    }
}
private final class MarkdownNSTextView: NSTextView {
    var documentUndoManager: UndoManager?
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let source = string as NSString
        if isRichText, isEditable, index < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: index, length: 0))
            let line = source.substring(with: paragraph)
            if index <= paragraph.location + 1, line.hasPrefix("☐ ") || line.hasPrefix("☑ ") {
                let range = NSRange(location: paragraph.location, length: 1)
                let character = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
                character.replaceCharacters(in: NSRange(location: 0, length: 1), with: line.hasPrefix("☐") ? "☑" : "☐")
                insertText(character, replacementRange: range)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.charactersIgnoringModifiers?.lowercased() == "z", event.modifierFlags.contains(.command), let manager = documentUndoManager {
            if event.modifierFlags.contains(.shift) { if manager.canRedo { manager.redo() } }
            else if manager.canUndo { manager.undo() }
            return true
        }
        guard isRichText, isEditable, window?.firstResponder === self, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, let format = MarkdownFormat.allCases.first(where: { $0.key == key && $0 != .link }) {
            let range = selectedRange()
            if range.length > 0 {
                let value = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
                let key: NSAttributedString.Key = format == .bold ? RichMarkdown.bold : RichMarkdown.italic
                if format == .link { return true }
                else {
                    let enabled = value.attribute(key, at: 0, effectiveRange: nil) == nil
                    if enabled { value.addAttribute(key, value: true, range: NSRange(location: 0, length: value.length)) }
                    else { value.removeAttribute(key, range: NSRange(location: 0, length: value.length)) }
                    value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, part, _ in
                        value.addAttribute(.font, value: RichMarkdown.font(bold: attrs[RichMarkdown.bold] != nil, italic: attrs[RichMarkdown.italic] != nil), range: part)
                    }
                }
                insertText(value, replacementRange: range); setSelectedRange(range)
            } else if format != .link {
                let key = format == .bold ? RichMarkdown.bold : RichMarkdown.italic
                var attrs = typingAttributes
                if attrs[key] == nil { attrs[key] = true } else { attrs.removeValue(forKey: key) }
                attrs[.font] = RichMarkdown.font(bold: attrs[RichMarkdown.bold] != nil, italic: attrs[RichMarkdown.italic] != nil)
                typingAttributes = attrs
            }
            return true
        }
        if (modifiers == .command || modifiers == [.command, .shift]), key == "f" || key == "g" {
            let item = NSMenuItem()
            item.tag = (key == "f" ? NSTextFinder.Action.showFindInterface : modifiers.contains(.shift) ? .previousMatch : .nextMatch).rawValue
            performFindPanelAction(item)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
#else
import UIKit
import MDTextKitUIKit
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    var isActive = true
    var request: RichEditRequest?
    var onFocus: (() -> Void)?
    var sharedUndoManager: UndoManager?
    var onFind: () -> Void = {}
    var plainText = false
    var inlineOnly = false
    var onSelection: (NoteEditorSelection) -> Void = { _ in }
    var expandsToContent = false
    var focusRequest: NoteEditorFocus?
    var searchRanges: [NSRange] = []
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onFocus: onFocus, plainText: plainText) }
    func makeUIView(context: Context) -> UITextView {
        let view = MDMarkdownTextView()
        view.onViewportChange = { [weak coordinator = context.coordinator] view in coordinator?.revealCaret(view) }
        view.documentUndoManager = sharedUndoManager
        view.onFind = onFind
        view.onCompositionChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }; coordinator?.reportSelection(view)
        }
        context.coordinator.onSelection = onSelection
        context.coordinator.inlineOnly = inlineOnly
        view.isScrollEnabled = !expandsToContent
        view.plainText = plainText
        view.inlineOnly = inlineOnly
        view.font = RichMarkdown.font(); view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear; view.smartQuotesType = .no; view.smartDashesType = .no
        view.load(markdown: text); view.delegate = context.coordinator; view.isFindInteractionEnabled = true
        view.renderMarkdown()
        view.accessibilityLabel = "笔记正文"
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard expandsToContent, let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(44, ceil(size.height)))
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        context.coordinator.text = $text
        context.coordinator.onFocus = onFocus
        context.coordinator.onSelection = onSelection
        context.coordinator.inlineOnly = inlineOnly
        view.isScrollEnabled = !expandsToContent
        (view as? MDMarkdownTextView)?.searchRanges = searchRanges
        if let focusRequest, context.coordinator.lastFocus != focusRequest.id {
            context.coordinator.lastFocus = focusRequest.id
            (view as? MDMarkdownTextView)?.requestFocus(selection: focusRequest.range)
        }
        if let request, context.coordinator.lastRequest != request.id {
            context.coordinator.lastRequest = request.id
            DispatchQueue.main.async {
            guard view.markedTextRange == nil else { return }
            (view as? MDMarkdownTextView)?.performMarkdownAction(request.action)
            view.becomeFirstResponder()
            }
            return
        }
        view.isEditable = isActive
        if context.coordinator.active != isActive {
            context.coordinator.active = isActive
            if isActive { view.becomeFirstResponder() } else { view.resignFirstResponder() }
        }
        if context.coordinator.lastSource != text, view.markedTextRange == nil { context.coordinator.lastSource = text; (view as? MDMarkdownTextView)?.load(markdown: text); if sharedUndoManager == nil { view.undoManager?.removeAllActions() } }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        let plainText: Bool
        var onFocus: (() -> Void)?
        var text: Binding<String>
        var lastSource: String
        var onSelection: (NoteEditorSelection) -> Void = { _ in }
        var inlineOnly = false
        func reportSelection(_ view: UITextView) {
            let format = (view as? MDMarkdownTextView)?.formattingState()
            let state = NoteEditorSelection(range: view.selectedRange, enabled: view.isEditable && !plainText, composing: view.markedTextRange != nil, inTable: inlineOnly, selected: format?.selected ?? [], mixed: format?.mixed ?? [])
            DispatchQueue.main.async { [weak self] in self?.onSelection(state) }
        }
        var active = true
        var lastRequest: UUID?
        var lastFocus: UUID?
        var updating = false
        private var revealScheduled = false
        private var keyboardFrame: CGRect = .null
        private weak var activeView: UITextView?
        init(text: Binding<String>, onFocus: (() -> Void)?, plainText: Bool) {
            self.text = text; self.lastSource = text.wrappedValue; self.onFocus = onFocus; self.plainText = plainText
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func keyboardFrameChanged(_ notification: Notification) {
            keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
            if let activeView { revealCaret(activeView) }
        }
        private func reportFocus(_ view: UITextView) {
            if updating {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let view, view.isFirstResponder else { return }
                    self?.onFocus?()
                }
            } else { onFocus?() }
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isFirstResponder { (textView as? MDMarkdownTextView)?.rememberSelection(); reportFocus(textView); reportSelection(textView); revealCaret(textView) }
        }
        func textViewDidBeginEditing(_ textView: UITextView) { reportFocus(textView); reportSelection(textView); revealCaret(textView) }
        func revealCaret(_ view: UITextView) {
            activeView = view
            guard !revealScheduled else { return }
            revealScheduled = true
            // The block scrolls inside a SwiftUI page. Keep its active line visible in both scroll views.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.revealScheduled = false
                let keyboardFrame = self.keyboardFrame
                guard let view, view.isFirstResponder, let selection = view.selectedTextRange else { return }
                view.layoutIfNeeded()
                if view.isScrollEnabled { view.scrollRectToVisible(view.caretRect(for: selection.end).insetBy(dx: 0, dy: -8), animated: false) }
                var ancestor = view.superview
                while let current = ancestor {
                    if let scroll = current as? UIScrollView {
                        // Do not fight an ongoing finger gesture or its momentum.
                        guard !scroll.isDragging, !scroll.isDecelerating else { return }
                        let caret = view.convert(view.caretRect(for: selection.end), to: scroll).insetBy(dx: -8, dy: -8)
                        var visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
                        if let window = view.window, !keyboardFrame.isNull {
                            let keyboard = scroll.convert(window.convert(keyboardFrame, from: nil), from: window)
                            // Floating keyboards only occlude a caret in their horizontal span.
                            if keyboard.intersects(visible), caret.maxX > keyboard.minX, caret.minX < keyboard.maxX {
                                visible.size.height = max(0, min(visible.maxY, keyboard.minY - 12) - visible.minY)
                            }
                        }
                        var offset = scroll.contentOffset
                        if caret.minY < visible.minY { offset.y -= visible.minY - caret.minY }
                        else if caret.maxY > visible.maxY { offset.y += caret.maxY - visible.maxY }
                        if caret.minX < visible.minX { offset.x -= visible.minX - caret.minX }
                        else if caret.maxX > visible.maxX { offset.x += caret.maxX - visible.maxX }
                        let minimum = CGPoint(x: -scroll.adjustedContentInset.left, y: -scroll.adjustedContentInset.top)
                        let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right),
                                              y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
                        offset.x = min(maximum.x, max(minimum.x, offset.x))
                        offset.y = min(maximum.y, max(minimum.y, offset.y))
                        if offset != scroll.contentOffset { scroll.setContentOffset(offset, animated: false) }
                        // A table adds a horizontal scroll view. Continue outward so
                        // the page also reveals the active cell above the keyboard.
                    }
                    ancestor = current.superview
                }
            }
        }
        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            reportSelection(view)
            // A marked range belongs to the input method, not the saved document.
            guard view.markedTextRange == nil, (view as? MDMarkdownTextView)?.isProcessingInput != true else { return }
            (view as? MDMarkdownTextView)?.commitChanges()
            (view as? MDMarkdownTextView)?.renderMarkdown()
            view.invalidateIntrinsicContentSize()
            lastSource = view.text
            if text.wrappedValue != lastSource { text.wrappedValue = lastSource }
            revealCaret(view)
        }
        func textViewDidEndEditing(_ view: UITextView) { textViewDidChange(view) }
    }
}
#endif
