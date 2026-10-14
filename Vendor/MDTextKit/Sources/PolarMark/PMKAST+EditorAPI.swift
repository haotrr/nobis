import Foundation

/// The ObjC-style `PMKAST` facade selectors, mapped onto the Swift operations. Every method returns the
/// array of `PMKASTOperationResult` the editor controller applies through `applyASTOperationResults`.
/// Operations whose C++ implementation (`PMK::Operation*`) is not ported yet return no results, which
/// the controller treats as "let the text view do the default thing".
public extension PMKAST {

    /// `PMKInlineStyle` indexes used by `toggleInlineStyle:selectionRange:style:`.
    static func inlineStyleKind(forStyleIndex index: Int) -> PMKInlineStyleKind? {
        switch index {
        case 0: return .strong
        case 1: return .emphasis
        case 2: return .strikethrough
        case 3: return .underline
        case 4, 5, 6, 7, 8, 9: return .highlighter
        case 10: return .code
        default: return nil   // 11 = math span (not ported)
        }
    }

    /// `PMKBlockStyle` indexes used by `toggleBlockStyle:selectionRange:style:`.
    static func blockStyleKind(forStyleIndex index: Int) -> PMKBlockStyleKind? {
        switch index {
        case 0...5: return .heading(index + 1)
        case 6: return .unorderedList
        case 7: return .orderedList
        case 8: return .taskList
        case 9: return .blockquote
        case 10: return .fencedCode
        default: return nil   // 11 math block, 12…17 callouts (not ported)
        }
    }

    func toggleInlineStyle(in range: NSRange, selectionRange: NSRange, style: Int) -> [PMKASTOperationResult] {
        guard let kind = PMKAST.inlineStyleKind(forStyleIndex: style), let r = toggleInlineStyle(kind, selection: selectionRange) else { return [] }
        return [r]
    }

    func toggleBlockStyle(in range: NSRange, selectionRange: NSRange, style: Int) -> [PMKASTOperationResult] {
        guard let kind = PMKAST.blockStyleKind(forStyleIndex: style), let r = toggleBlockStyle(kind, selection: selectionRange) else { return [] }
        return [r]
    }

    func toggleTask(in range: NSRange, selectionRange: NSRange, style: Int) -> [PMKASTOperationResult] {
        guard let r = toggleTask(at: range.location) else { return [] }
        var result = r
        result.proposedSelection = selectionRange
        return [result]
    }

    func deletePrevious(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        guard let r = deletePrevious(selection: selectionRange) else { return [] }
        return [r]
    }

    func deleteNext(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }

    func insertNewline(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        [insertNewline(selection: selectionRange)]
    }

    func indent(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [indent(selection: selectionRange)] }

    func outdent(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        guard let r = outdent(selection: selectionRange) else { return [] }
        return [r]
    }

    func insertThematicBreak(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        [insertThematicBreak(selection: selectionRange)]
    }

    func moveLinesUp(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func moveLinesDown(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }

    /// Runs after every parse over the reparsed range.
    func renumberOrderedList(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        var seen = Set<Int>()
        var results: [PMKASTOperationResult] = []
        for item in nodes(ofType: .listItem, in: range) where item.ordered {
            guard let list = item.parent, !seen.contains(list.range.location) else { continue }
            seen.insert(list.range.location)
            results.append(contentsOf: renumberOrderedList(at: item.range.location).map { r in
                var fixed = r
                fixed.proposedSelection = selectionRange
                return fixed
            })
        }
        return results.sorted { $0.replacementRange.location > $1.replacementRange.location }
    }

    func normalizeIndentation(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    /// A note that starts with a callout gets a leading newline.
    func normalizeCallout(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] {
        guard let first = rootNode.children.first, first.type == .blockquote, first.calloutType >= 0, first.range.location == 0 else { return [] }
        return [PMKASTOperationResult(replacementRange: NSRange(location: 0, length: 0), replacementString: "\n",
                                      proposedSelection: NSRange(location: selectionRange.location + 1, length: selectionRange.length))]
    }
    func escapePipes(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }

    // Corrections applied from `textView:shouldChangeTextInRange:replacementString:`.
    func listItemSpaceCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func fencedCodeCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func calloutCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func mathBlockCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func invalidCharacterCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func deleteWhitespaceCorrection(in range: NSRange, replacementString: String, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
    func insertTable(in range: NSRange, selectionRange: NSRange) -> [PMKASTOperationResult] { [] }
}
