import AppKit

/// Vector icons for the five callout kinds, drawn into a flipped NSImage and scaled by
/// `fontSize / 20`. Coordinates recovered from the arm64 asm (y-down); `C` entries are end point then controls.
public final class MDCalloutIcon {
    public let type: Int
    public let fontSize: CGFloat
    public let color: NSColor

    public init(type: Int, fontSize: CGFloat, color: NSColor) {
        self.type = max(0, min(4, type)); self.fontSize = fontSize; self.color = color
    }

    public var scale: CGFloat { fontSize / 20 }
    public static let baseSizes: [CGSize] = [CGSize(width: 23.44, height: 18.41), CGSize(width: 18.92, height: 24.15),
                                             CGSize(width: 22.51, height: 22.0), CGSize(width: 21.13, height: 18.93),
                                             CGSize(width: 21.08, height: 19.91)]
    public var size: CGSize { let b = MDCalloutIcon.baseSizes[type]; return CGSize(width: b.width * scale, height: b.height * scale) }

    public lazy var icon: NSImage = {
        let img = NSImage(size: size, flipped: true) { [self] _ in
            color.setFill()
            for pathSource in MDCalloutIcon.paths[type] {
                let path = MDCalloutIcon.bezierPath(from: pathSource)
                path.transform(using: AffineTransform(scale: scale))
                path.fill()
            }
            return true
        }
        return img
    }()

    static func bezierPath(from source: String) -> NSBezierPath {
        let path = NSBezierPath()
        let tokens = source.split(separator: " ")
        var i = 0
        func num() -> CGFloat { let v = CGFloat(Double(tokens[i]) ?? 0); i += 1; return v }
        while i < tokens.count {
            let op = tokens[i]; i += 1
            switch op {
            case "M": path.move(to: NSPoint(x: num(), y: num()))
            case "L": path.line(to: NSPoint(x: num(), y: num()))
            case "C":
                let end = NSPoint(x: num(), y: num()), c1 = NSPoint(x: num(), y: num()), c2 = NSPoint(x: num(), y: num())
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            case "Z": path.close()
            default: break
            }
        }
        return path
    }

    static let paths: [[String]] = [
        // NOTE
        ["M 19.74 0.04 C 21.94 0.42 21.02 0.04 21.48 0.17 C 23.03 1.5 22.41 0.67 22.78 1.04 C 23.41 3.71 23.27 1.97 23.41 2.43 L 23.41 14.74 C 23.03 16.94 23.41 16.01 23.27 16.48 C 21.94 18.02 22.78 17.41 22.41 17.77 C 19.74 18.41 21.48 18.27 21.02 18.41 L 3.67 18.41 C 1.46 18.02 2.39 18.41 1.93 18.27 C 0.38 16.94 1 17.77 0.63 17.41 C 0 14.74 0.13 16.48 0 16.01 L 0 3.71 C 0.38 1.5 0 2.43 0.13 1.97 C 1.46 0.42 0.63 1.04 1 0.67 C 3.67 0.04 1.93 0.17 2.39 0.04 L 19.74 0.04 Z M 19.79 2.12 L 3.62 2.12 C 2.69 2.28 3.08 2.12 2.89 2.18 C 2.24 2.73 2.5 2.38 2.34 2.54 C 2.08 3.66 2.14 2.93 2.08 3.12 L 2.08 14.79 C 2.24 15.71 2.08 15.32 2.14 15.52 C 2.69 16.17 2.34 15.91 2.5 16.06 C 3.62 16.33 2.89 16.27 3.08 16.33 L 19.79 16.33 C 20.71 16.17 20.33 16.33 20.52 16.27 C 21.17 15.71 20.91 16.06 21.06 15.91 C 21.33 14.79 21.27 15.52 21.33 15.32 L 21.33 3.66 C 21.17 2.73 21.33 3.12 21.27 2.93 C 20.71 2.28 21.06 2.54 20.91 2.38 C 19.79 2.12 20.52 2.18 20.33 2.12 Z M 16.43 5.31 C 17.13 6.01 16.82 5.31 17.13 5.62 C 16.43 6.71 17.13 6.4 16.82 6.71 L 5.97 6.71 C 5.27 6.01 5.58 6.71 5.27 6.4 C 5.97 5.31 5.27 5.62 5.58 5.31 L 16.43 5.31 Z M 16.43 8.52 C 17.13 9.22 16.82 8.52 17.13 8.84 C 16.43 9.92 17.13 9.61 16.82 9.92 L 5.97 9.92 C 5.27 9.22 5.58 9.92 5.27 9.61 C 5.97 8.52 5.27 8.84 5.58 8.52 L 16.43 8.52 Z M 12.91 11.73 C 13.61 12.43 13.3 11.73 13.61 12.05 C 12.91 13.14 13.61 12.82 13.3 13.14 L 5.97 13.14 C 5.27 12.43 5.58 13.14 5.27 12.82 C 5.97 11.73 5.27 12.05 5.58 11.73 L 12.91 11.73 Z"],
        // TIP (three sparkles)
        ["M 8.6 4.84 C 8.85 4.61 8.74 4.84 8.83 4.74 C 10.79 2.68 9.12 3.04 9.1 2.99 C 11.01 2.42 10.92 2.65 11.01 2.56 C 10.78 2.16 11.01 2.28 10.92 2.18 C 8.85 0.23 9.1 1.88 9.12 1.82 C 8.6 0 8.83 0.1 8.74 0 C 8.34 0.24 8.45 0 8.36 0.1 C 6.4 2.16 8.08 1.8 8.09 1.85 C 6.18 2.42 6.26 2.19 6.18 2.28 C 6.41 2.68 6.18 2.56 6.26 2.65 C 8.34 4.61 8.09 2.97 8.07 3.03 C 8.6 4.84 8.36 4.74 8.45 4.84 Z",
         "M 3.85 11.74 C 4.25 11.38 4.07 11.74 4.23 11.59 C 7.35 8.3 4.6 8.81 4.66 8.79 C 7.7 7.89 7.55 8.26 7.7 8.11 C 7.35 7.5 7.7 7.69 7.55 7.52 C 4.25 4.42 4.67 7.13 4.59 7.05 C 3.85 4.05 4.23 4.2 4.07 4.05 C 3.45 4.44 3.64 4.05 3.48 4.2 C 0.35 7.5 3.14 7 3.03 7.01 C 0 7.89 0.15 7.54 0 7.69 C 0.4 8.3 0 8.12 0.15 8.26 C 3.45 11.36 3.03 8.71 3.14 8.78 C 3.85 11.74 3.48 11.59 3.64 11.74 Z",
         "M 10.71 22.59 C 11.36 21.99 11.04 22.59 11.3 22.34 C 17.95 15.39 12.07 16.75 12.8 15.97 C 18.56 14.73 18.31 15.35 18.56 15.08 C 17.95 14.08 18.56 14.4 18.31 14.13 C 11.36 7.47 12.81 13.47 12.11 12.72 C 10.71 6.89 11.3 7.13 11.04 6.89 C 10.06 7.47 10.37 6.89 10.12 7.13 C 3.47 14.08 9.35 12.72 8.61 13.51 C 2.86 14.73 3.11 14.12 2.86 14.39 C 3.47 15.39 2.86 15.08 3.1 15.34 C 10.06 21.99 8.6 16.08 9.28 16.75 C 10.71 22.59 10.12 22.34 10.38 22.59 Z"],
        // IMPORTANT (bubble + "!")
        ["M 6.5 22 C 8.29 21.07 7.1 22 7.56 21.72 L 11.62 18.14 L 17.47 18.14 C 22.14 13.47 20.43 18.14 22.14 16.4 L 22.14 5.83 C 17.47 1.15 22.14 2.9 20.43 1.15 L 4.67 1.15 C 0 5.83 1.71 1.15 0 2.89 L 0 13.47 C 4.56 18.14 0 16.4 1.78 18.14 L 5.13 18.14 L 5.13 20.45 C 6.5 22 5.13 21.4 5.64 22 Z M 7.03 19.57 L 7.03 16.81 C 6.19 15.97 7.03 16.2 6.76 15.97 L 4.77 15.97 C 2.17 13.37 3.02 15.97 2.17 15.08 L 2.17 5.92 C 4.77 3.33 2.17 4.21 3.02 3.33 L 17.38 3.33 C 19.97 5.92 19.12 3.33 19.97 4.21 L 19.97 13.37 C 17.38 15.97 19.97 15.08 19.12 15.97 L 11.48 15.97 C 10.12 16.53 10.85 15.97 10.56 16.08 Z",
         "M 11.08 11.17 C 12.01 10.25 11.65 11.17 11.99 10.85 L 12.16 5.81 C 11.07 4.75 12.19 5.2 11.72 4.75 C 9.98 5.8 10.41 4.75 9.96 5.19 L 10.12 10.25 C 11.08 11.17 10.15 10.85 10.49 11.17 Z M 11.08 14.46 C 12.29 13.34 11.75 14.46 12.29 14 C 11.08 12.23 12.29 12.69 11.76 12.23 C 9.86 13.34 10.4 12.23 9.86 12.69 C 11.08 14.46 9.86 13.99 10.41 14.46 Z"],
        // WARNING (triangle + "!")
        ["M 2.86 18.93 L 17.92 18.93 C 20.77 16.09 19.66 18.93 20.77 17.65 C 20.38 14.64 20.77 15.6 20.64 15.1 L 12.84 1.48 C 10.39 0.05 12.29 0.53 11.35 0.05 C 7.94 1.48 9.42 0.05 8.47 0.53 L 0.39 14.64 C 0 16.09 0.12 15.11 0 15.6 C 2.86 18.93 0 17.65 1.11 18.93 Z M 3.14 16.86 C 2.24 15.92 2.58 16.86 2.24 16.42 C 2.35 15.41 2.24 15.78 2.27 15.58 L 9.61 2.7 C 10.39 2.28 9.78 2.41 10.09 2.28 C 11.16 2.71 10.69 2.28 10.99 2.41 L 18.42 15.43 C 18.54 15.92 18.5 15.59 18.54 15.78 C 17.63 16.86 18.54 16.42 18.18 16.86 Z",
         "M 10.39 12.05 C 11.32 11.12 10.97 12.05 11.3 11.73 L 11.47 6.69 C 10.38 5.63 11.5 6.07 11.03 5.63 C 9.3 6.68 9.73 5.63 9.27 6.06 L 9.44 11.12 C 10.39 12.05 9.46 11.72 9.8 12.05 Z M 10.39 15.33 C 11.6 14.22 11.06 15.33 11.6 14.87 C 10.39 13.1 11.6 13.56 11.07 13.1 C 9.18 14.22 9.71 13.1 9.18 13.57 C 10.39 15.33 9.18 14.87 9.72 15.33 Z"],
        // CAUTION (octagon + "!")
        ["M 7.36 19.9 L 13.37 19.9 C 16.1 18.68 14.65 19.9 15.39 19.46 L 19.84 14.47 C 20.72 12.09 20.54 13.68 20.72 13.16 L 20.72 7.81 C 19.77 5.44 20.72 6.74 20.48 6.27 L 16.1 1.23 C 13.37 0 15.4 0.44 14.65 0 L 7.36 0 C 4.63 1.23 6.08 0 5.32 0.45 L 0.89 5.44 C 0 7.81 0.18 6.23 0 6.74 L 0 12.09 C 0.89 14.47 0 13.16 0.18 13.68 L 4.63 18.68 C 7.36 19.9 5.32 19.46 6.08 19.9 Z M 7.79 17.77 C 6.09 17.01 6.89 17.77 6.58 17.55 L 2.81 13.37 C 2.34 11.93 2.43 12.93 2.34 12.65 L 2.34 7.97 C 2.81 6.54 2.34 7.25 2.43 6.97 L 6.09 2.9 C 7.79 2.14 6.58 2.35 6.89 2.14 L 12.94 2.14 C 14.63 2.9 13.83 2.14 14.14 2.35 L 17.91 6.54 C 18.39 7.97 18.29 6.97 18.39 7.25 L 18.39 11.93 C 17.91 13.37 18.39 12.65 18.29 12.93 L 14.63 17.01 C 12.94 17.77 14.14 17.55 13.83 17.77 Z",
         "M 10.36 11.48 C 11.3 10.55 10.94 11.48 11.27 11.16 L 11.45 6.11 C 10.35 5.05 11.47 5.49 11.01 5.05 C 9.27 6.1 9.69 5.05 9.25 5.48 L 9.42 10.55 C 10.36 11.48 9.44 11.15 9.78 11.48 Z M 10.36 14.76 C 11.57 13.65 11.04 14.76 11.57 14.3 C 10.36 12.53 11.57 13 11.04 12.53 C 9.16 13.65 9.69 12.53 9.16 13 C 10.36 14.76 9.16 14.29 9.7 14.76 Z"],
    ]
}

/// The `[!TYPE] ` marker becomes icon + "  Label" (label hidden while the
/// caret edits an untitled head line).
public final class MDCalloutTextAttachment: SFTextAttachment {
    public override class var supportsSecureCoding: Bool { true }
    public private(set) var type: Int = 0
    public private(set) var icon: NSImage = NSImage()
    public private(set) var label = NSMutableAttributedString()
    public var hideLabel = false { didSet { if hideLabel != oldValue { calculateSize(); updateAttachmentImage() } } }

    public convenience init(representedAttributedText text: NSAttributedString, labels: [Int: String], showLabel: Bool) {
        self.init(representedAttributedText: text)
        hideLabel = !showLabel
        type = (text.length > 0 ? text.attribute(.pmkCallout, at: 0, effectiveRange: nil) as? NSNumber : nil)?.intValue ?? 0
        let font = (text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let colors = text.length > 0 ? text.attribute(.mdCalloutColors, at: 0, effectiveRange: nil) as? [String: NSColor] : nil
        icon = MDCalloutIcon(type: type, fontSize: font.pointSize, color: colors?["icon"] ?? .black).icon
        let attrs = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        label = NSMutableAttributedString(string: "  " + (labels[type] ?? ""), attributes: attrs.filter { $0.key != .attachment })
        calculateSize()
    }

    private func calculateSize() {
        let s: NSAttributedString = hideLabel ? NSAttributedString(string: "  ", attributes: label.length > 0 ? label.attributes(at: 0, effectiveRange: nil) : [:]) : label
        let r = s.boundingRect(with: CGSize(width: 3000, height: 3000), options: [], context: nil)
        attachmentSize = CGSize(width: r.width + icon.size.width, height: r.height)
        attachmentBaselineOffset = r.origin.y
    }

    public override func drawAttachment(in rect: CGRect) {
        let x = rect.origin.x.rounded(), y = rect.origin.y.rounded(), h = rect.height.rounded()
        let iw = icon.size.width, ih = icon.size.height
        let iconY = y + ((h + abs(attachmentBaselineOffset)) - ih) * 0.5 + h * -0.05
        var iconX = x, labelX = x + iw
        if label.length > 0, (label.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection == .rightToLeft {
            iconX = CGRect(x: x, y: y, width: rect.width.rounded(), height: h).maxX - iw
            labelX -= iw
        }
        icon.draw(in: CGRect(x: iconX, y: iconY, width: iw, height: ih))
        if !hideLabel { label.draw(at: NSPoint(x: labelX, y: y)) }
    }
}
