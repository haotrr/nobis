import SwiftUI

struct QuoteSelectionSheet: View {
    let source: String
    var embedded = false
    var onCancel: (() -> Void)? = nil
    let onSelect: (String) -> Void
    @State private var selection = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选取要讨论的原文").font(.headline)
            Text("选中文字后，点“引用评注”。最多 2,000 字。").font(.callout).foregroundStyle(.secondary)
            SelectableSource(source: source, selection: $selection)
                .padding(12).lifeCard().frame(minHeight: 240).accessibilityLabel("可选取的文档原文")
            HStack {
                Button("取消") { if let onCancel { onCancel() } else { dismiss() } }
                Spacer()
                Text("已选 \(selection.count) 字").font(.caption).foregroundStyle(.secondary)
                Button("引用评注") { onSelect(selection) }.disabled(selection.isEmpty || selection.count > 2_000).keyboardShortcut(.defaultAction)
            }
        }.padding(embedded ? 0 : 24).background { if !embedded { LifeBackground() } }.editorDimensions(width: 620, height: 480, embedded: embedded)
    }
}

#if os(macOS)
import AppKit
private struct SelectableSource: NSViewRepresentable {
    let source: String
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false; view.isSelectable = true; view.font = .preferredFont(forTextStyle: .body)
        view.string = source; view.delegate = context.coordinator; view.textContainerInset = NSSize(width: 8, height: 8)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            selection.wrappedValue = (view.string as NSString).substring(with: range)
        }
    }
}
#else
import UIKit
private struct SelectableSource: UIViewRepresentable {
    let source: String
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.text = source; view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
    final class Coordinator: NSObject, UITextViewDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        func textViewDidChangeSelection(_ view: UITextView) {
            selection.wrappedValue = (view.text as NSString).substring(with: view.selectedRange)
        }
    }
}
#endif
