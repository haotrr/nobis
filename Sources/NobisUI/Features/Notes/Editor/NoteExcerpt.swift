import Foundation

/// Remove image destinations before truncating; a truncated data URL is no longer Markdown.
enum NoteExcerpt {
    static func hidingImageAddresses(in source: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"!\[((?:\\.|[^\]])*)\]\([^()]*+(?:\([^()]*+\)[^()]*+)*\)"#) else { return source }
        // ICU can stop matching very large payloads. Strip those with a linear scan first.
        let compact = NSMutableString(string: source)
        let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var offset = 0
        while offset < compact.length {
            let start = compact.range(of: "data:image/", range: NSRange(location: offset, length: compact.length - offset))
            guard start.location != NSNotFound else { break }
            let marker = compact.range(of: ";base64,", range: NSRange(location: start.location, length: compact.length - start.location))
            guard marker.location != NSNotFound else { break }
            let body = NSMaxRange(marker)
            let stop = compact.rangeOfCharacter(from: base64.inverted, range: NSRange(location: body, length: compact.length - body))
            let end = stop.location == NSNotFound ? compact.length : stop.location
            compact.replaceCharacters(in: NSRange(location: start.location, length: end - start.location), with: "embedded-image")
            offset = start.location + "embedded-image".utf16.count
        }
        let text = NSString(string: compact)
        let result = NSMutableString(string: text as String)
        for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).reversed() {
            let alt = text.substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: alt.isEmpty ? "图片" : alt)
        }
        return result as String
    }
}
