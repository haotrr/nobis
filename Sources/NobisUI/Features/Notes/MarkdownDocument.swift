import SwiftUI
import UniformTypeIdentifiers
import FamilyDomain

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText, .plainText] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 200_000,
              let text = String(data: data, encoding: .utf8), text.count <= 20_000 else {
            throw NobisError.validation("请选择不超过 20,000 字的 UTF-8 Markdown 文档。")
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
