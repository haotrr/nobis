#if os(macOS)
import AppKit
import SwiftUI
import Testing
import FamilyDomain
import FamilyCore
import MDTextKit
import MDTextKitUI
@testable import NobisUI

@MainActor @Suite(.serialized)
struct NoteEditorWindowTests {
    private func settle(_ session: NoteEditorWindow) async throws {
        session.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        session.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func waitForDraft(_ store: DocumentDraftStore, key: UUID, matching: (String) -> Bool) async throws {
        for _ in 0..<100 {
            if let draft = try store.read(key), matching(draft.body.notes) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("草稿未在期限内完成后台写入")
    }

    private func editor(in view: NSView?) -> MDTextView? {
        guard let view else { return nil }
        if let text = view as? MDTextView { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @Test func reopeningAndResizingKeepDraftUndoAndSave() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "窗口验证", familyName: "隔离", partnerName: "", demo: false)
        let space = try #require(model.selectedSpaceID)
        var body = RecordBody(kind: .document, title: "窗口测试")
        body.notes = "- [ ] 中文任务\n\n原文"
        try model.save(body, spaceID: space)
        let record = try #require(model.activeRecords.first { $0.body.kind == .document })
        let windows = NoteEditorWindows()
        let session = windows.open(model: model, existing: record)
        defer { session.finish() }
        try await settle(session)
        let text = try #require(editor(in: session.window.contentView))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        NobisMDTextView.apply("toggle", to: text)
        try await settle(session)
        try await waitForDraft(model.draftStore, key: record.id) { $0.contains("- [x]") }
        #expect(try model.draftStore.read(record.id)?.body.notes.contains("- [x]") == true)
        let reopened = windows.open(model: model, existing: record)
        #expect(reopened === session)
        #expect(editor(in: reopened.window.contentView) === text)
        session.alwaysOnTop = true
        #expect(session.window.level == .floating)
        session.window.setContentSize(NSSize(width: 440, height: 430))
        try await settle(session)
        #expect(editor(in: session.window.contentView) === text)
        text.editorUndoManager.undo()
        #expect(text.markdown == body.notes)
        text.editorUndoManager.redo()
        #expect(text.markdown.contains("- [x]"))
        session.alwaysOnTop = false
        #expect(session.window.level == .normal)
        session.window.saveNote?()
        try await settle(session)
        #expect(try model.core?.record(record.id, spaceID: space).body.notes == text.markdown)
        #expect(try model.draftStore.read(record.id) == nil)
        // Saving must not replace the live text view or clear its native undo history.
        text.editorUndoManager.undo()
        try await settle(session)
        #expect(text.markdown == body.notes)
        try await waitForDraft(model.draftStore, key: record.id) { $0 == body.notes }
        #expect(try model.draftStore.read(record.id)?.body.notes == body.notes)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle(session)
        let marked = text.markedRange()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            session.window.appearance = NSAppearance(named: appearance)
            session.window.setContentSize(NSSize(width: 440, height: 500))
            session.alwaysOnTop.toggle()
            try await settle(session)
            #expect(text.hasMarkedText())
            #expect(text.markedRange() == marked)
        }
        session.window.saveNote?()
        #expect(!session.windowShouldClose(session.window))
        try await settle(session)
        #expect(text.hasMarkedText())
        #expect(!session.isFinished)
        #expect(try model.draftStore.read(record.id)?.body.notes == body.notes)
    }

    @Test func newlySavedNoteAdoptsWindowIdentity() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "窗口验证", familyName: "隔离", partnerName: "", demo: false)
        let space = try #require(model.selectedSpaceID)
        var body = RecordBody(kind: .document, title: "新建草稿")
        body.notes = "恢复的中文正文"
        let id = UUID()
        try model.draftStore.save(DocumentDraft(body: body, spaceID: space, recordID: id, expected: []), key: space)
        let windows = NoteEditorWindows()
        let session = windows.open(model: model)
        defer { session.finish() }
        try await settle(session)
        session.window.saveNote?()
        try await settle(session)
        let saved = try #require(model.activeRecords.first { $0.id == id })
        #expect(saved.body.notes == body.notes)
        #expect(windows.open(model: model, existing: saved) === session)
        #expect(try model.draftStore.read(space) == nil)
        let next = windows.open(model: model)
        defer { next.finish() }
        #expect(next !== session)
    }

    @Test func defaultsToInlineAndDetachesWithoutReplacingEditor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "内嵌验证", familyName: "隔离", partnerName: "", demo: false)
        let space = try #require(model.selectedSpaceID)
        var body = RecordBody(kind: .document, title: "默认内嵌")
        body.notes = "- [ ] 中文任务"
        try model.save(body, spaceID: space)
        let record = try #require(model.activeRecords.first { $0.body.kind == .document })
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentView = NSHostingView(rootView: DocumentEditor(model: model, existing: record, embedded: true))
        main.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let session = NoteEditorWindows.shared.acquire(model: model, existing: record)
        defer { session.finish(); main.contentView = nil; main.close() }
        try await settle(session)
        #expect(!session.isDetached)
        #expect(!session.window.isVisible)
        let text = try #require(editor(in: main.contentView))
        main.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        NobisMDTextView.apply("toggle", to: text)
        try await settle(session)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        let typingKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: main.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        text.keyDown(with: typingKey)
        try await settle(session)
        #expect(text.editorUndoManager.canUndo)
        let before = try #require(try model.draftStore.read(record.id))
        main.makeFirstResponder(main.contentView)
        session.show()
        try await settle(session)
        #expect(session.isDetached)
        #expect(editor(in: session.window.contentView) === text)
        #expect(editor(in: main.contentView) == nil)
        #expect(session.window.firstResponder === text)
        #expect(try model.draftStore.read(record.id)?.body == before.body)
        let undoKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: session.window.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        #expect(session.window.performKeyEquivalent(with: undoKey))
        #expect(!text.markdown.hasSuffix("x"))
        text.editorUndoManager.undo()
        #expect(text.markdown == body.notes)
        text.editorUndoManager.redo()
        text.editorUndoManager.redo()
        #expect(text.markdown.contains("- [x]"))
        session.window.saveNote?()
        try await settle(session)
        #expect(try model.core?.record(record.id, spaceID: space).body.notes == text.markdown)
    }

    @Test func graphRecreationKeepsBodySelectionUndoAndSaveIdentity() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "窗口验证", familyName: "隔离", partnerName: "", demo: false)
        let space = try #require(model.selectedSpaceID)
        let state = DocumentEditorState(model: model, existing: nil, project: nil, group: "分组")
        state.value.title = "重建测试"
        state.value.notes = "中文正文"
        let runtime = NoteEditorRuntime()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var save: (() -> Void)?
        func mount() {
            window.contentViewController = nil
            window.contentViewController = NSHostingController(rootView:
                DocumentEditorContent(model: model, retainedState: state, embedded: true,
                    onReady: { _, action in save = action }).environment(\.noteEditorRuntime, runtime))
            window.makeKeyAndOrderFront(nil)
        }
        defer { runtime.stop(); window.close() }
        mount()
        try await Task.sleep(for: .milliseconds(200))
        let text = try #require(editor(in: window.contentView))
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        window.makeFirstResponder(text)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        text.keyDown(with: key)
        try await Task.sleep(for: .milliseconds(200))
        let edited = text.markdown
        let selection = text.selectedRange()
        #expect(edited.hasSuffix("x"))
        mount()
        try await Task.sleep(for: .milliseconds(200))
        #expect(editor(in: window.contentView) === text)
        #expect(text.selectedRange() == selection)
        #expect(text.markdown == edited)
        text.editorUndoManager.undo()
        #expect(text.markdown == "中文正文")
        text.editorUndoManager.redo()
        #expect(text.markdown == edited)
        save?()
        try await Task.sleep(for: .milliseconds(200))
        let id = try #require(state.existing?.id)
        mount()
        try await Task.sleep(for: .milliseconds(200))
        text.editorUndoManager.undo()
        try await Task.sleep(for: .milliseconds(200))
        save?()
        try await Task.sleep(for: .milliseconds(200))
        #expect(state.existing?.id == id)
        #expect(model.activeRecords.filter { $0.body.kind == .document }.count == 1)
        #expect(try model.core?.record(id, spaceID: space).body.notes == "中文正文")
        #expect(state.value.noteGroup == "分组")
    }

    @Test func cleanCloseReleasesOwnership() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        let windows = NoteEditorWindows()
        let first = windows.open(model: model)
        try await settle(first)
        #expect(!first.windowShouldClose(first.window))
        #expect(first.isFinished)
        let second = windows.open(model: model)
        defer { second.finish() }
        #expect(first !== second)
    }
}
#endif
