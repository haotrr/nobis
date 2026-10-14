import AppKit
import PolarMark

// Inline stylers, each a faithful port of the decompiled MDTextKit class of the same name.

/// Bold trait on content + markers, marker colour on the markers.
@MainActor public final class MDStrongTextStyler: MDBaseTextStyler {
    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateStrong(in: range, options: []) { content, opening, closing, _ in
            guard content.length != 0 else { return }
            let whole = NSUnionRange(opening, closing)
            if let font = s.font(at: content.location), let bold = font.fontVariant(ofSize: font.pointSize, byAddingTraits: .bold) {
                s.addAttribute(.font, value: bold, range: whole)
            }
            s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
        }
    }
}

/// Italic variant per font run, skew fallback, marker colour.
@MainActor public final class MDEmphasisTextStyler: MDBaseTextStyler {
    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateEmphasis(in: range, options: []) { content, opening, closing, _ in
            guard content.length != 0 else { return }
            let whole = NSUnionRange(opening, closing)
            s.enumerateAttribute(.font, in: whole, options: []) { value, run, _ in
                guard let font = value as? NSFont else { return }
                s.addAttribute(.font, value: self.italicFont(for: font), range: run)
            }
            s.fixItalicAttribute(in: content)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
        }
    }

    public func italicFont(for font: NSFont) -> NSFont {
        if let cached = cache.object(forKey: font) as? NSFont { return cached }
        let italic = font.fontVariant(ofSize: font.pointSize, byAddingTraits: .italic) ?? font
        cache.setObject(italic, forKey: font)
        return italic
    }
}

@MainActor public final class MDStrikethroughTextStyler: MDBaseTextStyler {
    public var textColor: NSColor = .black

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateStrikethrough(in: range, options: []) { content, opening, closing, _ in
            guard content.length != 0 else { return }
            s.addAttribute(.strikethroughStyle, value: NSNumber(value: NSUnderlineStyle.single.rawValue), range: content)
            s.addAttribute(.foregroundColor, value: self.textColor, range: content)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
        }
    }
}

@MainActor public final class MDUnderlineTextStyler: MDBaseTextStyler {
    public var underlineColor: NSColor = .black

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateUnderline(in: range, options: []) { content, opening, closing, _ in
            guard content.length != 0 else { return }
            s.addAttribute(.underlineStyle, value: NSNumber(value: NSUnderlineStyle.single.rawValue), range: content)
            s.addAttribute(.underlineColor, value: self.underlineColor, range: content)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
        }
    }
}

/// Code font on the content, text attributes on the whole span, boundary spacers.
@MainActor public final class MDCodeTextStyler: MDBaseTextStyler {
    public var textAttributes: [NSAttributedString.Key: Any] = [:]
    public var codeFont: NSFont = .systemFont(ofSize: 14)
    public var fontSizeMultiplier: CGFloat = 1

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateCode(in: range, options: []) { content, opening, closing, _ in
            let whole = NSUnionRange(opening, closing)
            let pointSize = s.font(at: opening.location)?.pointSize ?? self.baseFontSize
            let font = NSFont(descriptor: self.codeFont.fontDescriptor, size: pointSize * self.fontSizeMultiplier) ?? self.codeFont
            s.addAttributes(self.textAttributes, range: whole)
            s.addAttribute(.font, value: font, range: content)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
            let spacer = MDCodeTextAttachment()
            spacer.attachmentSize = CGSize(width: CGFloat(Float(Int(pointSize * self.fontSizeMultiplier * 0.25))), height: self.baseFontSize)
            spacer.updateAttachmentImage()
            self.addBoundarySpacerAttachment(spacer, in: s, range: whole, replacementBlock: replacementBlock)
        }
    }
}

/// `[label](url)`: label becomes a clickable link, the URL part becomes an icon attachment.
@MainActor public final class MDLinkTextStyler: MDBaseTextStyler {
    public var linkColor: NSColor = .black
    public var attachmentColor: NSColor?
    public var disablePreview = false

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateLink(in: range, options: [.reverse]) { label, url, title, open1, close1, open2, close2, _ in
            let urlString = ns.substring(with: url)
            var labelEmpty = true
            if label.length != 0, url.length != 0 {
                labelEmpty = ns.substring(with: label).trimmingCharacters(in: .whitespaces).isEmpty
            }
            for marker in [open1, close1, open2, close2] where marker.location != NSNotFound {
                s.addAttribute(.foregroundColor, value: self.markerColor, range: marker)
            }
            if let valid = NSURL.validURL(fromString: urlString) {
                s.addAttribute(.link, value: valid, range: label)
                s.addAttribute(.foregroundColor, value: self.linkColor, range: label)
                // The rendered result has no underline, so this is 0.
                if s.attribute(.underlineStyle, at: label.location, effectiveRange: nil) == nil {
                    s.addAttribute(.underlineStyle, value: NSNumber(value: 0), range: label)
                }
                s.addAttribute(.underlineStyle, value: NSNumber(value: 0), range: NSUnionRange(open2, close2))
            }
            if labelEmpty {
                s.addAttribute(.mdPreventMarkdownHiding, value: NSNumber(value: 1), range: NSUnionRange(open1, close2))
            }
            let font = s.font(at: url.location)
            let parens = NSUnionRange(open2, close2)
            let inner = NSRange(location: parens.location + 1, length: parens.length - 2)
            let a = MDLinkTextAttachment(representedAttributedText: s.attributedSubstring(from: inner))
            let ps = font?.pointSize ?? self.baseFontSize
            let side = CGFloat(Int(ps))
            let margin = CGFloat(Int(ps * 0.4))
            a.attachmentSize = CGSize(width: margin + side, height: side)
            a.drawingRect = CGRect(x: margin / 2, y: 0, width: side, height: side)
            a.color = self.attachmentColor
            a.attachmentBaselineOffset = s.baselineOffsetForAttachment(at: open1.location, attachmentHeight: a.attachmentSize.height)
            a.updateAttachmentImage()
            let replacement = a.attachmentAttributedString
            s.replaceCharacters(in: inner, with: replacement)
            if replacement.attribute(.pmkLinkURL, at: 0, effectiveRange: nil) == nil {
                s.addAttribute(.pmkLinkURL, value: urlString, range: NSRange(location: inner.location, length: 1))
            }
            if replacement.attribute(.pmkLink, at: 0, effectiveRange: nil) == nil {
                s.addAttribute(.pmkLink, value: NSNumber(value: 1), range: NSRange(location: inner.location, length: 1))
            }
            if url.length == 0 && labelEmpty {
                let attrs = s.attributes(at: parens.location, effectiveRange: nil)
                s.addAttributes(attrs, range: NSRange(location: inner.location, length: 1))
                s.removeAttribute(.pmkLinkMarker, range: NSRange(location: inner.location, length: 1))
            }
            replacementBlock(inner, replacement)
            _ = title
        }
    }
}

/// `![alt](path)` becomes an inline image attachment.
@MainActor public final class MDImageTextStyler: MDBaseTextStyler {
    /// Host hook: markdown path → file URL.
    public var fileResolver: ((String) -> URL?)?
    /// Host-owned asynchronous fetch/cache; this callback never performs network I/O.
    public var dataResolver: ((String) -> Data?)?

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateImage(in: range, options: []) { label, url, _, open1, close1, open2, close2, _ in
            let whole = NSUnionRange(open1, close2)
            if label.length == 0 && url.length == 0 {
                s.addAttribute(.mdPreventMarkdownHiding, value: NSNumber(value: 1), range: whole)
            }
            for marker in [open1, close1, open2, close2] where marker.location != NSNotFound {
                s.addAttribute(.foregroundColor, value: self.markerColor, range: marker)
            }
            var path = ns.substring(with: url)
            if let decoded = path.removingPercentEncoding { path = decoded }
            let a = MDImageTextAttachment(representedAttributedText: s.attributedSubstring(from: whole))
            a.maxTextContainerWidth = self.maxTextContainerWidth
            a.setFilePath(path)
            a.resolvedFileURL = self.fileResolver?(path)
            a.imageData = self.dataResolver?(path)
            a.updateAttachmentImage()
            let replacement = a.attachmentAttributedString.mutableCopy() as! NSMutableAttributedString
            replacement.removeAttribute(.pmkImageMarker, range: NSRange(location: 0, length: 1))
            s.replaceCharacters(in: whole, with: replacement)
            replacementBlock(whole, replacement)
        }
    }
}

/// Tag pill: background colour, text/hash colours, optional link and icon, spacers.
@MainActor public final class MDHashtagTextStyler: MDBaseTextStyler {
    public var backgroundColor: NSColor = .black
    public var textColor: NSColor = .black
    public var hashColor: NSColor = .black
    public var tagURLBlock: ((String) -> URL?)?
    public var tagIconBlock: ((String) -> NSImage?)?

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateHashtag(in: range, options: []) { content, opening, closing, _ in
            var whole = NSUnionRange(opening, content)
            if closing.location != NSNotFound { whole = NSUnionRange(whole, closing) }
            s.addAttribute(.mdTagBackgroundColor, value: self.backgroundColor, range: whole)
            s.addAttribute(.foregroundColor, value: self.textColor, range: whole)
            s.addAttribute(.foregroundColor, value: self.hashColor, range: opening)
            if closing.location != NSNotFound, closing.length != 0 { s.addAttribute(.foregroundColor, value: self.hashColor, range: closing) }
            let tag = (s.attribute(.pmkHashtag, at: content.location, effectiveRange: nil) as? String) ?? ""
            if let block = self.tagURLBlock, let url = block(tag) {
                s.addAttribute(.link, value: url, range: whole)
            }
            s.enumerateAttribute(.pmkHashtagSeparator, in: content, options: []) { v, r, _ in
                guard v != nil else { return }
                s.addAttribute(.foregroundColor, value: self.hashColor, range: r)
            }
            let font = s.font(at: opening.location) ?? NSFont.systemFont(ofSize: self.baseFontSize)
            let spacer = MDTagTextAttachment()
            // Round(pointSize / 1.5) with an icon, round(pointSize * 0.5) without (frinta = round half away).
            let width: CGFloat = self.tagIconBlock == nil ? (font.pointSize * 0.5).rounded(.toNearestOrAwayFromZero) : (font.pointSize / 1.5).rounded(.toNearestOrAwayFromZero)
            spacer.attachmentSize = CGSize(width: width, height: self.baseFontSize)
            spacer.updateAttachmentImage()
            self.addBoundarySpacerAttachment(spacer, in: s, range: whole, replacementBlock: replacementBlock)
            s.removeAttribute(.mdSpacer, range: NSRange(location: NSMaxRange(whole) + 1, length: 1))
            guard let iconBlock = self.tagIconBlock, let icon = iconBlock(tag) else { return }
            let rtl = self.isAttributedString(s, RTLAt: opening.location)
            let iconAttachment = MDHashtagIconTextAttachment(representedAttributedText: s.attributedSubstring(from: NSRange(location: whole.location + 1, length: 0)))
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            let configured = icon.withSymbolConfiguration(config) ?? icon
            iconAttachment.icon = configured
            let gap = CGFloat(Int(font.pointSize * 0.35))
            let iconSize = configured.size
            iconAttachment.attachmentSize = CGSize(width: iconSize.width + gap, height: iconSize.height)
            iconAttachment.drawingRect = CGRect(x: rtl ? gap : 0, y: 0, width: iconSize.width, height: iconSize.height)
            iconAttachment.attachmentBaselineOffset = s.baselineOffsetForAttachment(at: whole.location + 1, attachmentHeight: iconAttachment.attachmentSize.height)
            iconAttachment.updateAttachmentImage()
            let attrs = s.attributes(at: whole.location + 1, effectiveRange: nil)
            let replacement = iconAttachment.attachmentAttributedString(with: attrs)
            let at = NSRange(location: whole.location + 1, length: 0)
            s.replaceCharacters(in: at, with: replacement)
            replacementBlock(at, replacement)
        }
    }
}

/// Bare URLs and e-mails become links.
@MainActor public final class MDAutoLinkTextStyler: MDBaseTextStyler {
    public var linkColor: NSColor = .black
    public var attachmentColor: NSColor?

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateAutoLinkURL(in: range, options: []) { run, opening, closing, _ in
            if let url = NSURL.validURL(fromString: ns.substring(with: run)) {
                s.addAttribute(.link, value: url, range: run)
                s.addAttribute(.foregroundColor, value: self.linkColor, range: run)
                if s.attribute(.underlineStyle, at: run.location, effectiveRange: nil) == nil {
                    s.addAttribute(.underlineStyle, value: NSNumber(value: 0), range: run)
                }
            }
            if opening.location != NSNotFound {
                s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
                s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
            }
        }
        s.enumerateAutoLinkEmail(in: range, options: []) { run, opening, closing, _ in
            if let url = URL(string: "mailto:" + ns.substring(with: run)) {
                s.addAttribute(.link, value: url, range: run)
                s.addAttribute(.foregroundColor, value: self.linkColor, range: run)
                s.addAttribute(.underlineStyle, value: NSNumber(value: 0), range: run)
            }
            if opening.location != NSNotFound {
                s.addAttribute(.foregroundColor, value: self.markerColor, range: opening)
                s.addAttribute(.foregroundColor, value: self.markerColor, range: closing)
            }
        }
    }
}

/// `==text==` with six colour slots.
@MainActor public final class MDHighlighterTextStyler: MDBaseTextStyler {
    public var textColors: [NSColor] = Array(repeating: .black, count: 6)
    public var backgroundColors: [NSColor] = Array(repeating: .green, count: 6)

    private func color(_ list: [NSColor], _ index: Int) -> NSColor { list[min(max(0, index), list.count - 1)] }

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateHighlighter(in: range, options: [], highlighterBlock: { _, _ in }, colorBlock: { run, colorIndex, _ in
            s.addAttribute(.mdHighlighterBackgroundColor, value: self.color(self.backgroundColors, colorIndex), range: run)
            s.enumerateAttribute(.foregroundColor, in: run, options: []) { value, r, _ in
                guard let current = value as? NSColor else { return }
                if current.isEqual(self.markerColor) {
                    s.addAttribute(.foregroundColor, value: self.color(self.textColors, colorIndex).withAlphaComponent(0.4), range: r)
                } else if s.attribute(.link, at: r.location, effectiveRange: nil) == nil, !s.isRangeInsideCode(r) {
                    s.addAttribute(.foregroundColor, value: self.color(self.textColors, colorIndex), range: r)
                }
            }
        }) { marker, isOpening, colorIndex, _ in
            s.addAttribute(.foregroundColor, value: self.color(self.textColors, colorIndex).withAlphaComponent(0.4), range: marker)
            if isOpening {
                let iconRange: NSRange
                let attrs: [NSAttributedString.Key: Any]
                if colorIndex == 0 {
                    iconRange = NSRange(location: NSMaxRange(marker), length: 0)
                    attrs = s.attributes(at: marker.location, effectiveRange: nil)
                } else {
                    iconRange = NSRange(location: NSMaxRange(marker) - 2, length: 2)
                    attrs = [:]
                }
                let icon = self.attachment(forRange: iconRange, color: self.color(self.textColors, colorIndex), in: s)
                let replacement = icon.attachmentAttributedString.mutableCopy() as! NSMutableAttributedString
                replacement.addAttributes(attrs, range: NSRange(location: 0, length: replacement.length))
                s.replaceCharacters(in: iconRange, with: replacement)
                replacementBlock(iconRange, replacement)
            }
            let font = s.font(at: marker.location) ?? NSFont.systemFont(ofSize: self.baseFontSize)
            let spacer = MDHighlighterSpacerTextAttachment()
            spacer.attachmentSize = CGSize(width: font.pointSize * 0.4, height: self.baseFontSize)
            spacer.updateAttachmentImage()
            if isOpening {
                spacer.attachmentSize = CGSize(width: spacer.attachmentSize.width - 1, height: spacer.attachmentSize.height)
                self.addLeftBoundarySpacerAttachment(spacer, in: s, at: marker.location, replacementBlock: replacementBlock)
            } else {
                self.addRightBoundarySpacerAttachment(spacer, in: s, at: NSMaxRange(marker), replacementBlock: replacementBlock)
            }
        }
    }

    public func attachment(forRange range: NSRange, color: NSColor, in s: NSAttributedString) -> MDHighlighterTextAttachment {
        let a = MDHighlighterTextAttachment(representedAttributedText: s.attributedSubstring(from: range))
        let ps = s.font(at: min(range.location, max(0, s.length - 1)))?.pointSize ?? baseFontSize
        let gap = CGFloat(Int(ps * 0.2))
        a.attachmentSize = CGSize(width: ps + gap, height: ps)
        a.drawingRect = CGRect(x: gap * 0.3, y: 0, width: ps, height: ps)
        a.attachmentBaselineOffset = s.baselineOffsetForAttachment(at: min(range.location, max(0, s.length - 1)), attachmentHeight: a.attachmentSize.height)
        a.color = color.withAlphaComponent(0.6)
        a.accentColor = color
        a.updateAttachmentImage()
        return a
    }
}

/// The backslash gets the marker colour and never becomes a link.
@MainActor public final class MDEscapeTextStyler: MDBaseTextStyler {
    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateEscape(in: range, options: []) { run, _ in
            s.addAttribute(.foregroundColor, value: self.markerColor, range: run)
            s.removeAttribute(.link, range: run)
        }
    }
}

// Inline stylers whose features are not part of this port keep their place in the pipeline.
@MainActor public final class MDColorTextStyler: MDBaseTextStyler {}
@MainActor public final class MDArrowTextStyler: MDBaseTextStyler {}
@MainActor public final class MDHTMLTextStyler: MDBaseTextStyler {}
@MainActor public final class MDSyntaxHighlightTextStyler: MDBaseTextStyler {}
@MainActor public final class MDReferenceTextStyler: MDBaseTextStyler {}
@MainActor public final class MDFileTextStyler: MDBaseTextStyler {}
@MainActor public final class MDFootnoteTextStyler: MDBaseTextStyler {}
@MainActor public final class MDWikiLinkTextStyler: MDBaseTextStyler {}
@MainActor public final class MDMathTextStyler: MDBaseTextStyler {}
