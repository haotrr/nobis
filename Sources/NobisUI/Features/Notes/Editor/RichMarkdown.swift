import Foundation
#if os(macOS)
import AppKit
typealias EditorFont = NSFont
private typealias EditorColor = NSColor
#else
import UIKit
typealias EditorFont = UIFont
private typealias EditorColor = UIColor
#endif

/// Paragraph metadata preserves Markdown structure while the native text view edits visible text.
enum NoteTypography {
    #if os(macOS)
    static let bodySize: CGFloat = 14
    static let codeSize: CGFloat = 13
    #else
    static let bodySize: CGFloat = 15
    static let codeSize: CGFloat = 14
    #endif
    static func headingSize(_ level: Int) -> CGFloat { bodySize + [6, 4, 2, 1, 0, 0][min(5, max(0, level - 1))] }
    static var codeFont: EditorFont {
        let font = EditorFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        #if os(macOS)
        return font
        #else
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
        #endif
    }
}

struct RichEditRequest: Equatable { let id = UUID(); let action: String }
enum RichMarkdown {
    static func applying(_ action: String, to source: NSAttributedString, selection: NSRange) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: source)
        if action.hasPrefix("link:"), selection.length > 0 {
            let link = String(action.dropFirst(5))
            if link.isEmpty { value.removeAttribute(.link, range: selection) }
            else { value.addAttribute(.link, value: link, range: selection) }
        } else if ["bold", "italic"].contains(action), selection.length > 0 {
            let key = action == "bold" ? bold : italic
            if value.attribute(key, at: selection.location, effectiveRange: nil) == nil { value.addAttribute(key, value: true, range: selection) }
            else { value.removeAttribute(key, range: selection) }
            value.enumerateAttributes(in: selection) { attrs, range, _ in value.addAttribute(.font, value: font(bold: attrs[bold] != nil, italic: attrs[italic] != nil), range: range) }
        } else if ["heading", "body", "checklist", "toggle", "list"].contains(action) {
            let range = (value.string as NSString).paragraphRange(for: selection)
            let raw = value.attributedSubstring(from: range)
            var markdown = encode(raw)
            if action == "toggle" {
                markdown = markdown.replacingOccurrences(of: "- [ ] ", with: "- [X] ").replacingOccurrences(of: "- [x] ", with: "- [ ] ").replacingOccurrences(of: "- [X] ", with: "- [x] ")
            } else {
                markdown = markdown.components(separatedBy: "\n").enumerated().map { index, line in
                    if line.isEmpty && index > 0 { return line }
                    let text = line.replacingOccurrences(of: #"^(#{1,6} |\s*(?:[-*+]|\d+[.)]) \[[ xX]\] |\s*[-*+] |\s*\d+[.)] |> )"#, with: "", options: .regularExpression)
                    return (action == "heading" ? "## " : action == "checklist" ? "- [ ] " : action == "list" ? "- " : "") + text
                }.joined(separator: "\n")
            }
            value.replaceCharacters(in: range, with: decode(markdown))
        }
        return value
    }

    static let prefix = NSAttributedString.Key("NobisMarkdownPrefix")
    static let bold = NSAttributedString.Key("NobisMarkdownBold")
    static let inlineCode = NSAttributedString.Key("NobisMarkdownInlineCode")
    static let italic = NSAttributedString.Key("NobisMarkdownItalic")
    static func font(_ size: CGFloat = NoteTypography.bodySize, bold: Bool = false, italic: Bool = false) -> EditorFont {
        let base = EditorFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        #if os(macOS)
        return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        #else
        let styled = italic ? EditorFont(descriptor: base.fontDescriptor.withSymbolicTraits([.traitItalic, bold ? .traitBold : []]) ?? base.fontDescriptor, size: size) : base
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: styled)
        #endif
    }
    static var base: [NSAttributedString.Key: Any] { [.font: font(), .foregroundColor: EditorColor.labelColorCompatible] }
    static func decode(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var fenced = false
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var content = line, marker = "", visible = ""
            if line.hasPrefix("```") { fenced.toggle() }
            else if !fenced, let range = line.range(of: #"^(#{1,6} |\s*(?:[-*+]|\d+[.)]) \[[ xX]\] |\s*[-*+] |\s*\d+[.)] |> )"#, options: .regularExpression) {
                marker = String(line[range]); content = String(line[range.upperBound...])
                if marker.contains("[ ]") { visible = "☐ " }
                else if marker.contains("[x]") || marker.contains("[X]") { visible = "☑ " }
                else if !marker.hasPrefix("#") && marker != "> " { visible = marker.range(of: #"\d"#, options: .regularExpression) == nil ? "• " : marker }
            }
            var attributes = base
            attributes[prefix] = marker
            if marker.hasPrefix("#") { attributes[.font] = font(NoteTypography.headingSize(marker.count - 1), bold: true) }
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 5
            paragraph.lineSpacing = 2
            if marker == "> " { paragraph.headIndent = 18; paragraph.firstLineHeadIndent = 18 }
            attributes[.paragraphStyle] = paragraph
            let part = NSMutableAttributedString(string: visible + content + (index < lines.count - 1 ? "\n" : ""), attributes: attributes)
            if !fenced && !line.hasPrefix("```") {
                let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
                for match in codeRegex.matches(in: part.string, range: NSRange(location: 0, length: part.length)).reversed() {
                    let value = part.attributedSubstring(from: match.range(at: 1))
                    part.replaceCharacters(in: match.range, with: value)
                    let range = NSRange(location: match.range.location, length: value.length)
                    part.addAttributes([inlineCode: true, .font: NoteTypography.codeFont], range: range)
                }
                for (pattern, key) in [(#"\*\*([^*\n]+)\*\*"#, bold), (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, italic)] {
                    let regex = try! NSRegularExpression(pattern: pattern)
                    for match in regex.matches(in: part.string, range: NSRange(location: 0, length: part.length)).reversed() {
                        guard part.attribute(inlineCode, at: match.range.location, effectiveRange: nil) == nil else { continue }
                        let value = part.attributedSubstring(from: match.range(at: 1))
                        part.replaceCharacters(in: match.range, with: value)
                        part.addAttribute(key, value: true, range: NSRange(location: match.range.location, length: value.length))
                    }
                }
                let regex = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#)
                for match in regex.matches(in: part.string, range: NSRange(location: 0, length: part.length)).reversed() {
                    guard part.attribute(inlineCode, at: match.range.location, effectiveRange: nil) == nil else { continue }
                    let label = part.attributedSubstring(from: match.range(at: 1)), url = (part.string as NSString).substring(with: match.range(at: 2))
                    part.replaceCharacters(in: match.range, with: label)
                    part.addAttribute(.link, value: url, range: NSRange(location: match.range.location, length: label.length))
                }
                part.enumerateAttributes(in: NSRange(location: 0, length: part.length)) { attrs, range, _ in
                    if attrs[bold] != nil || attrs[italic] != nil { part.addAttribute(.font, value: font(bold: attrs[bold] != nil, italic: attrs[italic] != nil), range: range) }
                }
            }
            result.append(part)
        }
        return result
    }
    static func encode(_ value: NSAttributedString) -> String {
        let string = value.string as NSString
        var offset = 0, lines: [String] = []
        for line in value.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            var marker = offset < value.length ? value.attribute(prefix, at: offset, effectiveRange: nil) as? String ?? "" : ""
            var skip = 0
            if line.hasPrefix("☐ ") || line.hasPrefix("☑ ") {
                let box = line.hasPrefix("☑") ? "[x]" : "[ ]"
                if marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil { marker = marker.replacingOccurrences(of: #"\[[ xX]\]"#, with: box, options: .regularExpression) }
                else { marker = "- " + box + " " }
                skip = 2
            } else if line.hasPrefix("• ") { skip = 2; if marker.isEmpty { marker = "- " } }
            else if marker.contains("[") || marker.contains("- ") { marker = "" }
            else if !marker.isEmpty && line.hasPrefix(marker) { skip = (marker as NSString).length }
            var rendered = ""
            value.enumerateAttributes(in: NSRange(location: offset + skip, length: max(0, length - skip))) { attrs, range, _ in
                var piece = string.substring(with: range)
                if attrs[inlineCode] != nil { piece = "`" + piece + "`" }
                if attrs[italic] != nil { piece = "*" + piece + "*" }
                if attrs[bold] != nil { piece = "**" + piece + "**" }
                if let link = attrs[.link] { piece = "[" + piece + "](\(link))" }
                rendered += piece
            }
            lines.append(marker + rendered); offset += length + 1
        }
        return lines.joined(separator: "\n")
    }
}
private extension EditorColor {
    static var labelColorCompatible: EditorColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }
}
