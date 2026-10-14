import Foundation

/// Three C++ corrections run in sequence
/// (PasteWhitespaceCorrection → PasteDeduplicateBlockCorrection → PasteLineEndingCorrection), each fed the
/// previous one's string and selection.
extension PMKAST {
    public func pasteCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] {
        let r = clamp(range)
        var text = replacementString
        var selection = clamp(selectionRange)
        var changed = false
        if let (t, sel) = pasteWhitespaceCorrection(range: r, text: text, selection: selection) { text = t; selection = sel; changed = true }
        if let (t, sel) = pasteDeduplicateBlockCorrection(range: r, text: text, selection: selection) { text = t; selection = sel; changed = true }
        if let (t, sel) = pasteLineEndingCorrection(range: r, text: text, selection: selection) { text = t; selection = sel; changed = true }
        guard changed else { return [] }
        return [PMKASTOperationResult(replacementRange: r, replacementString: text, proposedSelection: selection)]
    }

    private func isInsideCodeOrMath(_ index: Int) -> Bool {
        node(ofType: .fencedCode, at: index) != nil || node(ofType: .code, at: index) != nil
    }

    /// Smart spacing around the pasted text (approximation of `PasteWhitespaceCorrection`).
    private func pasteWhitespaceCorrection(range r: NSRange, text: String, selection: NSRange) -> (String, NSRange)? {
        guard !text.isEmpty, !text.hasPrefix("\n"), !text.hasSuffix("\n"), !isInsideCodeOrMath(r.location) else { return nil }
        let markers: Set<Character> = ["*", "_", "~", "`", "=", "\"", "#"]
        func isOpenPunct(_ c: Character) -> Bool { "([{<「『《“‘".contains(c) }
        func isClosePunct(_ c: Character) -> Bool { ")]}>」』》”’,.;:!?".contains(c) }
        func suppresses(_ c: Character) -> Bool { c.isNumber || "$€£¥".contains(c) || c.unicodeScalars.first.map { $0.value >= 0x2E80 } == true }
        let before: Character? = r.location > 0 ? Character(String(utf16CodeUnits: [utf16[r.location - 1]], count: 1)) : nil
        let afterIndex = NSMaxRange(r)
        let after: Character? = afterIndex < utf16.count ? Character(String(utf16CodeUnits: [utf16[afterIndex]], count: 1)) : nil
        let first = text.first!, last = text.last!
        var out = text
        var sel = selection
        let leftOK = before == nil || before == "\n" || before!.isWhitespace || isOpenPunct(before!) || markers.contains(before!)
        let rightOK = after == nil || after == "\n" || after == "\r" || after!.isWhitespace || isClosePunct(after!)
        if !leftOK, !first.isWhitespace, !(before.map(suppresses) ?? false), !suppresses(first) {
            out = " " + out; sel.location += 1
        } else if leftOK, first == " ", before != nil, before!.isWhitespace {
            out.removeFirst(); sel.location = max(0, sel.location - 1)
        }
        if !rightOK, !last.isWhitespace, !(after.map(suppresses) ?? false), !suppresses(last) {
            out += " "
        }
        return out == text ? nil : (out, sel)
    }

    /// Caret right after a list / block marker and the pasted text starts with the same kind of marker → drop it
    /// (`- ` + paste `- item` → `- item`).
    private func pasteDeduplicateBlockCorrection(range r: NSRange, text: String, selection: NSRange) -> (String, NSRange)? {
        let info = lineInfo(at: r.location, parser: BlockParser(text: utf16, rules: rules))
        guard r.location == info.markerEnd, info.markerEnd > info.indentEnd else { return nil }
        let marker = substring(NSRange(location: info.indentEnd, length: info.markerEnd - info.indentEnd))
        let pastedPrefix: String? = {
            let ns = text as NSString
            let line = ns.components(separatedBy: "\n").first ?? ""
            let lp = BlockParser(text: Array(line.utf16), rules: rules)
            let l = Line(index: 0, start: 0, end: (line as NSString).length, nextStart: (line as NSString).length)
            switch lp.classify(l, from: 0) {
            case .listItem(_, _, _, _, let ms, let me): return (line as NSString).substring(with: NSRange(location: ms, length: me - ms))
            case .heading(_, let ms, let me): return (line as NSString).substring(with: NSRange(location: ms, length: me - ms))
            default: return nil
            }
        }()
        guard let prefix = pastedPrefix, !prefix.isEmpty else { return nil }
        let sameKind: Bool = {
            if case .listItem = info.kind { return prefix.last == " " && marker.last == " " && (prefix.first == marker.first || (prefix.first!.isNumber && marker.first!.isNumber)) }
            if case .heading = info.kind { return prefix.hasPrefix("#") && marker.hasPrefix("#") }
            return false
        }()
        guard sameKind else { return nil }
        let out = String(text.dropFirst(prefix.count))
        return (out, NSRange(location: max(0, selection.location - (prefix as NSString).length), length: selection.length))
    }

    /// Multi-line paste inside a list / quote continues the container on every line.
    private func pasteLineEndingCorrection(range r: NSRange, text: String, selection: NSRange) -> (String, NSRange)? {
        guard text.contains("\n"), r.location + (text as NSString).length <= selection.location || true else { return nil }
        let nl = insertNewline(selection: NSRange(location: r.location, length: 0)).replacementString
        guard nl != "\n", nl.hasPrefix("\n") else { return nil }
        let out = text.replacingOccurrences(of: "\n", with: nl)
        let extra = (out as NSString).length - (text as NSString).length
        return (out, NSRange(location: selection.location + extra, length: selection.length))
    }
}
