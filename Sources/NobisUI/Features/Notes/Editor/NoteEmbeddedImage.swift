import Foundation
import FamilyCore
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// Self-contained Markdown images follow the existing draft, revision and backup lifecycle.
enum NoteEmbeddedImage {
    static let prefix = "data:image/jpeg;base64,"
    static let maximumBytes = DocumentContentLimits.maximumImageBytes
    static func data(_ rawAddress: String) -> Data? {
        let address = rawAddress.hasPrefix("<") && rawAddress.hasSuffix(">") ? String(rawAddress.dropFirst().dropLast()) : rawAddress
        guard address.hasPrefix(prefix), address.utf8.count <= prefix.utf8.count + (maximumBytes + 2) / 3 * 4,
              let data = Data(base64Encoded: String(address.dropFirst(prefix.count))), data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1600, height <= 1600 else { return nil }
        return data
    }
    static func importFile(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ImportError.invalid }
        for size in [1600, 1200, 800] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImportError.invalid }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImportError.invalid }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImportError.invalid }
            if data.length <= maximumBytes { return prefix + (data as Data).base64EncodedString() }
        }
        throw ImportError.tooLarge
    }
    enum ImportError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: "无法读取这张照片，请选择其他图片。"
            case .tooLarge: "图片内容过大，请选择较小的图片。"
            }
        }
    }
}

struct NoteEmbeddedImageView: View {
    let address: String
    let label: String
    @State private var image: Image?
    @State private var failed = false
    var body: some View {
        NoteImageViewport(phase: image.map(AsyncImagePhase.success) ?? (failed ? .failure(NoteEmbeddedImage.ImportError.invalid) : .empty), label: label)
            .task(id: address) {
                image = nil; failed = false
                let data = await Task.detached(priority: .userInitiated) { NoteEmbeddedImage.data(address) }.value
                guard !Task.isCancelled else { return }
                #if os(iOS)
                image = data.flatMap(UIImage.init(data:)).map { Image(uiImage: $0) }
                #else
                image = data.flatMap(NSImage.init(data:)).map { Image(nsImage: $0) }
                #endif
                failed = image == nil
            }
    }
}
