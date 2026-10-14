import AppKit
import PolarMark

public final class SFRectCollection: NSObject {
    public var rects: [CGRect] = []
    public var selected = false
    public func addRect(_ r: CGRect) { rects.append(r) }
    public func enumerateRects(_ block: (CGRect, Int) -> Void) { for (i, r) in rects.enumerated() { block(r, i) } }
    public var firstRect: CGRect { rects.first ?? .zero }
    public var lastRect: CGRect { rects.last ?? .zero }
}

/// Centers a column of at most `maxColumSize` points, never narrower than `minInset` insets.
public final class MDTextContainer: NSTextContainer {
    public var minInset: CGFloat = 0
    public var maxColumSize: CGFloat = 0

    public override var lineFragmentPadding: CGFloat {
        get {
            if maxColumSize == 0 { return super.lineFragmentPadding }
            let inset = (size.width - maxColumSize) * 0.5
            return max(minInset, inset)
        }
        set { super.lineFragmentPadding = newValue }
    }

    public var currentColumnWidth: CGFloat { size.width - lineFragmentPadding * 2 }
}

/// TextKit 1 layout manager that draws the block/inline backgrounds and keeps
/// baselines steady around attachments.
public final class MDLayoutManager: NSLayoutManager, @MainActor NSLayoutManagerDelegate {
    public var showBackgroundGrid = false
    public var preventAttachmentViewFromRearranging = false
    public var styledRange = NSNotFoundRange
    public var defaultLineSpacing: CGFloat = 0
    public var defaultParagraphIndent: CGFloat = 0
    public var baseTabSize: CGFloat = 0
    public var basePointSize: CGFloat = 0
    public var columnSize: CGFloat = 0
    public var gutterSize: CGFloat = 0
    public var defaultFont: NSFont = .systemFont(ofSize: 14)
    public var selectionInactiveColor: NSColor = .unemphasizedSelectedContentBackgroundColor

    // `init` only resets `styledRange`; the delegate methods below are used by the
    // table attachment's layout manager (MDTextKitUI.MDLayoutManagerDelegate), not by the note editor.
    public override init() {
        super.init()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private var mdStorage: NSTextStorage? { textStorage }

    // MARK: Drawing entry points

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        rearrangeAttachmentsViews(forGlyphRange: glyphsToShow, at: origin)
    }

    public func drawBackgroundUnderSelection(forGlyphRange r: NSRange, at p: NSPoint) {
        if showBackgroundGrid { drawBackgroundGrid(forGlyphRange: r, at: p) }
        drawIndentedCodeBackground(forGlyphRange: r, at: p)
        drawFencedCodeBackground(forGlyphRange: r, at: p)
        drawHighlighterBackground(forGlyphRange: r, at: p)
        drawInlineCodeBackground(forGlyphRange: r, at: p)
        drawTagsBackground(forGlyphRange: r, at: p)
    }

    public func drawBackgroundOverSelection(forGlyphRange r: NSRange, at p: NSPoint) {
        drawSearchResultBackground(forGlyphRange: r, at: p)
        drawBlockQuoteBackground(forGlyphRange: r, at: p)
    }

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawBackgroundUnderSelection(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawBackgroundOverSelection(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Selection fill; view attachments and
    /// search results are left alone, inactive selection uses `selectionInactiveColor` at 50%.
    public override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = mdStorage else { return }
        if charRange.length == 1, let a = storage.textAttachment(at: charRange.location), a.isViewAttachment { return }
        if storage.attribute(.mdSearchResultBackgroundColor, at: charRange.location, effectiveRange: nil) != nil { return }
        var fill = color
        if color == NSColor.unemphasizedSelectedContentBackgroundColor { fill = selectionInactiveColor }
        // An opaque selection colour draws at half strength; a translucent one already says how strong.
        let alpha = fill.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        if alpha >= 1 { fill = fill.withAlphaComponent(0.5) }
        fill.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: fill)
        color.setFill()
    }

    // MARK: Attachments

    public func rangeOfTextAttachment(near point: CGPoint, withDelta delta: CGFloat) -> NSRange {
        guard let storage = mdStorage, let container = textContainers.first else { return NSNotFoundRange }
        let d = max(1, delta)
        let probe = CGRect(x: point.x, y: point.y, width: 1, height: 1).insetBy(dx: -d, dy: -d)
        let glyphs = glyphRange(forBoundingRect: probe, in: container)
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard NSMaxRange(chars) <= storage.length else { return NSNotFoundRange }
        var best = NSNotFoundRange
        var bestDistance: CGFloat = -1
        storage.enumerateAttribute(.attachment, in: chars, options: []) { value, run, _ in
            guard value != nil else { return }
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rect = self.boundingRect(forGlyphRange: g, in: container)
            let cx = min(max(point.x, rect.minX), rect.maxX)
            let cy = min(max(point.y, rect.minY), rect.maxY)
            let distance = CGFloat(sqrt(Float((point.x - cx) * (point.x - cx) + (point.y - cy) * (point.y - cy))))
            if (bestDistance == -1 || distance < bestDistance), distance <= d {
                bestDistance = distance
                best = run
            }
        }
        return best
    }

    public func attachmentFrame(forGlyphAt index: Int, at origin: CGPoint) -> CGRect {
        let line = lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
        let loc = location(forGlyphAt: index)
        let size = attachmentSize(forGlyphAt: index)
        return CGRect(x: line.minX + origin.x + loc.x, y: line.minY + origin.y + (loc.y - size.height), width: size.width, height: size.height)
    }

    public func attachmentFrame(forCharacterAt index: Int, at origin: CGPoint) -> CGRect {
        let g = glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        return attachmentFrame(forGlyphAt: g.location, at: origin)
    }

    public func rearrangeAttachmentsViews(forCharacterRange range: NSRange, at origin: CGPoint) {
        let g = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        rearrangeAttachmentsViews(forGlyphRange: g, at: origin)
    }

    /// Moves view-backed attachments to their glyph frames.
    public func rearrangeAttachmentsViews(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard origin.x >= 0, origin.y >= 0, !preventAttachmentViewFromRearranging, let storage = mdStorage else { return }
        let chars = characterRange(forGlyphRange: range, actualGlyphRange: nil)
        storage.enumerateAttribute(.attachment, in: chars, options: [.longestEffectiveRangeNotRequired]) { value, run, _ in
            guard let view = value as? SFTextAttachmentView, let controller = view.attachmentViewController else { return }
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let line = self.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
            let loc = self.location(forGlyphAt: g.location)
            let size = self.attachmentSize(forGlyphAt: g.location)
            if size.width == 1, size.height == 1 { return }
            let frame = CGRect(x: CGFloat(Int(line.minX + origin.x + loc.x)), y: CGFloat(Int(origin.y + line.minY + loc.y - size.height)), width: size.width, height: size.height)
            let textView = self.firstTextView
            // NSLayoutManager draws on the main thread; the attachment's view is main-actor.
            MainActor.assumeIsolated {
                if controller.view.superview == nil, let textView { textView.addSubview(controller.view) }
                if controller.view.frame != frame { controller.view.frame = frame }
            }
        }
    }

    // MARK: Line fragments / baselines

    public func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                              lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                              in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        var changed = false
        let fixed = fixedBaseline(forBaselineOffset: baselineOffset.pointee, lineFragment: lineFragmentRect.pointee, forGlyphRange: glyphRange)
        if CGFloat(Int(baselineOffset.pointee)) != CGFloat(Int(fixed)) {
            baselineOffset.pointee = fixed
            changed = true
        }
        guard let storage = layoutManager.textStorage else { return changed }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let ns = storage.string as NSString
        var skip = textContainers.count > 1
        var onlyNewlines = true
        var sawNewline = false
        var sawAttachment = false
        if chars.length > 0 {
            for i in chars.location..<NSMaxRange(chars) {
                let c = ns.character(at: i)
                if c == 0xFFFC {
                    if !sawAttachment, let a = storage.textAttachment(at: i) {
                        if let sf = a as? SFTextAttachment, !sf.wantAttachmentBaselineOffset { skip = true }
                        sawAttachment = a.isViewAttachment
                    }
                    onlyNewlines = false
                } else {
                    let isNewline = c == 0x0A
                    sawNewline = sawNewline || isNewline
                    onlyNewlines = onlyNewlines && isNewline
                }
            }
        }
        if !skip, onlyNewlines || sawNewline {
            let attrs = storage.attributes(at: chars.location, effectiveRange: nil)
            let font = (attrs[.font] as? NSFont) ?? defaultFont
            let paragraph = (attrs[.paragraphStyle] as? NSParagraphStyle) ?? .default
            let expected = CGFloat(Int(paragraph.minimumLineHeight + paragraph.lineSpacing))
            let descent = CGFloat(Int(abs(font.descender)))
            if onlyNewlines, expected < CGFloat(Int(lineFragmentUsedRect.pointee.height)) {
                lineFragmentRect.pointee.size.height += descent
                lineFragmentUsedRect.pointee.size.height += descent
            }
            if sawNewline {
                let extra = paragraph.lineSpacing + descent
                lineFragmentRect.pointee.size.height += extra
                lineFragmentUsedRect.pointee.size.height += extra
                baselineOffset.pointee += extra
                if onlyNewlines { baselineOffset.pointee += abs(font.descender) }
            }
            changed = true
        }
        return changed
    }

    /// Keeps the baseline where the
    /// paragraph's font puts it, so a tall attachment on the line doesn't push the text up.
    public func fixedBaseline(forBaselineOffset offset: CGFloat, lineFragment: CGRect, forGlyphRange glyphRange: NSRange) -> CGFloat {
        guard let storage = mdStorage, glyphRange.length > 0 else { return offset }
        let chars = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.length > 0, NSMaxRange(chars) <= storage.length else { return offset }
        let ns = storage.string as NSString
        let lastIndex = NSMaxRange(chars) - 1
        let lastChar = ns.character(at: lastIndex)
        if storage.isRangeInsideBlockCode(NSRange(location: chars.location, length: 1)) { return offset }
        let paragraph = storage.paragraphStyle(at: chars.location) ?? .default
        var font = defaultFont
        let probe = (lastChar == 0x0A && lastIndex > 0) ? lastIndex - 1 : lastIndex
        let heading = storage.longestRange(forAttribute: .pmkHeading, at: probe)
        if heading.location != NSNotFound, let f = storage.nonHiddenFont(at: heading.location) { font = f }
        let ascender = font.ascender
        let descender = font.descender
        var lineHeight = CGFloat(Int(paragraph.minimumLineHeight + paragraph.lineSpacing))
        if lastChar == 0x0A { lineHeight += paragraph.paragraphSpacing }
        let base = CGFloat(Int(ascender)) + (lineFragment.height - lineHeight)
        let fontHeight = CGFloat(Int(ascender)) + CGFloat(Int(-descender))
        if paragraph.minimumLineHeight <= fontHeight { return base }
        return CGFloat(Int(paragraph.minimumLineHeight - fontHeight)) + base
    }

    // MARK: Backgrounds

    private func enumerateCharacters(_ key: NSAttributedString.Key, glyphRange: NSRange, _ body: (Any, NSRange, NSTextContainer) -> Void) {
        guard let storage = mdStorage else { return }
        let chars = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else { return }
        storage.enumerateAttribute(key, in: chars, options: []) { value, run, _ in
            guard let v = value else { return }
            body(v, run, container)
        }
    }

    public func drawIndentedCodeBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let storage = mdStorage else { return }
        enumerateCharacters(.pmkIndentedCode, glyphRange: range) { _, run, container in
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let color = (storage.attribute(.mdCodeBackgroundColor, at: run.location, effectiveRange: nil) as? NSColor) ?? .clear
            let rect = self.boundingRect(forGlyphRange: g, in: container)
            let width = container.size.width - container.lineFragmentPadding * 2
            let r = CGRect(x: origin.x + container.lineFragmentPadding + self.defaultParagraphIndent,
                           y: origin.y + rect.minY, width: width - self.defaultParagraphIndent * 2, height: rect.height).integral
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: self.basePointSize * 3, yRadius: self.basePointSize * 3).fill()
        }
    }

    /// Trims trailing newlines/spaces/attachments, then draws.
    public func drawFencedCodeBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let storage = mdStorage else { return }
        let ns = storage.string as NSString
        enumerateCharacters(.pmkFencedCode, glyphRange: range) { _, run, _ in
            guard (storage.paragraphStyle(at: run.location)?.minimumLineHeight ?? 0) > 0 else { return }
            var len = run.length
            while len > 0 {
                let c = ns.character(at: run.location + len - 1)
                if c != 0x0A, c != 0x20, c != 0xFFFC {
                    let color = (storage.attribute(.mdCodeBackgroundColor, at: run.location, effectiveRange: nil) as? NSColor) ?? .clear
                    self.drawBlockBackground(forCharRange: NSRange(location: run.location, length: len), at: origin, color: color)
                    return
                }
                len -= 1
            }
        }
    }

    public func drawInlineCodeBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let storage = mdStorage else { return }
        enumerateCharacters(.pmkCode, glyphRange: range) { _, run, container in
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rects = self.rectArrayForInlineDrawing(atGlyphRange: g, in: container, at: origin)
            let ps = storage.nonHiddenFont(at: run.location)?.pointSize ?? self.defaultFont.pointSize
            let paths = self.bezierPaths(forRectArray: rects, borderWidth: CGSize(width: 0, height: self.basePointSize * 1.5), cornerRadius: ps / 5, roundMiddlePaths: true, rtl: false)
            let color = (storage.attribute(.mdCodeBackgroundColor, at: run.location, effectiveRange: nil) as? NSColor) ?? .clear
            color.setFill()
            paths.forEach { $0.fill() }
        }
    }

    public func drawTagsBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        enumerateCharacters(.mdTagBackgroundColor, glyphRange: range) { value, run, container in
            guard let color = value as? NSColor else { return }
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rects = self.rectArrayForInlineDrawing(atGlyphRange: g, in: container, at: origin)
            guard let first = rects.first else { return }
            let radius = (first.height + self.basePointSize * -2) * 0.5
            let paths = self.bezierPaths(forRectArray: rects, borderWidth: CGSize(width: self.basePointSize, height: self.basePointSize), cornerRadius: radius, roundMiddlePaths: false, rtl: self.isRTL(at: run.location))
            color.setFill()
            paths.forEach { $0.fill() }
        }
    }

    public func drawHighlighterBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let storage = mdStorage else { return }
        enumerateCharacters(.mdHighlighterBackgroundColor, glyphRange: range) { value, run, container in
            guard let color = value as? NSColor else { return }
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rects = self.rectArrayForInlineDrawing(atGlyphRange: g, in: container, at: origin)
            let ps = storage.nonHiddenFont(at: run.location)?.pointSize ?? self.defaultFont.pointSize
            let paths = self.bezierPaths(forRectArray: rects, borderWidth: CGSize(width: 0, height: self.basePointSize * 1.5), cornerRadius: ps / 5, roundMiddlePaths: true, rtl: false)
            color.setFill()
            paths.forEach { $0.fill() }
        }
    }

    public func drawSearchResultBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let storage = mdStorage else { return }
        enumerateCharacters(.mdSearchResultBackgroundColor, glyphRange: range) { value, run, container in
            guard let color = value as? NSColor else { return }
            let g = self.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rects = self.rectArrayForInlineDrawing(atGlyphRange: g, in: container, at: origin)
            let ps = storage.nonHiddenFont(at: run.location)?.pointSize ?? self.defaultFont.pointSize
            let paths = self.bezierPaths(forRectArray: rects, borderWidth: .zero, cornerRadius: ps / 5, roundMiddlePaths: true, rtl: false)
            color.setFill()
            paths.forEach { $0.fill() }
        }
    }

    /// One bar per blockquote *level* (listBlock of
    /// `enumerateBlockquoteInRange:options:listBlock:listItemBlock:`, item block nil). Even levels are filled,
    /// odd levels are drawn as an outline (`tbnz w21,#0` on the level argument); rect x/y floor, w/h round.
    public func drawBlockQuoteBackground(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard range.length != 0, let storage = mdStorage, let container = textContainer(forGlyphAt: range.location, effectiveRange: nil) else { return }
        var chars = characterRange(forGlyphRange: range, actualGlyphRange: nil)
        chars = storage.extendRangeToFullyContainBlockquote(chars)
        let ns = storage.string as NSString
        let barOffset = columnSize * 0.5
        let barWidth = columnSize * 0.18
        var barColor: NSColor? = nil
        storage.enumerateBlockquote(in: chars, options: [], listBlock: { levelRange, level, _, _ in
            var markerRange = NSRange(location: NSNotFound, length: 0)
            _ = storage.rangeOfBlockquoteItem(at: levelRange.location, markerRange: &markerRange)
            var len = levelRange.length
            if len > 0, ns.character(at: NSMaxRange(levelRange) - 1) == 0x0A { len -= 1 }
            guard markerRange.location != NSNotFound else { return }
            if let callout = storage.attribute(.mdCalloutColors, at: markerRange.location, effectiveRange: nil) as? [String: NSColor] {
                self.drawCalloutBackground(levelRange: NSRange(location: levelRange.location, length: len), markerRange: markerRange, colors: callout, container: container, origin: origin)
                return
            }
            if barColor == nil { barColor = storage.attribute(.mdBlockQuoteBackgroundColor, at: levelRange.location, effectiveRange: nil) as? NSColor }
            guard let color = barColor else { return }
            let markerGlyphs = self.glyphRange(forCharacterRange: markerRange, actualCharacterRange: nil)
            let markerRect = self.boundingRect(forGlyphRange: markerGlyphs, in: container)
            let levelGlyphs = self.glyphRange(forCharacterRange: NSRange(location: levelRange.location, length: len), actualCharacterRange: nil)
            let levelRect = self.boundingRect(forGlyphRange: levelGlyphs, in: container)
            let x: CGFloat
            if self.isRTL(at: levelRange.location) {
                x = origin.x + (markerRect.maxX - (barOffset + barWidth * 0.5))
            } else {
                x = origin.x + markerRect.minX + barOffset + barWidth * -0.5
            }
            let rect = CGRect(x: floor(x), y: floor(origin.y + levelRect.minY + self.basePointSize * 3),
                              width: (barWidth).rounded(), height: (levelRect.height + self.basePointSize * -4).rounded())
            if level & 1 == 1 {
                let inset = rect.insetBy(dx: self.basePointSize * 0.5, dy: self.basePointSize * 0.5)
                let path = NSBezierPath(roundedRect: inset, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5)
                color.setStroke()
                path.lineWidth = self.basePointSize
                path.stroke()
            } else {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5).fill()
            }
        }, listItemBlock: nil)
    }

    /// Callout branch of the blockquote background block — tinted box with border and a left ribbon.
    private func drawCalloutBackground(levelRange: NSRange, markerRange: NSRange, colors: [String: NSColor], container: NSTextContainer, origin: CGPoint) {
        guard let storage = mdStorage else { return }
        let bg = colors["background"] ?? .clear, border = colors["border"] ?? .clear, ribbon = colors["ribbon"] ?? .clear
        let fontPt = defaultFont.pointSize
        let pi = container.lineFragmentPadding + defaultParagraphIndent
        let rtl = isRTL(at: levelRange.location)
        let mR = boundingRect(forGlyphRange: glyphRange(forCharacterRange: markerRange, actualCharacterRange: nil), in: container)
        let bR = boundingRect(forGlyphRange: glyphRange(forCharacterRange: levelRange, actualCharacterRange: nil), in: container)
        let W = container.size.width - 2 * pi
        let off = rtl ? container.size.width - (pi + mR.maxX) : mR.minX - pi
        let r = CGRect(x: bR.minX, y: bR.minY, width: W - off, height: bR.height).integral
        let half = columnSize * 0.5, stripe = columnSize * 0.18
        let nest = CGFloat(storage.calloutNestLevel(at: levelRange.location))
        let w = r.width - (2 * half - stripe) - (baseTabSize * nest - baseTabSize)
        let x = rtl ? origin.x + (mR.maxX - (half - stripe * 0.5) - w) : origin.x + mR.minX + (half - stripe * 0.5)
        let R = CGRect(x: x.rounded(), y: (origin.y + r.minY).rounded(), width: w, height: r.height).insetBy(dx: 0, dy: fontPt * -0.8)
        let box = R.insetBy(dx: basePointSize, dy: basePointSize * 0.5)
        let p = NSBezierPath(roundedRect: box, xRadius: basePointSize * 3, yRadius: basePointSize * 3)
        bg.setFill(); p.fill()
        border.setStroke(); p.lineWidth = basePointSize; p.stroke()
        let ribbonX = rtl ? R.maxX - stripe : R.minX
        let corners: RectCorners = rtl ? [.topRight, .bottomRight] : [.topLeft, .bottomLeft]
        ribbon.setFill()
        NSBezierPath.path(roundedRect: CGRect(x: ribbonX, y: R.minY, width: stripe, height: R.height), byRounding: corners, radius: basePointSize * 3).fill()
    }

    /// Debug column grid.
    public func drawBackgroundGrid(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let container = textContainer(forGlyphAt: range.location, effectiveRange: nil) else { return }
        let used = usedRect(for: container)
        let columns = Int((used.width - container.lineFragmentPadding * 2) / baseTabSize)
        guard columns >= 0 else { return }
        let y = CGFloat(Float(Int(origin.y + used.minY)))
        let h = CGFloat(Float(Int(used.height)))
        for i in 0...columns {
            let x = CGFloat(Float(Int(container.lineFragmentPadding + origin.x + (columnSize + gutterSize) * CGFloat(i))))
            let rect = CGRect(x: x, y: y, width: columnSize, height: h)
            let fill = i % 2 == 0 ? NSColor(red: 0.96, green: 0.96, blue: 1.0, alpha: 1) : NSColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
            fill.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(red: 0.9, green: 0.8, blue: 1.0, alpha: 1).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// Rounded block behind a fenced code / math block,
    /// pulled left to the list bullet / attachment when the block sits inside a list item.
    public func drawBlockBackground(forCharRange range: NSRange, at origin: CGPoint, color: NSColor) {
        guard let storage = mdStorage else { return }
        let g = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard let container = textContainer(forGlyphAt: g.location, effectiveRange: nil) else { return }
        var union = CGRect.zero
        for (i, r) in rectArray(forGlyphRange: g, in: container, at: origin).enumerated() { union = i == 0 ? r : union.union(r) }
        let inset = container.lineFragmentPadding + defaultParagraphIndent
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: range)
        var attachment = storage.textAttachment(at: paragraph.location)
        if attachment == nil, range.location != 0 { attachment = storage.textAttachment(at: range.location - 1) }
        var shift: CGFloat = 0
        if let a = attachment {
            let ps = storage.nonHiddenFont(at: range.location)?.pointSize ?? defaultFont.pointSize
            shift = a.bounds.width + 0 + ps * -0.5
        } else if range.location != 0, storage.hasListMarker(at: range.location - 1) {
            let markerRect = boundingRect(forGlyphRange: NSRange(location: range.location - 1, length: 1), in: container)
            let ps = storage.nonHiddenFont(at: range.location)?.pointSize ?? defaultFont.pointSize
            shift = (markerRect.maxX - inset) + ps * -0.5
        }
        var rect = union
        rect.origin.x = origin.x + inset + shift
        rect.size.width = container.size.width - (shift + inset * 2)
        rect.size.width -= nestedBackgroundOffset(at: range.location)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: basePointSize * 3, yRadius: basePointSize * 3).fill()
    }

    // MARK: Rect helpers

    /// A single-line run is clamped to the
    /// expected line height so taller glyphs do not inflate the pill.
    public func rectArrayForInlineDrawing(atGlyphRange range: NSRange, in container: NSTextContainer, at origin: CGPoint) -> [CGRect] {
        var rects = nonCollapsedRectArray(forGlyphRange: range, in: container, at: origin)
        let index = characterIndexForGlyph(at: range.location)
        if rects.count == 1, let first = rects.first {
            let expected = expectedLineHeight(at: index)
            if expected < first.height {
                rects = [CGRect(x: first.minX, y: first.minY + (first.height - expected), width: first.width, height: expected)]
            }
        }
        guard let storage = mdStorage else { return rects }
        let lineHeight = expectedLineHeight(at: index)
        return rects.map { rect in
            let glyphs = glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            let lineGlyphs = NSIntersectionRange(range, glyphs)
            guard lineGlyphs.length > 0 else { return rect }
            let chars = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            guard let ink = storage.inkExtents(in: chars) else { return rect }
            let baseline = origin.y + lineFragmentRect(forGlyphAt: lineGlyphs.location, effectiveRange: nil).minY
                + location(forGlyphAt: lineGlyphs.location).y
            let height = max(lineHeight, ink.above + ink.below)
            let middle = baseline - (ink.above - ink.below) / 2
            return CGRect(x: rect.minX, y: middle - height / 2, width: rect.width, height: height)
        }
    }

    /// Rounds the outer corners of
    /// a multi-line run so the pill reads as one shape.
    public func bezierPaths(forRectArray rects: [CGRect], borderWidth: CGSize, cornerRadius: CGFloat, roundMiddlePaths: Bool, rtl: Bool) -> [NSBezierPath] {
        var paths: [NSBezierPath] = []
        for (i, original) in rects.enumerated() {
            var r = original
            if r.width > 0, r.height > 0, borderWidth.width != 0 || borderWidth.height != 0 {
                r = r.insetBy(dx: -borderWidth.width, dy: -borderWidth.height)
            }
            if cornerRadius <= 0 {
                paths.append(NSBezierPath(rect: r)); continue
            }
            if rects.count == 1 {
                paths.append(NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)); continue
            }
            var corners: RectCorners
            if !roundMiddlePaths {
                if i == 0 { corners = rtl ? [.topRight, .bottomRight] : [.topLeft, .bottomLeft] }
                else if i == rects.count - 1 { corners = rtl ? [.topLeft, .bottomLeft] : [.topRight, .bottomRight] }
                else { paths.append(NSBezierPath(rect: r)); continue }
            } else if i == 0 {
                let next = rects[1]
                corners = [.topLeft, .topRight]
                if next.minX < original.minX || original.maxX < next.maxX { corners = [.topLeft, .topRight, .bottomLeft] }
                if next.maxX < original.maxX { corners.insert(.bottomRight) }
            } else if i == rects.count - 1 {
                let prev = rects[i - 1]
                corners = [.bottomLeft, .bottomRight]
                if original.minX < prev.minX { corners.insert(.topLeft) }
                if prev.maxX < original.maxX || original.maxX < prev.minX { corners.insert(.topRight) }
            } else {
                let next = rects[i + 1]
                let prev = rects[i - 1]
                corners = []
                if original.minX < prev.minX { corners.insert(.topLeft) }
                if prev.maxX < original.maxX { corners.insert(.topRight) }
                if original.minX < next.minX { corners.insert(.bottomLeft) }
                if next.maxX < original.maxX { corners.insert(.bottomRight) }
            }
            paths.append(NSBezierPath.path(roundedRect: r, byRounding: corners, radius: cornerRadius))
        }
        return paths
    }

    public func rectArray(forGlyphRange range: NSRange, in container: NSTextContainer, at origin: CGPoint) -> [CGRect] {
        var out: [CGRect] = []
        enumerateEnclosingRects(forGlyphRange: range, withinSelectedGlyphRange: range, in: container) { rect, _ in
            out.append(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
        }
        return out
    }

    /// Per line fragment, dropping the trailing newline glyph.
    public func nonCollapsedRectArray(forGlyphRange range: NSRange, in container: NSTextContainer, at origin: CGPoint) -> [CGRect] {
        var out: [CGRect] = []
        guard let storage = mdStorage else { return out }
        let ns = storage.string as NSString
        enumerateLineFragments(forGlyphRange: range) { _, _, _, lineGlyphs, _ in
            var r = NSIntersectionRange(range, lineGlyphs)
            if NSMaxRange(lineGlyphs) < NSMaxRange(range) {
                let last = self.characterIndexForGlyph(at: NSMaxRange(lineGlyphs) - 1)
                if last < ns.length, ns.character(at: last) == 0x0A { r.length -= 1 }
            }
            self.enumerateEnclosingRects(forGlyphRange: r, withinSelectedGlyphRange: r, in: container) { rect, _ in
                out.append(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
            }
        }
        return out
    }

    public func rectCollection(forGlyphRange range: NSRange, in container: NSTextContainer, at origin: CGPoint) -> SFRectCollection {
        let c = SFRectCollection()
        enumerateEnclosingRects(forGlyphRange: range, withinSelectedGlyphRange: range, in: container) { rect, _ in
            c.addRect(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
        }
        return c
    }

    public func isRangeAtTheStartOfTheTextColumn(_ range: NSRange) -> Bool {
        guard range.location != 0, let storage = mdStorage else { return true }
        let prev = range.location - 1
        if (storage.string as NSString).character(at: prev) == 0x0A { return true }
        return storage.hasListMarker(at: prev) || storage.hasBlockquoteMarker(at: prev)
    }

    public func isRTL(at index: Int) -> Bool {
        guard let storage = mdStorage, index < storage.length else { return false }
        let v = (storage.attribute(.pmkDirection, at: index, effectiveRange: nil) as? NSNumber)?.intValue
        return v == PMKDirectionValue.rtl.rawValue
    }

    public func expectedLineHeight(at index: Int) -> CGFloat {
        guard let storage = mdStorage, let p = storage.paragraphStyle(at: index) else { return 0 }
        return CGFloat(Int(p.minimumLineHeight + p.lineSpacing))
    }

    public func nestedBackgroundOffset(at index: Int) -> CGFloat {
        guard let storage = mdStorage else { return 0 }
        return baseTabSize * CGFloat(storage.calloutNestLevel(at: index))
    }
}

/// Which corners to round — UIRectCorner-style masks (topLeft 1, topRight 2, bottomLeft 4, bottomRight 8).
public struct RectCorners: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let topLeft = RectCorners(rawValue: 1)
    public static let topRight = RectCorners(rawValue: 2)
    public static let bottomLeft = RectCorners(rawValue: 4)
    public static let bottomRight = RectCorners(rawValue: 8)
}

public extension NSBezierPath {
    /// `bezierPathWithRoundedRect:byRoundingCorners:cornerRadii:` (flipped coordinates: "top" is minY).
    static func path(roundedRect rect: CGRect, byRounding corners: RectCorners, radius: CGFloat) -> NSBezierPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let p = NSBezierPath()
        let tl = corners.contains(.topLeft) ? r : 0
        let tr = corners.contains(.topRight) ? r : 0
        let bl = corners.contains(.bottomLeft) ? r : 0
        let br = corners.contains(.bottomRight) ? r : 0
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.line(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { p.appendArc(withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: 270, endAngle: 360) }
        p.line(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { p.appendArc(withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: 0, endAngle: 90) }
        p.line(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { p.appendArc(withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: 90, endAngle: 180) }
        p.line(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { p.appendArc(withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: 180, endAngle: 270) }
        p.close()
        return p
    }
}
