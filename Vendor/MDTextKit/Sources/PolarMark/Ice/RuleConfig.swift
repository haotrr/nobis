import Foundation

/// `Ice::RuleConfig` / `Ice::RuleMap`. Lets callers disable rules
/// (`-[PMKAST disableRule:]`, `+[PMKAST setUsesSimplifiedRuleSet:]`).
public struct RuleConfig: Equatable, Sendable {
    public var strong = true
    public var emphasis = true
    public var strikethrough = true
    public var underline = true
    public var highlighter = true
    public var code = true
    public var links = true
    public var images = true
    public var hashtags = false   // tag support disabled by request
    public var autolinks = true
    public var escapes = true
    public var hardLineBreaks = true

    public init() {}

    public static let standard = RuleConfig()

    /// The "simplified rule set" (used for titles / previews): inline only, no tags.
    public static var simplified: RuleConfig {
        var r = RuleConfig()
        r.hashtags = false
        r.images = false
        return r
    }

    public mutating func disable(_ name: String) {
        switch name.lowercased() {
        case "strong": strong = false
        case "emphasis": emphasis = false
        case "strikethrough": strikethrough = false
        case "underline": underline = false
        case "highlighter": highlighter = false
        case "code": code = false
        case "links", "link": links = false
        case "images", "image": images = false
        case "hashtags", "hashtag": hashtags = false
        case "autolinks", "autolink": autolinks = false
        case "escapes", "escape": escapes = false
        case "hardlinebreaks": hardLineBreaks = false
        default: break
        }
    }
}
