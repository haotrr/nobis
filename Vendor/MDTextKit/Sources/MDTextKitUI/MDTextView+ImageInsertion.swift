import AppKit
import MDTextKit

extension MDEditorController {
    /// Serialize an image destination without exposing host-specific file storage policy.
    public static func markdownImage(alt: String, address: String) -> String {
        let label = alt.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
            .components(separatedBy: .newlines).joined(separator: " ")
        let destination = address.replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
            .components(separatedBy: .newlines).joined()
        return "![" + label + "](<" + destination + ">)"
    }
}

extension MDTextView {
    /// Insert after the selection, preserving selected prose and the native undo history.
    /// Hosts resolve and persist image data before calling this operation.
    public func insertMarkdownImage(alt: String, address: String) {
        guard isEditable, !hasMarkedText() else { return }
        let source = string as NSString
        let location = NSMaxRange(selectedRange())
        guard location <= source.length else { return }
        let prefix = location > 0 && source.character(at: location - 1) != 10 ? "\n" : ""
        let suffix = location < source.length && source.character(at: location) == 10 ? "" : "\n"
        let markdown = prefix + MDEditorController.markdownImage(alt: alt, address: address) + suffix
        breakUndoCoalescing()
        editorController.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: markdown), in: self)
        editorController.notifyTextChanges(in: self)
    }
}
