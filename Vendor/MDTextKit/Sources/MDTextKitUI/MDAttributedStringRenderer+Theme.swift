import AppKit
import MDTextKit
import SFThemeKit

// `extension MDAttributedStringRenderer` in MDTextKitUI (Swift) — recovered from the
// disassembly of `styleObject(with:)` and its metric helpers.
public extension MDAttributedStringRenderer {

    /// "editor.text size"
    func baseFontSize(for tm: SFThemeManager) -> CGFloat { tm.number(forKey: "editor.text size", default: 0) }

    /// "editor.text font" at the base size.
    func baseFont(for tm: SFThemeManager) -> NSFont { tm.font(forKey: "editor.text font", size: baseFontSize(for: tm)) }

    /// `tabSizeForFontSize(_:)` = ceil(size × 2.2)
    func tabSize(forFontSize size: CGFloat) -> CGFloat { ceil(size * 2.2) }
    /// `columnSizeForFontSize(_:)` = ceil(tab × 2/3)
    func columnSize(forFontSize size: CGFloat) -> CGFloat { ceil(tabSize(forFontSize: size) * 0.6666666666666666) }
    /// `gutterSizeForFontSize(_:)` = ceil(tab × 1/3)
    func gutterSize(forFontSize size: CGFloat) -> CGFloat { ceil(tabSize(forFontSize: size) * 0.3333333333333333) }
    /// The side margin, which is the body paragraph indent on both sides: "editor.side margin" or one tab.
    /// It never gets narrower than the heading marker that hangs in it, 1.1 × size, plus 0.25 × size each side.
    func sideMargin(for tm: SFThemeManager, fontSize size: CGFloat) -> CGFloat {
        max(tm.number(forKey: "editor.side margin", default: tabSize(forFontSize: size)), ceil(size * 1.6))
    }
    /// `pointSizeForFontSize(_:)` → `NSFont.basePointSizeForFontSize:`
    func pointSize(forFontSize size: CGFloat) -> CGFloat { NSFont.basePointSize(forFontSize: size) }
    /// `lineWidthForForThemeManager(_:)` = size × ("editor.line width multiplier" or 48)
    func lineWidth(for tm: SFThemeManager) -> CGFloat { baseFontSize(for: tm) * tm.number(forKey: "editor.line width multiplier", default: 48) }

    /// Matches the code font's x-height/cap-height to the body font.
    func codeFontSizeMultiplier(for tm: SFThemeManager) -> CGFloat {
        let base = baseFont(for: tm)
        let code = tm.font(forKey: "editor.code.font", size: base.pointSize)
        return ((base.xHeight / code.xHeight) + (base.capHeight / code.capHeight)) * 0.5
    }

    func codeFont(for tm: SFThemeManager) -> NSFont {
        tm.font(forKey: "editor.code.font", size: baseFontSize(for: tm) * codeFontSizeMultiplier(for: tm))
    }

    /// Centered line height, 19 tab stops, indent = default paragraph indent.
    func baseParagraphStyle(for tm: SFThemeManager) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lineHeightMultiplier = tm.number(forKey: "editor.line height multiplier", default: 0)
        let spacingMultiplier = tm.number(forKey: "editor.paragraph spacing multiplier", default: 0)
        let font = baseFont(for: tm)
        let indent = defaultParagraphIndent
        let tab = tabSize(forFontSize: font.pointSize)
        var stops: [NSTextTab] = []
        for i in 0..<19 {
            stops.append(NSTextTab(textAlignment: .natural, location: indent + tab * CGFloat(i), options: [:]))
        }
        p.setCenteredLineHeightMultiplier(lineHeightMultiplier, for: font)
        p.tabStops = stops
        p.defaultTabInterval = tab
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        p.tailIndent = -indent
        p.paragraphSpacing = spacingMultiplier * font.pointSize
        return p
    }

    /// `bodyParagraphIndent` setter used by table cell editors — zero indents on every styler and on the
    /// body paragraph style (tab stops restart at the new indent).
    func setBodyParagraphIndent(_ indent: CGFloat) {
        for styler in textStylers {
            styler.defaultParagraphIndent = indent
            styler.cache.removeAllObjects()   // the heading markers are sized by the indent
        }
        guard let p = (bodyStyler.bodyTextAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
        let tab = p.defaultTabInterval
        p.tabStops = (0..<19).map { NSTextTab(textAlignment: .natural, location: indent + tab * CGFloat($0), options: [:]) }
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        p.tailIndent = -indent
        bodyStyler.bodyTextAttributes[.paragraphStyle] = p
    }

    var defaultFontSize: CGFloat { bodyStyler.baseFontSize }
    var defaultParagraphIndent: CGFloat { bodyStyler.defaultParagraphIndent }
    var tabSize: CGFloat { bodyStyler.baseTabSize }
    var columnSize: CGFloat { bodyStyler.columnSize }
    var gutterSize: CGFloat { bodyStyler.gutterSize }
    var defaultPointsize: CGFloat { bodyStyler.basePointSize }
    var textContainerMaxWidth: CGFloat { bodyStyler.maxTextContainerWidth }
    /// `textContainerMinInset()` = 23
    var textContainerMinInset: CGFloat { 23 }
    var defaultLineSpacing: CGFloat { (bodyStyler.bodyTextAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0 }
    var defaultTextAttributes: [NSAttributedString.Key: Any] { bodyStyler.bodyTextAttributes }

    func styleObject(with tm: SFThemeManager) {
        for styler in textStylers { styler.cache.removeAllObjects() }
        let markerColor = tm.color(forKey: "editor.marker color", default: .black)
        let textColor = tm.color(forKey: "editor.text color", default: .black)
        let useDefaultIndent = tm.currentTheme.bool(forKeyPath: "editor.use default paragraph indent") ?? true
        for styler in textStylers {
            styler.markerColor = markerColor
            styler.baseTextColor = textColor
            styler.baseFontSize = baseFontSize(for: tm)
            styler.baseTabSize = tabSize(forFontSize: styler.baseFontSize)
            styler.basePointSize = pointSize(forFontSize: styler.baseFontSize)
            styler.defaultParagraphIndent = useDefaultIndent ? sideMargin(for: tm, fontSize: styler.baseFontSize) : 0
            styler.columnSize = columnSize(forFontSize: styler.baseFontSize)
            styler.gutterSize = gutterSize(forFontSize: styler.baseFontSize)
            styler.maxTextContainerWidth = lineWidth(for: tm)
        }

        // body
        let baseFont = baseFont(for: tm)
        let paragraph = baseParagraphStyle(for: tm)
        bodyStyler.bodyTextAttributes = [.font: baseFont, .paragraphStyle: paragraph, .foregroundColor: textColor]

        // bidi
        let ltr = paragraph.mutableCopy() as! NSMutableParagraphStyle; ltr.alignment = .left
        let rtl = paragraph.mutableCopy() as! NSMutableParagraphStyle; rtl.alignment = .right
        let natural = paragraph.mutableCopy() as! NSMutableParagraphStyle; natural.alignment = .natural
        bidiStyler.paragraphIndent = tm.number(forKey: "editor.paragraph indent multiplier", default: 0) * baseFont.pointSize
        bidiStyler.ltrParagraphStyle = ltr
        bidiStyler.rtlParagraphStyle = rtl
        bidiStyler.preferredParagraphStyle = natural

        // heading
        headingStyler.headerFont = tm.font(forKey: "editor.headers.font", size: defaultFontSize)
        headingStyler.modularScale = tm.number(forKey: "editor.headers.modular scale", default: 0)
        headingStyler.lineHeightMultiplier = tm.number(forKey: "editor.headers.line height multiplier", default: 0)
        headingStyler.paddingTopMultiplier = tm.number(forKey: "editor.headers.padding top multiplier", default: 0)
        headingStyler.paddingBottomMultiplier = tm.number(forKey: "editor.headers.padding bottom multiplier", default: 0)
        headingStyler.addTopBottomPadding = tm.bool(forKey: "editor.headers.add top bottom padding", default: false)
        let headersTextColor = tm.color(forKey: "editor.headers.text color", default: textColor)
        headingStyler.accentColor = headersTextColor.withAlphaComponent(0.7)
        headingStyler.textColor = headersTextColor

        // ordered / unordered lists
        orderedListStyler.markerColor = tm.color(forKey: "editor.list marker color", default: markerColor)
        unorderedListStyler.markerColor = tm.color(forKey: "editor.list marker color", default: markerColor)
        unorderedListStyler.taskBorderColor = tm.color(forKey: "editor.task.border color", default: markerColor)
        unorderedListStyler.taskCheckColor = tm.color(forKey: "editor.task.check color", default: textColor)
        unorderedListStyler.taskFillColor = nil
        unorderedListStyler.completedTaskTextColor = tm.color(forKey: "editor.text light color", default: markerColor)

        // blockquote: list marker colour for the bar; the text keeps the body face (quotes are rendered in the
        // regular text font even though otool labels the key literal "editor.headers.font").
        blockQuoteStyler.markerColor = tm.color(forKey: "editor.list marker color", default: markerColor)
        // The callout head line uses the headers font; colours derive from the
        // highlighter palette through HSL (blue→NOTE, green→TIP, purple→IMPORTANT, yellow→WARNING, red→CAUTION).
        blockQuoteStyler.textAttributes = [.font: tm.font(forKey: "editor.headers.font", size: defaultFontSize)]
        blockQuoteStyler.calloutLabels = [0: "Note", 1: "Tip", 2: "Important", 3: "Warning", 4: "Caution"]
        blockQuoteStyler.calloutColors = MDCalloutPalette.colors(themeManager: tm)

        // inline code / fenced code
        let codeTextColor = tm.color(forKey: "editor.code.text color", default: textColor)
        let codeBackground = tm.color(forKey: "editor.code.background color", default: .windowBackgroundColor)
        let codeBorder = tm.color(forKey: "editor.code.border color", default: .separatorColor)
        let codeFont = codeFont(for: tm)
        codeStyler.codeFont = codeFont
        codeStyler.fontSizeMultiplier = codeFontSizeMultiplier(for: tm)
        codeStyler.textAttributes = [.foregroundColor: codeTextColor, .mdCodeBorderColor: codeBorder, .mdCodeBackgroundColor: codeBackground]
        let codeParagraph = baseParagraphStyle(for: tm).mutableCopy() as! NSMutableParagraphStyle
        codeParagraph.baseWritingDirection = .leftToRight
        codeParagraph.setCenteredLineHeightMultiplier(tm.number(forKey: "editor.line height multiplier", default: 0), for: codeFont)
        codeParagraph.paragraphSpacing = 0
        fencedCodeStyler.languageColor = tm.color(forKey: "editor.text light color", default: markerColor)
        fencedCodeStyler.textAttributes = [.font: codeFont, .paragraphStyle: codeParagraph, .foregroundColor: codeTextColor,
                                           .mdCodeBorderColor: codeBorder, .mdCodeBackgroundColor: codeBackground]

        // highlighter: default, red, blue, green, yellow, purple
        var backgrounds: [NSColor] = []
        var texts: [NSColor] = []
        for name in ["default", "red", "blue", "green", "yellow", "purple"] {
            backgrounds.append(tm.color(forKey: "editor.highlighter.\(name).background color", default: .green))
            texts.append(tm.color(forKey: "editor.highlighter.\(name).text color", default: textColor))
        }
        highlighterStyler.backgroundColors = backgrounds
        highlighterStyler.textColors = texts

        // links
        let linkColor = tm.color(forKey: "editor.link color", default: .linkColor)
        let lightColor = tm.color(forKey: "editor.text light color", default: markerColor)
        autoLinkStyler.linkColor = linkColor
        autoLinkStyler.attachmentColor = lightColor.withAlphaComponent(0.6)
        linkStyler.linkColor = linkColor
        linkStyler.attachmentColor = lightColor.withAlphaComponent(0.6)
        underlineStyler.underlineColor = tm.color(forKey: "editor.accent color", default: textColor)
        strikethroughStyler.textColor = lightColor

        // tags
        // Fold pill colours.
        foldTextStyler.backgroundColor = tm.color(forKey: "base.background tertiary color", default: .lightGray).withAlphaComponent(0.6)
        foldTextStyler.textColor = tm.color(forKey: "base.text secondary color", default: .darkGray).withAlphaComponent(0.7)
        hashtagStyler.textColor = tm.color(forKey: "editor.tag.text color", default: textColor)
        hashtagStyler.backgroundColor = tm.color(forKey: "editor.tag.background color", default: markerColor)
        hashtagStyler.hashColor = tm.color(forKey: "editor.tag.marker color", default: markerColor)
        // The host supplies the tag icon: the "number" SF Symbol in the tag marker colour.
        let tagIconColor = hashtagStyler.hashColor
        hashtagStyler.tagIconBlock = { _ in
            NSImage(systemSymbolName: "number", accessibilityDescription: nil)?.tinted(with: tagIconColor)
        }

        thematicBreakStyler.borderColor = tm.color(forKey: "editor.separator.border color", default: markerColor)
    }
}

public extension MDTextContainer {
    @MainActor func style(with renderer: MDAttributedStringRenderer, themeManager: SFThemeManager) {
        maxColumSize = renderer.textContainerMaxWidth
        minInset = renderer.textContainerMinInset
    }
}

public extension MDLayoutManager {
    @MainActor func style(with renderer: MDAttributedStringRenderer, themeManager tm: SFThemeManager) {
        if let f = renderer.defaultTextAttributes[.font] as? NSFont { defaultFont = f }
        defaultLineSpacing = renderer.defaultLineSpacing
        defaultParagraphIndent = renderer.defaultParagraphIndent
        baseTabSize = renderer.tabSize
        basePointSize = renderer.defaultPointsize
        columnSize = renderer.columnSize
        gutterSize = renderer.gutterSize
        selectionInactiveColor = tm.color(forKey: "editor.selection inactive color", default: .unemphasizedSelectedContentBackgroundColor)
    }
}

extension NSImage {
    /// Returns a template-free copy of the image filled with `color` (used for the tag icon).
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}


/// Callout colour derivation (MDTextKitUI, `styleObject` for the blockquote styler).
enum MDCalloutPalette {
    @MainActor static func colors(themeManager tm: SFThemeManager) -> [Int: [String: NSColor]] {
        let white = NSColor(red: 1, green: 1, blue: 1, alpha: 1)
        let isLight = tm.color(forKey: "editor.background color", default: white).isLightColor
        let table: [(String, Int)] = [("blue", 0), ("green", 1), ("purple", 2), ("yellow", 3), ("red", 4)]
        var out: [Int: [String: NSColor]] = [:]
        for (name, type) in table {
            var T = tm.color(forKey: "editor.highlighter.\(name).text color", default: white)
            if T.isSameRGBA(as: white) { T = T.withAlphaComponent(0.9) }
            let B = tm.color(forKey: "editor.highlighter.\(name).background color", default: white)
            let (hT, sT, _, aT) = hsl(T)
            let (hB, _, _, aB) = hsl(B)
            var c: [String: NSColor] = [:]
            if isLight {
                c["background"] = B.withAlphaComponent(0.15)
                c["text"] = T
                switch type {
                case 0, 1, 2:
                    let base = HSL(hT, 80, 35, aT)
                    c["ribbon"] = base.withAlphaComponent(0.8); c["icon"] = base
                    c["border"] = base.withAlphaComponent(type == 2 ? 0.07 : 0.1)
                case 3:
                    let base = HSL(45, sT, 50, aT)
                    c["ribbon"] = base; c["icon"] = base; c["border"] = base.withAlphaComponent(0.15)
                default:
                    let base = HSL(hT, sT, 50, aT)
                    c["ribbon"] = base; c["icon"] = base; c["border"] = base.withAlphaComponent(0.1)
                }
            } else {
                let L: CGFloat = type == 2 ? 49 : 40
                let base = HSL(hB, 80, L, aB)
                c["background"] = base.withAlphaComponent(0.15)
                c["border"] = base.withAlphaComponent(0.1)
                c["ribbon"] = B; c["icon"] = T; c["text"] = T
            }
            out[type] = c
        }
        return out
    }

    /// HSL helper: returns (h in degrees, s %, l %, alpha).
    static func hsl(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0, sB: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&hue, saturation: &sB, brightness: &b, alpha: &a)
        let h = hue * 360
        let l = (2 - sB) * b / 2
        let s: CGFloat = (l > 0 && l < 1) ? sB * b / (l <= 0.5 ? 2 * l : 2 - 2 * l) : 0
        return (h, s * 100, l * 100, a)
    }

    static func HSL(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat) -> NSColor {
        let S = s / 100, L = l / 100
        let m = S * (L <= 0.5 ? L : 1 - L)
        return NSColor(hue: h / 360, saturation: (L == 0 || L == 1) ? 0 : 2 * m / (L + m), brightness: L + m, alpha: a)
    }
}

extension NSColor {
    /// Perceived luminance above one half.
    var isLightColor: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.5
    }
    func isSameRGBA(as other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.001 && abs(a.greenComponent - b.greenComponent) < 0.001
            && abs(a.blueComponent - b.blueComponent) < 0.001 && abs(a.alphaComponent - b.alphaComponent) < 0.001
    }
}
