import Foundation

public extension PMKAST {
    /// Removes the syntax of formatting constructs touching the selection. Structures
    /// carrying data (images, tables, tasks, fenced code) remain intact.
    func clearFormatting(selection: NSRange, inlineOnly: Bool = false, headingsOnly: Bool = false) -> PMKASTOperationResult? {
        let source = substring(rootNode.range) as NSString
        guard selection.location <= source.length, NSMaxRange(selection) <= source.length else { return nil }
        var removals: [NSRange] = []
        func touches(_ range: NSRange) -> Bool {
            selection.length == 0 ? NSLocationInRange(selection.location, range) : NSIntersectionRange(selection, range).length > 0
        }
        rootNode.walk { node in
            guard touches(node.range) else { return }
            switch node.type {
            case .strong, .emphasis, .strikethrough, .underline, .highlighter, .code:
                guard !headingsOnly else { return }
                removals += node.markerRanges
            case .link:
                guard !headingsOnly else { return }
                removals += [NSRange(location: node.range.location, length: node.contentRange.location - node.range.location),
                             NSRange(location: NSMaxRange(node.contentRange), length: NSMaxRange(node.range) - NSMaxRange(node.contentRange))]
            case .heading where !inlineOnly:
                removals += node.markerRanges
            default: break
            }
        }
        let sorted = removals.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, NSMaxRange(last) >= range.location { merged[merged.count - 1] = NSUnionRange(last, range) }
            else { merged.append(range) }
        }
        guard let first = merged.first, let last = merged.last else { return nil }
        let replacementRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let value = NSMutableString(string: source.substring(with: replacementRange))
        for range in merged.reversed() { value.deleteCharacters(in: NSRange(location: range.location - replacementRange.location, length: range.length)) }
        func mapped(_ index: Int) -> Int {
            index - merged.reduce(0) { $0 + max(0, min(index, NSMaxRange($1)) - $1.location) }
        }
        return PMKASTOperationResult(replacementRange: replacementRange, replacementString: value as String,
            proposedSelection: NSRange(location: mapped(selection.location), length: mapped(NSMaxRange(selection)) - mapped(selection.location)))
    }
}
