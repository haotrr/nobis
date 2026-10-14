import AppKit
import PolarMark

// Block-level stylers, each a faithful port of the decompiled MDTextKit class of the same name.

/// Applies the body font/paragraph style to the whole range.
@MainActor public final class MDBodyTextStyler: MDBaseTextStyler {
    public var bodyTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .paragraphStyle: NSParagraphStyle.default,
    ]

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        guard !bodyTextAttributes.isEmpty else { return }
        s.addAttributes(bodyTextAttributes, range: range)
    }
}

/// Paragraph style per PMKDirection, forced writing direction on inline runs,
/// base writing direction on list/quote paragraphs, and the paragraph indent for plain paragraphs.
@MainActor public final class MDBidiTextStyler: MDBaseTextStyler {
    public var ltrParagraphStyle: NSParagraphStyle = .default
    public var rtlParagraphStyle: NSParagraphStyle = .default
    public var preferredParagraphStyle: NSParagraphStyle = .default
    public var paragraphIndent: CGFloat = 0
    public var inlineAttributes: [NSAttributedString.Key] = [
        .pmkCode, .pmkEmphasis, .pmkHashtag, .pmkHighlighter, .pmkImage, .pmkLink, .pmkStrikethrough, .pmkStrong,
        .pmkUnderline, .pmkHTMLBlock, .pmkHTMLInline, .pmkReference, .pmkReferenceDefinition, .pmkFootNote, .pmkWikiLink,
    ]
    public var forcedLTRAttributes: [NSAttributedString.Key] = [.pmkColor, .pmkHTMLEntity]

    private static let blockAttributes: [NSAttributedString.Key] = [
        .pmkHeading, .pmkList, .pmkBlockquote, .pmkTable, .pmkReferenceDefinition, .pmkFencedCode, .pmkIndentedCode,
        .pmkHTMLBlock, .pmkYaml, .pmkThematicBreak, .pmkImage,
    ]

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateAttribute(.pmkDirection, in: range, options: []) { value, run, _ in
            guard let v = (value as? NSNumber)?.intValue else { return }
            let style: NSParagraphStyle
            if v == PMKDirectionValue.ltr.rawValue { style = self.ltrParagraphStyle }
            else if v == PMKDirectionValue.rtl.rawValue { style = self.rtlParagraphStyle }
            else { style = self.preferredParagraphStyle }
            s.addAttribute(.paragraphStyle, value: style, range: run)
        }
        for key in inlineAttributes {
            s.enumerateAttribute(key, in: range, options: []) { value, run, _ in
                guard value != nil else { return }
                self.forceWritingDirectionToMatchParagraph(in: run, in: s)
            }
        }
        for key in forcedLTRAttributes {
            s.enumerateAttribute(key, in: range, options: []) { value, run, _ in
                guard value != nil else { return }
                self.forceWritingDirectionToLTR(in: run, in: s)
            }
        }
        for key in [NSAttributedString.Key.pmkList, .pmkBlockquote] {
            s.enumerateAttribute(key, in: range, options: []) { value, run, _ in
                guard value != nil else { return }
                s.enumerateAttribute(.paragraphStyle, in: run, options: []) { pv, pr, _ in
                    guard let p = pv as? NSParagraphStyle else { return }
                    let dir = s.writingDirection(at: pr.location)
                    let m = p.mutableCopy() as! NSMutableParagraphStyle
                    m.baseWritingDirection = NSWritingDirection(rawValue: dir) ?? .natural
                    s.addAttribute(.paragraphStyle, value: m, range: pr)
                }
            }
        }
        guard paragraphIndent != 0 else { return }
        let ns = s.string as NSString
        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, sub, enclosing, _ in
            // skip leading spaces, then look at the first real character's attributes
            var i = sub.location
            let last = NSMaxRange(enclosing) - 1
            while i < last, ns.character(at: i) == 0x20 { i += 1 }
            guard i < s.length else { return }
            let attrs = s.attributes(at: i, effectiveRange: nil)
            for key in Self.blockAttributes where attrs[key] != nil { return }
            let p = ((attrs[.paragraphStyle] as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            p.firstLineHeadIndent += self.paragraphIndent
            s.addAttribute(.paragraphStyle, value: p, range: enclosing)
        }
    }
}

@MainActor public final class MDHeadingTextStyler: MDBaseTextStyler {
    public var headerFont: NSFont = .systemFont(ofSize: 14)
    public var modularScale: CGFloat = 1
    public var lineHeightMultiplier: CGFloat = 1
    public var addTopBottomPadding = false
    public var paddingTopMultiplier: CGFloat = 0
    public var paddingBottomMultiplier: CGFloat = 0
    public var textColor: NSColor = .black
    public var accentColor: NSColor = .black

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateHeading(in: range, options: []) { content, atxMarker, setextMarker, headingRange, level, _ in
            let base = s.font(at: headingRange.location) ?? self.headerFont
            let font = self.headingFont(forBaseFont: base, headerLevel: level)
            s.addAttribute(.font, value: font, range: headingRange)
            s.addAttribute(.foregroundColor, value: self.textColor, range: headingRange)
            let p = (s.paragraphStyle(at: headingRange.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            p.setCenteredLineHeightMultiplier(self.lineHeightMultiplier, for: font)
            if setextMarker.location == NSNotFound {
                if self.addTopBottomPadding {
                    p.paragraphSpacingBefore += CGFloat(Float(self.paddingTopMultiplier * font.pointSize).rounded(.toNearestOrAwayFromZero)) // roundf
                    let next = ns.nextParagraph(for: headingRange)
                    var skipBottom = false
                    if next.length == 1, ns.character(at: next.location) == 0x0A, next.location > 0, ns.character(at: next.location - 1) == 0x0A {
                        skipBottom = true
                    }
                    if !skipBottom {
                        p.paragraphSpacing += CGFloat(Float(self.paddingBottomMultiplier * font.pointSize).rounded(.toNearestOrAwayFromZero)) // roundf
                    }
                }
                p.firstLineHeadIndent -= self.defaultParagraphIndent
            }
            s.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: headingRange))
            if atxMarker.location != NSNotFound { s.addAttribute(.foregroundColor, value: self.markerColor, range: atxMarker) }
            if setextMarker.location != NSNotFound { s.addAttribute(.foregroundColor, value: self.markerColor, range: setextMarker) }
            let rtl = self.isAttributedString(s, RTLAt: headingRange.location)
            let attachment: SFTextAttachment
            let replaced: NSRange
            if atxMarker.location == NSNotFound {
                attachment = self.setextAttachment(forRepresentedAttributedText: s.attributedSubstring(from: setextMarker), headerLevel: level, headerFont: font)
                replaced = setextMarker
            } else {
                attachment = self.atxAttachment(forRepresentedAttributedText: s.attributedSubstring(from: atxMarker), headerLevel: level, headerFont: font, rtl: rtl)
                replaced = atxMarker
            }
            let a = attachment.attachmentAttributedString
            s.replaceCharacters(in: replaced, with: a)
            replacementBlock(replaced, a)
        }
    }

    public func atxAttachment(forRepresentedAttributedText text: NSAttributedString, headerLevel level: Int, headerFont: NSFont, rtl: Bool) -> MDATXHeadingAttachment {
        let key = "atx|\(level)|\(rtl)|\(text.string)" as NSString
        if let cached = cache.object(forKey: key) as? MDATXHeadingAttachment {
            cached.representedAttributedText = text
            return cached.copyAttachment()
        }
        // The marker hangs in the side margin and is centred in it; with no margin it takes one tab.
        let slot = defaultParagraphIndent > 0 ? defaultParagraphIndent : baseTabSize
        let w = baseFontSize * 1.1
        // The ink is the longest bar, 0.9 × w (`MDATXHeadingAttachment.drawAttachment`), so centre that.
        let x = (slot - CGFloat(Int(w * 0.9))) * 0.5
        let a = MDATXHeadingAttachment(representedAttributedText: text)
        a.attachmentSize = CGSize(width: slot, height: w)
        a.drawingRect = CGRect(x: x, y: 0, width: w, height: baseFontSize * 0.9)
        if rtl { a.drawingRect = CGRect(x: a.attachmentSize.width - x - w, y: 0, width: w, height: baseFontSize * 0.9) }
        if level > 3 {
            a.attachmentBaselineOffset = text.baselineOffsetForAttachment(at: 0, attachmentHeight: a.attachmentSize.height)
        }
        a.representedAttributedText = text
        a.color = markerColor
        a.accentColor = accentColor
        a.borderWidth = basePointSize
        a.level = level
        a.updateAttachmentImage()
        cache.setObject(a, forKey: key)
        return a.copyAttachment()
    }

    public func setextAttachment(forRepresentedAttributedText text: NSAttributedString, headerLevel level: Int, headerFont: NSFont) -> MDSETEXTHeadingAttachment {
        let key = "setext|\(level)" as NSString
        if let cached = cache.object(forKey: key) as? MDSETEXTHeadingAttachment {
            cached.representedAttributedText = text
            return cached.copyAttachment()
        }
        let a = MDSETEXTHeadingAttachment(representedAttributedText: text)
        a.attachmentSize = CGSize(width: fullLineWidth, height: baseFontSize)
        a.lineWidth = basePointSize + basePointSize
        a.lineColor = markerColor
        a.attachmentBaselineOffset = text.baselineOffsetForAttachment(at: 0, attachmentHeight: a.attachmentSize.height)
        a.updateAttachmentImage()
        cache.setObject(a, forKey: key)
        return a.copyAttachment()
    }

    public func headingFont(forBaseFont base: NSFont, headerLevel level: Int) -> NSFont {
        let key = "font|\(base.fontName)|\(base.pointSize)|\(level)" as NSString
        if let cached = cache.object(forKey: key) as? NSFont { return cached }
        let size = headerSize(forBaseSize: baseFontSize, headerLevel: level, maxHeaderLevel: 7, modularScale: modularScale)
        let font = NSFont(descriptor: headerFont.fontDescriptor, size: size) ?? headerFont
        cache.setObject(font, forKey: key)
        return font
    }

    public func headerSize(forBaseSize base: CGFloat, headerLevel level: Int, maxHeaderLevel maxLevel: Int, modularScale scale: CGFloat) -> CGFloat {
        var mapped = level < 4 ? level : maxLevel
        if level == 3 { mapped = 5 }
        if level == 2 { mapped = 3 }
        return CGFloat(Float(base * pow(scale, CGFloat(maxLevel - mapped))).rounded(.toNearestOrAwayFromZero)) // roundf
    }
}

/// Bullets and task checkboxes.
@MainActor public final class MDUnorderedListTextStyler: MDBaseTextStyler {
    public var taskFillColor: NSColor?
    public var taskBorderColor: NSColor?
    public var taskCheckColor: NSColor?
    public var completedTaskTextColor: NSColor = .lightGray

    public override init() {
        super.init()
        markerColor = .blue
    }

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateUnorderedList(in: range, options: [], listBlock: { _, _, _, _ in }) { itemRange, markerRange, info, _ in
            self.indentListItemRange(itemRange, indentWidth: self.baseTabSize, in: s, replacementBlock: replacementBlock)
            guard markerRange.location != NSNotFound else { return }
            let represented = s.attributedSubstring(from: markerRange)
            let rtl = self.isAttributedString(s, RTLAt: itemRange.location)
            let attachment: SFTextAttachment
            if info.taskType == 0 {
                attachment = self.attachment(forRepresentedAttributedText: represented, listLevel: info.listLevel, rtl: rtl)
            } else {
                let completed = info.taskType == 2
                attachment = self.taskAttachment(forRepresentedAttributedText: represented, listLevel: info.listLevel, taskCompleted: completed, rtl: rtl)
                if completed {
                    let own = s.rangeOfListItemWithoutSublists(at: itemRange.location)
                    s.addAttribute(.foregroundColor, value: self.completedTaskTextColor, range: own)
                }
            }
            let a = attachment.attachmentAttributedString
            s.replaceCharacters(in: markerRange, with: a)
            replacementBlock(markerRange, a)
        }
    }

    public func attachment(forRepresentedAttributedText text: NSAttributedString, listLevel: Int, rtl: Bool) -> MDUnorderedListTextAttachment {
        let key = "bullet|\(listLevel & 3)|\(rtl)|\(text.string)" as NSString
        if let cached = cache.object(forKey: key) as? MDUnorderedListTextAttachment {
            cached.representedAttributedText = text
            return cached.copyAttachment()
        }
        // The cell is only as tall as the dot (plus a small extra for deeper levels), so the
        // baseline offset centres the dot on the cap height.
        let size = baseFontSize * 0.4
        let a = MDUnorderedListTextAttachment(representedAttributedText: text)
        let extra: CGFloat = listLevel > 1 ? baseFontSize * 0.2 : 0
        a.attachmentSize = CGSize(width: baseTabSize, height: size + extra)
        let x = (columnSize - size) * 0.5
        let yOffset = extra * 0.5
        a.drawingRect = CGRect(x: x, y: yOffset, width: size, height: size)
        if rtl { a.drawingRect = CGRect(x: a.attachmentSize.width - x - size, y: yOffset, width: size, height: size) }
        a.attachmentBaselineOffset = text.baselineOffsetForAttachment(at: 0, attachmentHeight: a.attachmentSize.height)
        a.bulletColor = markerColor
        a.bulletLevel = listLevel
        a.bulletBorderWidth = basePointSize
        a.updateAttachmentImage()
        cache.setObject(a, forKey: key)
        return a.copyAttachment()
    }

    public func taskAttachment(forRepresentedAttributedText text: NSAttributedString, listLevel: Int, taskCompleted: Bool, rtl: Bool) -> MDTaskTextAttachment {
        let key = "task|\(rtl)|\(text.string.lowercased())" as NSString
        if let cached = cache.object(forKey: key) as? MDTaskTextAttachment {
            cached.representedAttributedText = text
            return cached.copyAttachment()
        }
        let size = baseFontSize * 1.05
        let x = (columnSize - size) * 0.5
        let a = MDTaskTextAttachment(representedAttributedText: text)
        a.attachmentSize = CGSize(width: baseTabSize, height: size)
        a.drawingRect = CGRect(x: x, y: 0, width: size, height: size)
        if rtl { a.drawingRect = CGRect(x: a.attachmentSize.width - x - size, y: 0, width: size, height: size) }
        a.attachmentBaselineOffset = text.baselineOffsetCentringAttachmentInLineBox(at: 0, attachmentHeight: size)
        a.fillColor = taskFillColor
        a.borderColor = taskBorderColor
        a.checkColor = taskCheckColor
        a.borderWidth = baseFontSize * 0.1
        a.borderCompletedWidth = basePointSize
        a.completed = taskCompleted
        a.updateAttachmentImage()
        cache.setObject(a, forKey: key)
        return a.copyAttachment()
    }
}

/// Numbers stay as text; a spacer attachment right-aligns them in the gutter.
@MainActor public final class MDOrderedListTextStyler: MDBaseTextStyler {
    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        var minimumLineHeight: CGFloat = 0
        var lineSpacing: CGFloat = 0
        s.enumerateOrderedList(in: range, options: [.reverse], listBlock: { levelRange, _, _, _ in
            let p = s.paragraphStyle(at: levelRange.location) ?? .default
            minimumLineHeight = p.minimumLineHeight
            lineSpacing = p.lineSpacing
        }) { itemRange, markerRange, _, _ in
            guard markerRange.location != NSNotFound else { return }
            let spaceWidth = self.spaceSize(forMarkerRange: markerRange, in: s)
            let numberWidth = self.numberPlusSeparatorSize(forMarkerRange: markerRange, in: s)
            var indent = self.baseTabSize
            if self.columnSize < numberWidth { indent = self.baseTabSize + (numberWidth - self.columnSize) }
            self.indentListItemRange(itemRange, indentWidth: indent, in: s, replacementBlock: replacementBlock)
            s.addAttribute(.kern, value: NSNumber(value: Double(self.gutterSize - spaceWidth)), range: NSRange(location: NSMaxRange(markerRange) - 1, length: 1))
            s.addAttribute(.foregroundColor, value: self.markerColor, range: markerRange)
            let spacer = MDOrderedListTextAttachment()
            spacer.attachmentSize = CGSize(width: max(0, self.columnSize - numberWidth), height: self.baseFontSize)
            spacer.updateAttachmentImage()
            self.addLeftBoundarySpacerAttachment(spacer, in: s, at: markerRange.location, replacementBlock: replacementBlock)
        }
        _ = minimumLineHeight; _ = lineSpacing
    }

    /// The width of the marker's trailing space (cached).
    public func spaceSize(forMarkerRange marker: NSRange, in s: NSAttributedString) -> CGFloat {
        let key = " " as NSString
        if let n = cache.object(forKey: key) as? NSNumber, n.doubleValue != 0 { return CGFloat(n.doubleValue) }
        let w = s.attributedSubstring(from: NSRange(location: NSMaxRange(marker) - 1, length: 1)).boundingRect(with: CGSize(width: 1000, height: 1000), options: []).width
        cache.setObject(NSNumber(value: Double(w)), forKey: key)
        return w
    }

    /// Width of "12." (cached per text).
    public func numberPlusSeparatorSize(forMarkerRange marker: NSRange, in s: NSAttributedString) -> CGFloat {
        let r = NSRange(location: marker.location, length: marker.length - 1)
        let key = (s.string as NSString).substring(with: r) as NSString
        if let n = cache.object(forKey: key) as? NSNumber, n.doubleValue != 0 { return CGFloat(n.doubleValue) }
        let w = s.attributedSubstring(from: r).boundingRect(with: CGSize(width: 1000, height: 1000), options: []).width
        cache.setObject(NSNumber(value: Double(w)), forKey: key)
        return w
    }
}

/// Leading tabs/spaces of nested list items become a sized spacer attachment.
@MainActor public final class MDIndentSpaceTextStyler: MDBaseTextStyler {
    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateAttribute(.pmkIndentSpace, in: range, options: []) { value, run, _ in
            guard value != nil else { return }
            let a = self.attachmentForRange(run, in: s).attachmentAttributedString.mutableCopy() as! NSMutableAttributedString
            s.replaceCharacters(in: run, with: a)
            replacementBlock(run, a)
        }
    }

    public static func attachment(forRange range: NSRange, in s: NSAttributedString, tabSize: CGFloat, paragraphIndent: CGFloat, fontSize: CGFloat) -> MDIndentSpaceTextAttachment {
        let a = MDIndentSpaceTextAttachment(representedAttributedText: s.attributedSubstring(from: range))
        let info = s.listOrBlockquoteItemInfo(at: NSMaxRange(range))
        let units = (s.attribute(.pmkIndentSpace, at: range.location, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
        var extra: CGFloat = 0
        if let info = info, info.isOrderedList {
            let headIndent = s.paragraphStyle(at: range.location)?.headIndent ?? 0
            extra = ((headIndent - tabSize) - paragraphIndent) - CGFloat(info.listLevel) * tabSize
        }
        a.attachmentSize = CGSize(width: extra + CGFloat(units) * tabSize, height: fontSize)
        a.updateAttachmentImage()
        return a
    }

    public override func attachmentForRange(_ range: NSRange, in s: NSAttributedString) -> MDIndentSpaceTextAttachment {
        Self.attachment(forRange: range, in: s, tabSize: baseTabSize, paragraphIndent: defaultParagraphIndent, fontSize: baseFontSize)
    }
}

/// "> " becomes an attachment, the quote gets its background colour and
/// extra paragraph spacing at its top and bottom paragraphs.
@MainActor public final class MDBlockQuoteTextStyler: MDBaseTextStyler {
    public var textAttributes: [NSAttributedString.Key: Any] = [:]
    public var calloutColors: [Int: [String: NSColor]] = [:]
    public var calloutLabels: [Int: String] = [:]

    public override init() {
        super.init()
        markerColor = .red
    }

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateBlockquote(in: range, options: [], listBlock: { levelRange, level, _, _ in
            // Callouts inside the level get the text attributes, colours, 0.8×size
            // paragraph spacing and the nested tail indent; a level without callouts only gets the bar colour.
            var handledCallout = false
            s.enumerateCallout(in: ns.paragraphRange(for: levelRange), options: []) { calloutRange, _, _, type, _ in
                guard (s.blockquoteItemInfo(at: calloutRange.location)?.listLevel ?? -1) == level else { return }
                s.addAttributes(self.textAttributes, range: calloutRange)
                if !self.calloutColors.isEmpty, let colors = self.calloutColors[type] {
                    if let text = colors["text"] { s.addAttribute(.foregroundColor, value: text, range: calloutRange) }
                    s.addAttribute(.mdCalloutColors, value: colors, range: calloutRange)
                }
                let firstParagraph = ns.paragraphRange(for: NSRange(location: levelRange.location, length: 1))
                let lastParagraph = ns.paragraphRange(for: NSRange(location: NSMaxRange(levelRange) - 1, length: 1))
                if firstParagraph == lastParagraph {
                    let p = (s.paragraphStyle(at: firstParagraph.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                    p.paragraphSpacingBefore = self.baseFontSize * 0.8
                    p.paragraphSpacing = self.baseFontSize * 0.8
                    s.addAttribute(.paragraphStyle, value: p, range: firstParagraph)
                } else {
                    let first = (s.paragraphStyle(at: firstParagraph.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                    let last = (s.paragraphStyle(at: lastParagraph.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                    first.paragraphSpacingBefore = self.baseFontSize * 0.8
                    s.addAttribute(.paragraphStyle, value: first, range: firstParagraph)
                    last.paragraphSpacing = self.baseFontSize * 0.8
                    s.addAttribute(.paragraphStyle, value: last, range: lastParagraph)
                }
                let nest = CGFloat(s.calloutNestLevel(at: levelRange.location))
                s.enumerateAttribute(.paragraphStyle, in: levelRange, options: []) { pv, pr, _ in
                    guard let p = (pv as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    p.tailIndent = -(self.baseTabSize * nest) - p.headIndent
                    s.addAttribute(.paragraphStyle, value: p, range: pr)
                }
                handledCallout = true
            }
            if !handledCallout {
                s.addAttribute(.mdBlockQuoteBackgroundColor, value: self.markerColor, range: levelRange)
            }
        }) { itemRange, markerRange, info, _ in
            self.indentBlockQuoteItemRange(itemRange, indentWidth: self.baseTabSize, in: s, replacementBlock: replacementBlock)
            guard markerRange.location != NSNotFound else { return }
            // walk back from the end of the marker to the last ">" and replace ">" + following space
            var end = NSMaxRange(markerRange)
            var i = end - 1
            while i >= markerRange.location {
                if ns.character(at: i) == 0x3E {
                    let r = NSRange(location: i, length: end - i)
                    let a = MDBlockQuoteTextAttachment(representedAttributedText: s.attributedSubstring(from: r))
                    a.attachmentSize = CGSize(width: self.baseTabSize, height: self.baseFontSize)
                    a.updateAttachmentImage()
                    let replacement = a.attachmentAttributedString
                    s.replaceCharacters(in: r, with: replacement)
                    replacementBlock(r, replacement)
                    end = i
                }
                i -= 1
            }
            // Callout head → the "[!TYPE] " marker becomes an MDCalloutTextAttachment (icon + label).
            if info.isCallout, info.itemIndex == 0 {
                let para2 = (s.string as NSString).paragraphRange(for: NSRange(location: min(markerRange.location, s.length), length: 0))
                s.enumerateCallout(in: para2, options: []) { _, marker, title, _, stop in
                    guard marker.location != NSNotFound, NSMaxRange(marker) <= s.length else { return }
                    var mr = marker
                    if NSMaxRange(mr) < s.length, (s.string as NSString).character(at: NSMaxRange(mr)) == 0x20 { mr.length += 1 }
                    let a = MDCalloutTextAttachment(representedAttributedText: s.attributedSubstring(from: mr), labels: self.calloutLabels, showLabel: title.location == NSNotFound)
                    a.updateAttachmentImage()
                    let rep = a.attachmentAttributedString
                    s.replaceCharacters(in: mr, with: rep)
                    replacementBlock(mr, rep)
                    stop.pointee = true
                }
            }
        }
    }
}

@MainActor public final class MDFencedCodeTextStyler: MDBaseTextStyler {
    public var textAttributes: [NSAttributedString.Key: Any] = [:]
    public var languageColor: NSColor = .black

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateFencedCode(in: range, options: []) { content, openMarker, closeMarker, languageRange, _, _ in
            let fullRange = NSUnionRange(openMarker, closeMarker.location == NSNotFound ? content : closeMarker)
            let originalParagraph = s.paragraphStyle(at: openMarker.location) ?? .default
            let font = s.font(at: openMarker.location) ?? NSFont.systemFont(ofSize: self.baseFontSize)
            s.addAttributes(self.textAttributes, range: fullRange)
            s.addAttribute(.foregroundColor, value: self.markerColor, range: openMarker)
            if closeMarker.location != NSNotFound { s.addAttribute(.foregroundColor, value: self.markerColor, range: closeMarker) }
            if languageRange.location != NSNotFound { s.addAttribute(.foregroundColor, value: self.languageColor, range: languageRange) }
            if let codeParagraph = self.textAttributes[.paragraphStyle] as? NSParagraphStyle, codeParagraph.headIndent < originalParagraph.headIndent {
                let p = codeParagraph.mutableCopy() as! NSMutableParagraphStyle
                p.headIndent = originalParagraph.headIndent
                s.addAttribute(.paragraphStyle, value: p, range: fullRange)
            }
            let paragraph = ns.paragraphRange(for: openMarker)
            if paragraph.location == openMarker.location {
                let inset = font.pointSize
                let p = (s.paragraphStyle(at: openMarker.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                p.firstLineHeadIndent += inset
                p.headIndent += inset
                p.tailIndent -= inset
                let tabKey = NSNumber(value: Double(self.baseTabSize))
                var tabs = self.cache.object(forKey: tabKey) as? [NSTextTab]
                if tabs == nil {
                    var list: [NSTextTab] = []
                    for i in 0..<18 {
                        list.append(NSTextTab(textAlignment: .natural, location: inset + self.defaultParagraphIndent + CGFloat(i) * self.baseTabSize, options: [:]))
                    }
                    self.cache.setObject(list as NSArray, forKey: tabKey)
                    tabs = list
                }
                p.tabStops = tabs!
                s.addAttribute(.paragraphStyle, value: p, range: fullRange)
            } else {
                // the fence sits inside a list / quote paragraph: keep that paragraph's spacing
                let p = (s.paragraphStyle(at: paragraph.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacing = (self.textAttributes[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacing ?? p.paragraphSpacing
                s.addAttribute(.paragraphStyle, value: p, range: paragraph)
                let nest = s.calloutNestLevel(at: fullRange.location)
                s.enumerateAttribute(.paragraphStyle, in: ns.paragraphRange(for: fullRange), options: []) { pv, pr, _ in
                    guard let ps = (pv as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    ps.tailIndent = -(self.defaultParagraphIndent + self.baseTabSize * CGFloat(nest)) - font.pointSize * 0.5
                    s.addAttribute(.paragraphStyle, value: ps, range: pr)
                }
            }
            let first = (s.paragraphStyle(at: fullRange.location) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            first.paragraphSpacingBefore = self.baseFontSize * 0.15
            s.addAttribute(.paragraphStyle, value: first, range: ns.paragraphRange(for: NSRange(location: fullRange.location, length: 1)))
            let lastIndex = NSMaxRange(fullRange) - 1
            let last = (s.paragraphStyle(at: lastIndex) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            last.paragraphSpacing = self.baseFontSize * 0.15
            s.addAttribute(.paragraphStyle, value: last, range: ns.paragraphRange(for: NSRange(location: lastIndex, length: 1)))
        }
    }
}

@MainActor public final class MDThematicBreakTextStyler: MDBaseTextStyler {
    public var borderColor: NSColor?

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        let ns = s.string as NSString
        s.enumerateThematicBreak(in: range, options: []) { run, _ in
            var r = run
            let paragraph = ns.paragraphRange(for: run)
            let lead = run.location - paragraph.location
            if lead < 4 {
                let prefix = ns.substring(with: NSRange(location: paragraph.location, length: lead)).replacingOccurrences(of: " ", with: "")
                if prefix.isEmpty { r = NSRange(location: paragraph.location, length: lead + run.length) }
            }
            let represented = s.attributedSubstring(from: r)
            let a = MDThematicBreakTextAttachment(representedAttributedText: represented)
            a.lineWidth = self.basePointSize
            a.attachmentSize = CGSize(width: self.fullLineWidth, height: self.baseFontSize)
            a.lineColor = self.borderColor
            a.attachmentBaselineOffset = represented.baselineOffsetForAttachment(at: 0, attachmentHeight: a.attachmentSize.height)
            a.updateAttachmentImage()
            let replacement = a.attachmentAttributedString
            s.replaceCharacters(in: r, with: replacement)
            replacementBlock(r, replacement)
        }
    }
}

@MainActor public final class MDHardLineBreakTextStyler: MDBaseTextStyler {
    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateHardLinebreak(in: range, options: []) { run, _ in
            let a = self.attachment(forRange: run, in: s).attachmentAttributedString.mutableCopy() as! NSMutableAttributedString
            s.replaceCharacters(in: run, with: a)
            replacementBlock(run, a)
        }
    }

    public func attachment(forRange range: NSRange, in s: NSAttributedString) -> MDHardLineBreakTextAttachment {
        let a = MDHardLineBreakTextAttachment(representedAttributedText: s.attributedSubstring(from: range))
        let ps = s.font(at: range.location)?.pointSize ?? baseFontSize
        let side = CGFloat(Int(ps))
        let margin = CGFloat(Int(ps * 0.4))
        a.attachmentSize = CGSize(width: margin + side, height: side)
        a.drawingRect = CGRect(x: margin / 2, y: 0, width: side, height: side)
        a.arrowColor = baseTextColor
        a.attachmentBaselineOffset = s.baselineOffsetForAttachment(at: range.location, attachmentHeight: a.attachmentSize.height)
        a.updateAttachmentImage()
        return a
    }
}

// Stylers whose features are not part of this port keep their place in the pipeline.
@MainActor public final class MDIndentedCodeTextStyler: MDBaseTextStyler {}
@MainActor public final class MDMathBlockTextStyler: MDBaseTextStyler {}
@MainActor public final class MDMermaidFencedCodeTextStyler: MDBaseTextStyler {}
/// The whole table block becomes one view-based `MDTableTextAttachment`.
@MainActor public final class MDTableTextStyler: MDBaseTextStyler {
    /// UI-layer hook that lays the grid out and renders it into the attachment.
    public var attachmentRenderer: ((MDTableTextAttachment) -> Void)?
    /// A cell editor's renderer disables the table styler.
    public var isEnabled = true

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        guard isEnabled else { return }
        s.enumerateTable(in: range, options: [], tableBlock: { tRange, _, _, _ in
            guard NSMaxRange(tRange) <= s.length else { return }
            let sub = s.attributedSubstring(from: tRange).mutableCopy() as! NSMutableAttributedString
            sub.fixAttributes(in: NSRange(location: 0, length: sub.length))
            sub.enumerateAttribute(.attachment, in: NSRange(location: 0, length: sub.length), options: [.reverse]) { v, r, _ in
                if let a = v as? SFTextAttachmentFileBackedView { sub.replaceCharacters(in: r, with: a.representedAttributedText) }
            }
            let att = MDTableTextAttachment(representedAttributedText: sub)
            att.maxTextContainerWidth = self.maxTextContainerWidth
            self.attachmentRenderer?(att)
            att.updateAttachmentImage()
            let rep = att.attachmentAttributedString.mutableCopy() as! NSMutableAttributedString
            s.replaceCharacters(in: tRange, with: rep)
            replacementBlock(tRange, rep)
        }, cellBlock: nil)
    }
}
@MainActor public final class MDMetadataTextStyler: MDBaseTextStyler {}
/// Replaces the fold comment plus the hidden section with one "•••" pill.
@MainActor public final class MDFoldTextStyler: MDBaseTextStyler {
    public var backgroundColor: NSColor?
    public var textColor: NSColor?

    public override func styleText(in s: NSMutableAttributedString, range: NSRange, replacementBlock: @escaping MDStylerReplacementBlock) {
        s.enumerateFold(in: range, options: []) { marker, folded, _ in
            let r = NSUnionRange(marker, folded)
            guard NSMaxRange(r) <= s.length else { return }
            let att = MDFoldTextAttachment(representedAttributedText: s.attributedSubstring(from: r))
            let p = self.basePointSize, f = self.baseFontSize
            att.attachmentSize = CGSize(width: (4 * p + f) * 2 + 4 * p, height: f)
            att.drawingRect = CGRect(x: 8 * p, y: 0, width: att.attachmentSize.width - 12 * p, height: att.attachmentSize.height)
            let level = s.headerLevel(at: r.location)
            if level == 0 || level >= 3 {
                let idx = r.location == 0 ? 1 : r.location - 1
                att.attachmentBaselineOffset = s.baselineOffsetForAttachment(at: min(idx, s.length - 1), attachmentHeight: att.attachmentSize.height)
            }
            att.backgroundColor = self.backgroundColor
            att.textColor = self.textColor
            att.updateAttachmentImage()
            att.collapsedRange = NSRange(location: marker.length, length: folded.length)
            let rep = att.attachmentAttributedString
            s.replaceCharacters(in: r, with: rep)
            replacementBlock(r, rep)
        }
    }
}
