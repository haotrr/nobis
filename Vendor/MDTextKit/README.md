# MDTextKit

A Markdown editor engine for macOS written in Swift (SwiftPM, macOS 26+, Swift 6, TextKit 1):
`PolarMark` (parser + AST) → `MDTextKit` (text storage, stylers, layout) → `MDTextKitUI` (text view, editor controller).
The storage string is always the Markdown source; markers are hidden until the caret enters a construct, and block
decorations (bullets, checkboxes, rules, fold pills, tables, images, callout icons) are text attachments drawn by the kit.

## Targets

| Target | Role |
|---|---|
| `PolarMark` | Block + inline parser, AST, annotated string with `PMK*` attribute keys, structural operations (`toggleInlineStyle`, `toggleBlockStyle`, `insertNewline`, `indent`, `toggleTask`, folding, selection / paste corrections). `replaceRange(_:withMarkdown:)` re-parses from the block before the edit until a parsed block matches an old one again, and reports the block-aligned range that must be re-styled; `annotatedString(forStringRange:)` annotates only the blocks that range touches. |
| `MDTextStorageCore` | The text storage's Objective-C primitives (`attributesAtIndex:effectiveRange:`, `length`), so TextKit's reads never bridge a dictionary into Swift. |
| `MDTextKit` | `MDTextStorage` (the AST beside the attributed string, an attachment table for coordinate mapping, the Markdown assembled from it), `MDAttributedStringRenderer` with the styler pipeline, `MDMarkdownHider` (0.01pt placeholder font + `MDOriginalAttributes`), `MDLayoutManager` (block backgrounds, quote bars, callout boxes, selection), `MDTextContainer` (centered column), `MDEditorController` (undo-aware text operations). |
| `MDTextKitUI` | `MDTextView` (attachment clicks, undo manager, pasteboard, drag and drop, `applyTheme`, `installTableEditing`, `imageFileResolver`, `openURL`), `MDEditorViewController` (assembly, theme changes, TextBundle open/save, bottom format bar, fold gutter), table cell editing, image loading. |
| `SFThemeKit` | JSON `.theme` files with `$a.b.c` references, `SFThemeManager` + `SFStylable`, per-process font registration. A theme value may also be an `NSColor`, so a host passes dynamic colours. The kit bundles no theme; the demo ships `Default` and `Dark`. |
| `TextBundle` | `.textbundle` packages and `.textpack` archives per textbundle.org spec v2: `info.json` (foreign metadata preserved), `text.*`, `assets/`. |
| `MDTextKitDemo` | Demo window with Format / View / File menus. |

## Editing flow

```
keystroke
 └─ MDTextStorage.replaceCharacters           change recorded, attachment table shifted
 └─ MDTextStorage.processEditing
     └─ PMKAST.replaceRange(withMarkdown:)     incremental parse, compute reparsed range
     └─ delegate: MDEditorController.performStyling
         ├─ PMKAST.annotatedString(forRange:)  PMK* attributes
         ├─ MDAttributedStringRenderer         stylers in order
         └─ MDMarkdownHider.updateHiding       hide markers not under the caret
 └─ selection change → MDMarkdownHider.showHideMarkdown
```

## Features

Headings, paragraphs, thematic breaks, fenced code, blockquotes (nested), callouts (`> [!NOTE]`, `[!TIP]`,
`[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), bullet / numbered / task lists (nested by tabs, click a checkbox to
toggle), strong, emphasis, strikethrough, underline, highlighter, inline code, links, autolinks, escapes, hard line
breaks, images (`![alt](relative/path.png)` resolved against the note's folder or the TextBundle assets), GitHub pipe
tables (rendered as a grid; click a cell to edit in place, Tab / Shift-Tab / arrows move between cells, ⋮ menu for
rows, columns, alignment and copy as Markdown / CSV / HTML), folding (`<!-- {"fold":true} -->` at the end of a heading
or list item line; Format › Toggle Fold / Fold All / Unfold All, gutter chevrons on hover, ⌘-click a heading marker).
Marker hiding, list continuation on return, smart backspace on markers, tab / shift-tab indentation, format toggles,
a dedicated undo manager, rich-text and Markdown pasteboard, line drag and drop, themes, TextBundle / TextPack open
and save.

Hashtags are parsed but intentionally not styled (`RuleConfig.hashtags = false`).

Not implemented: footnotes, wiki links, math and Mermaid rendering, syntax highlighting inside code blocks, bidi
handling, YAML metadata, search, TOC and statistics panels, autocomplete.

## Host integration

A host that draws its own chrome uses `MDTextView` directly: create an `MDEditorController`, an
`MDTextView(frame:editorController:)` and an `SFThemeManager(theme:)`, then call `applyTheme(_:)`,
`installTableEditing(themeManager:)` and set `imageFileResolver` and `openURL`. `MDEditorController.formatting(in:)`
reports what the selection is inside (heading level, inline styles, link, code block, quote, list kind) so a
toolbar lights the toggle that would undo it. Text, attribute and selection changes post
`MDTextViewTextDidChangeNotification`, `MDTextViewTextAttributesDidChangeNotification` and
`MDTextViewTextDidChangeSelectionNotification` synchronously. There is no shared theme manager: the host owns one.

## Fonts and themes

Themes use the system font by default (`"system"`, `"system-bold"`, `"system-mono"`, `"system-rounded"`,
`"system-serif"`, `"system-semibold"`, or any PostScript name). Custom fonts can be registered for the process
with `SFFontLoader.registerFonts(in:)` or by pointing `MDTEXTKIT_FONTS_DIR` at a folder of `.otf` / `.ttf` files;
the theme's `editor.text font` / `editor.headers.font` / `editor.code.font` then refer to them by PostScript name.
`SFThemeManager.overrides` lets the host app override theme values (for example `"editor.text size"`). An
`"<font key> cjk"` override names a family that joins that font's cascade list.

## Run

```bash
cd ~/Developer/MDTextKit && ./tools/make_app.sh && open -n dist/MDTextKitDemo.app --args --size 723x748 --font-size 16 --file "$PWD/Samples/all-styles.md"
```

- `./tools/make_app.sh`：`swift build` 后组装 `dist/MDTextKitDemo.app`（每次改代码后重新执行；`tools/` 不入库）。
- `--size WxH`：窗口内容尺寸；`--font-size N`：用户字号，覆盖主题的 `editor.text size`；`--file`：打开任意 Markdown 文件（相对路径图片按该文件所在目录解析）；`--dark`：Dark 主题；`--autosave path`：每次改动写回文件；`--dump-layout`：打印每行 fragment 后退出；`--snapshot out.png [caret]`：离屏渲染后退出。
- 直接调试：`swift run MDTextKitDemo --size 723x748 --font-size 16`。
- 测试：`swift test`。
- `Samples/`（示例笔记）、`tools/`（打包和截图比对脚本）、`reference/`（分析资料）都只在本地，不入库。
