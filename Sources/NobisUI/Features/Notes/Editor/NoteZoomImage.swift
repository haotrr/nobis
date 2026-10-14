import SwiftUI

struct NoteImageZoomCommand: Equatable {
    let id = UUID()
    var factor: CGFloat? = nil
}

struct NoteZoomImage: View {
    let data: Data
    let label: String
    @State private var command = NoteImageZoomCommand()
    var body: some View {
        VStack(spacing: 8) {
            NoteZoomViewport(data: data, label: label, command: command)
                .frame(height: 300).clipped()
            HStack {
                Button { command = NoteImageZoomCommand(factor: 0.5) } label: { NoteToolbarLabel(symbol: "minus.magnifyingglass") }.accessibilityLabel("缩小")
                Button { command = NoteImageZoomCommand(factor: 2) } label: { NoteToolbarLabel(symbol: "plus.magnifyingglass") }.accessibilityLabel("放大")
                Button { command = NoteImageZoomCommand() } label: { NoteToolbarLabel(title: "适合窗口") }
            }.noteToolbarControls()
        }
    }
}

#if os(iOS)
import UIKit
struct NoteZoomViewport: UIViewRepresentable {
    let data: Data
    let label: String
    let command: NoteImageZoomCommand
    func makeUIView(context: Context) -> NoteImageScrollView { NoteImageScrollView() }
    func updateUIView(_ view: NoteImageScrollView, context: Context) {
        view.picture.accessibilityLabel = label
        if view.source != data { view.source = data; view.picture.image = UIImage(data: data); view.resetLayout() }
        if view.lastCommand != command.id {
            view.lastCommand = command.id
            view.setZoomScale(command.factor.map { min(6, max(1, view.zoomScale * $0)) } ?? 1, animated: false)
        }
    }
}

final class NoteImageScrollView: UIScrollView, UIScrollViewDelegate {
    let picture = UIImageView()
    var source: Data?
    var lastCommand: UUID?
    private var viewport = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 6
        bouncesZoom = true; backgroundColor = .secondarySystemBackground
        picture.contentMode = .scaleAspectFit; picture.isAccessibilityElement = true
        addSubview(picture)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }
    func resetLayout() { viewport = .zero; setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        if viewport != bounds.size {
            viewport = bounds.size
            setZoomScale(1, animated: false)
            picture.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    @objc private func doubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let point = recognizer.location(in: picture)
            let size = CGSize(width: bounds.width / 2, height: bounds.height / 2)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
#else
import AppKit
struct NoteZoomViewport: NSViewRepresentable {
    let data: Data
    let label: String
    let command: NoteImageZoomCommand
    func makeNSView(context: Context) -> NoteImageScrollView { NoteImageScrollView() }
    func updateNSView(_ view: NoteImageScrollView, context: Context) {
        view.picture.setAccessibilityLabel(label)
        if view.source != data { view.source = data; view.picture.image = NSImage(data: data); view.resetLayout() }
        if view.lastCommand != command.id {
            view.lastCommand = command.id
            view.magnification = command.factor.map { min(6, max(1, view.magnification * $0)) } ?? 1
        }
    }
}
final class NoteImageScrollView: NSScrollView {
    let picture = NSImageView()
    var source: Data?
    var lastCommand: UUID?
    private var viewport = CGSize.zero
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = true; minMagnification = 1; maxMagnification = 6
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        documentView = picture
    }
    required init?(coder: NSCoder) { fatalError() }
    func resetLayout() { viewport = .zero; needsLayout = true }
    override func layout() {
        super.layout()
        if viewport != frame.size {
            viewport = frame.size; magnification = 1
            picture.frame = CGRect(origin: .zero, size: contentSize)
        }
    }
}
#endif
