import Foundation
import Testing
@testable import NobisUI

@Suite("所见即所得 Markdown") @MainActor struct RichMarkdownTests {
    @Test func basicRoundTrip() {
        let source = "## 中文标题\n正文 **粗体** 与 *斜体* 😀\n- [ ] 相机\n- [x] 酒店\n- 列表\n> 引用\n[网站](https://example.com)\n"
        let rich = RichMarkdown.decode(source)
        #expect(!rich.string.contains("**"))
        #expect(rich.string.contains("☐ 相机"))
        #expect(RichMarkdown.encode(rich) == source)
    }
    @Test func unsupportedAndCodeRemainIntact() {
        let source = "```swift\n**原样**\n- [ ] 代码\n```\n| a | b |\n| --- | --- |\n![图](https://example.com/a.png)"
        #expect(RichMarkdown.encode(RichMarkdown.decode(source)) == source)
    }
    @Test func checklistChangesSameMarkdownState() {
        let source = RichMarkdown.decode("- [ ] 相机\n下一行")
        let changed = RichMarkdown.applying("toggle", to: source, selection: NSRange(location: 2, length: 0))
        #expect(RichMarkdown.encode(changed) == "- [x] 相机\n下一行")
    }
    @Test func formattingPreservesUnicode() {
        let source = RichMarkdown.decode("你好😀")
        let changed = RichMarkdown.applying("bold", to: source, selection: NSRange(location: 2, length: 2))
        #expect(RichMarkdown.encode(changed) == "你好**😀**")
    }
}
