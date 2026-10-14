import AppKit
import PolarMark

public let MDTextViewTextDidChangeNotification = Notification.Name("MDTextViewTextDidChangeNotification")
public let MDTextViewTextAttributesDidChangeNotification = Notification.Name("MDTextViewTextAttributesDidChangeNotification")
public let MDTextViewTextDidChangeSelectionNotification = Notification.Name("MDTextViewTextDidChangeSelectionNotification")

/// Lets the host validate/replace attachments (file previews, images…).
@MainActor public protocol MDTextAttachmentConfigurator: AnyObject {
    func isTextAttachmentValid(_ attachment: SFTextAttachment) -> Bool
    func replacementAttributedString(forTextAttachment attachment: SFTextAttachment) -> NSAttributedString?
}

public extension MDTextAttachmentConfigurator {
    func replacementAttributedString(forTextAttachment attachment: SFTextAttachment) -> NSAttributedString? { nil }
}

/// The glue between the text view, the text storage/AST, the renderer,
/// the hider and the differ. Ported method by method from the decompilation.
/// A text view that owns its undo history instead of letting AppKit record typing.
@MainActor public protocol MDUndoHost: AnyObject {
    var editorUndoManager: UndoManager { get }
}

@MainActor public final class MDEditorController: NSObject {
    public var attributedStringRenderer = MDAttributedStringRenderer()
    public var editorBehaviourController = MDEditorBehaviourController()
    public var attrStringDiffer = MDAttributedStringDiffer()
    public weak var textAttachmentConfigurator: MDTextAttachmentConfigurator?
    public var useDiff = true
    public var autoHideMarkdown = false
    /// The restyle a typed space schedules; a new edit cancels it.
    public var restyleTask: Task<Void, Never>?

    public override init() {
        super.init()
        attrStringDiffer.ignoreAttachments = true
        attrStringDiffer.ignoreColorInCodeBlocks = true
    }

    private func storage(_ tv: NSTextView) -> MDTextStorage { tv.textStorage as! MDTextStorage }

    /// The editor's own manager; AppKit's is nil on purpose, so it registers no typing records.
    private func undoManager(for tv: NSTextView) -> UndoManager? { (tv as? MDUndoHost)?.editorUndoManager ?? tv.undoManager }

    // MARK: Loading / styling

    public func loadString(_ string: String, into textView: NSTextView) {
        storage(textView).setAttributedString(NSAttributedString(string: string))
        performStyling(in: textView, withAutomaticTextChanges: false)
        rearrangeAttachmentsViews(in: textView, range: NSRange(location: 0, length: storage(textView).length))
        undoManager(for: textView)?.removeAllActions()
    }

    /// Theme change: restyle everything in place without touching the undo stack (`styleTextView:with:` is wrapped
    /// in disable/enableUndoRegistration).
    public func restyleAll(in textView: NSTextView) {
        let ts = storage(textView)
        let selection = textView.selectedRange()
        undoManager(for: textView)?.disableUndoRegistration()
        let markdown = ts.stringByExpandingTextAttachments
        let stringSelection = ts.stringRange(fromAttributedStringRange: selection)
        ts.setAttributedString(NSAttributedString(string: markdown))
        performStyling(in: textView, withAutomaticTextChanges: false)
        rearrangeAttachmentsViews(in: textView, range: NSRange(location: 0, length: ts.length))
        let restored = ts.attributedStringRange(fromStringRange: stringSelection)
        if restored.location != NSNotFound, NSMaxRange(restored) <= ts.length { textView.setSelectedRange(restored) }
        undoManager(for: textView)?.enableUndoRegistration()
    }

    public func styledAttributedString(fromString string: String) -> NSMutableAttributedString {
        let s = attributedStringRenderer.styledAttributedString(fromString: string)
        var none = NSNotFoundRange
        validateTextAttachments(with: textAttachmentConfigurator, in: s, selectionRange: &none, selectionLocationOffset: 0)
        if autoHideMarkdown { _ = hideMarkdown(in: NSRange(location: 0, length: s.length), in: s) }
        return s
    }

    public func performStyling(in textView: NSTextView) { performStyling(in: textView, withAutomaticTextChanges: true) }

    /// The main styling pass after every edit.
    public func performStyling(in textView: NSTextView, withAutomaticTextChanges automatic: Bool) {
        if automatic { performAutomaticTextChanges(in: textView) }
        var selection = textView.selectedRange()
        let ts = storage(textView)
        var styledRange = NSNotFoundRange
        ts.parseChanges { annotated, range in
            var proposed = ts.offsetSelection(selection, byReplacingTextAttachmentIn: range)
            let styled = annotated.mutableCopy() as! NSMutableAttributedString
            self.attributedStringRenderer.styleAttributedString(styled, proposedSelectionRange: &proposed, selectionLocationOffset: range.location)
            let styledLength = styled.length
            if self.autoHideMarkdown {
                var local = NSString.convertSelectionRange(fromSelection: proposed, toSubstringRange: range)
                if textView.window?.firstResponder !== textView { local = NSNotFoundRange }
                self.autoHideMarkdown(in: styled, selectionRange: local)
            }
            var outerDiff = NSNotFoundRange
            let innerDiff = self.diffRange(fromInnerAttrString: styled, outerAttrString: ts, inOuterRange: range, outerDiffRange: &outerDiff)
            var replacement = styled
            var target = range
            if innerDiff.location != NSNotFound {
                replacement = styled.attributedSubstring(from: innerDiff).mutableCopy() as! NSMutableAttributedString
                self.validateTextAttachments(with: self.textAttachmentConfigurator, in: replacement, selectionRange: &proposed, selectionLocationOffset: innerDiff.location + range.location)
                target = outerDiff
            }
            let undoing = undoManager(for: textView)?.isUndoing ?? false
            let redoing = undoManager(for: textView)?.isRedoing ?? false
            if innerDiff.location == NSNotFound {
                if !undoing, !redoing {
                    ts.beginEditing()
                    replacement.enumerateAttribute(.mdAsyncStylingIdentifier, in: NSRange(location: 0, length: replacement.length), options: []) { v, r, _ in
                        guard let v = v else { return }
                        ts.addAttribute(.mdAsyncStylingIdentifier, value: v, range: NSRange(location: target.location + r.location, length: r.length))
                    }
                    ts.endEditing()
                }
                styledRange = target
                self.invalidateDisplay(forStyledRange: styledRange, in: textView)
                return
            }
            let sameText = (ts.string as NSString).substring(with: target) == replacement.string
            if !sameText || !self.useDiff {
                if !(undoing || redoing) {
                    self.replaceCharacters(in: target, with: replacement, selectRange: proposed, in: textView)
                    styledRange = NSRange(location: target.location, length: replacement.length)
                } else {
                    styledRange = target
                }
            } else {
                ts.beginEditing()
                replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length), options: []) { attrs, r, _ in
                    self.attrStringDiffer.setAttributesPreservingViewAttachments(attrs, range: NSRange(location: target.location + r.location, length: r.length), in: ts)
                }
                ts.endEditing()
                textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: range.location, length: styledLength))
                styledRange = (undoing || redoing) ? target : NSRange(location: target.location, length: replacement.length)
            }
            selection = proposed
            self.invalidateDisplay(forStyledRange: styledRange, in: textView)
        }
    }

    /// `replaceCharactersInRange:withAttributedString:selectRange:` (MDTextView) — replace + select without
    /// going through `shouldChangeText`.
    /// `-[NSTextView(Bridge) replaceCharactersInRange:withAttributedString:selectRange:]` (ClassBridge) — writes
    /// straight into the storage (no shouldChangeText), registers the inverse replacement with the old attributed
    /// substring and the old selection, selects the requested range, and only during undo/redo calls `didChangeText`.
    public func replaceCharacters(in range: NSRange, with s: NSAttributedString, selectRange selection: NSRange, in textView: NSTextView) {
        let ts = storage(textView)
        guard NSMaxRange(range) <= ts.length else { return }
        // A typing group still open would record ranges this replacement moves.
        textView.breakUndoCoalescing()
        let oldSelection = textView.selectedRange()
        let old = ts.attributedSubstring(from: range)
        let newLength = s.length
        if let um = undoManager(for: textView) {
            um.registerUndo(withTarget: textView) { [weak self] tv in
                self?.replaceCharacters(in: NSRange(location: range.location, length: newLength), with: old, selectRange: oldSelection, in: tv)
            }
        }
        ts.replaceCharacters(in: range, with: s)
        if selection.location != NSNotFound { textView.setSelectedRange(NSRange(location: min(selection.location, ts.length), length: min(selection.length, max(0, ts.length - selection.location)))) }
        textView.setNeedsDisplay(textView.bounds, avoidAdditionalLayout: false)
        if let um = undoManager(for: textView), um.isUndoing || um.isRedoing { textView.didChangeText() }
    }

    /// Redraw the visible part, plus neighbouring paragraphs and the
    /// enclosing blockquote (its bar spans several lines).
    public func invalidateDisplay(forStyledRange range: NSRange, in textView: NSTextView) {
        let ts = storage(textView)
        let ns = ts.string as NSString
        if range.location < ts.length, ns.character(at: range.location) == 0x0A {
            textView.needsDisplay = true
            return
        }
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.enclosingScrollView?.documentVisibleRect ?? textView.visibleRect
        let visibleGlyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let intersection = NSIntersectionRange(visibleChars, range)
        if intersection.length != 0 {
            let g = lm.glyphRange(forCharacterRange: intersection, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: g, in: container)
            textView.setNeedsDisplay(rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y), avoidAdditionalLayout: true)
        }
        var extended = range
        let prev = ns.previousParagraph(for: range)
        if prev.location != NSNotFound { extended = NSUnionRange(extended, prev) }
        let next = ns.nextParagraph(for: extended)
        if next.location != NSNotFound { extended = NSUnionRange(extended, next) }
        let quote = ts.extendRangeToFullyContainBlockquote(extended)
        if ts.isRangeInsideBlockquote(quote) { lm.invalidateDisplay(forCharacterRange: quote) }
    }

    public func diffRange(fromInnerAttrString inner: NSAttributedString, outerAttrString outer: NSAttributedString, inOuterRange range: NSRange, outerDiffRange: inout NSRange) -> NSRange {
        guard useDiff else {
            outerDiffRange = range
            return NSRange(location: 0, length: inner.length)
        }
        return attrStringDiffer.diffRange(between: inner, and: outer, in: range, secondDiffRange: &outerDiffRange)
    }

    // MARK: Folding

    public func toggleFolding(at index: Int, in textView: NSTextView) {
        let results = foldToggleResults(at: index, in: textView)
        if !results.isEmpty { applyASTOperationResults(results, in: textView) }
    }

    public func canToggleFolding(at index: Int, in textView: NSTextView) -> Bool { !foldToggleResults(at: index, in: textView).isEmpty }

    private func foldToggleResults(at index: Int, in textView: NSTextView) -> [PMKASTOperationResult] {
        let ts = storage(textView)
        let r = ts.stringRange(fromAttributedStringRange: NSRange(location: index, length: 0))
        let sel = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        return ts.ast.toggleFold(in: r, selectionRange: sel)
    }

    /// `hasFoldableContentAtIndex:inTextView:` → PMKFoldable attribute present.
    public func hasFoldableContent(at index: Int, in textView: NSTextView) -> Bool {
        let ts = storage(textView)
        guard index >= 0, index < ts.length else { return false }
        return ts.attribute(.pmkFoldable, at: index, effectiveRange: nil) != nil
    }

    public func foldAllHeading(in textView: NSTextView) {
        let ts = storage(textView)
        let sel = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        let results = ts.ast.foldAllHeading(selectionRange: sel)
        if !results.isEmpty { applyASTOperationResults(results, in: textView) }
    }

    public func unfoldAllHeading(in textView: NSTextView) {
        let ts = storage(textView)
        let sel = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        let results = ts.ast.unfoldAllHeading(selectionRange: sel)
        if !results.isEmpty { applyASTOperationResults(results, in: textView) }
    }

    /// `markdownLinkWithLabel:url:title:preview:` (label / url only).
    public static func markdownLink(label: String, url: String) -> String {
        "[" + label + "](" + PMKAST.percentEscapedURL(url) + ")"
    }

    /// List renumbering, unfolding, stray comment removal, indentation and
    /// callout normalisation over the reparsed range (pipes escaping when styling inlines only).
    public func performAutomaticTextChanges(in textView: NSTextView) {
        let ts = storage(textView)
        guard !(undoManager(for: textView)?.isUndoing ?? false), !(undoManager(for: textView)?.isRedoing ?? false) else { return }
        guard ts.currentReparsedRange.location != NSNotFound else { return }
        let ast = ts.ast
        var selection = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        func apply(_ results: [PMKASTOperationResult]) {
            guard !results.isEmpty else { return }
            applyASTOperationResults(results, in: textView, postTextDidChange: false)
            selection = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        }
        if ast.parseInlinesOnly {
            apply(ast.escapePipes(in: ts.currentReparsedRange, selectionRange: selection))
            return
        }
        apply(ast.renumberOrderedList(in: ts.currentReparsedRange, selectionRange: selection))
        apply(ast.unfoldAtRangeEdges(selection, selectionRange: selection))
        apply(ast.removeStrayMetaComment(in: ts.currentReparsedRange, selectionRange: selection))
        apply(ast.normalizeIndentation(in: ts.currentReparsedRange, selectionRange: selection))
        apply(ast.normalizeCallout(in: ts.currentReparsedRange, selectionRange: selection))
    }

    public func validateTextAttachments(with configurator: MDTextAttachmentConfigurator?, in s: NSMutableAttributedString, selectionRange: inout NSRange, selectionLocationOffset offset: Int) {
        guard let configurator = configurator else { return }
        var sel = selectionRange
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length), options: []) { value, run, _ in
            guard let a = value as? SFTextAttachment else { return }
            if !configurator.isTextAttachmentValid(a) {
                let replacement = configurator.replacementAttributedString(forTextAttachment: a) ?? a.representedAttributedText
                s.replaceCharacters(in: run, with: replacement)
                if sel.location != NSNotFound {
                    sel = NSAttributedString.offsetSelectionRange(sel, forReplacementRange: NSRange(location: offset + run.location, length: run.length), replacementAttributedString: replacement)
                }
            } else if let fold = a as? MDFoldTextAttachment {
                let inner = fold.representedAttributedText.mutableCopy() as! NSMutableAttributedString
                var none = NSNotFoundRange
                self.validateTextAttachments(with: configurator, in: inner, selectionRange: &none, selectionLocationOffset: 0)
                if !inner.isEqual(to: fold.representedAttributedText) {
                    fold.collapsedRange.length += inner.length - fold.representedAttributedText.length
                    fold.representedAttributedText = inner
                }
            }
        }
        selectionRange = sel
    }

    /// The range that must be restyled when an attachment changes.
    public func additionalRange(forAttachment a: NSTextAttachment, at index: Int, in s: NSAttributedString) -> NSRange {
        if a.isList { return s.rangeOfListItem(at: index) }
        if a.isHeader { return s.headerRange(at: index) }
        if a.isTable || a.isThematicBreak { return (s.string as NSString).paragraphRange(for: NSRange(location: index, length: 1)) }
        if a.isLink { return s.linkRange(at: index) }
        if a.isBlockquote { return s.rangeOfBlockquoteItem(at: index) }
        if a.isMermaid { return s.codeBlockRange(at: index) }
        return NSRange(location: index, length: 1)
    }

    public func rearrangeAttachmentsViews(in textView: NSTextView, range: NSRange) {
        (textView.layoutManager as? MDLayoutManager)?.rearrangeAttachmentsViews(forCharacterRange: range, at: textView.textContainerOrigin)
    }

    /// An attachment (e.g. a checkbox) changed
    /// the markdown it stands for: push the change into the AST without touching the attributed string.
    public func textView(_ textView: NSTextView, didChangeAttachmentTextRepresentation attachment: SFTextAttachment, previousRepresentedText previous: String) {
        let ts = storage(textView)
        ts.attachmentTextDidChange()
        var fold = NSNotFoundRange
        let attachmentRange = ts.range(ofTextAttachment: attachment, foldRange: &fold)
        var stringRange: NSRange
        if fold.location == NSNotFound {
            stringRange = ts.stringRange(fromAttributedStringRange: NSRange(location: attachmentRange.location, length: 0))
        } else {
            let foldStart = ts.stringRange(fromAttributedStringRange: NSRange(location: fold.location, length: 0))
            let inner = (ts.textAttachment(at: fold.location) as? SFTextAttachment)?.representedAttributedText ?? NSAttributedString()
            stringRange = inner.stringRange(fromAttributedStringRange: attachmentRange)
            stringRange.location += foldStart.location
        }
        stringRange.length = (previous as NSString).length
        ts.recordNewReplacementChange(forStringRange: stringRange, replacementString: attachment.representedText)
        notifyTextChanges(in: textView)
    }

    public func replaceCharacters(in range: NSRange, with s: NSAttributedString, in textView: NSTextView) {
        undoManager(for: textView)?.beginUndoGrouping()
        replaceCharacters(in: range, with: s, selectRange: NSNotFoundRange, in: textView)
        performStyling(in: textView)
        undoManager(for: textView)?.endUndoGrouping()
    }

    // MARK: Edit interception

    /// Behaviour operations first (applied asynchronously),
    /// then the AST corrections. Returns false when the edit was handled here.
    public func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        guard let string = string else { return true }
        guard !(undoManager(for: textView)?.isUndoing ?? false), !(undoManager(for: textView)?.isRedoing ?? false) else { return true }
        if textView.hasMarkedText(), string != "" { return true }
        let ts = storage(textView)
        if let results = editorBehaviourController.results(forEditIn: range, replacementString: string, attributedString: ts, selectionRange: textView.selectedRange()) {
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyTextOperationResults(results, in: textView)
                guard string == " " else { return }
                self.restyleTask?.cancel()
                self.restyleTask = Task { @MainActor [weak self, weak textView] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, let textView else { return }
                    self.performStyling(in: textView)
                    self.restyleTask = nil
                }
            }
            return false
        }
        let selection = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        let stringRange = ts.stringRange(fromAttributedStringRange: range)
        let proposed = NSAttributedString.offsetSelectionRange(selection, forReplacementRange: stringRange, replacementLength: (string as NSString).length)
        let ast = ts.ast
        var results = ast.listItemSpaceCorrection(in: stringRange, replacementString: string, selectionRange: proposed)
        if results.isEmpty { results = ast.fencedCodeCorrection(in: stringRange, replacementString: string, selectionRange: proposed) }
        if results.isEmpty { results = ast.calloutCorrection(in: stringRange, replacementString: string, selectionRange: proposed) }
        if results.isEmpty { results = ast.mathBlockCorrection(in: stringRange, replacementString: string, selectionRange: proposed) }
        if results.isEmpty { results = ast.invalidCharacterCorrection(in: stringRange, replacementString: string, selectionRange: proposed) }
        if results.isEmpty, string == "" { results = ast.deleteWhitespaceCorrection(in: stringRange, replacementString: string, selectionRange: proposed) }
        guard !results.isEmpty else { return true }
        applyASTOperationResults(results, in: textView)
        return false
    }

    /// AST selection correction, then spacer skipping.
    public func adjustedSelection(for textView: NSTextView, currentSelection current: NSRange, proposedSelection proposed: NSRange) -> NSRange {
        let ts = storage(textView)
        var result = proposed
        if proposed.length != 0, !ts.editedCharacters {
            let currentString = ts.stringRange(fromAttributedStringRange: current)
            let proposedString = ts.stringRange(fromAttributedStringRange: proposed)
            if NSMaxRange(proposedString) <= ts.ast.markdownLength {
                let corrections = ts.ast.selectionCorrection(in: currentString, replacementString: nil, selectionRange: proposedString)
                if let last = corrections.last {
                    result = ts.attributedStringRange(fromStringRange: last.proposedSelection)
                }
            }
        }
        result = ts.spacersAdjustedSelection(forProposedSelection: result, currentSelection: current)
        return headingMarkerAdjustedSelection(result, currentSelection: current, in: ts)
    }

    /// The caret never stands before a heading marker: it goes after the marker, or, when it steps
    /// back onto the marker from the heading text, to the end of the line above.
    func headingMarkerAdjustedSelection(_ proposed: NSRange, currentSelection current: NSRange, in ts: NSAttributedString) -> NSRange {
        let loc = proposed.location
        guard proposed.length == 0, loc < ts.length,
              (ts.attribute(.attachment, at: loc, effectiveRange: nil) as? SFTextAttachment)?.isATXHeader == true else { return proposed }
        let steppedBack = current.length == 0 && current.location == loc + 1
        return NSRange(location: steppedBack && loc > 0 ? loc - 1 : loc + 1, length: 0)
    }

    // MARK: Notifications

    public func notifyTextChanges(in textView: NSTextView) {
        NotificationCenter.default.post(name: MDTextViewTextDidChangeNotification, object: textView)
    }

    public func notifyTextAttributesChanges(in textView: NSTextView) {
        NotificationCenter.default.post(name: MDTextViewTextAttributesDidChangeNotification, object: textView)
    }

    public func notifyTextSelectionChanges(in textView: NSTextView) {
        NotificationCenter.default.post(name: MDTextViewTextDidChangeSelectionNotification, object: textView)
    }

    // MARK: Typing attributes

    public func fixTypingAttributes(in textView: NSTextView) { fixTypingAttributes(in: textView, range: textView.selectedRange()) }

    /// At the very end of the text, typing uses the bidi styler's
    /// preferred paragraph style plus the paragraph indent.
    public func fixTypingAttributes(in textView: NSTextView, range: NSRange) {
        guard range.length == 0, range.location == storage(textView).length else { return }
        var attrs = textView.typingAttributes
        let p = attributedStringRenderer.bidiStyler.preferredParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        p.firstLineHeadIndent += attributedStringRenderer.bidiStyler.paragraphIndent
        attrs[.paragraphStyle] = p
        textView.typingAttributes = attrs
    }

    // MARK: Links (disabled links are stored under "_NSLinkAttributeName")

    public static let disabledLinkAttribute = NSAttributedString.Key("_NSLinkAttributeName")

    /// Links are clickable only while the view is not first responder.
    public func autodisableLinks(in textView: NSTextView) {
        if textView.window?.firstResponder === textView { disableLinks(in: textView) } else { enableLinks(in: textView) }
    }

    public func enableLinks(in textView: NSTextView) { enableLinks(in: textView, range: NSRange(location: 0, length: storage(textView).length)) }
    public func enableLinks(in textView: NSTextView, range: NSRange) { _ = enableLinks(in: storage(textView), range: range) }

    @discardableResult
    public func enableLinks(in s: NSMutableAttributedString, range: NSRange) -> Bool {
        var changed = false
        s.enumerateAttribute(Self.disabledLinkAttribute, in: range, options: []) { v, r, _ in
            guard let v = v else { return }
            s.addAttribute(.link, value: v, range: r)
            s.removeAttribute(Self.disabledLinkAttribute, range: r)
            changed = true
        }
        return changed
    }

    public func disableLinks(in textView: NSTextView) { disableLinks(in: textView, range: NSRange(location: 0, length: storage(textView).length)) }
    public func disableLinks(in textView: NSTextView, range: NSRange) { _ = disableLinks(in: storage(textView), range: range) }

    @discardableResult
    public func disableLinks(in s: NSMutableAttributedString, range: NSRange) -> Bool {
        var changed = false
        s.enumerateAttribute(.link, in: range, options: []) { v, r, _ in
            guard let v = v else { return }
            s.addAttribute(Self.disabledLinkAttribute, value: v, range: r)
            s.removeAttribute(.link, range: r)
            changed = true
        }
        return changed
    }

    public func url(at point: CGPoint, in textView: NSTextView) -> URL? {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return nil }
        let ts = storage(textView)
        for r in linkRanges(in: textView) + disabledLinkRanges(in: textView) {
            let rect = lm.boundingRect(forGlyphRange: r, in: container)
            guard rect.contains(point) else { continue }
            if let u = ts.attribute(.link, at: r.location, effectiveRange: nil) as? URL { return u }
            if let u = ts.attribute(Self.disabledLinkAttribute, at: r.location, effectiveRange: nil) as? URL { return u }
        }
        return nil
    }

    public func urls(in range: NSRange, in textView: NSTextView) -> [URL] {
        let ts = storage(textView)
        var out: [URL] = []
        for r in linkRanges(in: textView) + disabledLinkRanges(in: textView) {
            let overlaps = NSIntersectionRange(r, range).length > 0 || NSLocationInRange(range.location, r) || NSLocationInRange(r.location, range)
            guard overlaps else { continue }
            if let u = ts.attribute(.link, at: r.location, effectiveRange: nil) as? URL { out.append(u) }
            if let u = ts.attribute(Self.disabledLinkAttribute, at: r.location, effectiveRange: nil) as? URL { out.append(u) }
        }
        return out
    }

    public func linkRanges(in textView: NSTextView) -> [NSRange] { urlContainingRanges(withAttribute: .link, in: textView) }
    public func disabledLinkRanges(in textView: NSTextView) -> [NSRange] { urlContainingRanges(withAttribute: Self.disabledLinkAttribute, in: textView) }

    public func urlContainingRanges(withAttribute key: NSAttributedString.Key, in textView: NSTextView) -> [NSRange] {
        let ts = storage(textView)
        var out: [NSRange] = []
        ts.enumerateAttribute(key, in: NSRange(location: 0, length: ts.length), options: []) { v, r, _ in
            if v is URL || v is NSURL { out.append(r) }
        }
        return out
    }

    // MARK: Markdown hiding

    public func autoHideMarkdown(in textView: NSTextView, forOldSelectionRange old: NSRange, newSelectionRange new: NSRange) {
        let ts = storage(textView)
        guard !ts.editedCharactersOrAttributes else { return }
        MDMarkdownHider().showHideMarkdown(in: textView, oldSelectionRange: old, newSelectionRange: new)
        autoHideCalloutTitle(in: textView, forOldSelectionRange: old, newSelectionRange: new)
    }

    /// On an untitled callout head
    /// line the "Note" label disappears while the caret sits after the marker, so a title can be typed.
    public func autoHideCalloutTitle(in textView: NSTextView, forOldSelectionRange old: NSRange, newSelectionRange new: NSRange) {
        let ts = storage(textView)
        let ns = ts.string as NSString
        for (sel, hide) in [(old, false), (new, true)] {
            guard sel.length == 0, sel.location < ts.length, ts.attribute(.pmkCallout, at: sel.location, effectiveRange: nil) != nil else { continue }
            let para = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
            ts.enumerateCallout(in: para, options: []) { _, marker, title, _, _ in
                guard marker.location != NSNotFound, marker.location < sel.location, title.location == NSNotFound,
                      let att = ts.textAttachment(at: marker.location) as? MDCalloutTextAttachment else { return }
                if att.hideLabel != hide {
                    att.hideLabel = hide
                    ts.addAttribute(NSAttributedString.Key("TMP"), value: 1, range: marker)
                    ts.removeAttribute(NSAttributedString.Key("TMP"), range: marker)
                    textView.layoutManager?.ensureLayout(forCharacterRange: marker)
                    textView.layoutManager?.invalidateDisplay(forCharacterRange: marker)
                }
            }
        }
    }

    public func hideMarkdown(in textView: NSTextView, range: NSRange) {
        let hider = MDMarkdownHider()
        let ts = storage(textView)
        let ranges = hider.rangesToCheckForMarkdownHiding(for: range, in: ts)
        ts.beginEditing()
        for r in ranges { _ = hider.hideMarkdown(in: r, in: ts) }
        ts.endEditing()
    }

    public func showMarkdown(in textView: NSTextView, range: NSRange) {
        let hider = MDMarkdownHider()
        let ts = storage(textView)
        let r = hider.rangeToCheckForMarkdownShowing(for: range, in: ts)
        _ = hider.showMarkdown(in: r, in: ts)
    }

    /// Hide everything, then show around the selection.
    public func autoHideMarkdown(in s: NSMutableAttributedString, selectionRange: NSRange) {
        let hider = MDMarkdownHider()
        _ = hider.hideMarkdown(in: NSRange(location: 0, length: s.length), in: s)
        guard selectionRange.location != NSNotFound else { return }
        let r = MDMarkdownHider().rangeToCheckForMarkdownShowing(for: selectionRange, in: s)
        if r.location != NSNotFound { _ = hider.showMarkdown(in: r, in: s) }
    }

    @discardableResult
    public func hideMarkdown(in range: NSRange, in s: NSMutableAttributedString, expandingRangeForAttributes expand: Bool = false) -> Bool {
        let hider = MDMarkdownHider()
        guard expand else { return hider.hideMarkdown(in: range, in: s) }
        guard range.location != NSNotFound else { return false }
        for r in hider.rangesToCheckForMarkdownHiding(for: range, in: s) { _ = hider.hideMarkdown(in: r, in: s) }
        return false
    }

    @discardableResult
    public func showMarkdown(in range: NSRange, in s: NSMutableAttributedString, expandingRangeForAttributes expand: Bool = false) -> Bool {
        let hider = MDMarkdownHider()
        guard expand else { return hider.showMarkdown(in: range, in: s) }
        guard range.location != NSNotFound else { return false }
        let r = MDMarkdownHider().rangeToCheckForMarkdownShowing(for: range, in: s)
        guard r.location != NSNotFound else { return false }
        return hider.showMarkdown(in: r, in: s)
    }

    // MARK: Applying operation results

    public func applyASTOperationResults(_ results: [PMKASTOperationResult], in textView: NSTextView) {
        applyASTOperationResults(results, in: textView, postTextDidChange: true)
    }

    /// Expands attachments over the union of the results,
    /// applies every replacement to the plain markdown, replaces once, then sets the last proposed selection.
    public func applyASTOperationResults(_ results: [PMKASTOperationResult], in textView: NSTextView, postTextDidChange post: Bool) {
        guard let first = results.first, let last = results.last else { return }
        let ts = storage(textView)
        let union = NSUnionRange(first.replacementRange, last.replacementRange)
        let attributedRange = ts.attributedStringRange(fromStringRange: union)
        let expanded = NSMutableString(string: ts.stringByExpandingTextAttachments(in: attributedRange))
        let base = ts.stringRange(fromAttributedStringRange: NSRange(location: attributedRange.location, length: 0)).location
        for r in results {
            expanded.replaceCharacters(in: NSRange(location: r.replacementRange.location - base, length: r.replacementRange.length), with: r.replacementString)
        }
        replaceCharacters(in: attributedRange, with: NSAttributedString(string: expanded as String), selectRange: NSNotFoundRange, in: textView)
        let selection = ts.attributedStringRange(fromStringRange: last.proposedSelection)
        textView.setSelectedRange(selection)
        if post { postTextDidChange(textView) }
    }

    public func expandTextAttachments(forASTOperationResults results: [PMKASTOperationResult], in textView: NSTextView) {
        let ts = storage(textView)
        for r in results {
            if r.replacementRange.length == 0, r.replacementString == "" { continue }
            let range = ts.attributedStringRange(fromStringRange: r.replacementRange)
            if range.length == 0 {
                if let a = ts.textAttachment(at: range.location) as? SFTextAttachment {
                    replaceCharacters(in: NSRange(location: range.location, length: 1), with: a.representedAttributedText, selectRange: NSNotFoundRange, in: textView)
                }
            } else {
                ts.enumerateAttribute(.attachment, in: range, options: []) { v, run, _ in
                    guard let a = v as? SFTextAttachment else { return }
                    self.replaceCharacters(in: NSRange(location: run.location, length: 1), with: a.representedAttributedText, selectRange: NSNotFoundRange, in: textView)
                }
            }
        }
    }

    public func applyTextOperationResult(_ result: MDTextOperationResult, in textView: NSTextView) {
        guard let replacement = result.replacementAttributedString else {
            textView.setSelectedRange(result.proposedSelectionRange)
            return
        }
        undoManager(for: textView)?.beginUndoGrouping()
        replaceCharacters(in: result.replacementRange, with: replacement, selectRange: result.proposedSelectionRange, in: textView)
        if result.needStyling { postTextDidChange(textView) }
        undoManager(for: textView)?.endUndoGrouping()
    }

    public func applyTextOperationResults(_ results: [MDTextOperationResult], in textView: NSTextView) {
        undoManager(for: textView)?.beginUndoGrouping()
        var styled = NSNotFoundRange
        for r in results {
            guard let replacement = r.replacementAttributedString else {
                textView.setSelectedRange(r.proposedSelectionRange)
                continue
            }
            replaceCharacters(in: r.replacementRange, with: replacement, selectRange: r.proposedSelectionRange, in: textView)
            let applied = NSRange(location: r.replacementRange.location, length: replacement.length)
            guard r.needStyling else { continue }
            if styled.location == NSNotFound {
                styled = applied
            } else {
                if applied.location < styled.location { styled.location = styled.location - r.replacementRange.length + replacement.length }
                styled = NSUnionRange(styled, applied)
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        if styled.location != NSNotFound { postTextDidChange(textView) }
        undoManager(for: textView)?.endUndoGrouping()
    }

    /// Posts the text-did-change notification; the text view's `didChangeText` restyles.
    /// Tells the delegate synchronously (no `didChangeText`).
    private func postTextDidChange(_ textView: NSTextView) {
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))
    }

    // MARK: Commands

    private func selectionStringRange(_ textView: NSTextView) -> NSRange {
        storage(textView).stringRange(fromAttributedStringRange: textView.selectedRange())
    }

    private func run(_ textView: NSTextView, _ body: (PMKAST, NSRange) -> [PMKASTOperationResult]) -> Bool {
        let results = body(storage(textView).ast, selectionStringRange(textView))
        guard !results.isEmpty else { return false }
        applyASTOperationResults(results, in: textView)
        return true
    }

    public func toggleTask(in textView: NSTextView, range: NSRange, style: Int) {
        let ts = storage(textView)
        let selection = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        let r = ts.stringRange(fromAttributedStringRange: range)
        let results = ts.ast.toggleTask(in: r, selectionRange: selection, style: style)
        if !results.isEmpty { applyASTOperationResults(results, in: textView) }
    }

    public func orderTasks(in textView: NSTextView, range: NSRange) {
        if let r = MDOrderTaskListTextOperation().result(forAttributedString: storage(textView), in: range, selectionRange: textView.selectedRange()) {
            applyTextOperationResult(r, in: textView)
        }
    }

    /// True lets the text view delete one character itself.
    public func textViewShouldDeleteBackward(_ textView: NSTextView) -> Bool {
        let sel = selectionStringRange(textView)
        let results = storage(textView).ast.deletePrevious(in: sel, selectionRange: sel)
        if results.isEmpty { return true }
        if results.count == 1, results[0].replacementRange == sel, results[0].replacementString == "" { return true }
        applyASTOperationResults(results, in: textView)
        return false
    }

    public func textViewShouldDeleteForward(_ textView: NSTextView) -> Bool {
        let sel = selectionStringRange(textView)
        let results = storage(textView).ast.deleteNext(in: sel, selectionRange: sel)
        if results.isEmpty { return true }
        if results.count == 1, results[0].replacementRange == sel, results[0].replacementString == "" { return true }
        applyASTOperationResults(results, in: textView)
        return false
    }

    public func insertThematicBreak(in textView: NSTextView) { _ = run(textView) { $0.insertThematicBreak(in: $1, selectionRange: $1) } }
    public func canAddIndent(in textView: NSTextView) -> Bool { !storage(textView).ast.indent(in: selectionStringRange(textView), selectionRange: selectionStringRange(textView)).isEmpty }
    public func addIndent(in textView: NSTextView) { _ = run(textView) { $0.indent(in: $1, selectionRange: $1) } }
    public func canRemoveIndent(in textView: NSTextView) -> Bool { !storage(textView).ast.outdent(in: selectionStringRange(textView), selectionRange: selectionStringRange(textView)).isEmpty }
    public func removeIndent(in textView: NSTextView) { _ = run(textView) { $0.outdent(in: $1, selectionRange: $1) } }

    /// True lets the text view insert a plain newline.
    public func textViewShouldInsertNewLine(_ textView: NSTextView) -> Bool {
        let sel = selectionStringRange(textView)
        let results = storage(textView).ast.insertNewline(in: sel, selectionRange: sel)
        if results.isEmpty { return true }
        if results.count == 1, results[0].replacementRange == sel, results[0].replacementString == "\n" { return true }
        applyASTOperationResults(results, in: textView)
        return false
    }

    public func textViewShouldInsertTab(_ textView: NSTextView) -> Bool { !run(textView) { $0.indent(in: $1, selectionRange: $1) } }
    public func textViewShouldRemoveTab(_ textView: NSTextView) -> Bool { !run(textView) { $0.outdent(in: $1, selectionRange: $1) } }
    public func moveParagraphUp(in textView: NSTextView) { _ = run(textView) { $0.moveLinesUp(in: $1, selectionRange: $1) } }
    public func moveParagraphDown(in textView: NSTextView) { _ = run(textView) { $0.moveLinesDown(in: $1, selectionRange: $1) } }

    public func dragRange(_ drag: NSRange, toRange destination: NSRange, in textView: NSTextView, dropAsNewLine: Bool) -> Bool {
        guard let r = MDDragTextOperation().result(forAttributedString: storage(textView), dragRange: drag, destinationRange: destination, selectionRange: textView.selectedRange(), dropAsNewLine: dropAsNewLine) else { return true }
        applyTextOperationResult(r, in: textView)
        return false
    }

    /// Where "move to beginning of line" should land:
    /// right after the list/quote/heading marker of the current line.
    public func selectionToFirstBlockMarker(in textView: NSTextView, limitToLineRange: Bool) -> NSRange {
        let ts = storage(textView)
        let sel = textView.selectedRange()
        let ns = ts.string as NSString
        var probe: Int
        if sel.location < ts.length {
            probe = sel.location == 0 ? 0 : sel.location - (ns.character(at: sel.location - 1) == 0x0A ? 0 : 1)
        } else {
            probe = sel.location - 1
        }
        probe = max(0, probe)
        var lineRange: NSRange
        if limitToLineRange, let lm = textView.layoutManager {
            var glyphs = NSRange()
            _ = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: probe), effectiveRange: &glyphs)
            lineRange = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        } else {
            lineRange = ns.paragraphRange(for: sel)
        }
        var marker = NSNotFoundRange
        if ts.isRangeInsideList(NSRange(location: probe, length: 0)) {
            _ = ts.rangeOfListItem(at: probe, markerRange: &marker)
        } else if ts.isRangeInsideBlockquote(NSRange(location: probe, length: 0)) {
            _ = ts.rangeOfBlockquoteItem(at: probe, markerRange: &marker)
        } else if ts.isRangeInsideHeader(NSRange(location: probe, length: 0)) {
            _ = ts.headerRange(at: probe, markerRange: &marker)
        }
        guard marker.location != NSNotFound, NSIntersectionRange(lineRange, marker).length != 0 else { return NSRange(location: NSNotFound, length: 0) }
        let end = NSMaxRange(marker)
        guard end < sel.location else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: end, length: NSMaxRange(sel) - end)
    }

    public func handleMoveToLeftEndOfLine(in textView: NSTextView, extendSelection: Bool) -> Bool {
        let target = selectionToFirstBlockMarker(in: textView, limitToLineRange: true)
        guard target.location != NSNotFound else { return false }
        let paragraph = (storage(textView).string as NSString).paragraphRange(for: textView.selectedRange())
        guard paragraph.location <= target.location, target.location - paragraph.location < paragraph.length else { return false }
        textView.setSelectedRange(NSRange(location: target.location, length: extendSelection ? target.length : 0))
        return true
    }

    public func handleDeleteToBeginningOfLine(in textView: NSTextView) -> Bool {
        let target = selectionToFirstBlockMarker(in: textView, limitToLineRange: true)
        guard target.location != NSNotFound else { return false }
        let paragraph = (storage(textView).string as NSString).paragraphRange(for: textView.selectedRange())
        guard paragraph.location <= target.location, target.location - paragraph.location < paragraph.length else { return false }
        replaceCharacters(in: target, with: NSAttributedString(string: ""), selectRange: NSNotFoundRange, in: textView)
        postTextDidChange(textView)
        return true
    }

    public func pasteCorrection(forReplacementString string: String, range: NSRange, in textView: NSTextView) -> Bool {
        let ts = storage(textView)
        let selection = ts.stringRange(fromAttributedStringRange: textView.selectedRange())
        let r = ts.stringRange(fromAttributedStringRange: range)
        let proposed = NSAttributedString.offsetSelectionRange(selection, forReplacementRange: r, replacementLength: (string as NSString).length)
        let results = ts.ast.pasteCorrection(in: r, replacementString: string, selectionRange: proposed)
        guard !results.isEmpty else { return false }
        applyASTOperationResults(results, in: textView)
        return true
    }

    public func applyToggleStyleOperation(_ op: MDBaseTextOperation, in textView: NSTextView) {
        if let r = op.result(forAttributedString: storage(textView), in: textView.selectedRange(), selectionRange: textView.selectedRange()) {
            applyTextOperationResult(r, in: textView)
        }
    }

    /// With a highlighter icon selected, toggles the whole highlight.
    public func toggleInlineStyle(_ style: Int, in textView: NSTextView) {
        let ts = storage(textView)
        var selection = textView.selectedRange()
        var restore = NSNotFoundRange
        var restoreLength = 0
        if selection.length == 1, let a = ts.textAttachment(at: selection.location), a.isHighlighter {
            restore = selection
            selection = ts.highlighterRange(at: selection.location)
            restoreLength = 1
        }
        let stringSelection = ts.stringRange(fromAttributedStringRange: selection)
        let results = ts.ast.toggleInlineStyle(in: stringSelection, selectionRange: stringSelection, style: style)
        if !results.isEmpty { applyASTOperationResults(results, in: textView) }
        if restore.location != NSNotFound, let a = ts.textAttachment(at: restore.location), a.isHighlighter {
            textView.setSelectedRange(NSRange(location: restore.location, length: restoreLength))
        }
    }

    /// What the selection is inside, so a toolbar lights the toggle that would undo it.
    public func formatting(in textView: NSTextView) -> MDFormatting { storage(textView).formatting(in: textView.selectedRange()) }

    public func toggleStrong(in tv: NSTextView) { toggleInlineStyle(0, in: tv) }
    public func toggleEmphasis(in tv: NSTextView) { toggleInlineStyle(1, in: tv) }
    public func toggleStrikethrough(in tv: NSTextView) { toggleInlineStyle(2, in: tv) }
    public func toggleUnderline(in tv: NSTextView) { toggleInlineStyle(3, in: tv) }
    public func toggleHighlighter(in tv: NSTextView) { toggleInlineStyle(4, in: tv) }
    public func toggleCode(in tv: NSTextView) { toggleInlineStyle(10, in: tv) }

    public func toggleBlockStyle(_ style: Int, in textView: NSTextView) {
        _ = run(textView) { $0.toggleBlockStyle(in: $1, selectionRange: $1, style: style) }
    }

    /// Levels 2…6 map to styles 1…5, anything else is heading 1.
    public func toggleHeading(in tv: NSTextView, headingLevel level: Int) {
        let style = (2...6).contains(level) ? level - 1 : 0
        toggleBlockStyle(style, in: tv)
    }
    public func toggleUnorderedList(in tv: NSTextView) { toggleBlockStyle(6, in: tv) }
    public func toggleOrderedList(in tv: NSTextView) { toggleBlockStyle(7, in: tv) }
    public func toggleTaskList(in tv: NSTextView) { toggleBlockStyle(8, in: tv) }
    public func toggleBlockQuote(in tv: NSTextView) { toggleBlockStyle(9, in: tv) }
    public func toggleCodeBlock(in tv: NSTextView) { toggleBlockStyle(10, in: tv) }
    public func orderCheckboxes(in tv: NSTextView) { applyToggleStyleOperation(MDOrderTaskListTextOperation(), in: tv) }
}
