import SwiftUI
import UniformTypeIdentifiers
import FamilyDomain
import FamilyCore

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText, .plainText] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= DocumentContentLimits.maximumFileBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw NobisError.validation("请选择不超过 20,000 字的 UTF-8 Markdown 文档。")
        }
        try DocumentContentLimits.validate(text)
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
