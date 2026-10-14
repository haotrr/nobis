import Foundation
import Testing
@testable import NobisUI

@MainActor @Suite("图片导入保护与摘要")
struct NoteImageImportTests {
    @Test func cancelledCompletionCannotEndNewImport() {
        var state = NoteImageImportState()
        let old = state.begin()
        state.cancel()
        #expect(!state.isLoading && !state.accepts(old))
        let next = state.begin()
        state.finish(old)
        #expect(state.isLoading && state.accepts(next))
        state.finish(next)
        #expect(!state.isLoading)
    }
    @Test func changedDocumentRejectsPhotoWithoutChangingFocusOrUndo() throws {
        let buffer = DocumentBlockBuffer("新的正文")
        let original = buffer.blocks
        #expect(throws: (any Error).self) {
            try buffer.insertPhoto(address: "invalid", source: "原正文", at: nil)
        }
        #expect(buffer.blocks == original)
        #expect(buffer.focus == nil && !buffer.undo.canUndo)
    }
    @Test func invalidImageDoesNotInsertEmptyBlock() {
        let buffer = DocumentBlockBuffer("正文")
        #expect(throws: (any Error).self) {
            try buffer.insertPhoto(address: "invalid", source: "正文", at: nil)
        }
        #expect(buffer.blocks.map(\.markdown).joined() == "正文")
        #expect(!buffer.undo.canUndo)
    }
    @Test func excerptRemovesInlinePayloadBeforeTruncation() {
        let payload = String(repeating: "ABCD", count: 170_000)
        let source = "- [x] 之前 ![照片](<data:image/jpeg;base64,\(payload)>) 之后\n![](https://example.com/a(b).png)"
        #expect(NoteExcerpt.hidingImageAddresses(in: source) == "- [x] 之前 照片 之后\n图片")
        #expect(NoteExcerpt.hidingImageAddresses(in: "普通 **正文** 和 [链接](https://example.com)") == "普通 **正文** 和 [链接](https://example.com)")
    }
}
