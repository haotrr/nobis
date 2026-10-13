import Foundation
import Testing
import FamilyCore

@Suite("Markdown 编辑快捷键") struct MarkdownEditingTests {
    @Test func formattingPreservesChineseEmojiSelectionAndToggles() throws {
        let original = "今天 😀 去海边"
        let selection = (original as NSString).range(of: "😀 去海边")
        let bold = try #require(MarkdownEdit.format(.bold, text: original, selection: selection))
        let formatted = (original as NSString).replacingCharacters(in: bold.range, with: bold.replacement)
        #expect(formatted == "今天 **😀 去海边**")
        #expect((formatted as NSString).substring(with: bold.selection) == "😀 去海边")
        let undo = try #require(MarkdownEdit.format(.bold, text: formatted, selection: bold.selection))
        #expect((formatted as NSString).replacingCharacters(in: undo.range, with: undo.replacement) == original)
        #expect(undo.selection == selection)
        let italic = try #require(MarkdownEdit.format(.italic, text: formatted, selection: bold.selection))
        let combined = (formatted as NSString).replacingCharacters(in: italic.range, with: italic.replacement)
        #expect(combined == "今天 ***😀 去海边***")
        let removeItalic = try #require(MarkdownEdit.format(.italic, text: combined, selection: italic.selection))
        #expect((combined as NSString).replacingCharacters(in: removeItalic.range, with: removeItalic.replacement) == formatted)
    }
    @Test func emptySelectionPlacesCaretInsideMarkersAndSelectsLinkURL() throws {
        let italic = try #require(MarkdownEdit.format(.italic, text: "", selection: NSRange(location: 0, length: 0)))
        #expect(italic.replacement == "**")
        #expect(italic.selection == NSRange(location: 1, length: 0))
        let link = try #require(MarkdownEdit.format(.link, text: "😀网站", selection: NSRange(location: 0, length: 4)))
        #expect(link.replacement == "[😀网站](https://)")
        #expect((link.replacement as NSString).substring(with: link.selection) == "https://")
        #expect(MarkdownEdit.format(.bold, text: "😀", selection: NSRange(location: 1, length: 1)) == nil)
        #expect(MarkdownEdit.format(.bold, text: "文字", selection: NSRange(location: 20, length: 0)) == nil)
    }
}
