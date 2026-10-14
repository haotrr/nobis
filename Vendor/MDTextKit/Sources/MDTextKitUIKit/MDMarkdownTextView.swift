#if canImport(UIKit)
import UIKit
import PolarMark

/// UIKit front end for the shared Markdown parser. Character offsets remain Markdown
/// UTF-16 offsets: styling never replaces characters or invalidates an IME selection.
@MainActor open class MDMarkdownTextView: UITextView {
    public var documentUndoManager: UndoManager?
    public var plainText = false
    public var inlineOnly = false
    public var onViewportChange: ((UITextView) -> Void)?
    public var onCompositionChange: (() -> Void)?
    private let localUndoManager = UndoManager()
    public override var undoManager: UndoManager? { documentUndoManager ?? localUndoManager }
    private var committed = ""
    private var committedSelection = NSRange(location: 0, length: 0)
    private var inputDepth = 0
    public var isProcessingInput: Bool { inputDepth > 0 }
    private var viewport = CGSize.zero
    private var rendering = false
    private var parsedSource: String?
    private var parsedAST: PMKAST?
    private var annotations: NSAttributedString?
    private var renderedSource: String?
    private var renderedStyle: String?
    private(set) var parseCount = 0

    private func syntax() -> PMKAST {
        let source = markdown
        if parsedSource != source || parsedAST == nil {
            parsedSource = source
            parsedAST = PMKAST(markdown: source)
            annotations = nil
            parseCount += 1
        }
        return parsedAST!
    }

    private func annotatedSyntax() -> NSAttributedString {
        let ast = syntax()
        if let annotations { return annotations }
        let value = ast.annotatedString()
        annotations = value
        return value
    }

    public var markdown: String { text ?? "" }

    private var requestedSelection: NSRange?
    public func requestFocus(selection: NSRange) {
        requestedSelection = selection
        if window != nil { applyRequestedFocus() }
    }
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyRequestedFocus() }
    }
    private func applyRequestedFocus() {
        guard let selection = requestedSelection, markedTextRange == nil else { return }
        requestedSelection = nil
        // SwiftUI must finish inserting the view before responder/selection callbacks run.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.markedTextRange == nil else { return }
            self.becomeFirstResponder()
            self.selectedRange = self.clamped(selection)
            self.rememberSelection()
            self.onViewportChange?(self)
        }
    }

    public func load(markdown: String) {
        guard markedTextRange == nil, self.markdown != markdown else { return }
        let selection = selectedRange
        renderedSource = nil
        text = markdown
        selectedRange = clamped(selection)
        committed = markdown
        committedSelection = selectedRange
        renderMarkdown()
    }

    /// Only attributes change; UIKit keeps ownership of keyboard edits and undo groups.
    public var searchRanges: [NSRange] = [] {
        didSet {
            guard oldValue != searchRanges else { return }
            renderedSource = nil
            renderMarkdown()
        }
    }

    public func renderMarkdown() {
        guard markedTextRange == nil, !rendering else { return }
        let source = markdown
        let style = "\(plainText)-\(inlineOnly)-\(traitCollection.preferredContentSizeCategory.rawValue)"
        guard renderedSource != source || renderedStyle != style else { return }
        renderedSource = source
        renderedStyle = style
        rendering = true
        defer { rendering = false }
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let code = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let base: [NSAttributedString.Key: Any] = [.font: plainText ? code : body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        let styled = NSMutableAttributedString(string: source, attributes: base)
        if !plainText {
            annotatedSyntax().enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
                var font = body
                if !inlineOnly, let level = attrs[.pmkHeading] as? NSNumber {
                    font = UIFont.preferredFont(forTextStyle: level.intValue == 1 ? .title1 : level.intValue == 2 ? .title2 : .headline, compatibleWith: traitCollection)
                }
                var traits = font.fontDescriptor.symbolicTraits
                if attrs[.pmkStrong] != nil { traits.insert(.traitBold) }
                if attrs[.pmkEmphasis] != nil { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
                if attrs[.pmkCode] != nil || attrs[.pmkFencedCode] != nil { font = code }
                styled.addAttribute(.font, value: font, range: range)
                if attrs[.pmkStrikethrough] != nil { styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                if PMKAttributes.markerAttributes.contains(where: { attrs[$0] != nil }) {
                    styled.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                }
            }
        }
        for range in searchRanges where range.location >= 0 && NSMaxRange(range) <= styled.length {
            styled.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.32), range: range)
        }
        let manager = undoManager
        manager?.disableUndoRegistration()
        textStorage.beginEditing()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
            textStorage.setAttributes(attrs, range: range)
        }
        textStorage.endEditing()
        manager?.enableUndoRegistration()
        typingAttributes = base
    }

    public func rememberSelection() {
        if markedTextRange == nil, markdown == committed { committedSelection = selectedRange }
    }

    /// One snapshot per committed edit, including a complete IME composition. UIKit's
    /// internal undo registration is suppressed while its input primitives run.
    public func commitChanges() {
        guard inputDepth == 0, markedTextRange == nil, markdown != committed else { return }
        let old = committed, selection = committedSelection
        undoManager?.registerUndo(withTarget: self) { target in target.restore(old, selection: selection) }
        committed = markdown
        committedSelection = selectedRange
    }

    private func input(_ change: () -> Void) {
        let manager = undoManager
        inputDepth += 1
        manager?.disableUndoRegistration()
        change()
        manager?.enableUndoRegistration()
        inputDepth -= 1
        if inputDepth == 0 {
            commitChanges()
            delegate?.textViewDidChange?(self)
            onCompositionChange?()
        }
    }

    public override func insertText(_ text: String) {
        // The IME owns Return while composing. Cells and code keep literal newlines.
        if text == "\n", markedTextRange == nil, !plainText, !inlineOnly, isEditable {
            let result = syntax().insertNewline(selection: selectedRange)
            let value = (markdown as NSString).replacingCharacters(in: result.replacementRange, with: result.replacementString)
            restore(value, selection: result.proposedSelection)
        } else {
            input { super.insertText(text) }
        }
    }
    public override func deleteBackward() { input { super.deleteBackward() } }
    public override func replace(_ range: UITextRange, withText text: String) { input { super.replace(range, withText: text) } }
    public override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        input { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }
    public override func unmarkText() { input { super.unmarkText() } }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if viewport != bounds.size {
            viewport = bounds.size
            onViewportChange?(self)
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { renderMarkdown() }
    }

    public func formattingState() -> (selected: Set<String>, mixed: Set<String>) {
        guard !plainText, markedTextRange == nil, !markdown.isEmpty else { return ([], []) }
        let annotated = annotatedSyntax()
        let selection = clamped(selectedRange)
        let range = selection.length == 0 ? NSRange(location: min(selection.location, annotated.length - 1), length: 1) : selection
        var all: Set<String>?, any = Set<String>()
        annotated.enumerateAttributes(in: range) { attrs, _, _ in
            var current = Set<String>()
            if attrs[.pmkStrong] != nil { current.insert("bold") }
            if attrs[.pmkEmphasis] != nil { current.insert("italic") }
            if attrs[.pmkStrikethrough] != nil { current.insert("strike") }
            if attrs[.pmkCode] != nil { current.insert("inline-code") }
            if !inlineOnly, attrs[.pmkBlockquote] != nil { current.insert("quote") }
            if !inlineOnly {
                if let level = attrs[.pmkHeading] as? NSNumber { current.insert("heading:\(level.intValue)") }
                if attrs[.pmkHeading] == nil { current.insert("body") }
                if let list = attrs[.pmkListItem] as? PMKListInfo {
                    if list.taskType > 0 { current.insert("checklist") }
                    else if list.listType == 1 { current.insert("list") }
                    else { current.insert("ordered") }
                }
            }
            any.formUnion(current)
            all = all.map { $0.intersection(current) } ?? current
        }
        return (all ?? [], any.subtracting(all ?? []))
    }

    /// Toolbar commands never commit or discard marked text.
    public func performMarkdownAction(_ action: String) {
        guard isEditable, !plainText, markedTextRange == nil else { return }
        let ast = syntax()
        let selection = selectedRange
        var result: PMKASTOperationResult?
        switch action {
        case "bold": result = ast.toggleInlineStyle(.strong, selection: selection)
        case "italic": result = ast.toggleInlineStyle(.emphasis, selection: selection)
        case "strike": result = ast.toggleInlineStyle(.strikethrough, selection: selection)
        case "inline-code": result = ast.toggleInlineStyle(.code, selection: selection)
        case "clear": result = ast.clearFormatting(selection: selection, inlineOnly: inlineOnly)
        case "heading:1" where !inlineOnly, "heading:2" where !inlineOnly, "heading:3" where !inlineOnly:
            result = ast.toggleBlockStyle(.heading(Int(action.suffix(1)) ?? 2), selection: selection)
        case "ordered" where !inlineOnly: result = ast.toggleBlockStyle(.orderedList, selection: selection)
        case "quote" where !inlineOnly: result = ast.toggleBlockStyle(.blockquote, selection: selection)
        case "heading" where !inlineOnly: result = ast.toggleBlockStyle(.heading(2), selection: selection)
        case "list" where !inlineOnly: result = ast.toggleBlockStyle(.unorderedList, selection: selection)
        case "checklist" where !inlineOnly: result = ast.toggleBlockStyle(.taskList, selection: selection)
        case "toggle" where !inlineOnly: result = ast.toggleTask(at: selection.location)
        case "body" where !inlineOnly:
            result = ast.clearFormatting(selection: selection, headingsOnly: true)
        default:
            if action.hasPrefix("link:") {
                let address = String(action.dropFirst(5))
                var link: PMKASTNode?
                ast.rootNode.walk { node in
                    if node.type == .link, node.range.location <= selection.location,
                       NSMaxRange(node.range) >= NSMaxRange(selection) { link = node }
                }
                let labelRange = link?.contentRange ?? selection
                let label = ast.substring(labelRange)
                if address.isEmpty, let link {
                    result = PMKASTOperationResult(replacementRange: link.range, replacementString: label,
                        proposedSelection: NSRange(location: link.range.location, length: label.utf16.count))
                } else if !label.isEmpty, let url = URL(string: address),
                          ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    let range = link?.range ?? selection
                    let replacement = "[\(label)](\(PMKAST.percentEscapedURL(url.absoluteString)))"
                    result = PMKASTOperationResult(replacementRange: range, replacementString: replacement,
                        proposedSelection: NSRange(location: range.location + 1, length: label.utf16.count))
                }
            }
        }
        guard let result else { return }
        let value = (markdown as NSString).replacingCharacters(in: result.replacementRange, with: result.replacementString)
        restore(value, selection: result.proposedSelection)
    }

    private func clamped(_ selection: NSRange) -> NSRange {
        let start = min(max(0, selection.location), textStorage.length)
        return NSRange(location: start, length: min(selection.length, textStorage.length - start))
    }

    private func restore(_ value: String, selection: NSRange) {
        guard markedTextRange == nil else { return }
        let previous = markdown, previousSelection = selectedRange
        undoManager?.registerUndo(withTarget: self) { target in target.restore(previous, selection: previousSelection) }
        // Do not assign attributedText: that resets UIKit's keyboard undo history.
        renderedSource = nil
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: value)
        selectedRange = clamped(selection)
        committed = value
        committedSelection = selectedRange
        renderMarkdown()
        becomeFirstResponder()
        delegate?.textViewDidChange?(self)
    }

    public var onFind: (() -> Void)?
    @objc private func findDocument() { guard markedTextRange == nil else { return }; onFind?() }

    public override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findDocument)), UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoEdit)), UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoEdit)), UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(bold)), UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italic))]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }
    @objc private func undoEdit() { guard markedTextRange == nil else { return }; undoManager?.undo() }
    @objc private func redoEdit() { guard markedTextRange == nil else { return }; undoManager?.redo() }
    @objc private func bold() { performMarkdownAction("bold") }
    @objc private func italic() { performMarkdownAction("italic") }
}
#endif
