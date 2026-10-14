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
    func open(model: AppModel, existing: Record? = nil, project: Record? = nil,
              group: String? = nil) -> NoteEditorWindow {
        let key = Key(model: ObjectIdentifier(model), id: existing?.id ?? project?.id ?? model.selectedSpaceID,
                      creating: existing == nil)
        if let session = sessions[key] {
            session.show()
            return session
        }
        let session = NoteEditorWindow()
        sessions[key] = session
        session.onFinish = { [weak self, weak session] in
            guard let self, let session else { return }
            sessions = sessions.filter { $0.value !== session }
        }
        let editor = DocumentEditorContent(model: model, existing: existing, project: project,
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
            }, onWindowState: { [weak session] title, dirty in
                session?.window.title = title.isEmpty ? "新建笔记" : title
                session?.window.isDocumentEdited = dirty
            })
        session.window.contentView = NSHostingView(rootView: NoteEditorWindowContent(
            model: model, session: session, editor: editor))
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
    let window: NoteEditingWindow
    var alwaysOnTop = false {
        didSet { window.level = alwaysOnTop ? .floating : .normal }
    }
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
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose?()
        return false // The editor owns the dirty-draft confirmation, including native ⌘W.
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        window.delegate = nil
        window.close()
        window.contentView = nil
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
                Toggle("窗口始终置顶", isOn: $session.alwaysOnTop)
                    .toggleStyle(.checkbox).help("让这个编辑窗口保持在其他普通窗口上方")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
        }
        .tint(colorScheme == .dark ? Color(red: 0.65, green: 0.82, blue: 0.73) : Color(red: 0.24, green: 0.43, blue: 0.36))
        .onChange(of: model.accessEpoch) { _, _ in session.finish() }
    }
}

/// Main navigation keeps the note's management and comments; editing has one window owner.
struct DocumentEditor: View {
    let model: AppModel
    var existing: Record? = nil
    var project: Record? = nil
    var group: String? = nil
    var embedded = false
    var onFinish: (() -> Void)? = nil
    @State private var opened = false
    @State private var session: NoteEditorWindow?

    var body: some View {
        ContentUnavailableView {
            Label("在独立窗口编辑笔记", systemImage: "macwindow")
        } description: {
            Text("可以调整窗口大小或始终置顶，未保存的修改会保留为本机草稿。")
        } actions: {
            Button("打开编辑窗口", action: open)
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            open()
        }
    }

    private func open() {
        if let session, !session.isFinished { session.show(); return }
        let record = session?.savedRecordID.flatMap { id in model.activeRecords.first { $0.id == id } } ?? existing
        session = NoteEditorWindows.shared.open(model: model, existing: record, project: project, group: group)
    }
}
#else
typealias DocumentEditor = DocumentEditorContent
#endif
