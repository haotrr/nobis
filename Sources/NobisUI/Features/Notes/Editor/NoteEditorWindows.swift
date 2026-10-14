import SwiftUI
import FamilyDomain

#if os(macOS)
import AppKit

/// Every Mac entry point routes through this owner; opening a note never replaces its editor.
@MainActor final class NoteEditorWindows {
    static let shared = NoteEditorWindows()

    struct Key: Hashable {
        let model: ObjectIdentifier
        let id: UUID?
        let creating: Bool
    }
    private var sessions: [Key: NoteEditorWindow] = [:]

    @discardableResult
    func acquire(model: AppModel, existing: Record? = nil, project: Record? = nil,
              group: String? = nil) -> NoteEditorWindow {
        let key = Key(model: ObjectIdentifier(model), id: existing?.id ?? project?.id ?? model.selectedSpaceID,
                      creating: existing == nil)
        if let session = sessions[key] {
            return session
        }
        let session = NoteEditorWindow()
        sessions[key] = session
        session.onFinish = { [weak self, weak session] in
            guard let self, let session else { return }
            sessions = sessions.filter { $0.value !== session }
        }
        let state = DocumentEditorState(model: model, existing: existing, project: project, group: group)
        let editor = DocumentEditorContent(model: model, retainedState: state, existing: existing, project: project,
            group: group, embedded: true, onFinish: { [weak session] in session?.finish() },
            onReady: { [weak session] close, save in
                session?.requestClose = close
                session?.window.saveNote = save
            },
            onSaved: { [weak self, weak session] id in
                guard let self, let session else { return }
                // A new draft becomes a saved note without replacing its view or undo history.
                session.savedRecordID = id
                sessions = sessions.filter { !($0.key.creating && $0.value === session) }
                sessions[Key(model: key.model, id: id, creating: false)] = session
            }, onWindowState: { [weak session] title, dirty, composing in
                session?.rememberTextResponder()
                session?.canDetach = !composing
                session?.window.title = title.isEmpty ? "新建笔记" : title
                session?.window.isDocumentEdited = dirty
            })
        session.editorController = NSHostingController(rootView: NoteEditorWindowContent(
            model: model, session: session, editor: editor))
        return session
    }
    @discardableResult
    func open(model: AppModel, existing: Record? = nil, project: Record? = nil,
              group: String? = nil) -> NoteEditorWindow {
        let session = acquire(model: model, existing: existing, project: project, group: group)
        session.show()
        return session
    }

}

@MainActor final class NoteEditingWindow: NSWindow {
    var saveNote: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            if event.charactersIgnoringModifiers == "s" { saveNote?(); return true }
            if event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor @Observable final class NoteEditorWindow: NSObject, NSWindowDelegate {
    let runtime = NoteEditorRuntime()
    let window: NoteEditingWindow
    var alwaysOnTop = false {
        didSet { window.level = alwaysOnTop ? .floating : .normal }
    }
    private weak var textResponder: NSTextView?
    var canDetach = true
    var editorController: NSViewController?
    var editorHost: NSView? { editorController?.view }
    private(set) var isDetached = false
    var inlineOwner: UUID?
    var inlineFinish: (() -> Void)?
    var savedRecordID: UUID?
    private(set) var isFinished = false
    var requestClose: (() -> Void)?
    var onFinish: (() -> Void)?

    override init() {
        window = NoteEditingWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "笔记"
        window.minSize = NSSize(width: 420, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        guard !isFinished else { return }
        rememberTextResponder()
        let restoreResponder = textResponder ?? bodyTextView(in: editorHost)
        if !isDetached {
            guard canDetach else { focus(); return }
            // SwiftUI may rebuild its graph on reparenting. The retained state and runtime
            // keep the live document and native undo stack independent of that graph.
            editorController?.removeFromParent()
            editorHost?.removeFromSuperview()
            window.contentViewController = editorController
            isDetached = true
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if let restoreResponder {
            window.makeFirstResponder(restoreResponder)
            Task { @MainActor [weak self, weak restoreResponder] in
                await Task.yield()
                guard let self, let restoreResponder, !self.isFinished, self.window.isKeyWindow else { return }
                self.window.makeFirstResponder(restoreResponder)
            }
        }
    }

    private func bodyTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NobisMDTextView { return text }
        return view.subviews.lazy.compactMap { self.bodyTextView(in: $0) }.first
    }

    func rememberTextResponder() {
        if let host = editorHost, let text = host.window?.firstResponder as? NSTextView,
           text.isDescendant(of: host) { textResponder = text }
    }

    func focus() {
        if isDetached { show() }
        else { editorHost?.window?.makeKeyAndOrderFront(nil) }
    }

    func releaseInline(_ owner: UUID) {
        guard inlineOwner == owner else { return }
        inlineOwner = nil
        inlineFinish = nil
        // SwiftUI may replace the surrounding layout during a resize. Let its new mount claim
        // this host before releasing a genuinely abandoned inline editing session.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.inlineOwner == nil, !self.isDetached else { return }
            self.finish()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose?()
        return false // The editor owns the dirty-draft confirmation, including native ⌘W.
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        runtime.stop()
        window.delegate = nil
        window.close()
        window.contentViewController = nil
        editorHost?.removeFromSuperview()
        editorController?.removeFromParent()
        editorController = nil
        if !isDetached { inlineFinish?() }
        inlineFinish = nil
        inlineOwner = nil
        window.saveNote = nil
        requestClose = nil
        onFinish?()
        onFinish = nil
    }
}

private struct NoteEditorWindowContent: View {
    let model: AppModel
    @Bindable var session: NoteEditorWindow
    let editor: DocumentEditorContent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        editor.safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                if session.isDetached {
                    Toggle("窗口始终置顶", isOn: $session.alwaysOnTop)
                        .toggleStyle(.checkbox).help("让这个编辑窗口保持在其他普通窗口上方")
                } else {
                    Button("在独立窗口打开", systemImage: "macwindow", action: session.show)
                        .disabled(!session.canDetach)
                }
            }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
        }
        .environment(\.noteEditorRuntime, session.runtime)
        .tint(NobisTheme.accent)
        .onChange(of: model.accessEpoch) { _, _ in session.finish() }
    }
}

/// The same native hosting view moves from this slot into the optional independent window.
private struct InlineNoteEditor: NSViewControllerRepresentable {
    let session: NoteEditorWindow
    let owner: UUID

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        guard !session.isDetached, session.inlineOwner == owner,
              let host = session.editorController, host.parent !== controller else { return }
        host.removeFromParent()
        host.view.removeFromSuperview()
        controller.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.frame = controller.view.bounds
        host.view.autoresizingMask = [.width, .height]
        controller.view.addSubview(host.view)
    }
}

struct DocumentEditor: View {
    let model: AppModel
    var existing: Record? = nil
    var project: Record? = nil
    var group: String? = nil
    var embedded = false
    var onFinish: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var owner = UUID()
    @State private var session: NoteEditorWindow?

    var body: some View {
        Group {
            if let session, !session.isFinished {
                if !session.isDetached && session.inlineOwner == owner {
                    InlineNoteEditor(session: session, owner: owner)
                } else {
                    ContentUnavailableView {
                        Label("笔记已在另一窗口编辑", systemImage: "macwindow")
                    } description: {
                        Text("草稿和撤销历史保留在已有编辑器中。")
                    } actions: {
                        Button("显示编辑窗口", action: session.focus)
                    }
                }
            } else {
                Button("继续编辑笔记", action: openInline)
            }
        }
        .onAppear { visible = true; openInline() }
        .onDisappear { visible = false; session?.releaseInline(owner) }
        .onChange(of: session?.inlineOwner) { _, value in
            if visible, value == nil, session?.isDetached == false, session?.isFinished == false { claimInline() }
        }
    }

    private func claimInline() {
        guard let session, !session.isDetached, session.inlineOwner == nil else { return }
        session.inlineOwner = owner
        session.inlineFinish = { if let onFinish { onFinish() } else { dismiss() } }
    }

    private func openInline() {
        if session == nil || session?.isFinished == true {
            let record = session?.savedRecordID.flatMap { id in model.activeRecords.first { $0.id == id } } ?? existing
            session = NoteEditorWindows.shared.acquire(model: model, existing: record, project: project, group: group)
        }
        claimInline()
    }
}

#else
typealias DocumentEditor = DocumentEditorContent
#endif
