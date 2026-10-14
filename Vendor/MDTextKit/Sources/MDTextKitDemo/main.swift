import AppKit
import MDTextKitUI
import MDTextKit
import SFThemeKit
import TextBundle
import UniformTypeIdentifiers

let sampleNote = """
# MDTextKit

Welcome to a **Swift** Markdown editor: *PolarMark* → *MDTextKit* → *MDTextKitUI*.
Markers like `**` and `*` stay in the text but are hidden until the caret enters the construct. #demo #markdown/editor

## Lists and tasks

- A bullet item with ~~strikethrough~~ and ~underline~
- Nested lists:
\t- second level
\t\t- third level
1. Ordered one
2. Ordered two
- [ ] An open task (click the checkbox)
- [x] A completed task

## Code

```swift
struct Note {
    let title: String   // the first heading
    var tags: [String] = []
    func render() -> Int { return 42 }
}
```

Inline `code spans` and ==highlighted text== work too, so does \\*escaping\\*.

> A quote with a [link](https://example.com) and https://autolink.example/path
> > nested quote level two

---

Final paragraph after a thematic break.
"""

/// The demo's own themes; the kit ships none.
enum DemoThemes {
    static var urls: [URL] {
        guard let dir = Bundle.module.url(forResource: "Themes", withExtension: nil) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "theme" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor static func theme(named name: String) -> SFTheme? {
        guard let url = urls.first(where: { $0.deletingPathExtension().lastPathComponent == name }) else { return nil }
        return try? SFTheme(contentsOf: url)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: MDEditorViewController!
    let themeManager = SFThemeManager(theme: DemoThemes.theme(named: "Default") ?? SFTheme(name: "Empty", jsonObject: [:]))
    private var autosaveObserver: MDNotificationToken?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--font-size 16` is the user font size setting, which overrides the theme's text size.
        if let i = CommandLine.arguments.firstIndex(of: "--font-size"), i + 1 < CommandLine.arguments.count, let size = Double(CommandLine.arguments[i + 1]) {
            themeManager.overrides["editor.text size"] = size
        }
        editor = MDEditorViewController(themeManager: themeManager)
        var size = NSSize(width: 900, height: 700)
        if let i = CommandLine.arguments.firstIndex(of: "--size"), i + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MDTextKit"
        window.contentViewController = editor
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        editor.load(markdown: sampleNote)
        // `--file path.md` loads a markdown file instead of the built-in sample.
        if let i = CommandLine.arguments.firstIndex(of: "--file"), i + 1 < CommandLine.arguments.count,
           let text = try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8) {
            editor.documentBaseURL = URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingLastPathComponent()
            editor.load(markdown: text)
        }
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(editor.textView)
        let args0 = CommandLine.arguments

        if let i = args0.firstIndex(of: "--autosave"), i + 1 < args0.count {
            let path = args0[i + 1]
            autosaveObserver = MDNotificationToken(NotificationCenter.default.addObserver(forName: MDTextViewTextDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { try? self?.editor.markdown.write(toFile: path, atomically: true, encoding: .utf8) }
            })
            try? editor.markdown.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // `--debug-table-edit` edits the first table's cell (1,0) programmatically and prints the resulting markdown.
        if args0.contains("--debug-table-edit") {
            Task { @MainActor [self] in
                try? await Task.sleep(for: .seconds(1))
                let ts = editor.textView.mdTextStorage
                var done = false
                ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: []) { v, _, stop in
                    guard let a = v as? MDTableTextAttachment, let vc = a.attachmentViewController as? MDTableAttachmentViewController else { return }
                    let md = vc.debugEdit(row: 1, column: 0, insert: " edited")
                    print("TABLE-EDIT represented:\n\(md)")
                    done = true
                    stop.pointee = true
                }
                if !done { print("TABLE-EDIT no table attachment / controller") }
                try? await Task.sleep(for: .seconds(0.5))
                print("TABLE-EDIT markdown:\n\(editor.markdown)"); NSApp.terminate(nil)
            }
        }
        // `--dump-layout` prints every line fragment (top, height, baseline, text) and exits (layout debugging).
        if args0.contains("--dump-layout") {
            Task { @MainActor [self] in
                try? await Task.sleep(for: .seconds(0.5))
                let tv = editor.textView!
                let lm = tv.layoutManager!, tc = tv.textContainer!
                lm.ensureLayout(for: tc)
                let ns = tv.string as NSString
                lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, used, _, glyphs, _ in
                    let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    var text = ns.substring(with: chars).replacingOccurrences(of: "\n", with: "⏎")
                    if text.count > 30 { text = String(text.prefix(30)) + "…" }
                    let loc = lm.location(forGlyphAt: glyphs.location)
                    print(String(format: "LINE y=%7.2f h=%5.2f used=%5.2f baseline=%5.2f  %@", rect.minY, rect.height, used.height, loc.y, text))
                }
                NSApp.terminate(nil)
            }
        }
        // `--snapshot out.png [caret]` renders the editor offscreen and exits (used for visual verification).
        let args = args0
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            if i + 2 < args.count, let caret = Int(args[i + 2]) {
                editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
            }
            if args.contains("--dark"), let t = DemoThemes.theme(named: "Dark") { themeManager.loadTheme(t) }
            Task { @MainActor [self] in
                try? await Task.sleep(for: .seconds(0.5))
                let tv = editor.textView!
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                let rect = NSRect(x: 0, y: 0, width: tv.bounds.width, height: max(tv.bounds.height, 100))
                if let rep = tv.bitmapImageRepForCachingDisplay(in: rect) {
                    tv.cacheDisplay(in: rect, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                        print("snapshot written to \(path) (\(Int(rect.width))x\(Int(rect.height)))")
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func switchTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let theme = DemoThemes.theme(named: name) else { return }
        themeManager.loadTheme(theme)
    }

    @objc func dumpMarkdown(_ sender: Any?) {
        print("---- markdown ----\n\(editor.markdown)\n------------------")
    }

    // MARK: File menu — TextBundle / TextPack / plain markdown

    private var documentURL: URL? { didSet { window.title = documentURL?.lastPathComponent ?? "MDTextKit" } }

    private static var textBundleTypes: [UTType] {
        var t: [UTType] = []
        if let a = UTType(filenameExtension: TextBundle.packageExtension) { t.append(a) }
        if let b = UTType(filenameExtension: TextBundle.compressedExtension) { t.append(b) }
        t.append(contentsOf: [.plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText])
        return t
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown, .textbundle or .textpack"
        panel.allowedContentTypes = AppDelegate.textBundleTypes
        panel.canChooseDirectories = true          // a .textbundle shows as a folder when the UTI is not registered
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            if TextBundle.isTextBundle(url) || TextBundle.isTextPack(url) {
                try editor.open(textBundleAt: url)
            } else {
                editor.documentBaseURL = url.deletingLastPathComponent()
                editor.load(markdown: try String(contentsOf: url, encoding: .utf8))
            }
            documentURL = url
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let url = documentURL else { return saveDocumentAs(sender) }
        save(to: url)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Save as .textbundle, .textpack or .md"
        panel.allowedContentTypes = AppDelegate.textBundleTypes
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = (documentURL?.deletingPathExtension().lastPathComponent ?? "Note") + ".textbundle"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    private func save(to url: URL) {
        do {
            if TextBundle.isTextBundle(url) || TextBundle.isTextPack(url) {
                try editor.save(toTextBundleAt: url)
            } else {
                try editor.markdown.write(to: url, atomically: true, encoding: .utf8)
            }
            documentURL = url
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Command-line flags (e.g. --snapshot) are handed to us as "files" before launch finished.
        guard editor != nil, FileManager.default.fileExists(atPath: filename) else { return false }
        open(URL(fileURLWithPath: filename))
        return true
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MDTextKit Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        let openI = NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o"); openI.target = self; file.addItem(openI)
        let saveI = NSMenuItem(title: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s"); saveI.target = self; file.addItem(saveI)
        let saveAsI = NSMenuItem(title: "Save As…", action: #selector(saveDocumentAs(_:)), keyEquivalent: "S"); saveAsI.target = self; file.addItem(saveAsI)
        fileItem.submenu = file

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(MDTextView.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(MDTextView.redo(_:)), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: ""); main.addItem(formatItem)
        let format = NSMenu(title: "Format")
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = editor
            format.addItem(i)
        }
        add("Bold", #selector(MDEditorViewController.toggleStrong(_:)), "b")
        add("Italic", #selector(MDEditorViewController.toggleEmphasis(_:)), "i")
        add("Underline", #selector(MDEditorViewController.toggleUnderline(_:)), "u")
        add("Strikethrough", #selector(MDEditorViewController.toggleStrikethrough(_:)), "u", [.command, .shift])
        add("Highlighter", #selector(MDEditorViewController.toggleHighlighter(_:)), "h", [.command, .shift])
        add("Inline Code", #selector(MDEditorViewController.toggleCode(_:)), "k", [.command, .shift])
        format.addItem(.separator())
        add("Heading 1", #selector(MDEditorViewController.toggleHeading1(_:)), "1")
        add("Heading 2", #selector(MDEditorViewController.toggleHeading2(_:)), "2")
        add("Heading 3", #selector(MDEditorViewController.toggleHeading3(_:)), "3")
        format.addItem(.separator())
        add("Bullet List", #selector(MDEditorViewController.toggleUnorderedList(_:)), "l", [.command, .shift])
        add("Numbered List", #selector(MDEditorViewController.toggleOrderedList(_:)), "n", [.command, .shift])
        add("Task List", #selector(MDEditorViewController.toggleTaskList(_:)), "t", [.command, .shift])
        add("Quote", #selector(MDEditorViewController.toggleBlockQuote(_:)), "'", [.command, .shift])
        add("Code Block", #selector(MDEditorViewController.toggleCodeBlock(_:)), "c", [.command, .shift, .option])
        add("Separator", #selector(MDEditorViewController.insertThematicBreak(_:)), "-", [.command, .shift])
        format.addItem(.separator())
        add("Toggle Fold", #selector(MDEditorViewController.toggleFolding(_:)), ".", [.command, .option])
        add("Fold All", #selector(MDEditorViewController.foldAll(_:)), ".", [.command, .option, .shift])
        add("Unfold All", #selector(MDEditorViewController.unfoldAll(_:)), ",", [.command, .option, .shift])
        format.addItem(.separator())
        add("Indent", #selector(MDEditorViewController.addIndent(_:)), "]")
        add("Outdent", #selector(MDEditorViewController.removeIndent(_:)), "[")
        formatItem.submenu = format

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        for url in DemoThemes.urls {
            let name = url.deletingPathExtension().lastPathComponent
            let i = NSMenuItem(title: "Theme: \(name)", action: #selector(switchTheme(_:)), keyEquivalent: "")
            i.representedObject = name
            i.target = self
            view.addItem(i)
        }
        view.addItem(.separator())
        let hide = NSMenuItem(title: "Toggle Markdown Hiding", action: #selector(MDEditorViewController.toggleMarkdownHiding(_:)), keyEquivalent: "m")
        hide.keyEquivalentModifierMask = [.command, .shift]; hide.target = editor; view.addItem(hide)
        let grid = NSMenuItem(title: "Toggle Layout Grid", action: #selector(MDEditorViewController.toggleBackgroundGrid(_:)), keyEquivalent: "g")
        grid.keyEquivalentModifierMask = [.command, .shift]; grid.target = editor; view.addItem(grid)
        let dump = NSMenuItem(title: "Print Markdown to Console", action: #selector(dumpMarkdown(_:)), keyEquivalent: "p")
        dump.keyEquivalentModifierMask = [.command, .shift]; dump.target = self; view.addItem(dump)
        viewItem.submenu = view

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
