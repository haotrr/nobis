import AppKit

/// PaintCode-style vector drawing for the marker icons.
/// The bezier coordinates are taken from the decompiled routines.
public enum MDTextKitStyleKit {

    private static func normalized(_ frame: CGRect) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let x0 = floor(frame.width * 0.0 + 0.5)
        let y0 = floor(frame.height * 0.0 + 0.5)
        let x = frame.minX + x0
        let y = frame.minY + y0
        let w = floor(frame.width + 0.5) - x0
        let h = floor(frame.height + 0.5) - y0
        return (x, y, w, h)
    }

    /// Chain-link glyph plus a 50% alpha underline stroke.
    public static func drawLinkIcon(frame: CGRect, fillColor: NSColor) {
        let f = normalized(frame)
        let (x, y, w, h) = (f.x, f.y, f.w, f.h)
        func p(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: x + w * px, y: y + h * py) }
        let path = NSBezierPath()
        path.move(to: p(0.70015, 0.14338))
        path.curve(to: p(0.72663, 0.1812), controlPoint1: p(0.68779, 0.14788), controlPoint2: p(0.70015, 0.14338))
        path.line(to: p(0.78616, 0.24074))
        path.curve(to: p(0.82399, 0.29443), controlPoint1: p(0.81264, 0.26721), controlPoint2: p(0.81948, 0.27957))
        path.curve(to: p(0.82399, 0.33933), controlPoint1: p(0.82849, 0.30928), controlPoint2: p(0.82849, 0.32448))
        path.curve(to: p(0.78616, 0.39302), controlPoint1: p(0.81948, 0.35419), controlPoint2: p(0.81264, 0.36655))
        path.line(to: p(0.35648, 0.8227))
        path.curve(to: p(0.31056, 0.86274), controlPoint1: p(0.33158, 0.84761), controlPoint2: p(0.32217, 0.85533))
        path.curve(to: p(0.27382, 0.8786), controlPoint1: p(0.29895, 0.87016), controlPoint2: p(0.28718, 0.87524))
        path.curve(to: p(0.21319, 0.88455), controlPoint1: p(0.26047, 0.88196), controlPoint2: p(0.24839, 0.88351))
        path.line(to: p(0.13186, 0.88695))
        path.curve(to: p(0.08, 0.83806), controlPoint1: p(0.10404, 0.88777), controlPoint2: p(0.08082, 0.86588))
        path.line(to: p(0.08, 0.83495))
        path.line(to: p(0.0826, 0.75392))
        path.curve(to: p(0.08868, 0.69346), controlPoint1: p(0.08373, 0.71881), controlPoint2: p(0.0853, 0.70677))
        path.curve(to: p(0.10453, 0.65684), controlPoint1: p(0.09205, 0.68014), controlPoint2: p(0.09713, 0.66841))
        path.curve(to: p(0.14449, 0.61105), controlPoint1: p(0.11194, 0.64528), controlPoint2: p(0.11964, 0.6359))
        path.line(to: p(0.57434, 0.1812))
        path.curve(to: p(0.62803, 0.14338), controlPoint1: p(0.60082, 0.15472), controlPoint2: p(0.61317, 0.14788))
        path.curve(to: p(0.67294, 0.14338), controlPoint1: p(0.64289, 0.13887), controlPoint2: p(0.65808, 0.13887))
        path.close()
        path.move(to: p(0.52547, 0.3444))
        path.line(to: p(0.1651, 0.70483))
        path.line(to: p(0.15648, 0.81093))
        path.line(to: p(0.26254, 0.80227))
        path.line(to: p(0.62293, 0.44187))
        path.line(to: p(0.52547, 0.3444))
        path.close()
        path.move(to: p(0.65967, 0.23051))
        path.curve(to: p(0.64471, 0.23051), controlPoint1: p(0.65472, 0.22901), controlPoint2: p(0.64966, 0.22901))
        path.curve(to: p(0.62681, 0.24312), controlPoint1: p(0.63975, 0.23201), controlPoint2: p(0.63563, 0.24312))
        path.line(to: p(0.57727, 0.29267))
        path.line(to: p(0.67467, 0.39007))
        path.line(to: p(0.72425, 0.34056))
        path.curve(to: p(0.73581, 0.32557), controlPoint1: p(0.73131, 0.33349), controlPoint2: p(0.73418, 0.32945))
        path.line(to: p(0.73686, 0.32266))
        path.curve(to: p(0.73686, 0.30769), controlPoint1: p(0.73836, 0.31771), controlPoint2: p(0.73836, 0.31264))
        path.curve(to: p(0.72425, 0.28979), controlPoint1: p(0.73535, 0.30274), controlPoint2: p(0.73307, 0.29862))
        path.line(to: p(0.67757, 0.24312))
        path.curve(to: p(0.65967, 0.23051), controlPoint1: p(0.66875, 0.23429), controlPoint2: p(0.66463, 0.23201))
        path.close()
        fillColor.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(0.5)
        let underline = NSBezierPath()
        underline.move(to: p(0.86081, 0.80697))
        underline.curve(to: p(0.90081, 0.84697), controlPoint1: p(0.8829, 0.80697), controlPoint2: p(0.90081, 0.82488))
        underline.curve(to: p(0.86081, 0.88697), controlPoint1: p(0.90081, 0.86906), controlPoint2: p(0.8829, 0.88697))
        underline.line(to: p(0.43085, 0.88691))
        underline.line(to: p(0.51085, 0.80691))
        underline.line(to: p(0.86081, 0.80697))
        underline.close()
        fillColor.setFill()
        underline.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The "return" arrow.
    public static func drawHardLineBreak(frame: CGRect, fillColor: NSColor) {
        let f = normalized(frame)
        let (x, y, w, h) = (f.x, f.y, f.w, f.h)
        func p(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: x + w * px, y: y + h * py) }
        let path = NSBezierPath()
        path.move(to: p(0.46971, 0.17667))
        path.curve(to: p(0.82971, 0.47667), controlPoint1: p(0.66831, 0.17667), controlPoint2: p(0.82971, 0.27807))
        path.curve(to: p(0.46971, 0.77667), controlPoint1: p(0.82971, 0.67527), controlPoint2: p(0.66831, 0.77667))
        path.line(to: p(0.37186, 0.77667))
        path.line(to: p(0.46971, 0.91287))
        path.line(to: p(0.41931, 0.95667))
        path.line(to: p(0.17931, 0.74727))
        path.curve(to: p(0.17931, 0.68607), controlPoint1: p(0.15951, 0.73047), controlPoint2: p(0.15951, 0.70287))
        path.line(to: p(0.41931, 0.47667))
        path.line(to: p(0.46971, 0.52047))
        path.line(to: p(0.35072, 0.68607))
        path.line(to: p(0.46971, 0.68607))
        path.curve(to: p(0.73928, 0.48873), controlPoint1: p(0.59803, 0.68607), controlPoint2: p(0.73085, 0.61358))
        path.line(to: p(0.73971, 0.47607))
        path.curve(to: p(0.46971, 0.26607), controlPoint1: p(0.73971, 0.34407), controlPoint2: p(0.60231, 0.26607))
        path.line(to: p(0.34971, 0.26607))
        path.line(to: p(0.34971, 0.17667))
        path.line(to: p(0.46971, 0.17667))
        path.close()
        path.windingRule = .evenOdd
        fillColor.setFill()
        path.fill()
    }

    public static func drawArrowIcon(frame: CGRect, fillColor: NSColor) {
        let f = normalized(frame)
        let (x, y, w, h) = (f.x, f.y, f.w, f.h)
        func p(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: x + w * px, y: y + h * py) }
        let path = NSBezierPath()
        path.move(to: p(0.55113, 0.26215))
        path.line(to: p(0.8066, 0.51761))
        path.curve(to: p(0.8066, 0.59335), controlPoint1: p(0.8274, 0.53841), controlPoint2: p(0.8274, 0.57255))
        path.line(to: p(0.55113, 0.84881))
        path.line(to: p(0.4978, 0.79548))
        path.line(to: p(0.63912, 0.59881))
        path.line(to: p(0.17278, 0.59881))
        path.line(to: p(0.17278, 0.51215))
        path.line(to: p(0.63912, 0.51215))
        path.line(to: p(0.4978, 0.31548))
        path.line(to: p(0.55113, 0.26215))
        path.close()
        path.windingRule = .evenOdd
        fillColor.setFill()
        path.fill()
    }

    /// Marker pen glyph at 90% alpha.
    public static func drawHighlighter(frame: CGRect, fillColor: NSColor, accentColor: NSColor) {
        let x0 = floor(frame.width * 0.04987 - 0.25)
        let x = frame.minX + x0 + 0.75
        let y0 = floor(frame.height * 0.08835 + 0.17)
        let y = frame.minY + y0 + 0.33
        let w = (floor(frame.width * 0.97692 - 0.15) - x0) - 0.09
        let h = (floor(frame.height * 0.8977 + 0.03) - y0) + 0.14
        func p(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: x + w * px, y: y + h * py) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(0.9)
        let path = NSBezierPath()
        path.move(to: p(0.60701, 0.0042))
        path.curve(to: p(0.67051, 0.04201), controlPoint1: p(0.62952, 0.01032), controlPoint2: p(0.64744, 0.02105))
        path.line(to: p(0.75696, 0.12489))
        path.line(to: p(0.76449, 0.1323))
        path.curve(to: p(0.80862, 0.19797), controlPoint1: p(0.78689, 0.15495), controlPoint2: p(0.79935, 0.17342))
        path.curve(to: p(0.81797, 0.28278), controlPoint1: p(0.81875, 0.22483), controlPoint2: p(0.82195, 0.25386))
        path.curve(to: p(0.78937, 0.3593), controlPoint1: p(0.81433, 0.30927), controlPoint2: p(0.80624, 0.33078))
        path.line(to: p(0.78372, 0.36858))
        path.line(to: p(0.53031, 0.775))
        path.curve(to: p(0.49926, 0.80991), controlPoint1: p(0.51992, 0.79069), controlPoint2: p(0.51105, 0.80068))
        path.curve(to: p(0.45096, 0.83144), controlPoint1: p(0.48472, 0.8213), controlPoint2: p(0.4684, 0.82858))
        path.curve(to: p(0.40713, 0.82965), controlPoint1: p(0.43676, 0.83377), controlPoint2: p(0.42425, 0.83324))
        path.line(to: p(0.37885, 0.82288))
        path.line(to: p(0.26755, 0.92623))
        path.line(to: p(0.07427, 0.73761))
        path.line(to: p(0.14425, 0.59901))
        path.line(to: p(0.13347, 0.56629))
        path.curve(to: p(0.12568, 0.53324), controlPoint1: p(0.12949, 0.55396), controlPoint2: p(0.12708, 0.5439))
        path.line(to: p(0.12486, 0.52521))
        path.line(to: p(0.12447, 0.51683))
        path.line(to: p(0.12461, 0.50559))
        path.curve(to: p(0.1346, 0.45943), controlPoint1: p(0.12543, 0.48965), controlPoint2: p(0.12879, 0.47411))
        path.curve(to: p(0.15949, 0.41802), controlPoint1: p(0.14052, 0.44445), controlPoint2: p(0.14764, 0.43264))
        path.line(to: p(0.46478, 0.06174))
        path.line(to: p(0.47183, 0.05371))
        path.curve(to: p(0.53246, 0.00837), controlPoint1: p(0.49331, 0.02987), controlPoint2: p(0.51037, 0.01706))
        path.curve(to: p(0.60701, 0.0042), controlPoint1: p(0.55664, -0.00114), controlPoint2: p(0.58216, -0.00257))
        path.close()
        // inner cut-outs
        path.move(to: p(0.24014, 0.46966))
        path.line(to: p(0.22445, 0.48596))
        path.line(to: p(0.22147, 0.4897))
        path.curve(to: p(0.21704, 0.49612), controlPoint1: p(0.21947, 0.4923), controlPoint2: p(0.21807, 0.49435))
        path.line(to: p(0.21508, 0.50006))
        path.line(to: p(0.21365, 0.50421))
        path.curve(to: p(0.21243, 0.51431), controlPoint1: p(0.21273, 0.50745), controlPoint2: p(0.21233, 0.51075))
        path.curve(to: p(0.21347, 0.52243), controlPoint1: p(0.21252, 0.51739), controlPoint2: p(0.21282, 0.51968))
        path.line(to: p(0.21464, 0.52685))
        path.line(to: p(0.21825, 0.53784))
        path.line(to: p(0.23994, 0.59934))
        path.line(to: p(0.23909, 0.61368))
        path.line(to: p(0.18902, 0.71398))
        path.line(to: p(0.26863, 0.79265))
        path.line(to: p(0.35051, 0.71811))
        path.line(to: p(0.36266, 0.71494))
        path.line(to: p(0.41694, 0.72908))
        path.line(to: p(0.42645, 0.73116))
        path.line(to: p(0.4307, 0.7318))
        path.curve(to: p(0.43856, 0.73165), controlPoint1: p(0.43371, 0.73214), controlPoint2: p(0.43586, 0.73209))
        path.curve(to: p(0.44964, 0.72671), controlPoint1: p(0.44264, 0.73098), controlPoint2: p(0.44623, 0.72938))
        path.curve(to: p(0.45736, 0.71832), controlPoint1: p(0.45233, 0.7246), controlPoint2: p(0.45444, 0.72238))
        path.line(to: p(0.46387, 0.7084))
        path.line(to: p(0.47305, 0.69352))
        path.line(to: p(0.24014, 0.46966))
        path.close()
        path.move(to: p(0.55697, 0.10908))
        path.curve(to: p(0.52922, 0.1312), controlPoint1: p(0.54799, 0.11253), controlPoint2: p(0.54141, 0.11764))
        path.line(to: p(0.30256, 0.39482))
        path.line(to: p(0.52272, 0.60944))
        path.line(to: p(0.70863, 0.31485))
        path.line(to: p(0.71261, 0.30831))
        path.line(to: p(0.55697, 0.10908))
        path.close()
        path.windingRule = .evenOdd
        fillColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        _ = accentColor
    }

    public static func imageOfLinkIcon(size: CGSize, fillColor: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in drawLinkIcon(frame: rect, fillColor: fillColor); return true }
    }
    public static func imageOfHardLineBreak(size: CGSize, fillColor: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in drawHardLineBreak(frame: rect, fillColor: fillColor); return true }
    }
    public static func imageOfArrowIcon(size: CGSize, fillColor: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in drawArrowIcon(frame: rect, fillColor: fillColor); return true }
    }
    public static func imageOfHighlighter(size: CGSize, fillColor: NSColor, accentColor: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in drawHighlighter(frame: rect, fillColor: fillColor, accentColor: accentColor); return true }
    }
}

public extension NSBezierPath {
    /// A continuous-corner rounded rect.
    static func squircle(in rect: CGRect, cornerRadius: CGFloat) -> NSBezierPath {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        let k: CGFloat = 1.2 // smoothing: control points pushed past the arc for the "squircle" look
        let c = r * k
        path.move(to: NSPoint(x: rect.minX + c, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - c, y: rect.minY))
        path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + c), controlPoint1: NSPoint(x: rect.maxX - c * 0.45, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + c * 0.45))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - c))
        path.curve(to: NSPoint(x: rect.maxX - c, y: rect.maxY), controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - c * 0.45), controlPoint2: NSPoint(x: rect.maxX - c * 0.45, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + c, y: rect.maxY))
        path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - c), controlPoint1: NSPoint(x: rect.minX + c * 0.45, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - c * 0.45))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + c))
        path.curve(to: NSPoint(x: rect.minX + c, y: rect.minY), controlPoint1: NSPoint(x: rect.minX, y: rect.minY + c * 0.45), controlPoint2: NSPoint(x: rect.minX + c * 0.45, y: rect.minY))
        path.close()
        return path
    }

    func rotateFromCenter(byDegrees degrees: CGFloat) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let t = AffineTransform(translationByX: center.x, byY: center.y)
        var rotated = AffineTransform(rotationByDegrees: degrees)
        rotated.append(t)
        var back = AffineTransform(translationByX: -center.x, byY: -center.y)
        back.append(rotated)
        transform(using: back)
    }
}
