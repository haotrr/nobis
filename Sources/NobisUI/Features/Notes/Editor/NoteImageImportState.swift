import Foundation
import FamilyCore

/// A cancelled task may finish after a new import has started.
struct NoteImageImportState {
    private(set) var active: UUID?
    var isLoading: Bool { active != nil }
    mutating func begin() -> UUID {
        let id = UUID(); active = id; return id
    }
    func accepts(_ id: UUID) -> Bool { active == id }
    mutating func finish(_ id: UUID) { if accepts(id) { active = nil } }
    mutating func cancel() { active = nil }
}

extension DocumentBlockBuffer {
    func insertPhoto(address: String, source: String, at selection: NoteEditorFocus?) throws {
        guard blocks.map(\.markdown).joined() == source else { throw NotePhotoInsertionError.changed }
        guard NoteEmbeddedImage.data(address) != nil else { throw NoteEmbeddedImage.ImportError.invalid }
        let content = DocumentBlock.Content.image(alt: "照片", address: address, title: "")
        try DocumentContentLimits.validate(source + "\n" + DocumentBlock(content).markdown)
        focus = selection
        insert(content)
    }
}

private enum NotePhotoInsertionError: LocalizedError {
    case changed
    var errorDescription: String? { "读取照片期间正文已变化，请重新选择照片。现有内容已保留。" }
}
