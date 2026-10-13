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
    var plainText = false
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
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    var isActive = true
    var request: RichEditRequest?
    var onFocus: (() -> Void)?
    var sharedUndoManager: UndoManager?
    var plainText = false
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onFocus: onFocus, plainText: plainText) }
    func makeUIView(context: Context) -> UITextView {
        let view = MarkdownUITextView()
        view.onViewportChange = { [weak coordinator = context.coordinator] view in coordinator?.revealCaret(view) }
        view.documentUndoManager = sharedUndoManager
        view.plainText = plainText
        view.font = RichMarkdown.font(); view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear; view.smartQuotesType = .no; view.smartDashesType = .no
        view.attributedText = plainText ? NSAttributedString(string: text, attributes: [.font: NoteTypography.codeFont, .foregroundColor: UIColor.label]) : RichMarkdown.decode(text); view.delegate = context.coordinator; view.isFindInteractionEnabled = true
        view.typingAttributes = plainText ? [.font: NoteTypography.codeFont] : RichMarkdown.base
        view.accessibilityLabel = "笔记正文"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocus = onFocus
        if let request, context.coordinator.lastRequest != request.id {
            context.coordinator.lastRequest = request.id
            DispatchQueue.main.async {
            view.unmarkText()
            let selection = view.selectedRange
            let previous = view.attributedText!
            (view as? MarkdownUITextView)?.restore(RichMarkdown.applying(request.action, to: previous, selection: selection), selection: selection)
            view.becomeFirstResponder()
            }
            return
        }
        view.isEditable = isActive
        if context.coordinator.active != isActive {
            context.coordinator.active = isActive
            if isActive { view.becomeFirstResponder() } else { view.resignFirstResponder() }
        }
        if context.coordinator.lastSource != text, view.markedTextRange == nil { context.coordinator.lastSource = text; view.attributedText = plainText ? NSAttributedString(string: text, attributes: [.font: NoteTypography.codeFont, .foregroundColor: UIColor.label]) : RichMarkdown.decode(text); if sharedUndoManager == nil { view.undoManager?.removeAllActions() } }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        let plainText: Bool
        var onFocus: (() -> Void)?
        var text: Binding<String>
        var lastSource: String
        var active = true
        var lastRequest: UUID?
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
            // SwiftUI restores the outer scroll offset after UIKit finishes the keyboard transition.
            // Reconcile once after that layout pass; normal typing remains immediate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let activeView = self.activeView else { return }
                self.revealCaret(activeView)
            }
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isFirstResponder { onFocus?(); revealCaret(textView) }
        }
        func textViewDidBeginEditing(_ textView: UITextView) { onFocus?(); revealCaret(textView) }
        func revealCaret(_ view: UITextView) {
            activeView = view
            let keyboardFrame = keyboardFrame
            // The block scrolls inside a SwiftUI page. Keep its active line visible in both scroll views.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isFirstResponder, let selection = view.selectedTextRange else { return }
                view.layoutIfNeeded()
                view.scrollRectToVisible(view.caretRect(for: selection.end).insetBy(dx: 0, dy: -8), animated: false)
                var ancestor = view.superview
                while let current = ancestor {
                    if let scroll = current as? UIScrollView {
                        let caret = view.convert(view.caretRect(for: selection.end), to: scroll).insetBy(dx: 0, dy: -8)
                        scroll.scrollRectToVisible(caret, animated: false)
                        if let window = view.window, !keyboardFrame.isNull {
                            let keyboard = window.convert(keyboardFrame, from: nil)
                            let line = view.convert(view.caretRect(for: selection.end), to: window)
                            let visibleTop = scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top + 12
                            var offset = scroll.contentOffset.y
                            if line.minY < visibleTop {
                                offset -= visibleTop - line.minY
                            } else if keyboard.intersects(window.bounds), line.maxY + 12 > keyboard.minY {
                                offset += line.maxY + 12 - keyboard.minY
                            }
                            let minimum = -scroll.adjustedContentInset.top
                            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(maximum, max(minimum, offset))), animated: false)
                        }
                        break
                    }
                    ancestor = current.superview
                }
            }
        }
        func textViewDidChange(_ view: UITextView) {
            // A marked range belongs to the input method, not the saved document.
            guard view.markedTextRange == nil else { return }
            lastSource = plainText ? view.text : RichMarkdown.encode(view.attributedText)
            if text.wrappedValue != lastSource { text.wrappedValue = lastSource }
            revealCaret(view)
        }
        func textViewDidEndEditing(_ view: UITextView) { textViewDidChange(view) }
    }
}
private final class MarkdownUITextView: UITextView {
    override func unmarkText() {
        super.unmarkText()
        // Some input methods confirm composition without another change callback.
        delegate?.textViewDidChange?(self)
    }
    var onViewportChange: ((UITextView) -> Void)?
    private var previousViewportSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousViewportSize {
            previousViewportSize = bounds.size
            onViewportChange?(self)
            if isFirstResponder, let transition = window?.rootViewController?.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [weak self] _ in
                    guard let self else { return }
                    self.onViewportChange?(self)
                }
            }
        }
    }
    var documentUndoManager: UndoManager?
    var plainText = false
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }

    func restore(_ value: NSAttributedString, selection: NSRange) {
        let previous = attributedText!, previousSelection = selectedRange
        undoManager?.registerUndo(withTarget: self) { target in target.restore(previous, selection: previousSelection) }
        attributedText = value
        selectedRange = NSRange(location: min(selection.location, value.length), length: min(selection.length, max(0, value.length - selection.location)))
        delegate?.textViewDidChange?(self)
    }

    override var keyCommands: [UIKeyCommand]? {
        let history = [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoDocument)), UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoDocument))]
        for command in history { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + history + MarkdownFormat.allCases.filter { $0 != .link }.map { format in
            let command = UIKeyCommand(input: format.key, modifierFlags: .command, action: #selector(formatText(_:)))
            command.discoverabilityTitle = format.title
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }
    @objc private func undoDocument() { if let manager = undoManager, manager.canUndo { manager.undo() } }
    @objc private func redoDocument() { if let manager = undoManager, manager.canRedo { manager.redo() } }
    @objc private func formatText(_ command: UIKeyCommand) {
        guard !plainText, isEditable, markedTextRange == nil, let format = MarkdownFormat.allCases.first(where: { $0.key == command.input }) else { return }
        let range = selectedRange
        guard range.length > 0 else { return }
        let value = NSMutableAttributedString(attributedString: attributedText)
        let key = format == .bold ? RichMarkdown.bold : RichMarkdown.italic
        if format == .link { return }
        else {
            if value.attribute(key, at: range.location, effectiveRange: nil) == nil { value.addAttribute(key, value: true, range: range) }
            else { value.removeAttribute(key, range: range) }
            value.enumerateAttributes(in: range) { attrs, part, _ in
                value.addAttribute(.font, value: RichMarkdown.font(bold: attrs[RichMarkdown.bold] != nil, italic: attrs[RichMarkdown.italic] != nil), range: part)
            }
        }
        restore(value, selection: range)
    }
}
#endif
