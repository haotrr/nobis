import AppKit
import PolarMark

// Ported from the decompiled attachment classes. Each one stands in for a run of
// markdown in the attributed string (see SFTextAttachment.representedAttributedText).

private extension CGRect {
    /// Floor x, ceil y, floor width, floor height.
    var pixelFloorCeil: CGRect { CGRect(x: floor(minX), y: ceil(minY), width: floor(width), height: floor(height)) }
    /// Round half away from zero on all four fields.
    var pixelRounded: CGRect {
        CGRect(x: minX.rounded(.toNearestOrAwayFromZero), y: minY.rounded(.toNearestOrAwayFromZero),
               width: width.rounded(.toNearestOrAwayFromZero), height: height.rounded(.toNearestOrAwayFromZero))
    }
}

/// The stacked bars + level number drawn where "# " was.
public final class MDATXHeadingAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var color: NSColor?
    public var accentColor: NSColor?
    public var borderWidth: CGFloat = 0
    public var level: Int = 1

    public override func drawAttachment(in rect: CGRect) {
        let w = rect.width
        let shortest = CGFloat(Int(w * 0.35))
        var middle = shortest
        if level == 4 || level == 6 { middle = CGFloat(Int(w * 0.5)) } else if level == 5 { middle = CGFloat(Int(w * 0.45)) }
        let longest = CGFloat(Int(w * 0.9))
        let unit = rect.height / 13.0
        let bar = CGFloat(Int(unit + unit))
        let x = CGFloat(Int(rect.origin.x))
        let maxY = CGRect(x: x, y: CGFloat(Int(rect.origin.y)), width: w, height: rect.height).maxY
        let y3 = CGFloat(Int(maxY - bar))
        let step = bar + CGFloat(Int(unit * 3.0))
        let y2 = y3 - step
        let y1 = y2 - step
        let radius = bar * 0.5
        let p1 = NSBezierPath(roundedRect: NSRect(x: x, y: y1, width: longest, height: bar), xRadius: radius, yRadius: radius)
        let p2 = NSBezierPath(roundedRect: NSRect(x: x, y: y2, width: middle, height: bar), xRadius: radius, yRadius: radius)
        let p3 = NSBezierPath(roundedRect: NSRect(x: x, y: y3, width: shortest, height: bar), xRadius: radius, yRadius: radius)
        (color ?? .black).setFill()
        p1.fill(); p2.fill(); p3.fill()
        // The level stands on the bottom bar's baseline, in the room the two short bars leave at the right.
        let number = numberAttributedString(fontSize: unit * 10.0)
        number.draw(with: NSRect(x: x, y: y3 + bar, width: longest, height: bar), options: [])
    }

    public func lineWidth(forLineNumber line: Int, level: Int, baseWidth: CGFloat) -> CGFloat {
        let full: Bool
        switch line {
        case 1: full = level == 1 || level == 4
        case 2: full = level == 2 || level == 5
        case 3: full = level == 3 || level == 6
        default: full = false
        }
        return CGFloat(Int(baseWidth * (full ? 0.9 : 0.55)))
    }

    /// Right-aligned level number in the accent color.
    public func numberAttributedString(fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return NSAttributedString(string: "\(level)", attributes: [.foregroundColor: accentColor ?? .black, .font: font, .paragraphStyle: p])
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        borderWidth = CGFloat((coder.decodeObject(of: NSNumber.self, forKey: "borderWidth"))?.doubleValue ?? 0)
        color = coder.decodeObject(of: NSColor.self, forKey: "color")
        level = coder.decodeObject(of: NSNumber.self, forKey: "level")?.intValue ?? 1
        accentColor = coder.decodeObject(of: NSColor.self, forKey: "accentColor")
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: Double(borderWidth)), forKey: "borderWidth")
        coder.encode(color, forKey: "color")
        coder.encode(NSNumber(value: level), forKey: "level")
        coder.encode(accentColor, forKey: "accentColor")
    }

    public override func copyAttachment() -> Self {
        let c = super.copyAttachment()
        c.borderWidth = borderWidth; c.color = color; c.level = level; c.accentColor = accentColor
        return c
    }
}

/// The underline drawn for `===` / `---` headings.
public final class MDSETEXTHeadingAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var lineWidth: CGFloat = 1
    public var lineColor: NSColor?

    public override func drawAttachment(in rect: CGRect) {
        (lineColor ?? .black).setFill()
        let r = NSRect(x: CGFloat(Int(rect.origin.x)), y: CGFloat(Int(rect.origin.y + (rect.height - lineWidth) * 0.5)), width: rect.width, height: lineWidth)
        NSBezierPath(roundedRect: r, xRadius: lineWidth * 0.5, yRadius: lineWidth * 0.5).fill()
    }

    public override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                                          characterIndex charIndex: Int, proposedRect: CGRect) -> CGRect {
        var r = super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex, proposedRect: proposedRect)
        if let c = textContainer { r.size.width = min(lineFrag.width, maxWidthAttachment(at: charIndex, for: c)) }
        return r
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        lineWidth = CGFloat(coder.decodeObject(of: NSNumber.self, forKey: "lineWidth")?.doubleValue ?? 1)
        lineColor = coder.decodeObject(of: NSColor.self, forKey: "lineColor")
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: Double(lineWidth)), forKey: "lineWidth")
        coder.encode(lineColor, forKey: "lineColor")
    }

    public override func copyAttachment() -> Self {
        let c = super.copyAttachment(); c.lineWidth = lineWidth; c.lineColor = lineColor; return c
    }
}

/// Bullet shapes per nesting level (level & 3).
public final class MDUnorderedListTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var bulletLevel: Int = 0
    public var bulletColor: NSColor?
    public var bulletBorderWidth: CGFloat = 1

    public override func drawAttachment(in rect: CGRect) {
        var r = rect.pixelFloorCeil
        let color = bulletColor ?? .black
        switch bulletLevel & 3 {
        case 0:
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
        case 1:
            color.setStroke()
            if Int(bulletBorderWidth) & 1 != 0 { r = r.insetBy(dx: bulletBorderWidth * 0.5, dy: bulletBorderWidth * 0.5) }
            let p = NSBezierPath(ovalIn: r)
            p.lineWidth = bulletBorderWidth
            p.stroke()
        case 2, 3:
            let filled = (bulletLevel & 3) == 2
            if filled { color.setFill() }
            color.setStroke()
            if Int(bulletBorderWidth) & 1 != 0 { r = r.insetBy(dx: bulletBorderWidth * 0.5, dy: bulletBorderWidth * 0.5) }
            let inset = CGFloat(Int(r.width + r.width / -1.4142135623730951) >> 1)
            let p = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: bulletBorderWidth * 0.5, yRadius: bulletBorderWidth * 0.5)
            p.rotateFromCenter(byDegrees: 45)
            p.lineWidth = bulletBorderWidth
            if filled { p.fill() }
            p.stroke()
        default: break
        }
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        bulletLevel = coder.decodeObject(of: NSNumber.self, forKey: "bulletLevel")?.intValue ?? 0
        bulletColor = coder.decodeObject(of: NSColor.self, forKey: "bulletColor")
        bulletBorderWidth = CGFloat(coder.decodeObject(of: NSNumber.self, forKey: "bulletBorderWidth")?.doubleValue ?? 1)
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: bulletLevel), forKey: "bulletLevel")
        coder.encode(bulletColor, forKey: "bulletColor")
        coder.encode(NSNumber(value: Double(bulletBorderWidth)), forKey: "bulletBorderWidth")
    }

    public override func copyAttachment() -> Self {
        let c = super.copyAttachment(); c.bulletLevel = bulletLevel; c.bulletColor = bulletColor; c.bulletBorderWidth = bulletBorderWidth; return c
    }
}

/// An invisible spacer that right-aligns the number.
public final class MDOrderedListTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
}

/// The checkbox.
public final class MDTaskTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var completed = false
    public var borderWidth: CGFloat = 1
    public var borderCompletedWidth: CGFloat = 1
    public var fillColor: NSColor?
    public var borderColor: NSColor?
    public var checkColor: NSColor?

    public override func drawAttachment(in rect: CGRect) {
        let r = rect.pixelFloorCeil.insetBy(dx: borderWidth * 0.5, dy: borderWidth * 0.5)
        drawCheckboxBody(for: r)
        if completed { drawCheckboxCheck(for: r) }
    }

    public func drawCheckboxBody(for rect: CGRect) {
        let path = NSBezierPath.squircle(in: rect, cornerRadius: CGFloat(Int(rect.width * 0.3)))
        if let fill = fillColor {
            fill.setFill()
            path.fill()
        }
        let border = borderColor ?? .black
        if completed {
            border.withAlphaComponent(0.35).setStroke()
            path.lineWidth = borderCompletedWidth
        } else {
            border.setStroke()
            path.lineWidth = borderWidth
        }
        path.stroke()
    }

    /// PaintCode check mark, filled with checkColor at alpha 0.4.
    public func drawCheckboxCheck(for rect: CGRect) {
        func p(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: rect.minX + rect.width * px, y: rect.minY + rect.height * py) }
        let path = NSBezierPath()
        path.move(to: p(0.81101, 0.24659))
        path.curve(to: p(0.77463, 0.24659), controlPoint1: p(0.80107, 0.23744), controlPoint2: p(0.78475, 0.23735))
        path.line(to: p(0.42044, 0.57518))
        path.line(to: p(0.27127, 0.51982))
        path.curve(to: p(0.24016, 0.52967), controlPoint1: p(0.25981, 0.51576), controlPoint2: p(0.24674, 0.52001))
        path.curve(to: p(0.24167, 0.56248), controlPoint1: p(0.23316, 0.53963), controlPoint2: p(0.23376, 0.55303))
        path.line(to: p(0.40534, 0.75516))
        path.curve(to: p(0.4257, 0.76471), controlPoint1: p(0.4105, 0.76115), controlPoint2: p(0.41791, 0.76471))
        path.line(to: p(0.42854, 0.76459))
        path.curve(to: p(0.44699, 0.75435), controlPoint1: p(0.43584, 0.76379), controlPoint2: p(0.44263, 0.76003))
        path.line(to: p(0.81385, 0.28284))
        path.curve(to: p(0.81101, 0.24659), controlPoint1: p(0.82236, 0.27188), controlPoint2: p(0.82115, 0.25594))
        path.close()
        path.move(to: p(0.4257, 0.75576))
        path.line(to: p(0.4257, 0.75587))
        path.miterLimit = 4
        (checkColor ?? .white).withAlphaComponent(0.4).setFill()
        path.fill()
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        completed = coder.decodeObject(of: NSNumber.self, forKey: "completed")?.boolValue ?? false
        borderWidth = CGFloat(coder.decodeObject(of: NSNumber.self, forKey: "borderWidth")?.doubleValue ?? 1)
        borderCompletedWidth = CGFloat(coder.decodeObject(of: NSNumber.self, forKey: "borderCompletedWidth")?.doubleValue ?? 1)
        fillColor = coder.decodeObject(of: NSColor.self, forKey: "fillColor")
        borderColor = coder.decodeObject(of: NSColor.self, forKey: "borderColor")
        checkColor = coder.decodeObject(of: NSColor.self, forKey: "checkColor")
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: completed), forKey: "completed")
        coder.encode(NSNumber(value: Double(borderWidth)), forKey: "borderWidth")
        coder.encode(NSNumber(value: Double(borderCompletedWidth)), forKey: "borderCompletedWidth")
        coder.encode(fillColor, forKey: "fillColor")
        coder.encode(borderColor, forKey: "borderColor")
        coder.encode(checkColor, forKey: "checkColor")
    }

    public override func copyAttachment() -> Self {
        let c = super.copyAttachment()
        c.completed = completed; c.borderWidth = borderWidth; c.borderCompletedWidth = borderCompletedWidth
        c.fillColor = fillColor; c.borderColor = borderColor; c.checkColor = checkColor
        return c
    }
}

/// The horizontal rule.
public final class MDThematicBreakTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var lineWidth: CGFloat = 1
    public var lineColor: NSColor?

    public override func drawAttachment(in rect: CGRect) {
        (lineColor ?? .black).setFill()
        let r = NSRect(x: CGFloat(Int(rect.origin.x)), y: CGFloat(Int(rect.origin.y + (rect.height - lineWidth) * 0.5)), width: rect.width, height: lineWidth)
        NSBezierPath(rect: r).fill()
    }

    public override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                                          characterIndex charIndex: Int, proposedRect: CGRect) -> CGRect {
        var r = super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex, proposedRect: proposedRect)
        if let c = textContainer { r.size.width = min(lineFrag.width, maxWidthAttachment(at: charIndex, for: c)) }
        return r
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        lineWidth = CGFloat(coder.decodeObject(of: NSNumber.self, forKey: "lineWidth")?.doubleValue ?? 1)
        lineColor = coder.decodeObject(of: NSColor.self, forKey: "lineColor")
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: Double(lineWidth)), forKey: "lineWidth")
        coder.encode(lineColor, forKey: "lineColor")
    }

    public override func copyAttachment() -> Self { let c = super.copyAttachment(); c.lineWidth = lineWidth; c.lineColor = lineColor; return c }
}

/// The return-arrow glyph.
public final class MDHardLineBreakTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var arrowColor: NSColor?
    public override func drawAttachment(in rect: CGRect) {
        MDTextKitStyleKit.drawHardLineBreak(frame: rect.pixelFloorCeil, fillColor: arrowColor ?? .black)
    }
    public override func decode(with coder: NSCoder) { super.decode(with: coder); arrowColor = coder.decodeObject(of: NSColor.self, forKey: "arrowColor") }
    public override func encode(with coder: NSCoder) { super.encode(with: coder); coder.encode(arrowColor, forKey: "arrowColor") }
    public override func copyAttachment() -> Self { let c = super.copyAttachment(); c.arrowColor = arrowColor; return c }
}

/// The marker-pen icon next to a highlighter.
public final class MDHighlighterTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var color: NSColor?
    public var accentColor: NSColor?
    public override func drawAttachment(in rect: CGRect) {
        MDTextKitStyleKit.drawHighlighter(frame: rect.pixelRounded, fillColor: color ?? .yellow, accentColor: accentColor ?? .yellow)
    }
    public override func decode(with coder: NSCoder) { super.decode(with: coder); color = coder.decodeObject(of: NSColor.self, forKey: "color"); accentColor = coder.decodeObject(of: NSColor.self, forKey: "accentColor") }
    public override func encode(with coder: NSCoder) { super.encode(with: coder); coder.encode(color, forKey: "color"); coder.encode(accentColor, forKey: "accentColor") }
    public override func copyAttachment() -> Self { let c = super.copyAttachment(); c.color = color; c.accentColor = accentColor; return c }
}

/// The link icon that replaces the URL part of `[label](url)`.
public final class MDLinkTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var color: NSColor?

    public override func drawAttachment(in rect: CGRect) {
        MDTextKitStyleKit.drawLinkIcon(frame: rect.pixelRounded, fillColor: color ?? .black)
    }

    /// The PMKLinkURL carried by the represented text.
    public var url: String? {
        var result: String? = nil
        representedAttributedText.enumerateAttribute(.pmkLinkURL, in: NSRange(location: 0, length: representedAttributedText.length), options: []) { v, r, stop in
            if v != nil { result = (v as? String) ?? (representedAttributedText.string as NSString).substring(with: r); stop.pointee = true }
        }
        return result
    }

    public var title: String? {
        var result: String? = nil
        representedAttributedText.enumerateAttribute(.pmkLinkTitle, in: NSRange(location: 0, length: representedAttributedText.length), options: []) { v, r, stop in
            if v != nil { result = (representedAttributedText.string as NSString).substring(with: r); stop.pointee = true }
        }
        return result
    }

    public override func decode(with coder: NSCoder) { super.decode(with: coder); color = coder.decodeObject(of: NSColor.self, forKey: "color") }
    public override func encode(with coder: NSCoder) { super.encode(with: coder); coder.encode(color, forKey: "color") }
    public override func copyAttachment() -> Self { let c = super.copyAttachment(); c.color = color; return c }
}

/// Draws an NSImage with margins.
public final class MDIconTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var icon: NSImage?

    public convenience init(icon: NSImage, leftMargin: CGFloat, rightMargin: CGFloat, baselineOffset: CGFloat) {
        self.init(representedAttributedText: nil)
        self.icon = icon
        attachmentSize = CGSize(width: rightMargin + leftMargin + icon.size.width, height: icon.size.height)
        drawingRect = CGRect(x: leftMargin, y: 0, width: icon.size.width, height: icon.size.height)
        attachmentBaselineOffset = baselineOffset
        updateAttachmentImage()
    }

    public override func drawAttachment(in rect: CGRect) { icon?.draw(in: rect) }
    public override func decode(with coder: NSCoder) { super.decode(with: coder); icon = coder.decodeObject(of: NSImage.self, forKey: "icon") }
    public override func encode(with coder: NSCoder) { super.encode(with: coder); coder.encode(icon, forKey: "icon") }
    public override func copyAttachment() -> Self { let c = super.copyAttachment(); c.icon = icon; return c }
}

/// Optional icon in front of a tag.
public final class MDHashtagIconTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var icon: NSImage?
    public override func drawAttachment(in rect: CGRect) { icon?.draw(in: rect) }
    public override func copyAttachment() -> Self { let c = super.copyAttachment(); c.icon = icon; return c }
}

/// Replaces "> "; draws nothing (the bar is drawn by the layout manager).
public final class MDBlockQuoteTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public override func drawAttachment(in rect: CGRect) {}
}

/// Replaces leading tabs of nested items; width = indent units * tab size.
public final class MDIndentSpaceTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
}

/// Zero-text boundary spacer around inline code.
public final class MDCodeTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
}

/// Zero-text boundary spacer around a tag pill.
public final class MDTagTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
}

/// Zero-text boundary spacer around a highlight.
public final class MDHighlighterSpacerTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
}

/// Inline image preview. The host resolves the
/// markdown path to a file; the image is downsampled to the line width × screen
/// scale and laid out at its pixel size, then fitted to the available width (asm @0x1bda0).
public final class MDImageTextAttachment: SFTextAttachmentFileBackedView {
    public override class var supportsSecureCoding: Bool { true }
    public var maxTextContainerWidth: CGFloat = 0
    public var alwaysUseFullWidth = false
    public var resolvedFileURL: URL?
    public var imageData: Data?
    public var placeholderSize = CGSize(width: 120, height: 24)

    public override func updateAttachmentImage() {
        guard let data = imageData ?? resolvedFileURL.flatMap({ try? Data(contentsOf: $0) }) else {
            temporaryImage = nil
            attachmentSize = placeholderSize
            return
        }
        let maxPx = (maxTextContainerWidth > 0 ? maxTextContainerWidth : 1200) * (NSScreen.main?.backingScaleFactor ?? 1)
        var image: NSImage?
        if (resolvedFileURL?.pathExtension ?? (filePath as NSString?)?.pathExtension)?.lowercased() == "gif" {
            image = NSImage(data: data)
            if let i = image, let rep = i.representations.first { image?.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false, kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPx, kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            }
        }
        temporaryImage = image
        attachmentSize = image?.size ?? placeholderSize
    }

    public override func drawAttachment(in rect: CGRect) {
        if let img = temporaryImage { img.draw(in: rect); return }
        // missing file placeholder
        NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let name = (filePath as NSString?)?.lastPathComponent ?? "image"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        NSAttributedString(string: "⨯ " + name, attributes: attrs).draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 4))
    }

    public override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                                          characterIndex charIndex: Int, proposedRect: CGRect) -> CGRect {
        var r = super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex, proposedRect: proposedRect)
        guard let c = textContainer, attachmentSize.width > 0, attachmentSize.height > 0 else { return r }
        let maxW = maxWidthAttachment(at: charIndex, for: c)
        if r.width >= maxW || alwaysUseFullWidth {
            r.size.width = maxW
            r.size.height = CGFloat(Float(maxW * attachmentSize.height / attachmentSize.width).rounded(.down))
        }
        let limit = CGFloat(UInt(min(proposedRect.height, c.size.height)))
        if r.height > limit {
            r.size.width = CGFloat(Float(attachmentSize.width * limit / attachmentSize.height).rounded(.down))
            r.size.height = limit
        }
        return r
    }

    public override func copyAttachment() -> Self {
        let c = super.copyAttachment()
        c.maxTextContainerWidth = maxTextContainerWidth; c.alwaysUseFullWidth = alwaysUseFullWidth
        c.resolvedFileURL = resolvedFileURL; c.imageData = imageData; c.temporaryImage = temporaryImage
        return c
    }
}

/// Rounded pill (radius h/4) with three dots; `collapsedRange` is relative to
/// `representedAttributedText` (marker length … folded length).
public final class MDFoldTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public var collapsedRange = NSRange(location: NSNotFound, length: 0)
    public var textColor: NSColor?
    public var backgroundColor: NSColor?

    public var collapsedText: String { representedAttributedText.stringByExpandingTextAttachments(in: collapsedRange) }
    public var collapsedAttributedText: NSAttributedString {
        collapsedRange.location != NSNotFound && NSMaxRange(collapsedRange) <= representedAttributedText.length
            ? representedAttributedText.attributedSubstring(from: collapsedRange) : NSAttributedString()
    }

    public override func drawAttachment(in rect: CGRect) {
        let x = floor(rect.origin.x), y = ceil(rect.origin.y), w = floor(rect.width), h = floor(rect.height)
        let r = CGRect(x: x, y: y, width: w, height: h)
        (backgroundColor ?? .lightGray).setFill()
        NSBezierPath(roundedRect: r, xRadius: h * 0.25, yRadius: h * 0.25).fill()
        let dot = CGFloat(Float(h / 3.5).rounded(.down))
        let ir = r.insetBy(dx: h / 3.0, dy: 0)
        let seg = ir.width / 3, pad = (seg - dot) * 0.5, dy = ir.minY + (ir.height - dot) * 0.5
        (textColor ?? .darkGray).setFill()
        for i in 0..<3 { NSBezierPath(ovalIn: CGRect(x: ir.minX + CGFloat(i) * seg + pad, y: dy, width: dot, height: dot)).fill() }
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        if let v = coder.decodeObject(of: NSValue.self, forKey: "collapsedRange") { collapsedRange = v.rangeValue }
        textColor = coder.decodeObject(of: NSColor.self, forKey: "textColor")
        backgroundColor = coder.decodeObject(of: NSColor.self, forKey: "backgroundColor")
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSValue(range: collapsedRange), forKey: "collapsedRange")
        coder.encode(textColor, forKey: "textColor")
        coder.encode(backgroundColor, forKey: "backgroundColor")
    }

    public override func copyAttachment() -> Self {
        let c = super.copyAttachment()
        c.collapsedRange = collapsedRange; c.textColor = textColor; c.backgroundColor = backgroundColor
        return c
    }
}


/// Width is clamped to the available line width.
public final class MDTableTextAttachment: SFTextAttachmentView {
    public override class var supportsSecureCoding: Bool { true }
    public var maxTextContainerWidth: CGFloat = 0

    public override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                                          characterIndex charIndex: Int, proposedRect: CGRect) -> CGRect {
        var r = super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex, proposedRect: proposedRect)
        if let c = textContainer { r.size.width = min(r.width, maxWidthAttachment(at: charIndex, for: c)) }
        return r
    }

    public override func decode(with coder: NSCoder) {
        super.decode(with: coder)
        maxTextContainerWidth = CGFloat(coder.decodeObject(of: NSNumber.self, forKey: "maxTextContainerWidth")?.doubleValue ?? 0)
    }
    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: Double(maxTextContainerWidth)), forKey: "maxTextContainerWidth")
    }
    public override func copyAttachment() -> Self {
        let c = super.copyAttachment(); c.maxTextContainerWidth = maxTextContainerWidth; c.temporaryImage = temporaryImage; return c
    }
}
