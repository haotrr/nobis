import Foundation

// The parser engine lives in an `Ice::`-style namespace
// (Ice::Lines, Ice::BlockParser, Ice::InlineParser, Ice::RuleMap...).
// This folder mirrors that split in Swift. Everything works on UTF-16 code
// units so that offsets are NSRange-compatible without conversion.

struct Line {
    let index: Int
    let start: Int        // offset of first code unit
    let end: Int          // offset of the "\n" (or text end); the line content is [start, end)
    let nextStart: Int    // start of the following line (end + 1 if a newline exists)
}

enum Lines {
    static func split(_ text: [UInt16]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var i = 0
        let n = text.count
        while i < n {
            if text[i] == 0x0A { // "\n"
                lines.append(Line(index: lines.count, start: start, end: i, nextStart: i + 1))
                start = i + 1
            }
            i += 1
        }
        lines.append(Line(index: lines.count, start: start, end: n, nextStart: n))
        return lines
    }
}

extension Array where Element == UInt16 {
    @inline(__always) func at(_ i: Int) -> UInt16? { i >= 0 && i < count ? self[i] : nil }
}

enum CU { // code units
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let newline: UInt16 = 0x0A
    static let hash: UInt16 = 0x23        // #
    static let gt: UInt16 = 0x3E          // >
    static let dash: UInt16 = 0x2D        // -
    static let plus: UInt16 = 0x2B        // +
    static let star: UInt16 = 0x2A        // *
    static let underscore: UInt16 = 0x5F  // _
    static let tilde: UInt16 = 0x7E       // ~
    static let equal: UInt16 = 0x3D       // =
    static let backtick: UInt16 = 0x60    // `
    static let backslash: UInt16 = 0x5C   // \
    static let lbracket: UInt16 = 0x5B    // [
    static let rbracket: UInt16 = 0x5D    // ]
    static let lparen: UInt16 = 0x28      // (
    static let rparen: UInt16 = 0x29      // )
    static let bang: UInt16 = 0x21        // !
    static let dot: UInt16 = 0x2E         // .
    static let x: UInt16 = 0x78
    static let X: UInt16 = 0x58
    static let colon: UInt16 = 0x3A
    static let slash: UInt16 = 0x2F

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) static func isSpaceOrTab(_ c: UInt16) -> Bool { c == space || c == tab }
    @inline(__always) static func isWhitespace(_ c: UInt16?) -> Bool {
        guard let c = c else { return true } // start/end of text counts as whitespace
        return c == space || c == tab || c == newline || c == 0x0D || c == 0xA0
    }
    @inline(__always) static func isPunctuation(_ c: UInt16?) -> Bool {
        guard let c = c else { return false }
        return (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
    @inline(__always) static func isAlphaNum(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c > 0x7F
    }
}
