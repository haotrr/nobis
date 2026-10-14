import AppKit
import PolarMark

/// `SFTextAttachment : NSTextAttachment`. Every visual element that replaces
/// markdown text (heading hashes, bullets, checkboxes, rules, ...) is one of these.
/// `representedAttributedText` is the exact markdown it stands for, so the
/// markdown can always be rebuilt from the attributed string.
open class SFTextAttachment: NSTextAttachment {
    public var representedAttributedText: NSAttributedString = NSAttributedString(string: "") {
        didSet { cachedRepresentedText = nil }
    }
    /// Every coordinate walk asks each attachment for its text; expanding it each time was the walk.
    private var cachedRepresentedText: String?
    public var attachmentFileWrapper: FileWrapper?
    public var drawingRect: CGRect = .zero
    public var attachmentBaselineOffset: CGFloat = 0
    public private(set) var preventAttachmentImageRendering = false
    public private(set) var hidden = false
    public var hiddenWithBounds = false
    private var storedAttachmentSize: CGSize = .zero

    public override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        commonInit()
    }

    public convenience init() {
        self.init(representedAttributedText: nil)
    }

    public required init(representedAttributedText: NSAttributedString?) {
        super.init(data: nil, ofType: nil)
        self.representedAttributedText = representedAttributedText ?? NSAttributedString(string: "")
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        decode(with: coder)
        commonInit()
        updateAttachmentImage()
    }

    open func commonInit() {
        // TextKit builds attachments on the main thread; NSCell is main-actor and the attachment is not.
        attachmentCell = MainActor.assumeIsolated { SFTextAttachmentCell() }
    }

    /// The markdown behind this attachment (expanding nested attachments).
    public var representedText: String {
        if let cachedRepresentedText { return cachedRepresentedText }
        let text = representedAttributedText.stringByExpandingTextAttachments
        cachedRepresentedText = text
        return text
    }

    /// Subclasses rebuild cached images here.
    open func updateAttachmentImage() {}

    public func setPreventAttachmentImageRendering(_ prevent: Bool) {
        preventAttachmentImageRendering = prevent
        if prevent { image = nil }
    }

    /// The one-character string carrying this attachment plus
    /// the attributes of the represented text's first character.
    public var attachmentAttributedString: NSAttributedString {
        let attrs = representedAttributedText.length == 0 ? nil : representedAttributedText.attributes(at: 0, effectiveRange: nil)
        return attachmentAttributedString(with: attrs)
    }

    public func attachmentAttributedString(with attributes: [NSAttributedString.Key: Any]?) -> NSAttributedString {
        let s = NSAttributedString(attachment: self)
        guard let attributes = attributes else { return s }
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttributes(attributes, range: NSRange(location: 0, length: 1))
        return m
    }

    // MARK: Hiding

    public var isHidden: Bool {
        get { hidden }
        set { setHidden(newValue, keepBounds: false) }
    }

    public func setHidden(_ hidden: Bool, keepBounds: Bool) {
        self.hidden = hidden
        hiddenWithBounds = keepBounds
        if !keepBounds && hidden {
            bounds = .zero
            return
        }
        if !hidden {
            bounds = CGRect(origin: .zero, size: attachmentSize)
            hiddenWithBounds = false
        }
    }

    public var attachmentSize: CGSize {
        get { (hidden && !hiddenWithBounds) ? .zero : storedAttachmentSize }
        set {
            storedAttachmentSize = newValue
            bounds = CGRect(origin: .zero, size: newValue)
        }
    }

    public var unhiddenAttachmentSize: CGSize { storedAttachmentSize }

    public func maxWidthAttachment(at index: Int, for container: NSTextContainer) -> CGFloat {
        let width = container.size.width
        let padding = container.lineFragmentPadding
        let p = container.layoutManager?.textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return width - padding * 2 - (p?.headIndent ?? 0) + (p?.tailIndent ?? 0)
    }

    open var wantAttachmentBaselineOffset: Bool { true }

    // MARK: Drawing

    public func drawAttachment(inFullRect rect: CGRect) {
        if hidden { return }
        var r = rect
        if drawingRect != .zero {
            r = CGRect(x: rect.origin.x + drawingRect.origin.x, y: rect.origin.y + drawingRect.origin.y,
                       width: drawingRect.width, height: drawingRect.height)
        }
        drawAttachment(in: r)
    }

    open func drawAttachment(in rect: CGRect) {}

    // NSTextAttachment's 4-argument attachmentBounds(for:...) is not overridden; only the cell path
    // (SFTextAttachmentCell.cellFrame → attachmentBounds(...proposedRect:)) applies the baseline offset.

    open func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                               characterIndex charIndex: Int, proposedRect: CGRect) -> CGRect {
        CGRect(x: proposedRect.origin.x, y: proposedRect.origin.y + attachmentBaselineOffset, width: proposedRect.width, height: proposedRect.height)
    }

    open override var description: String { "\(super.description) hidden=\(hidden)" }

    // MARK: Metadata

    public var metadata: [String: Any]? {
        guard representedAttributedText.length > 0 else { return nil }
        return representedAttributedText.attribute(.pmkMetadata, at: representedAttributedText.length - 1, effectiveRange: nil) as? [String: Any]
    }

    public var hasPreviewMetadata: Bool { (metadata?["preview"] as? Bool) ?? false }

    // MARK: Coding / copying

    open func decode(with coder: NSCoder) {
        if let t = coder.decodeObject(of: NSAttributedString.self, forKey: "representedAttributedText") { representedAttributedText = t }
        if let v = coder.decodeObject(of: NSValue.self, forKey: "attachmentSize") { attachmentSize = v.sizeValue }
        if let v = coder.decodeObject(of: NSValue.self, forKey: "drawingRect") { drawingRect = v.rectValue }
        if let n = coder.decodeObject(of: NSNumber.self, forKey: "attachmentBaselineOffset") { attachmentBaselineOffset = CGFloat(n.doubleValue) }
        if let w = coder.decodeObject(of: FileWrapper.self, forKey: "attachmentFileWrapper") { attachmentFileWrapper = w }
    }

    open override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(representedAttributedText, forKey: "representedAttributedText")
        coder.encode(NSValue(size: unhiddenAttachmentSize), forKey: "attachmentSize")
        coder.encode(NSValue(rect: drawingRect), forKey: "drawingRect")
        coder.encode(NSNumber(value: Double(attachmentBaselineOffset)), forKey: "attachmentBaselineOffset")
        if let w = attachmentFileWrapper { coder.encode(w, forKey: "attachmentFileWrapper") }
    }

    public override class var supportsSecureCoding: Bool { true }

    /// A fresh instance with the same represented text, size, rect and offset.
    open func copyAttachment() -> Self {
        let c = type(of: self).init(representedAttributedText: representedAttributedText.copy() as? NSAttributedString)
        c.attachmentSize = attachmentSize
        c.drawingRect = drawingRect
        c.attachmentBaselineOffset = attachmentBaselineOffset
        c.image = image?.copy() as? NSImage
        return c
    }
}

/// Delegates size and drawing to the attachment.
public final class SFTextAttachmentCell: NSTextAttachmentCell, @MainActor NSSecureCoding {
    public nonisolated static var supportsSecureCoding: Bool { true }

    private nonisolated var sfAttachment: SFTextAttachment? { attachment as? SFTextAttachment }

    public override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let proposed = super.cellFrame(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
        guard let a = sfAttachment else { return proposed }
        // The attachment's bounds are the cell frame; its y is the baseline offset.
        return a.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex, proposedRect: proposed)
    }

    public override func cellSize() -> NSSize { sfAttachment?.attachmentSize ?? .zero }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        sfAttachment?.drawAttachment(inFullRect: cellFrame)
    }

    public override func wantsToTrackMouse() -> Bool { !(sfAttachment?.isHidden ?? true) }
}

/// Backed by a real NSView (tables, math,
/// previews). Draws a temporary image while the view is not on screen.
open class SFTextAttachmentView: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public weak var attachmentViewController: NSViewController?
    public var temporaryImage: NSImage?

    public required init(representedAttributedText: NSAttributedString?) {
        super.init(representedAttributedText: representedAttributedText)
        setPreventAttachmentImageRendering(true)
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// The image stands in only while the view is off screen; drawn under the view it doubles the text.
    open override func drawAttachment(in rect: CGRect) {
        let controller = attachmentViewController
        let image = temporaryImage
        MainActor.assumeIsolated {
            if let view = controller?.view, view.superview != nil { return }
            image?.draw(in: NSView.focusView?.backingAlignedRect(rect, options: .alignAllEdgesNearest) ?? rect)
        }
    }
}

/// Images and files.
open class SFTextAttachmentFileBackedView: SFTextAttachmentView {
    public override class var supportsSecureCoding: Bool { true }
    public private(set) var filePath: String?

    public required init(representedAttributedText: NSAttributedString?) { super.init(representedAttributedText: representedAttributedText) }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        filePath = coder.decodeObject(of: NSString.self, forKey: "filePath") as String?
    }

    /// Rewrites the (percent-escaped) path inside the represented markdown.
    public func setFilePath(_ path: String?) {
        guard let path = path else { filePath = nil; return }
        guard let current = filePath else { filePath = path; return }
        guard current != path else { return }
        let old = PMKAST.percentEscapedURL(current)
        let new = PMKAST.percentEscapedURL(path)
        let text = representedAttributedText.string as NSString
        let r = text.range(of: old)
        if r.location != NSNotFound {
            let m = NSMutableAttributedString(attributedString: representedAttributedText)
            m.replaceCharacters(in: r, with: new)
            representedAttributedText = m
        }
        filePath = path
    }

    open override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(filePath, forKey: "filePath")
    }

    open override func copyAttachment() -> Self {
        let c = super.copyAttachment()
        c.setFilePath(filePath)
        return c
    }
}
