import XCTest
@testable import PolarMark

final class PolarMarkTests: XCTestCase {

    func testHeadingAndParagraph() {
        let ast = PMKAST(markdown: "# Title\n\nHello **world** and *you*.\n")
        let types = ast.rootNode.children.map { $0.type }
        XCTAssertEqual(types, [.heading, .paragraph])
        let h = ast.rootNode.children[0]
        XCTAssertEqual(h.level, 1)
        XCTAssertEqual(h.markerRanges, [NSRange(location: 0, length: 2)])
        let p = ast.rootNode.children[1]
        XCTAssertEqual(p.children.map { $0.type }, [.strong, .emphasis])
        XCTAssertEqual(ast.markdown(for: p.children[0]), "**world**")
        XCTAssertEqual(ast.markdown(for: p.children[1]), "*you*")
    }

    func testAnnotatedStringAttributes() {
        let ast = PMKAST(markdown: "Hello **world**")
        let s = ast.annotatedString()
        var r = NSRange()
        XCTAssertNotNil(s.attribute(.pmkStrong, at: 8, longestEffectiveRange: &r, in: NSRange(location: 0, length: s.length)))
        XCTAssertEqual(r, NSRange(location: 6, length: 9))
        XCTAssertEqual((s.attribute(.pmkStrongMarker, at: 6, effectiveRange: nil) as? NSNumber)?.intValue, PMKMarkerValue.open.rawValue)
        XCTAssertEqual((s.attribute(.pmkStrongMarker, at: 13, effectiveRange: nil) as? NSNumber)?.intValue, PMKMarkerValue.close.rawValue)
        XCTAssertNil(s.attribute(.pmkStrongMarker, at: 9, effectiveRange: nil))
    }

    func testLists() {
        let md = "- one\n- [ ] two\n\t- nested\n1. first\n2. second\n"
        let ast = PMKAST(markdown: md)
        let blocks = ast.rootNode.children
        XCTAssertEqual(blocks.map { $0.type }, [.list, .list])
        let bullets = blocks[0]
        XCTAssertFalse(bullets.ordered)
        XCTAssertEqual(bullets.children.count, 2)
        XCTAssertEqual(bullets.children[1].task, .open)
        let nested = bullets.children[1].children.first { $0.type == .list }
        XCTAssertNotNil(nested)
        XCTAssertEqual(nested?.level, 2)
        let ordered = blocks[1]
        XCTAssertTrue(ordered.ordered)
        XCTAssertEqual(ordered.children.map { $0.number }, [1, 2])
    }

    func testFencedCodeAndQuote() {
        let md = "```swift\nlet x = 1\n```\n> quoted *em*\n> more\n"
        let ast = PMKAST(markdown: md)
        let blocks = ast.rootNode.children
        XCTAssertEqual(blocks.map { $0.type }, [.fencedCode, .blockquote])
        XCTAssertEqual(blocks[0].language, "swift")
        XCTAssertTrue(blocks[0].closed)
        XCTAssertEqual(ast.substring(blocks[0].contentRange), "let x = 1\n")
        XCTAssertEqual(blocks[1].level, 1)
        XCTAssertEqual(blocks[1].children.first?.type, .paragraph)
        XCTAssertEqual(blocks[1].children.first?.children.first?.type, .emphasis)
    }

    func testInlineVariety() {
        let md = "a `code` b [link](https://x.y) c #tag d https://auto.link/e ==hl== ~~del~~ ~und~ \\*esc*"
        let ast = PMKAST(markdown: md)
        ast.rules.hashtags = true   // tag parsing is off by default now
        let kinds = ast.rootNode.children[0].children.map { $0.type }
        XCTAssertEqual(kinds, [.code, .link, .hashtag, .autolink, .highlighter, .strikethrough, .underline, .escape])
        let link = ast.rootNode.children[0].children[1]
        XCTAssertEqual(link.url, "https://x.y")
        XCTAssertEqual(link.label, "link")
    }

    func testIncrementalReparseRangeIsLocal() {
        let md = "# A\n\npara one\n\npara two\n\n# B\n"
        let ast = PMKAST(markdown: md)
        // insert into "para one"
        let r = ast.replaceRange(NSRange(location: 10, length: 0), withMarkdown: "X")
        XCTAssertEqual(ast.markdown, "# A\n\npara Xone\n\npara two\n\n# B\n")
        // From the end of the unchanged block before the edit to the start of the one after it.
        XCTAssertEqual(r, NSRange(location: 4, length: 12)) // "\npara Xone\n\n"
        XCTAssertEqual(ast.rootNode.children.count, 4)
    }

    func testIncrementalReparseStopsAtTheUnchangedBlock() {
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
        let ast = PMKAST(markdown: "## H\n\n\(table)")
        // Delete the heading's newline: the blank line's newline now ends it and the table follows.
        let r = ast.replaceRange(NSRange(location: 4, length: 1), withMarkdown: "")
        XCTAssertEqual(ast.markdown, "## H\n\(table)")
        XCTAssertEqual(ast.rootNode.children.map { $0.type }, [.heading, .table])
        // Ends where the unchanged table starts: a cut into its first row drops the other rows.
        XCTAssertEqual(r, NSRange(location: 0, length: 5))
    }

    func testIncrementalReparseExpandsWhenFenceOpens() {
        let md = "one\n\ntwo\n\nthree\n"
        let ast = PMKAST(markdown: md)
        let r = ast.replaceRange(NSRange(location: 0, length: 0), withMarkdown: "```\n")
        // Everything becomes an unclosed code block, so the whole document must be restyled.
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(NSMaxRange(r), ast.markdownLength)
        XCTAssertEqual(ast.rootNode.children.first?.type, .fencedCode)
        XCTAssertFalse(ast.rootNode.children.first!.closed)
    }

    func testToggleInlineStyle() {
        let ast = PMKAST(markdown: "hello world")
        let wrap = ast.toggleInlineStyle(.strong, selection: NSRange(location: 6, length: 5))!
        XCTAssertEqual(wrap.replacementString, "**world**")
        XCTAssertEqual(wrap.proposedSelection, NSRange(location: 8, length: 5))
        ast.replaceRange(wrap.replacementRange, withMarkdown: wrap.replacementString)
        let unwrap = ast.toggleInlineStyle(.strong, selection: NSRange(location: 8, length: 5))!
        XCTAssertEqual(unwrap.replacementString, "world")
        XCTAssertEqual(unwrap.replacementRange, NSRange(location: 6, length: 9))
    }

    func testToggleHeadingAndList() {
        let ast = PMKAST(markdown: "plain line")
        let h = ast.toggleBlockStyle(.heading(2), selection: NSRange(location: 3, length: 0))!
        XCTAssertEqual(h.replacementString, "## plain line")
        XCTAssertEqual(h.proposedSelection.location, 6)
        ast.replaceRange(h.replacementRange, withMarkdown: h.replacementString)
        let off = ast.toggleBlockStyle(.heading(2), selection: NSRange(location: 6, length: 0))!
        XCTAssertEqual(off.replacementString, "plain line")
        let task = ast.toggleBlockStyle(.taskList, selection: NSRange(location: 6, length: 0))!
        XCTAssertEqual(task.replacementString, "- [ ] plain line")
    }

    func testNewlineContinuesList() {
        let ast = PMKAST(markdown: "- item")
        let r = ast.insertNewline(selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(r.replacementString, "\n- ")
        let ast2 = PMKAST(markdown: "- ")
        let exit = ast2.insertNewline(selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(exit.replacementRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(exit.replacementString, "")
        let ast3 = PMKAST(markdown: "3. x")
        XCTAssertEqual(ast3.insertNewline(selection: NSRange(location: 4, length: 0)).replacementString, "\n4. ")
    }

    func testToggleTask() {
        let ast = PMKAST(markdown: "- [ ] todo\n- [x] done\n")
        let r = ast.toggleTask(at: 7)!
        XCTAssertEqual(r.replacementRange, NSRange(location: 3, length: 1))
        XCTAssertEqual(r.replacementString, "x")
        let r2 = ast.toggleTask(at: 15)!
        XCTAssertEqual(r2.replacementString, " ")
    }
}
