import SwiftUI

/// A stable canvas keeps surrounding text still as remote image phases change.
/// Images fit inside it without cropping; its dimensions depend only on available width.
struct NoteImageViewport: View {
    var phase: AsyncImagePhase
    var label: String
    var body: some View {
        NoteImageCanvas {
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit().accessibilityLabel(label)
            case .failure:
                Label("图片暂时无法加载", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary).padding(12)
            default:
                ProgressView("正在加载图片").padding(12)
            }
        }
    }
}

struct NoteImageCanvas<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        Color.clear.aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: 560)
            .overlay { content() }
            .frame(maxWidth: .infinity)
    }
}
