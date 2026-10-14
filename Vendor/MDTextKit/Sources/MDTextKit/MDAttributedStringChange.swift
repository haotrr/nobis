import AppKit

/// One recorded edit, in both the attributed
/// (attachment-bearing) and the plain markdown coordinate spaces.
public final class MDAttributedStringChange: NSObject {
    public var oldPlainRange = NSRange()
    public var oldAttributedRange = NSRange()
    public var oldAttributedString: NSAttributedString?
    public var currentPlainRange = NSRange()
    public var currentAttributedRange = NSRange()
    public var currentAttributedString: NSMutableAttributedString?

    public var isDiscardable: Bool { oldString == currentString }
    public var oldString: String { oldAttributedString?.stringByExpandingTextAttachments ?? "" }
    public var currentString: String { currentAttributedString?.stringByExpandingTextAttachments ?? "" }

    public override var description: String {
        "\(super.description) replaced \(NSStringFromRange(oldPlainRange)) '\(oldString)' with \(NSStringFromRange(currentPlainRange)) '\(currentString)'"
    }
}

/// `MDAttributedStringChangeTracker`. Records every character / attribute edit
/// made on the text storage between two `processEditing` passes, plus the attachments
/// that were added or removed (net of each other).
public final class MDAttributedStringChangeTracker: NSObject {
    public private(set) var changes: [MDAttributedStringChange] = []
    private var attachmentAdded = NSCountedSet()
    private var attachmentRemoved = NSCountedSet()
    private var attachmentAddedOrder = NSMutableOrderedSet()
    private var attachmentRemovedOrder = NSMutableOrderedSet()

    public func resetChanges() {
        changes.removeAll()
        attachmentAdded.removeAllObjects()
        attachmentRemoved.removeAllObjects()
        attachmentAddedOrder.removeAllObjects()
        attachmentRemovedOrder.removeAllObjects()
    }

    public func trackReplaceCharacters(in range: NSRange, in attributedString: NSAttributedString, with string: String, plainRange: NSRange? = nil) {
        let change = MDAttributedStringChange()
        change.oldPlainRange = plainRange ?? attributedString.stringRange(fromAttributedStringRange: range)
        change.oldAttributedRange = range
        change.oldAttributedString = attributedString.attributedSubstring(from: range)
        let newLength = (string as NSString).length
        change.currentAttributedString = NSMutableAttributedString(string: string)
        change.currentAttributedRange = NSRange(location: range.location, length: newLength)
        change.currentPlainRange = NSRange(location: change.oldPlainRange.location, length: newLength)
        changes.append(change)
        if range.length != 0 {
            for i in range.location..<NSMaxRange(range) {
                if let att = attributedString.attributes(at: i, effectiveRange: nil)[.attachment] as? NSTextAttachment {
                    attachmentRemoved.add(att)
                    attachmentRemovedOrder.add(att)
                }
            }
        }
    }

    /// An attachment being set on an
    /// attachment character is folded into the last recorded change so the plain range stays right.
    public func trackSetAttributes(_ attrs: [NSAttributedString.Key: Any], in attributedString: NSAttributedString, range: NSRange) {
        guard range.length < 2, range.location < attributedString.length else { return }
        guard (attributedString.string as NSString).character(at: range.location) == 0xFFFC,
              let att = attrs[.attachment] as? SFTextAttachment else { return }
        if let last = changes.last, let cur = last.currentAttributedString {
            let inter = NSIntersectionRange(range, last.currentAttributedRange)
            if inter.length > 0 {
                cur.addAttribute(.attachment, value: att, range: NSRange(location: inter.location - last.currentAttributedRange.location, length: inter.length))
                let textLength = (att.representedText as NSString).length
                last.currentPlainRange = NSRange(location: last.currentPlainRange.location,
                                                 length: last.currentPlainRange.length + textLength - inter.length)
            }
        }
        if range.length > 0 {
            for i in range.location..<NSMaxRange(range) {
                if let existing = attributedString.attributes(at: i, effectiveRange: nil)[.attachment] as? NSTextAttachment, existing !== att {
                    attachmentRemoved.add(existing)
                    attachmentRemovedOrder.add(existing)
                }
            }
        }
        let current = attributedString.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
        if current !== att {
            attachmentAdded.add(att)
            attachmentAddedOrder.add(att)
        }
    }

    /// Added more times than removed, in insertion order.
    public var addedAttachments: [NSTextAttachment] {
        attachmentAddedOrder.array.compactMap { obj -> NSTextAttachment? in
            guard let a = obj as? NSTextAttachment else { return nil }
            return attachmentAdded.count(for: a) - attachmentRemoved.count(for: a) > 0 ? a : nil
        }
    }

    public var removedAttachments: [NSTextAttachment] {
        attachmentRemovedOrder.array.compactMap { obj -> NSTextAttachment? in
            guard let a = obj as? NSTextAttachment else { return nil }
            return attachmentAdded.count(for: a) - attachmentRemoved.count(for: a) < 0 ? a : nil
        }
    }
}
