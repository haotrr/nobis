import AppKit
import MDTextKit
import PolarMark
import UniformTypeIdentifiers

/// Keyed archive of the
/// attributed substring including attachments.
public extension NSAttributedString {
    func dataFromPolarRepresentation() -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
    }
    func containsFileBackedAttachments(in range: NSRange) -> Bool {
        var found = false
        enumerateAttribute(.attachment, in: range, options: []) { v, _, stop in if v is SFTextAttachmentFileBackedView { found = true; stop.pointee = true } }
        return found
    }
}

public extension NSMutableAttributedString {
    static func attributedString(fromPolarData data: Data) -> NSMutableAttributedString? {
        let classes: [AnyClass] = [NSAttributedString.self, NSMutableAttributedString.self, SFTextAttachment.self, PMKListInfo.self, NSValue.self, FileWrapper.self, NSDate.self, NSImage.self, SFTextAttachmentCell.self]
        if let a = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString {
            return NSMutableAttributedString(attributedString: a)
        }
        // NSAttributedString decodes attribute values securely only for its own classes, not PMKListInfo.
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        guard let a = unarchiver.decodeObject(of: classes, forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString else { return nil }
        return NSMutableAttributedString(attributedString: a)
    }
}

/// `MDRTFImporter` (rich text → markdown) and the reverse direction used for RTFD copies. The importer walks
/// font traits, underline/strikethrough, links, text lists and heading-sized fonts.
public enum MDRTFImporter {
    public static func markdown(from rich: NSAttributedString) -> String {
        let ns = rich.string as NSString
        var out = ""
        var paragraphStart = 0
        let bodySize: CGFloat = {
            var sizes: [CGFloat] = []
            rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length), options: []) { v, _, _ in if let f = v as? NSFont { sizes.append(f.pointSize) } }
            return sizes.min() ?? 13
        }()
        while paragraphStart < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: paragraphStart, length: 0))
            let text = ns.substring(with: pr)
            let attrs = rich.attributes(at: pr.location, effectiveRange: nil)
            var prefix = ""
            if let ps = attrs[.paragraphStyle] as? NSParagraphStyle, let list = ps.textLists.last {
                prefix = list.markerFormat.rawValue.contains("decimal") ? "1. " : "- "
                prefix = String(repeating: "\t", count: max(0, ps.textLists.count - 1)) + prefix
            } else if let f = attrs[.font] as? NSFont, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 {
                let ratio = f.pointSize / bodySize
                if ratio >= 1.9 { prefix = "# " } else if ratio >= 1.45 { prefix = "## " } else if ratio >= 1.2 { prefix = "### " }
            }
            var line = ""
            rich.enumerateAttributes(in: pr, options: []) { a, r, _ in
                var piece = ns.substring(with: r)
                if piece.hasSuffix("\n") { piece.removeLast() }
                if let att = a[.attachment] as? SFTextAttachment { piece = att.representedText }
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { line += piece; return }
                let lead = String(piece.prefix(while: { $0 == " " })), trail = String(piece.reversed().prefix(while: { $0 == " " }))
                var core = trimmed
                if let f = a[.font] as? NSFont {
                    let traits = f.fontDescriptor.symbolicTraits
                    if traits.contains(.monoSpace) { core = "`" + core + "`" }
                    if traits.contains(.bold), prefix.isEmpty || !prefix.hasPrefix("#") { core = "**" + core + "**" }
                    if traits.contains(.italic) { core = "*" + core + "*" }
                }
                if (a[.underlineStyle] as? Int ?? 0) != 0, a[.link] == nil { core = "~" + core + "~" }
                if (a[.strikethroughStyle] as? Int ?? 0) != 0 { core = "~~" + core + "~~" }
                if let link = a[.link] { let u = (link as? URL)?.absoluteString ?? (link as? String) ?? ""; if !u.isEmpty { core = "[" + core + "](" + u + ")" } }
                line += lead + core + trail
            }
            out += prefix + line + (text.hasSuffix("\n") ? "\n" : "")
            paragraphStart = NSMaxRange(pr)
        }
        return out
    }

    /// Rich text for an RTFD copy: the styled editor text with attachments replaced by their markdown source.
    public static func richText(fromStyled styled: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: styled)
        m.enumerateAttribute(.attachment, in: NSRange(location: 0, length: m.length), options: [.reverse]) { v, r, _ in
            if let a = v as? SFTextAttachment {
                var attrs = m.attributes(at: r.location, effectiveRange: nil); attrs[.attachment] = nil
                m.replaceCharacters(in: r, with: NSAttributedString(string: a.representedText, attributes: attrs))
            }
        }
        for key in [NSAttributedString.Key.mdSpacer, .mdOriginalAttributes] { m.removeAttribute(key, range: NSRange(location: 0, length: m.length)) }
        return m
    }
}

/// Which pasteboard content wins and how it becomes markdown.
@MainActor public final class MDPasteboardReader {
    public var pasteDestinationInsideCode = false
    public weak var markdownRenderer: MDAttributedStringRenderer?
    public var readURLsBlock: (([URL]) -> Void)?
    public var readFilesBlock: (([URL]) -> Void)?
    public var readAttributedStringBlock: ((NSAttributedString) -> Void)?

    public init() {}

    public func read(from pb: NSPasteboard, withAttachments: Bool) -> Bool {
        let types = pb.types ?? []
        // 1. the editor's own archived attributed string
        if let data = pb.data(forType: MDTextView.attributedStringPboardType), let a = NSMutableAttributedString.attributedString(fromPolarData: data) {
            if !withAttachments {
                a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length), options: [.reverse]) { v, r, _ in if v is SFTextAttachmentFileBackedView { a.replaceCharacters(in: r, with: "") } }
            }
            readAttributedStringBlock?(a)
            return true
        }
        // 2. HTML only when there is no RTF; 3. RTF(D)
        let hasRTF = types.contains(.rtfd) || types.contains(.rtf)
        if !hasRTF, let a = rtfAttributedString(fromHTML: pb) { readAttributedStringBlock?(a); return true }
        if let a = rtfAttributedString(from: pb) { readAttributedStringBlock?(a); return true }
        // 4. files, images, PDFs
        if withAttachments {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let first = urls.first, (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                readFilesBlock?(urls); return true
            }
            if let pdf = pb.data(forType: .pdf), let url = temporaryFile(named: "document.pdf", data: pdf) { readFilesBlock?([url]); return true }
            if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [.compressionFactor: 1.0]), let url = temporaryFile(named: "image.png", data: png) {
                readFilesBlock?([url]); return true
            }
        }
        // 5. URLs
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .newlines), !s.contains("\n"), let url = URL(string: s), s.lowercased().hasPrefix("http") {
            readURLsBlock?([url]); return true
        }
        return false
    }

    private func rtfAttributedString(fromHTML pb: NSPasteboard) -> NSAttributedString? {
        guard let html = pb.string(forType: .html) else { return nil }
        if pb.availableType(from: [.tiff, .html]) == .tiff { return nil }
        guard let data = html.data(using: .utf8), let a = NSMutableAttributedString(html: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return nil }
        return convert(a)
    }

    private func rtfAttributedString(from pb: NSPasteboard) -> NSAttributedString? {
        var rich: NSAttributedString?
        if let d = pb.data(forType: .rtfd) { rich = NSAttributedString(rtfd: d, documentAttributes: nil) }
        if rich == nil, let d = pb.data(forType: .rtf) { rich = NSAttributedString(rtf: d, documentAttributes: nil) }
        guard let r = rich else { return nil }
        if pasteDestinationInsideCode { return NSAttributedString(string: r.string.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")) }
        return convert(r)
    }

    private func convert(_ rich: NSAttributedString) -> NSAttributedString {
        if pasteDestinationInsideCode { return NSAttributedString(string: rich.string) }
        let md = MDRTFImporter.markdown(from: rich)
        return markdownRenderer?.styledAttributedString(fromString: md) ?? NSAttributedString(string: md)
    }

    private func temporaryFile(named name: String, data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
