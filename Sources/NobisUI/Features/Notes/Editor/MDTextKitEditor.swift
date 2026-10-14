#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import FamilyCore
import SwiftUI
import MDTextKit
import MDTextKitUI
import SFThemeKit
import PolarMark

/// Outlives SwiftUI graph replacement when an editor moves between windows.
@MainActor final class NoteEditorRuntime {
    var coordinator: MDTextKitEditor.Coordinator?
    func stop() { coordinator?.stop(); coordinator = nil }
}

private struct NoteEditorRuntimeKey: EnvironmentKey {
    static let defaultValue: NoteEditorRuntime? = nil
}
extension EnvironmentValues {
    var noteEditorRuntime: NoteEditorRuntime? {
        get { self[NoteEditorRuntimeKey.self] }
        set { self[NoteEditorRuntimeKey.self] = newValue }
    }
}

/// The host owns drafts and saves; the component owns only the live Markdown buffer.
struct MDTextKitEditor: NSViewRepresentable {
    @Environment(\.noteEditorRuntime) private var runtime
    @Binding var text: String
    var request: RichEditRequest?
    var editable = true
    var loadImages = true
    var preserveSelection = false
    var onSelection: (NoteEditorSelection) -> Void = { _ in }
    var onFind: () -> Void = {}
    var search: NoteSearchSession? = nil

    func makeCoordinator() -> Coordinator {
        if let coordinator = runtime?.coordinator { return coordinator }
        let coordinator = Coordinator(text: $text)
        coordinator.sessionOwned = runtime != nil
        runtime?.coordinator = coordinator
        return coordinator
    }

    func makeNSView(context: Context) -> NobisMDTextView {
        context.coordinator.update(self)
        return context.coordinator.view
    }

    func updateNSView(_ view: NobisMDTextView, context: Context) { context.coordinator.update(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NobisMDTextView, context: Context) -> CGSize? {
        nsView.measuredSize(width: max(100, proposal.width ?? 600))
    }

    static func dismantleNSView(_ nsView: NobisMDTextView, coordinator: Coordinator) { if !coordinator.sessionOwned { coordinator.stop() } }

    @MainActor final class Coordinator {
        var sessionOwned = false
        var binding: Binding<String>
        let view: NobisMDTextView
        let theme: SFThemeManager
        private var observers: [NSObjectProtocol] = []
        private var emitted: String?
        private var installing = false
        private var lastRequest: UUID?
        private var linkPopover: NSPopover?
        private var imagePanel: NSOpenPanel?
        private var imageSheet: NSWindow?
        private var importingImage = false
        private var linkKeyMonitor: Any?
        private weak var activeView: MDTextView?
        private var images: [String: Data] = [:]
        private var imageTasks: [String: Task<Void, Never>] = [:]
        private var failedImages: Set<String> = []
        private var imagesEnabled = false
        private var needsImageRefresh = false
        private var stopped = false
        private var onSelection: (NoteEditorSelection) -> Void = { _ in }
        private var preserveSelection = false
        private var reported: NoteEditorSelection?

        func selectionState(for target: MDTextView) -> NoteEditorSelection {
            let format = target.editorController.formatting(in: target)
            var state = NoteEditorSelection(enabled: target.isEditable, composing: target.hasMarkedText(), inTable: target !== view)
            if let level = format.headingLevel, level > 0 { state.selected.insert("heading:\(level)") }
            if format.headingLevel == 0 { state.selected.insert("body") }
            if format.headingLevel == nil { state.mixed.formUnion(["heading:1", "heading:2", "heading:3", "body"]) }
            for (style, action) in [(MDFormatting.InlineStyle.strong, "bold"), (.emphasis, "italic"), (.strikethrough, "strike"), (.code, "inline-code")] {
                if format.inline.contains(style) { state.selected.insert(action) }
                if format.mixedInline.contains(style) { state.mixed.insert(action) }
            }
            if format.list == .bullet { state.selected.insert("list") }
            if format.list == .task { state.selected.insert("checklist") }
            if format.list == .ordered { state.selected.insert("ordered") }
            if format.isBlockquote { state.selected.insert("quote") }
            return state
        }

        private func reportSelection() {
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                let target = self.activeView.flatMap { $0 === self.view || $0.isDescendant(of: self.view) ? $0 : nil } ?? self.view
                var state = self.selectionState(for: target)
                if !self.preserveSelection, let responder = self.view.window?.firstResponder as? NSTextView,
                   responder !== self.view, !responder.isDescendant(of: self.view) { state.enabled = false }
                if state != self.reported { self.reported = state; self.onSelection(state) }
                self.refreshImagesIfPossible()
            }
        }

        init(text: Binding<String>) {
            binding = text
            let controller = MDEditorController()
            controller.autoHideMarkdown = true
            view = NobisMDTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 240), editorController: controller)
            theme = Self.makeTheme()
            view.applyTheme(theme)
            view.drawsBackground = false
            view.isVerticallyResizable = false
            view.autoresizingMask = []
            view.textContainerInset = NSSize(width: 0, height: 12)
            view.mdTextContainer.maxColumSize = 0
            view.setAccessibilityLabel("笔记正文")
            view.installTableEditing(themeManager: theme)
            view.inspectImage = { [weak self] index in self?.showImageInspector(at: index) }
            view.retryImage = { [weak self] path in self?.retryImage(path) }
            view.addFilesBlock = { [weak self] urls, selection in
                guard let self else { return }
                self.importImages(urls, into: self.view, selection: selection, original: self.view.markdown)
            }
            view.openURL = { url in
                guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
                NSWorkspace.shared.open(url)
            }
            controller.attributedStringRenderer.imageStyler.reservedImageSize = CGSize(width: 560, height: 420)
            controller.attributedStringRenderer.imageStyler.dataResolver = { [weak self] path in self?.imageData(path) }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: MDTextViewTextDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
            observers.append(center.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportSelection() }
            })
            observers.append(center.addObserver(forName: MDTextViewTextDidChangeSelectionNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let target = self.view.window?.firstResponder as? MDTextView,
                       target === self.view || target.isDescendant(of: self.view) { self.activeView = target }
                    self.reportSelection()
                }
            })
        }

        func update(_ host: MDTextKitEditor) {
            binding = host.$text
            view.onFind = host.onFind
            onSelection = host.onSelection
            preserveSelection = host.preserveSelection
            defer { reportSelection() }
            if view.isEditable != host.editable { emitted = nil }
            view.isEditable = host.editable
            view.isSelectable = true
            let enabledImages = !imagesEnabled && host.loadImages
            imagesEnabled = host.loadImages
            // The binding contains only committed text. Never push it over marked text.
            if emitted != host.text, !view.hasMarkedText() {
                installing = true
                view.editorController.loadString(host.text, into: view)
                view.invalidateMeasurement()
                emitted = host.text
                installing = false
                needsImageRefresh = true
            } else if enabledImages { needsImageRefresh = true }
            refreshImagesIfPossible()
            highlightMatches(host.search)
            if let request = host.request, request.id != lastRequest {
                lastRequest = request.id
                let target = activeView.flatMap { $0 === view || $0.isDescendant(of: view) ? $0 : nil } ?? view
                guard host.editable, !target.hasMarkedText() else { return }
                // SwiftUI updates must not synchronously mutate the binding again.
                Task { @MainActor [weak self, weak target] in
                    guard let self, !self.stopped, let target, target.isEditable, !target.hasMarkedText() else { return }
                    target.window?.makeFirstResponder(target)
                    if let plan = request.replacement {
                        do { try self.replaceMatches(plan); host.search?.didReplace(plan, text: self.view.markdown) }
                        catch { host.search?.issue = error.localizedDescription }
                    }
                    else if let match = request.match { self.selectMatch(match) }
                    else if request.action == "show-find" { host.onFind() }
                    else if request.action == "show-link" { self.showLinkEditor(in: target) }
                    else if request.action == "insert-image-file" { self.chooseImage(in: target) }
                    else { NobisMDTextView.apply(request.action, to: target) }
                }
            }
        }

        func selectMatch(_ match: NoteSearchMatch) {
            let blocks = DocumentBlocks.parse(view.markdown)
            guard blocks.indices.contains(match.block), !view.hasMarkedText() else { return }
            let block = blocks[match.block]
            guard match.isValid(in: block) else { return }
            var offset = blocks.prefix(match.block).reduce(0) { $0 + $1.markdown.utf16.count }
            if let row = match.row, let column = match.column {
                let mapped = view.mdTextStorage.attributedStringRange(fromStringRange: NSRange(location: offset, length: block.markdown.utf16.count))
                view.scrollRangeToVisible(mapped)
                if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
                view.mdTextStorage.enumerateAttribute(.attachment, in: mapped) { value, _, stop in
                    if let attachment = value as? MDTableTextAttachment,
                       let table = attachment.attachmentViewController as? MDTableAttachmentViewController {
                        table.selectMatch(row: row, column: column, range: match.range); stop.pointee = true
                    }
                }
            } else {
                if case .code = block.content { offset += (block.markdown as NSString).range(of: "\n").location + 1 }
                let mapped = view.mdTextStorage.attributedStringRange(fromStringRange: NSRange(location: offset + match.range.location, length: match.range.length))
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(mapped)
                view.scrollRangeToVisible(mapped)
            }
        }

        func replaceMatches(_ plan: NoteSearchReplacement) throws {
            guard view.isEditable, !view.hasMarkedText(), activeView?.hasMarkedText() != true else { throw NoteImageEditError.changed }
            let before = DocumentBlocks.parse(view.markdown)
            let after = try plan.applying(to: before)
            var offset = 0
            var changes: [(NSRange, String)] = []
            for (old, new) in zip(before, after) {
                let range = NSRange(location: offset, length: old.markdown.utf16.count)
                if old.markdown != new.markdown { changes.append((range, new.markdown)) }
                offset += range.length
            }
            guard !changes.isEmpty else { return }
            view.window?.makeFirstResponder(view)
            view.editorUndoManager.beginUndoGrouping()
            defer { view.editorUndoManager.endUndoGrouping() }
            for (range, text) in changes.reversed() {
                let mapped = view.mdTextStorage.attributedStringRange(fromStringRange: range)
                view.editorController.replaceCharacters(in: mapped, with: NSAttributedString(string: text), in: view)
            }
            view.editorController.notifyTextChanges(in: view)
        }

        func highlightMatches(_ search: NoteSearchSession?) {
            guard !view.hasMarkedText(), activeView?.hasMarkedText() != true else { return }
            let full = NSRange(location: 0, length: view.mdTextStorage.length)
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let blocks = DocumentBlocks.parse(view.markdown)
            var offset = 0
            for (index, block) in blocks.enumerated() {
                let mapped = view.mdTextStorage.attributedStringRange(fromStringRange: NSRange(location: offset, length: block.markdown.utf16.count))
                if case .table = block.content {
                    view.mdTextStorage.enumerateAttribute(.attachment, in: mapped) { value, _, _ in
                        guard let attachment = value as? MDTableTextAttachment,
                              let table = attachment.attachmentViewController as? MDTableAttachmentViewController else { return }
                        let hits = search?.isPresented == true ? search?.matches.filter { $0.block == index && $0.isValid(in: block) } ?? [] : []
                        table.setSearchMatches(hits.flatMap { hit -> [(Int, Int, NSRange)] in
                            guard let row = hit.row, let column = hit.column else { return [] }
                            return (hit.segments ?? [hit.range]).map { (row, column, $0) }
                        })
                    }
                } else {
                    var start = offset
                    if case .code = block.content { start += (block.markdown as NSString).range(of: "\n").location + 1 }
                    for range in (search?.isPresented == true ? search?.matches.filter { $0.block == index && $0.isValid(in: block) }.flatMap { $0.segments ?? [$0.range] } ?? [] : []) where start + NSMaxRange(range) <= view.markdown.utf16.count {
                        let hit = view.mdTextStorage.attributedStringRange(fromStringRange: NSRange(location: start + range.location, length: range.length))
                        view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.32), forCharacterRange: hit)
                    }
                }
                offset += block.markdown.utf16.count
            }
        }

        func showImageInspector(at index: Int) {
            guard imageSheet == nil, !view.hasMarkedText(), let window = view.window else { return }
            let sourceRange = view.mdTextStorage.markdownRange(fromAttributedRange: NSRange(location: index, length: 1))
            guard let edit = NoteImageEdit(source: view.markdown, at: sourceRange.location) else { return }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            sheet.title = "图片"
            sheet.contentViewController = NSHostingController(rootView: NoteImageInspector(content: edit.content, canEdit: view.isEditable, apply: { [weak self] value in
                guard let self, !self.stopped, self.view.isEditable, !self.view.hasMarkedText() else { throw NoteImageEditError.changed }
                try self.applyImageEdit(edit, replacement: value)
            }, close: { [weak self, weak sheet, weak window] in
                if let sheet { window?.endSheet(sheet) }
                self?.imageSheet = nil
            }))
            imageSheet = sheet
            window.beginSheet(sheet)
        }

        func applyImageEdit(_ edit: NoteImageEdit, replacement: NoteImageContent?) throws {
            guard view.isEditable, !view.hasMarkedText() else { throw NoteImageEditError.changed }
            _ = try edit.applying(to: view.markdown, replacement: replacement)
            let replacementText = edit.replacementText(replacement)
            let range = view.mdTextStorage.attributedStringRange(fromStringRange: edit.range)
            view.editorController.replaceCharacters(in: range, with: NSAttributedString(string: replacementText), in: view)
            view.editorController.notifyTextChanges(in: view)
        }

        private func chooseImage(in target: MDTextView) {
            guard imagePanel == nil, !importingImage, let window = target.window else { return }
            let selection = target.selectedRange(), original = view.markdown
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "插入图片"
            imagePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak target] response in
                guard let self else { return }
                self.imagePanel = nil
                guard response == .OK, let url = panel.url, let target else { return }
                self.importImages([url], into: target, selection: selection, original: original)
            }
        }

        private func importImages(_ urls: [URL], into target: MDTextView, selection: NSRange, original: String) {
            guard !importingImage, target.isEditable, !target.hasMarkedText(), !urls.isEmpty else { return }
            importingImage = true
            Task { @MainActor [weak self, weak target] in
                guard let self else { return }
                defer { self.importingImage = false }
                do {
                    let addresses = try await Task.detached(priority: .userInitiated) {
                        try urls.map { url in
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            return try NoteEmbeddedImage.importFile(url)
                        }
                    }.value
                    guard !self.stopped, let target, target.window != nil, target.isEditable else { return }
                    guard self.view.markdown == original, !target.hasMarkedText() else { throw NoteImageInsertionError.contentChanged }
                    let markdown = addresses.map { MDEditorController.markdownImage(alt: "图片", address: $0) }.joined(separator: "\n")
                    try DocumentContentLimits.validate(original + "\n" + markdown)
                    target.window?.makeFirstResponder(target)
                    target.setSelectedRange(selection)
                    target.editorUndoManager.beginUndoGrouping()
                    for address in addresses { target.insertMarkdownImage(alt: "图片", address: address) }
                    target.editorUndoManager.endUndoGrouping()
                } catch {
                    guard !self.stopped, let window = target?.window else { return }
                    let alert = NSAlert()
                    alert.messageText = "图片未插入"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }

        private func showLinkEditor(in target: MDTextView) {
            let context = NobisMDTextView.linkContext(in: target)
            target.scrollRangeToVisible(context.range)
            let screen = target.firstRect(forCharacterRange: context.range, actualRange: nil)
            guard let window = target.window else { return }
            let anchor = target.convert(window.convertFromScreen(screen), from: nil)
            linkPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: NoteLinkForm(address: context.address, cancel: { [weak popover] in popover?.close() }) { [weak target, weak popover] address in
                guard let target, !target.hasMarkedText() else { return }
                popover?.close()
                target.window?.makeFirstResponder(target)
                target.setSelectedRange(context.range)
                NobisMDTextView.apply("link:" + address, to: target)
            })
            linkPopover = popover
            if linkKeyMonitor == nil {
                linkKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let handled = MainActor.assumeIsolated {
                        guard event.keyCode == 53, let popover = self?.linkPopover, popover.isShown else { return false }
                        if let field = popover.contentViewController?.view.window?.firstResponder as? NSTextView, field.hasMarkedText() { return false }
                        popover.close()
                        return true
                    }
                    return handled ? nil : event
                }
            }
            popover.show(relativeTo: anchor, of: target, preferredEdge: .maxY)
        }

        private func publish() {
            guard !stopped, !installing, !view.hasMarkedText() else { return }
            view.invalidateMeasurement()
            let source = view.markdown
            emitted = source
            if binding.wrappedValue != source { binding.wrappedValue = source }
            needsImageRefresh = true
            refreshImagesIfPossible()
            reportSelection()
        }

        private func imageData(_ path: String, retry: Bool = false) -> Data? {
            if let data = images[path] { return data }
            if let data = NoteEmbeddedImage.data(path) { images[path] = data; return data }
            guard imagesEnabled, !failedImages.contains(path), imageTasks[path] == nil,
                  let url = URL(string: path), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            imageTasks[path] = Task { @MainActor [weak self] in
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.needsImageRefresh = true
                self.refreshImagesIfPossible()
                do {
                    let request = URLRequest(url: url, cachePolicy: retry ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled, !self.stopped else { return }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          response.url?.scheme?.lowercased() == "https",
                          data.count <= 20 * 1_024 * 1_024, NSImage(data: data) != nil else {
                        self.receiveImageFailure(path: path)
                        return
                    }
                    self.receiveImage(data, path: path)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.receiveImageFailure(path: path)
                }
            }
            return nil
        }

        func receiveImageFailure(path: String) {
            guard !stopped else { return }
            imageTasks[path]?.cancel()
            imageTasks[path] = nil
            failedImages.insert(path)
            needsImageRefresh = true
            refreshImagesIfPossible()
        }

        func retryImage(_ path: String) {
            guard !stopped, imagesEnabled, failedImages.contains(path), !view.hasMarkedText() else { return }
            failedImages.remove(path)
            _ = imageData(path, retry: true)
            needsImageRefresh = true
            refreshImagesIfPossible()
        }

        func receiveImage(_ data: Data, path: String) {
            guard !stopped else { return }
            imageTasks[path]?.cancel()
            imageTasks[path] = nil
            failedImages.remove(path)
            images[path] = data
            needsImageRefresh = true
            refreshImagesIfPossible()
        }

        private func refreshImagesIfPossible() {
            guard needsImageRefresh, !installing, !view.hasMarkedText() else { return }
            if let cell = view.window?.firstResponder as? MDTextView, cell !== view, cell.isDescendant(of: view) { return }
            needsImageRefresh = false
            installing = true
            // Reserved bounds do not change: update pixels without rebuilding text,
            // selection, undo, or the enclosing scroll view's content geometry.
            view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, range, _ in
                guard let attachment = value as? MDImageTextAttachment, let path = attachment.filePath,
                      let data = imageData(path), attachment.imageData != data else { return }
                attachment.imageData = data
                attachment.updateAttachmentImage()
                view.layoutManager?.invalidateDisplay(forCharacterRange: range)
            }
            view.imageStates = Dictionary(uniqueKeysWithValues: imageTasks.keys.map { ($0, false) })
            for path in failedImages { view.imageStates[path] = true }
            view.layoutImageStatus()
            view.needsDisplay = true
            installing = false
        }

        func stop() {
            if let linkKeyMonitor { NSEvent.removeMonitor(linkKeyMonitor) }
            linkKeyMonitor = nil
            linkPopover?.close()
            linkPopover = nil
            stopped = true
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let sheet = imageSheet { sheet.sheetParent?.endSheet(sheet) }; imageSheet = nil
            imagePanel?.cancel(nil)
            imagePanel = nil
            imageTasks.values.forEach { $0.cancel() }
            imageTasks.removeAll()
        }

        private static func makeTheme() -> SFThemeManager {
            SFThemeManager(theme: SFTheme(name: "Nobis", jsonObject: [
                "base": ["background color": NSColor.textBackgroundColor, "text color": NSColor.labelColor],
                "editor": [
                    "text color": NSColor.labelColor, "marker color": NSColor.tertiaryLabelColor,
                    "cursor color": NSColor.controlAccentColor, "selection color": NSColor.selectedTextBackgroundColor,
                    "text font": "system", "text size": NoteTypography.bodySize,
                    "line height multiplier": 1.5, "line width multiplier": 0,
                    "headers": ["font": "system-bold", "text color": NSColor.labelColor, "modular scale": 1.125,
                                "line height multiplier": 1.3, "add top bottom padding": true,
                                "padding top multiplier": 0.5, "padding bottom multiplier": 0.3],
                    "code": ["font": "system-mono", "text color": NSColor.labelColor,
                             "border color": NSColor.separatorColor, "background color": NSColor.quaternaryLabelColor.withAlphaComponent(0.12)],
                    "link": ["text color": NSColor.linkColor],
                    "task": ["background color": NSColor.textBackgroundColor, "border color": NSColor.secondaryLabelColor,
                             "check color": NSColor.controlAccentColor],
                    "table": ["border color": NSColor.separatorColor, "cell background color": NSColor.textBackgroundColor,
                              "cell alternate background color": NSColor.controlBackgroundColor],
                    "separator": ["border color": NSColor.separatorColor]
                ]
            ]))
        }
    }
}

@MainActor final class NobisMDTextView: MDTextView {
    private var measurement: CGSize?
    private var revealScheduled = false
    var imageStates: [String: Bool] = [:] // true means failed; false means loading.
    var retryImage: ((String) -> Void)?
    var inspectImage: ((Int) -> Void)?
    private var contextImageIndex: Int?
    private var imageStatusViews: [Int: NoteImageStatusView] = [:]

    private func imageIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, mdTextStorage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard mdTextStorage.textAttachment(at: index) is MDImageTextAttachment else { return nil }
        return index
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !hasMarkedText(), let index = imageIndex(at: convert(event.locationInWindow, from: nil)) {
            inspectImage?(index); return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if !hasMarkedText(), let index = imageIndex(at: convert(event.locationInWindow, from: nil)) {
            contextImageIndex = index
            let menu = NSMenu()
            let item = NSMenuItem(title: isEditable ? "查看与编辑图片" : "查看图片", action: #selector(openContextImage), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            return menu
        }
        return super.menu(for: event)
    }
    @objc private func openContextImage() { if let contextImageIndex { inspectImage?(contextImageIndex) } }

    override func accessibilityChildren() -> [Any]? {
        let controls: [NSView] = imageStatusViews.values.flatMap { $0.subviews.filter { !$0.isHidden } }
        return (super.accessibilityChildren() ?? []) + controls
    }

    override func layout() {
        super.layout()
        layoutImageStatus()
    }

    func layoutImageStatus() {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return }
        var retained: Set<Int> = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let image = value as? MDImageTextAttachment, image.temporaryImage == nil,
                  let path = image.filePath, let failed = imageStates[path] else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard rect.width > 0, rect.height > 0 else { return }
            let status = imageStatusViews[range.location] ?? NoteImageStatusView()
            if status.superview == nil { addSubview(status) }
            imageStatusViews[range.location] = status
            retained.insert(range.location)
            status.frame = rect
            status.configure(failed: failed, retry: { [weak self] in self?.retryImage?(path) })
        }
        for key in Array(imageStatusViews.keys) where !retained.contains(key) {
            imageStatusViews.removeValue(forKey: key)?.removeFromSuperview()
        }
    }


    func invalidateMeasurement() {
        measurement = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func measuredSize(width: CGFloat) -> CGSize {
        if let measurement, abs(measurement.width - width) < 0.5 { return measurement }
        let changedWidth = abs(frame.width - width) >= 0.5
        if changedWidth { setFrameSize(NSSize(width: width, height: frame.height)) }
        guard let layoutManager, let textContainer else { return CGSize(width: width, height: 240) }
        layoutManager.ensureLayout(for: textContainer)
        let result = CGSize(width: width, height: max(240, ceil(layoutManager.usedRect(for: textContainer).maxY + textContainerInset.height * 2 + 8)))
        measurement = result
        if changedWidth { revealCaretAfterLayout() }
        return result
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateMeasurement()
        revealCaretAfterLayout()
    }

    func revealCaretAfterLayout() {
        guard !revealScheduled, window?.firstResponder === self else { return }
        revealScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.revealScheduled = false
            guard self.window?.firstResponder === self else { return }
            self.scrollRangeToVisible(self.selectedRange())
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags.contains(.shift) { if editorUndoManager.canRedo { editorUndoManager.redo() } }
            else if editorUndoManager.canUndo { editorUndoManager.undo() }
            return true
        }
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(), ["b", "i"].contains(key) {
            Self.apply(key == "b" ? "bold" : "italic", to: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func linkContext(in view: MDTextView) -> (range: NSRange, label: String, address: String) {
        let storage = view.mdTextStorage
        let range = view.selectedRange()
        let sourceRange = storage.markdownRange(fromAttributedRange: range)
        let ast = PMKAST(markdown: view.markdown)
        var link: PMKASTNode?
        ast.rootNode.walk { node in
            if node.type == .link, node.range.location <= sourceRange.location,
               NSMaxRange(node.range) > sourceRange.location,
               NSMaxRange(node.range) >= NSMaxRange(sourceRange) { link = node }
        }
        if let link {
            return (storage.attributedStringRange(fromStringRange: link.range), ast.substring(link.contentRange), link.url)
        }
        return (range, storage.stringByExpandingTextAttachments(in: range), "")
    }

    static func apply(_ action: String, to view: MDTextView) {
        guard view.isEditable, !view.hasMarkedText() else { return }
        let controller = view.editorController
        view.breakUndoCoalescing()
        switch action {
        case "bold": controller.toggleStrong(in: view)
        case "italic": controller.toggleEmphasis(in: view)
        case "strike": controller.toggleStrikethrough(in: view)
        case "inline-code": controller.toggleCode(in: view)
        case "ordered": controller.toggleOrderedList(in: view)
        case "quote": controller.toggleBlockQuote(in: view)
        case "heading:1", "heading:2", "heading:3":
            controller.toggleHeading(in: view, headingLevel: Int(action.suffix(1)) ?? 2)
        case "clear", "body":
            let sourceRange = view.mdTextStorage.markdownRange(fromAttributedRange: view.selectedRange())
            if let result = PMKAST(markdown: view.markdown).clearFormatting(selection: sourceRange, headingsOnly: action == "body") {
                let range = view.mdTextStorage.attributedStringRange(fromStringRange: result.replacementRange)
                controller.replaceCharacters(in: range, with: NSAttributedString(string: result.replacementString), in: view)
                view.setSelectedRange(view.mdTextStorage.attributedStringRange(fromStringRange: result.proposedSelection))
            }
        case "heading": if controller.formatting(in: view).headingLevel != 2 { controller.toggleHeading(in: view, headingLevel: 2) }
        case "list": controller.toggleUnorderedList(in: view)
        case "checklist": controller.toggleTaskList(in: view)
        case "toggle": controller.toggleTask(in: view, range: view.selectedRange(), style: 0)
        case "insert-table": insertBlock("| 列一 | 列二 |\n| --- | --- |\n|  |  |", into: view)
        case "insert-image": insertBlock("![图片说明](https://)", into: view)
        case "insert-code": controller.toggleCodeBlock(in: view)
        default:
            if action.hasPrefix("link:") {
                let address = String(action.dropFirst(5))
                guard address.isEmpty || URL(string: address).map({ ["https", "http", "mailto"].contains($0.scheme?.lowercased() ?? "") }) == true else { return }
                let context = linkContext(in: view)
                let label = context.label.isEmpty ? "链接文字" : context.label
                let markdown = address.isEmpty ? label : MDEditorController.markdownLink(label: label, url: address)
                controller.replaceCharacters(in: context.range, with: NSAttributedString(string: markdown), in: view)
            }
        }
        controller.notifyTextChanges(in: view)
    }

    private static func insertBlock(_ markdown: String, into view: MDTextView) {
        let selection = view.selectedRange()
        let paragraph = (view.string as NSString).paragraphRange(for: selection)
        let end = NSMaxRange(paragraph)
        let prefix = end > 0 && !(view.string as NSString).substring(to: end).hasSuffix("\n") ? "\n\n" : "\n"
        view.editorController.replaceCharacters(in: NSRange(location: end, length: 0),
            with: NSAttributedString(string: prefix + markdown + "\n\n"), in: view)
    }
}
private enum NoteImageInsertionError: LocalizedError {
    case contentChanged
    var errorDescription: String? { "读取图片期间正文已变化，请在新的光标位置重新插入。" }
}
private struct NoteLinkForm: View {
    @State var address: String
    var cancel: () -> Void
    var apply: (String) -> Void
    @FocusState private var focused: Bool
    private var valid: Bool {
        address.isEmpty || URL(string: address).map { ["https", "http", "mailto"].contains($0.scheme?.lowercased() ?? "") } == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文字链接").font(.headline)
            TextField("https://", text: $address).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if valid { apply(address) } }
            HStack {
                Button("移除链接") { apply("") }.disabled(address.isEmpty)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("应用") { apply(address) }.disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 280).onAppear { focused = true }
    }
}
/// An overlay inside the attachment bounds; never participates in text layout.
@MainActor final class NoteImageStatusView: NSView {
    private let label = NSTextField(labelWithString: "")
    let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private var retry: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.setAccessibilityLabel("重新加载图片")
        addSubview(label)
        addSubview(retryButton)
    }
    required init?(coder: NSCoder) { nil }
    func configure(failed: Bool, retry: @escaping () -> Void) {
        label.stringValue = failed ? "图片暂时无法加载" : "正在加载图片…"
        retryButton.isHidden = !failed
        self.retry = retry
        needsLayout = true
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: bounds.midY + 4, width: max(0, bounds.width - 16), height: 20)
        retryButton.frame = NSRect(x: bounds.midX - 40, y: bounds.midY - 32, width: 80, height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
    @objc private func retryClicked() { retry?() }
}
#endif
