import AppKit
import MDTextStorageCore
import PolarMark

/// Told from `processEditing`, on the thread TextKit edits on; `MDTextView` keeps attachment views in step.
public protocol MDTextStorageDelegate: AnyObject {
    /// Called from `processEditing` after the AST was updated.
    func textStorage(_ storage: MDTextStorage, processedChanges tracker: MDAttributedStringChangeTracker)
    func textStorage(_ storage: MDTextStorage, didAddAttachment attachment: NSTextAttachment)
    func textStorage(_ storage: MDTextStorage, didRemoveAttachment attachment: NSTextAttachment)
}

public extension MDTextStorageDelegate {
    func textStorage(_ storage: MDTextStorage, processedChanges tracker: MDAttributedStringChangeTracker) {}
    func textStorage(_ storage: MDTextStorage, didAddAttachment attachment: NSTextAttachment) {}
    func textStorage(_ storage: MDTextStorage, didRemoveAttachment attachment: NSTextAttachment) {}
}

/// `MDTextStorage : NSTextStorage`. Backed by a plain NSMutableAttributedString
/// (`_imp`). Every edit is recorded by the change tracker; `processEditing` pushes the
/// recorded edits into the PolarMark AST (in markdown coordinates, which differ from the
/// attributed string's because attachments replace markdown runs) and remembers the
/// range that must be re-styled (`currentReparsedRange`, markdown coordinates).
public final class MDTextStorage: MDAttributedStorage {
    public var ast = PMKAST(markdown: "")
    public var changeTracker = MDAttributedStringChangeTracker()
    public var currentReparsedRange = NSNotFoundRange
    public var preventASTChanges = false
    public weak var mdDelegate: MDTextStorageDelegate?

    /// True while an edit of that kind is being processed.
    public var editedCharacters: Bool { editedMask.contains(.editedCharacters) && isProcessingEdits }
    public var editedCharactersOrAttributes: Bool { (editedMask.contains(.editedCharacters) || editedMask.contains(.editedAttributes)) && isProcessingEdits }
    private var isProcessingEdits = false

    public override init() {
        super.init()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { fatalError() }

    // MARK: NSAttributedString primitives

    /// Bridged once per edit: TextKit asks for the string and its length on every attribute run.
    private var cachedString: String?

    public override var string: String {
        if let cachedString { return cachedString }
        let string = imp.string
        cachedString = string
        return string
    }

    /// The backing string, for walks that must not pay Swift's bridging of every attribute run.
    public var backing: NSAttributedString { imp }

    // MARK: Attachment table

    /// One attachment, where it sits and how much markdown it stands for.
    public struct AttachmentEntry {
        public var location: Int
        public let attachment: SFTextAttachment
        /// The markdown offset of the first represented character; valid once the table is rebuilt.
        public var markdownStart = 0
        public var markdownLength = 0
    }

    private var entries: [AttachmentEntry] = []
    private var tableIsStale = true

    /// Every `SFTextAttachment` in order, with markdown offsets, so a coordinate walk is a lookup.
    public var attachmentTable: [AttachmentEntry] {
        if tableIsStale { rebuildTable() }
        return entries
    }

    /// Called when an attachment's represented text changed in place, as a table cell edit does.
    public func attachmentTextDidChange() { tableIsStale = true }

    private func rebuildTable() {
        var markdownDelta = 0
        for i in entries.indices {
            let length = (entries[i].attachment.representedText as NSString).length
            entries[i].markdownLength = length
            entries[i].markdownStart = entries[i].location + markdownDelta
            markdownDelta += length - 1
        }
        tableIsStale = false
    }

    private func entryIndex(atOrAfter location: Int) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func tableDidReplace(_ range: NSRange, delta: Int) {
        let first = entryIndex(atOrAfter: range.location)
        let end = entryIndex(atOrAfter: NSMaxRange(range))
        if first < end { entries.removeSubrange(first..<end) }
        if delta != 0 { for i in first..<entries.count { entries[i].location += delta } }
        tableIsStale = true
    }

    private func tableDidSetAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        guard range.length > 0 else { return }
        let first = entryIndex(atOrAfter: range.location)
        let end = entryIndex(atOrAfter: NSMaxRange(range))
        if let attachment = attrs?[.attachment] as? SFTextAttachment {
            let replacement = (range.location..<NSMaxRange(range)).map { AttachmentEntry(location: $0, attachment: attachment) }
            entries.replaceSubrange(first..<end, with: replacement)
        } else if first < end {
            entries.removeSubrange(first..<end)
        } else {
            return
        }
        tableIsStale = true
    }

    /// `stringRange(fromAttributedStringRange:)` from the table: two binary searches and a sum.
    public func markdownRange(fromAttributedRange range: NSRange) -> NSRange {
        let table = attachmentTable
        let limit = min(NSMaxRange(range), length)
        var before = 0
        var inside = 0
        var i = 0
        while i < table.count, table[i].location < limit {
            let delta = table[i].markdownLength - 1
            if table[i].location < range.location { before += delta } else { inside += delta }
            i += 1
        }
        return NSRange(location: range.location + before, length: range.length + inside)
    }

    /// Where an index walk towards markdown offset `markdown` may begin: the last attachment with
    /// represented text that starts before it, so the walk still sees one report before the target.
    public func walkStart(forMarkdownOffset markdown: Int) -> (location: Int, markdownStart: Int)? {
        let table = attachmentTable
        var low = 0
        var high = table.count
        while low < high {
            let mid = (low + high) / 2
            if table[mid].markdownStart < markdown { low = mid + 1 } else { high = mid }
        }
        var i = low - 1
        while i >= 0 {
            let entry = table[i]
            if entry.markdownLength > 0, entry.markdownStart <= markdown - 1 { return (entry.location, entry.markdownStart) }
            i -= 1
        }
        return nil
    }

    /// The markdown, assembled from the string between attachments and each attachment's text.
    public var markdown: String {
        let table = attachmentTable
        let ns = string as NSString
        let result = NSMutableString(capacity: ns.length)
        var cursor = 0
        for entry in table {
            if entry.location > cursor { result.append(ns.substring(with: NSRange(location: cursor, length: entry.location - cursor))) }
            result.append(entry.attachment.representedText)
            cursor = entry.location + 1
        }
        if cursor < ns.length { result.append(ns.substring(from: cursor)) }
        return result as String
    }


    /// Resets tracking and the AST, then lets NSTextStorage do the replacement.
    public override func setAttributedString(_ attrString: NSAttributedString) {
        preventASTChanges = true
        replaceCharacters(in: NSRange(location: 0, length: length), with: "")
        preventASTChanges = false
        ast.reset()
        changeTracker.resetChanges()
        currentReparsedRange = NSNotFoundRange
        super.setAttributedString(attrString)
    }

    public override func replaceCharacters(in range: NSRange, with str: String) {
        changeTracker.trackReplaceCharacters(in: range, in: imp, with: str, plainRange: markdownRange(fromAttributedRange: range))
        imp.replaceCharacters(in: range, with: NSAttributedString(string: str))
        cachedString = nil
        tableDidReplace(range, delta: (str as NSString).length - range.length)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
    }

    public override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        changeTracker.trackSetAttributes(attrs ?? [:], in: imp, range: range)
        imp.setAttributes(attrs, range: range)
        tableDidSetAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    // MARK: Editing pipeline

    public override func processEditing() {
        isProcessingEdits = true
        processChanges()
        super.processEditing()
        isProcessingEdits = false
    }

    private func processChanges() {
        updateAST(with: changeTracker.changes)
        mdDelegate?.textStorage(self, processedChanges: changeTracker)
        for a in changeTracker.addedAttachments { mdDelegate?.textStorage(self, didAddAttachment: a) }
        for a in changeTracker.removedAttachments { mdDelegate?.textStorage(self, didRemoveAttachment: a) }
        changeTracker.resetChanges()
    }

    private func updateAST(with changes: [MDAttributedStringChange]) {
        guard !changes.isEmpty, !preventASTChanges else { return }
        for change in changes {
            let replacement = change.currentString
            let reparsed = ast.replaceRange(change.oldPlainRange, withMarkdown: replacement)
            validateAndSetReparsedRange(reparsed, forReplacementRange: change.oldPlainRange, replacementLength: (replacement as NSString).length)
        }
    }

    /// Keeps the union
    /// of every reparsed range, shifting the earlier ones past the new edit.
    public func validateAndSetReparsedRange(_ reparsed: NSRange, forReplacementRange replacement: NSRange, replacementLength: Int) {
        var result = reparsed
        if currentReparsedRange.location != NSNotFound {
            currentReparsedRange = NSAttributedString.offsetSelectionRange(currentReparsedRange, forReplacementRange: replacement, replacementLength: replacementLength)
            result = NSUnionRange(currentReparsedRange, reparsed)
        }
        currentReparsedRange = result
    }

    /// Hands the annotated markdown of the reparsed range and
    /// the matching attributed-string range to the styler, then clears the pending range.
    public func parseChanges(using block: (NSAttributedString, NSRange) -> Void) {
        if currentReparsedRange.location != NSNotFound {
            let annotated = ast.annotatedString(forStringRange: currentReparsedRange)
            let attributedRange = attributedStringRange(fromStringRange: currentReparsedRange)
            preventASTChanges = true
            block(annotated, attributedRange)
            preventASTChanges = false
        }
        currentReparsedRange = NSNotFoundRange
    }

    /// Used when an
    /// operation already applied a replacement to the AST directly.
    public func recordNewReplacementChange(forStringRange range: NSRange, replacementString: String) {
        ast.replaceRange(range, withMarkdown: replacementString)
        if currentReparsedRange.location != NSNotFound {
            currentReparsedRange = NSAttributedString.offsetSelectionRange(currentReparsedRange, forReplacementRange: range, replacementLength: (replacementString as NSString).length)
        }
    }
}
