import Foundation

/// UTF-16 ranges match AppKit/UIKit selections, including emoji and Chinese text.
public enum MarkdownFormat: String, CaseIterable, Sendable {
    case bold, italic, link
    public var title: String { switch self { case .bold: "粗体"; case .italic: "斜体"; case .link: "插入链接" } }
    public var key: String { switch self { case .bold: "b"; case .italic: "i"; case .link: "k" } }
}
public struct MarkdownEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange
    public static func format(_ format: MarkdownFormat, text: String, selection: NSRange) -> Self? {
        let units = Array(text.utf16)
        guard selection.location <= units.count, selection.length <= units.count - selection.location,
              Range(selection, in: text) != nil else { return nil }
        for offset in [selection.location, NSMaxRange(selection)] where offset > 0 && offset < units.count {
            if (0xD800...0xDBFF).contains(units[offset - 1]), (0xDC00...0xDFFF).contains(units[offset]) { return nil }
        }
        let source = text as NSString, selected = source.substring(with: selection)
        if format == .link {
            let label = selected.isEmpty ? "文字" : selected
            return Self(range: selection, replacement: "[\(label)](https://)", selection: NSRange(location: selection.location + (label as NSString).length + 3, length: 8))
        }
        let marker = format == .bold ? "**" : "*", count = marker.utf16.count
        let before = source.substring(to: selection.location).reversed().prefix { $0 == "*" }.count
        let after = source.substring(from: NSMaxRange(selection)).prefix { $0 == "*" }.count
        let canRemove = format == .bold ? before >= 2 && after >= 2 : before % 2 == 1 && after % 2 == 1
        // Repeating the command with the inner text still selected removes its markers.
        if canRemove, selection.location >= count, NSMaxRange(selection) + count <= source.length,
           source.substring(with: NSRange(location: selection.location - count, length: count)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(selection), length: count)) == marker {
            return Self(range: NSRange(location: selection.location - count, length: selection.length + count * 2), replacement: selected, selection: NSRange(location: selection.location - count, length: selection.length))
        }
        return Self(range: selection, replacement: marker + selected + marker, selection: NSRange(location: selection.location + count, length: selection.length))
    }
}
