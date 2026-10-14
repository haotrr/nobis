import AppKit

/// Objects that re-style themselves when the theme changes
/// (`-[SFThemeManager registerStylableObject:]` / `styleObjectWithThemeManager:`).
@MainActor
public protocol SFStylable: AnyObject {
    func styleObject(with themeManager: SFThemeManager)
}

/// `SFThemeManager`. Holds the current theme, caches typed lookups and
/// pushes theme changes to registered objects. The host owns the instance; there is no shared one.
@MainActor
public final class SFThemeManager {
    public static let themeDidChangeNotification = Notification.Name("SFThemeManagerThemeDidChange")

    public private(set) var currentTheme: SFTheme
    /// User typography settings override theme values such as
    /// "editor.text size", "editor.text font", "editor.line height multiplier", "editor.line width multiplier".
    /// A colour override is an `NSColor` or a hex string.
    public var overrides: [String: Any] = [:] {
        didSet { fontCache.removeAll(); styleRegisteredStylableObjects() }
    }
    private var stylables = NSHashTable<AnyObject>.weakObjects()
    private var fontCache: [String: NSFont] = [:]

    public init(theme: SFTheme) {
        SFFontLoader.registerFontsFromEnvironment()
        currentTheme = theme
    }

    // MARK: Loading

    public func loadTheme(_ theme: SFTheme, updateStylableObjects: Bool = true) {
        currentTheme = theme
        fontCache.removeAll()
        if updateStylableObjects { styleRegisteredStylableObjects() }
        NotificationCenter.default.post(name: SFThemeManager.themeDidChangeNotification, object: self)
    }

    public func registerStylableObject(_ object: SFStylable) {
        stylables.add(object)
        object.styleObject(with: self)
    }

    public func unregisterStylableObject(_ object: SFStylable) { stylables.remove(object) }

    public func styleRegisteredStylableObjects() {
        for o in stylables.allObjects { (o as? SFStylable)?.styleObject(with: self) }
    }

    // MARK: Typed lookups

    public func color(forKey key: String, default fallback: NSColor = .textColor) -> NSColor {
        if let c = overrides[key] as? NSColor { return c }
        if let s = overrides[key] as? String, let c = SFTheme.color(fromHex: s) { return c }
        return currentTheme.color(forKeyPath: key) ?? fallback
    }

    public func number(forKey key: String, default fallback: CGFloat) -> CGFloat {
        if let n = overrides[key] as? NSNumber { return CGFloat(n.doubleValue) }
        if let d = overrides[key] as? Double { return CGFloat(d) }
        return currentTheme.number(forKeyPath: key) ?? fallback
    }

    public func bool(forKey key: String, default fallback: Bool) -> Bool {
        if let b = overrides[key] as? Bool { return b }
        return currentTheme.bool(forKeyPath: key) ?? fallback
    }

    public func string(forKey key: String) -> String? { (overrides[key] as? String) ?? currentTheme.string(forKeyPath: key) }

    /// Font names: "system", "system-rounded", "system-serif", "system-mono" or a PostScript name.
    /// A `"<key> cjk"` value names a family that joins the font's cascade list.
    public func font(forKey key: String, size: CGFloat) -> NSFont {
        let name = string(forKey: key) ?? "system"
        let cjk = string(forKey: key + " cjk")
        let cacheKey = "\(name)@\(size)/\(cjk ?? "")"
        if let f = fontCache[cacheKey] { return f }
        var font: NSFont
        switch name {
        case "system", "": font = NSFont.systemFont(ofSize: size)
        case "system-bold": font = NSFont.boldSystemFont(ofSize: size)
        case "system-semibold": font = NSFont.systemFont(ofSize: size, weight: .semibold)
        case "system-rounded": font = NSFont.systemFont(ofSize: size).withDesign(.rounded)
        case "system-serif": font = NSFont.systemFont(ofSize: size).withDesign(.serif)
        case "system-mono": font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default: font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        }
        if let cjk, !cjk.isEmpty { font = font.withCascade(family: cjk) }
        fontCache[cacheKey] = font
        return font
    }
}

public extension NSFont {
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
        guard let d = fontDescriptor.withDesign(design) else { return self }
        return NSFont(descriptor: d, size: pointSize) ?? self
    }

    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: pointSize) ?? self
    }

    /// Adds `family` to the cascade list, with its bold face when this font is bold.
    func withCascade(family: String) -> NSFont {
        var fallback = NSFontDescriptor(fontAttributes: [.family: family])
        if isBold { fallback = fallback.withSymbolicTraits(.bold) }
        let d = fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }

    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}
