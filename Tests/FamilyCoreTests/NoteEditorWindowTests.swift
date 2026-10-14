#if os(macOS)
import AppKit
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
