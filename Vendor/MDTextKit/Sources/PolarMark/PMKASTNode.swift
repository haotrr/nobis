import Foundation

public enum PMKNodeType: String {
    case document
    case paragraph
    case heading
    case thematicBreak
    case fencedCode
    case blockquote
    case list
    case listItem
    // inline
    case strong, emphasis, strikethrough, underline, highlighter, code
    case link, image, hashtag, autolink, escape, hardLineBreak
    case table, tableRow, tableCell   // table / rows / cells; row 1 is the delimiter row
    case calloutHead     // `[!NOTE]`-style first line of a blockquote; level = callout type 0…4
    case foldMarker      // the `<!-- {"fold":true} -->` comment ending a foldable head line
}

/// `PMKASTNode` (ObjC facade over `Ice::Node`).
/// Ranges are UTF-16 offsets into the markdown string, so they can be used
/// directly as `NSRange` on the text storage.
public final class PMKASTNode {
    public let type: PMKNodeType
    public internal(set) var range: NSRange
    public internal(set) var markerRanges: [NSRange] = []
    public internal(set) var children: [PMKASTNode] = []
    public internal(set) weak var parent: PMKASTNode?

    // Type-specific payload
    public internal(set) var level: Int = 0            // heading level / list level / blockquote depth
    public internal(set) var ordered: Bool = false
    public internal(set) var number: Int = 0
    public internal(set) var task: PMKTaskState = .notTask
    public internal(set) var language: String = ""     // fenced code
    public internal(set) var url: String = ""          // link / image / autolink
    public internal(set) var label: String = ""        // hashtag name / link label
    public internal(set) var contentRange: NSRange = NSRange(location: 0, length: 0) // text without markers
    public internal(set) var closed: Bool = true       // fenced code has closing fence
    public internal(set) var indentRange: NSRange?     // list item: whitespace before the marker
    public internal(set) var calloutType: Int = -1      // blockquote: 0 NOTE, 1 TIP, 2 IMPORTANT, 3 WARNING, 4 CAUTION, -1 none

    init(type: PMKNodeType, range: NSRange) {
        self.type = type
        self.range = range
    }

    func add(_ child: PMKASTNode) {
        child.parent = self
        children.append(child)
    }

    /// Moves the subtree by `delta` code units, for blocks an edit above them left untouched.
    func shift(by delta: Int) {
        range.location += delta
        for i in markerRanges.indices { markerRanges[i].location += delta }
        contentRange.location += delta
        if indentRange != nil { indentRange!.location += delta }
        for c in children { c.shift(by: delta) }
    }

    public var firstChild: PMKASTNode? { children.first }
    public var lastChild: PMKASTNode? { children.last }

    public var nextSibling: PMKASTNode? {
        guard let p = parent, let i = p.children.firstIndex(where: { $0 === self }) else { return nil }
        return i + 1 < p.children.count ? p.children[i + 1] : nil
    }

    public var previousSibling: PMKASTNode? {
        guard let p = parent, let i = p.children.firstIndex(where: { $0 === self }), i > 0 else { return nil }
        return p.children[i - 1]
    }

    public var typeAsString: String { type.rawValue }

    /// Depth-first enumeration.
    public func walk(_ body: (PMKASTNode) -> Void) {
        body(self)
        for c in children { c.walk(body) }
    }

    /// Stable signature used by the incremental reparse diff (type + payload + ranges relative to node start).
    func signature(relativeTo origin: Int) -> String {
        var s = "\(type.rawValue)|\(range.location - origin),\(range.length)|\(level)|\(ordered)|\(number)|\(task.rawValue)|\(language)|\(url)|\(label)|\(closed)"
        for m in markerRanges { s += "|m\(m.location - origin),\(m.length)" }
        for c in children { s += "{" + c.signature(relativeTo: origin) + "}" }
        return s
    }

    public var description: String {
        var out = ""
        func dump(_ n: PMKASTNode, _ indent: Int) {
            out += String(repeating: "  ", count: indent) + "\(n.type.rawValue) \(NSStringFromRange(n.range))"
            if n.level > 0 { out += " level=\(n.level)" }
            if n.type == .list || n.type == .listItem { out += n.ordered ? " ordered" : " bullet"; if n.task != .notTask { out += " task=\(n.task)" } }
            if !n.language.isEmpty { out += " lang=\(n.language)" }
            if !n.url.isEmpty { out += " url=\(n.url)" }
            out += "\n"
            for c in n.children { dump(c, indent + 1) }
        }
        dump(self, 0)
        return out
    }
}
