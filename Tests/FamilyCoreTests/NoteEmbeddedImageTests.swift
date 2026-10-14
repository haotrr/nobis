#if os(macOS)
import AppKit
import Testing
import FamilyCore
import FamilyDomain
import FamilyPersistence
import MDTextKit
@testable import NobisUI

@MainActor @Suite struct NoteEmbeddedImageTests {
    @Test func photoSurvivesDraftDatabaseBackupAndMarkdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.tiff")
        let image = NSImage(size: NSSize(width: 2400, height: 1200), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        try #require(image.tiffRepresentation).write(to: file)
        let address = try NoteEmbeddedImage.importFile(file)
        let data = try #require(NoteEmbeddedImage.data(address))
        #expect(data.count <= NoteEmbeddedImage.maximumBytes)
        let rendered = try #require(NSImage(data: data)?.representations.first)
        #expect(rendered.pixelsWide == 1600)
        #expect(rendered.pixelsHigh == 800)
        let buffer = DocumentBlockBuffer("之前😀之后")
        buffer.focus = NoteEditorFocus(target: buffer.blocks[0].id.uuidString, range: NSRange(location: 4, length: 0))
        try buffer.insertPhoto(address: address, source: "之前😀之后", at: buffer.focus)
        let markdown = buffer.blocks.map(\.markdown).joined()
        #expect(markdown.hasPrefix("之前😀\n![照片]"))
        #expect(markdown.hasSuffix("之后"))
        #expect(DocumentBlocks.parse(markdown).map(\.markdown).joined() == markdown)
        buffer.undo.undo()
        #expect(buffer.blocks.map(\.markdown).joined() == "之前😀之后")
        buffer.undo.redo()
        #expect(buffer.blocks.map(\.markdown).joined() == markdown)
        let fixture = Fixture()
        var body = RecordBody(kind: .document, title: "相册图片")
        body.notes = markdown
        let drafts = DocumentDraftStore(directory: directory.appendingPathComponent("drafts"))
        let key = UUID()
        try drafts.save(DocumentDraft(body: body, spaceID: fixture.family.id, recordID: nil, expected: []), key: key)
        #expect(try DocumentDraftStore(directory: drafts.directory).read(key)?.body.notes == markdown)
        let store = directory.appendingPathComponent("store")
        let repository = try CoreDataRepository(directory: store, initialSpaces: [fixture.family])
        let core = FamilyCore(repository: repository, session: AccessSession(memberID: fixture.a.id, allowedSpaceIDs: [fixture.family.id]))
        try core.save(body, spaceID: fixture.family.id)
        let reopened = try CoreDataRepository(directory: store).load()
        let restored = try Backup.decode(Backup.encode(reopened))
        #expect(restored.revisions.first?.body.notes == markdown)
        let coordinator = MDTextKitEditor.Coordinator(text: .constant(markdown))
        defer { coordinator.stop() }
        coordinator.update(MDTextKitEditor(text: .constant(markdown), loadImages: false))
        var displayed = false
        coordinator.view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: coordinator.view.textStorage!.length)) { item, _, _ in
            if let image = item as? MDImageTextAttachment { displayed = image.temporaryImage != nil }
        }
        #expect(displayed)
    }
    @Test func contentLimitsKeepProseAndImageBudgetsSeparate() throws {
        try DocumentContentLimits.validate(String(repeating: "文", count: 20_000))
        #expect(throws: (any Error).self) { try DocumentContentLimits.validate(String(repeating: "文", count: 20_001)) }
        var bytes = Data([0xff, 0xd8, 0xff])
        bytes.append(Data(repeating: 0, count: DocumentContentLimits.maximumImageBytes))
        let over = "![照片](<" + NoteEmbeddedImage.prefix + bytes.base64EncodedString() + ">)"
        #expect(throws: (any Error).self) { try DocumentContentLimits.validate(over) }
        #expect(throws: (any Error).self) { try DocumentContentLimits.validate("![照片](<data:image/jpeg;base64,aGVsbG8=>)") }
    }
    @Test func invalidImagesAreRejected() throws {
        #expect(NoteEmbeddedImage.data(NoteEmbeddedImage.prefix + "invalid") == nil)
        #expect(NoteEmbeddedImage.data("file:///etc/passwd") == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not an image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try NoteEmbeddedImage.importFile(file) }
    }
}
#endif
