import Foundation
import Testing
@testable import NobisUI

@MainActor @Suite("查找替换与高亮")
struct NoteSearchReplacementTests {
    @Test func changingSourceAndOptionsInvalidatesOrdinalAndStaleRequest() {
        let search = NoteSearchSession()
        search.query = "a"; search.isPresented = true
        search.navigate(1, in: "a A a")
        search.navigate(1, in: "a A a")
        #expect(search.index == 1)
        search.refresh(in: "a")
        #expect(search.index == -1 && search.matches.count == 1 && search.request == nil)
        search.caseSensitive = true
        search.refresh(in: "a A")
        #expect(search.matches.count == 1)
        search.query = "missing"; search.refresh(in: "a A")
        #expect(search.matches.isEmpty)
        search.composing = true; search.replace(all: true, in: "a A")
        #expect(search.request == nil)
        search.close(); #expect(search.ranges(in: 0).isEmpty)
    }

    @Test func singleReplacementAdvancesPastReplacementText() throws {
        let search = NoteSearchSession(); search.query = "a"; search.replacement = "aa"
        search.replace(all: false, in: "a a")
        let plan = try #require(search.request?.replacement)
        let result = try plan.applying(to: DocumentBlocks.parse(plan.source)).map(\.markdown).joined()
        search.didReplace(plan, text: result)
        #expect(result == "aa a")
        #expect(search.matches[search.index].range.location == 3)
    }

    @Test func manyMatchesAreReplacedWithoutRepeatedParsing() throws {
        let source = String(repeating: "词 ", count: 5_000)
        let blocks = DocumentBlocks.parse(source)
        let hits = NoteDocumentSearch.matches(in: blocks, query: "词")
        #expect(hits.count == 5_000)
        let result = try NoteSearchReplacement(source: source, matches: hits, replacement: "新").applying(to: blocks)
        #expect(result.map(\.markdown).joined() == String(repeating: "新 ", count: 5_000))
    }

    @Test func visibleMatchesBridgeFormattingAndExcludeURLs() throws {
        let source = "前**中文**😀 [链接](https://example.com/secret)"
        let blocks = DocumentBlocks.parse(source)
        let hits = NoteDocumentSearch.matches(in: blocks, query: "前中文😀")
        #expect(hits.count == 1)
        #expect(hits[0].segments?.count == 3)
        #expect(NoteDocumentSearch.matches(in: blocks, query: "secret").isEmpty)
        let updated = try NoteSearchReplacement(source: source, matches: hits, replacement: "新文").applying(to: blocks)
        #expect(updated.map(\.markdown).joined() == "新文 [链接](https://example.com/secret)")
        for (text, query, replacement, expected) in [
            ("前**中文后**", "前中文", "新", "新**后**"),
            ("**中文**", "中文", "新", "**新**"),
            ("**中文**", "中文", "", ""),
            ("[中文](https://example.com)", "中文", "新", "[新](https://example.com)"),
            ("[中文](https://example.com)", "中文", "", "")
        ] {
            let blocks = DocumentBlocks.parse(text)
            let hits = NoteDocumentSearch.matches(in: blocks, query: query)
            let result = try NoteSearchReplacement(source: text, matches: hits, replacement: replacement).applying(to: blocks)
            #expect(result.map(\.markdown).joined() == expected)
        }
    }

    @Test func replacementPreservesBlocksEscapesAndRejectsChangedSource() throws {
        let source = "前😀目标目标\n\n| 标题 |\n| --- |\n| 目标 |\n\n```swift\n目标\n```\n![目标](https://example.com/a.png)\n"
        let buffer = DocumentBlockBuffer(source)
        let original = buffer.blocks
        let hits = NoteDocumentSearch.matches(in: original, query: "目标")
        let plan = NoteSearchReplacement(source: source, matches: hits, replacement: "新|值")
        let next = try plan.applying(to: original)
        #expect(next.map(\.id) == original.map(\.id))
        let updated = next.map(\.markdown).joined()
        #expect(updated.contains("新\\|值"))
        #expect(updated.contains("![目标]"))
        #expect(NoteDocumentSearch.matches(in: DocumentBlocks.parse(updated), query: "目标").isEmpty)
        buffer.undo.groupsByEvent = false
        buffer.undo.beginUndoGrouping(); buffer.replace(next, undo: buffer.undo); buffer.undo.endUndoGrouping()
        buffer.undo.undo(); #expect(buffer.blocks == original)
        buffer.undo.redo(); #expect(buffer.blocks == next)
        #expect(throws: NoteImageEditError.self) { try plan.applying(to: DocumentBlocks.parse(source + "变化")) }
    }
}
