import AppKit

/// A JSON document where string values may reference other
/// values with `$a.b.c` (keys may contain spaces). A colour value is a hex string or an `NSColor`,
/// so a host can hand in dynamic colours that follow the appearance.
@MainActor
public final class SFTheme {
    public let name: String
    public private(set) var root: [String: Any]
    private var cache: [String: Any] = [:]

    public init(name: String, jsonObject: [String: Any]) {
        self.name = name
        self.root = jsonObject
    }

    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SFThemeKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Theme root is not an object"])
        }
        self.init(name: url.deletingPathExtension().lastPathComponent, jsonObject: obj)
    }

    /// Raw lookup of a dotted key path (keys may contain spaces).
    private func rawValue(forKeyPath path: String) -> Any? {
        var cur: Any = root
        for key in path.split(separator: ".").map(String.init) {
            guard let dict = cur as? [String: Any], let next = dict[key] else { return nil }
            cur = next
        }
        return cur
    }

    /// `-[SFTheme themeValueForKeyPath:]` with `$ref` resolution.
    public func value(forKeyPath path: String) -> Any? {
        if let c = cache[path] { return c }
        var seen: Set<String> = []
        var p = path
        while true {
            guard !seen.contains(p) else { return nil }
            seen.insert(p)
            guard let v = rawValue(forKeyPath: p) else { return nil }
            if let s = v as? String, s.hasPrefix("$") {
                p = String(s.dropFirst())
                continue
            }
            cache[path] = v
            return v
        }
    }

    public func string(forKeyPath path: String) -> String? { value(forKeyPath: path) as? String }
    public func number(forKeyPath path: String) -> CGFloat? {
        if let n = value(forKeyPath: path) as? NSNumber { return CGFloat(n.doubleValue) }
        if let s = value(forKeyPath: path) as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }
    public func bool(forKeyPath path: String) -> Bool? {
        if let n = value(forKeyPath: path) as? NSNumber { return n.boolValue }
        return nil
    }

    /// `SFColorHexValueTransformer`. Accepts #RGB, #RRGGBB, #RRGGBBAA.
    public static func color(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            let r = CGFloat((v >> 8) & 0xF) / 15, g = CGFloat((v >> 4) & 0xF) / 15, b = CGFloat(v & 0xF) / 15
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 6:
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        case 8:
            return NSColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255, blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        default: return nil
        }
    }

    public func color(forKeyPath path: String) -> NSColor? {
        switch value(forKeyPath: path) {
        case let c as NSColor: return c
        case let s as String: return SFTheme.color(fromHex: s)
        default: return nil
        }
    }
}
