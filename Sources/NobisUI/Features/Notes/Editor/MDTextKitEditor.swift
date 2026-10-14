#if os(macOS)
import AppKit
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
            if format.headingLevel == 2 { state.selected.insert("heading") }
            if format.headingLevel == 0 { state.selected.insert("body") }
            if format.headingLevel == nil { state.mixed.formUnion(["heading", "body"]) }
            for (style, action) in [(MDFormatting.InlineStyle.strong, "bold"), (.emphasis, "italic")] {
                if format.inline.contains(style) { state.selected.insert(action) }
                if format.mixedInline.contains(style) { state.mixed.insert(action) }
            }
            if format.list == .bullet { state.selected.insert("list") }
            if format.list == .task { state.selected.insert("checklist") }
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
            view.retryImage = { [weak self] path in self?.retryImage(path) }
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
            if let request = host.request, request.id != lastRequest {
                lastRequest = request.id
                let target = activeView.flatMap { $0 === view || $0.isDescendant(of: view) ? $0 : nil } ?? view
                guard host.editable, !target.hasMarkedText() else { return }
                // SwiftUI updates must not synchronously mutate the binding again.
                Task { @MainActor [weak self, weak target] in
                    guard let self, !self.stopped, let target, target.isEditable, !target.hasMarkedText() else { return }
                    target.window?.makeFirstResponder(target)
                    if request.action == "show-link" { self.showLinkEditor(in: target) }
                    else { NobisMDTextView.apply(request.action, to: target) }
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
    private var imageStatusViews: [Int: NoteImageStatusView] = [:]

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
        case "heading": if controller.formatting(in: view).headingLevel != 2 { controller.toggleHeading(in: view, headingLevel: 2) }
        case "body":
            if let level = controller.formatting(in: view).headingLevel { controller.toggleHeading(in: view, headingLevel: level) }
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
