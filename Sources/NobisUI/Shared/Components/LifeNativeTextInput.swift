#if os(iOS)
import SwiftUI
import UIKit

/// Plain form input with an owned text storage so IME appearance can change in place.
struct LifeNativeTextInput: UIViewRepresentable {
    let title: String
    @Binding var text: String
    let multiline: Bool
    let compact: Bool
    @Binding var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.markedTextStyle = [.foregroundColor: UIColor.label]
        view.typingAttributes[.foregroundColor] = UIColor.label
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 5
        view.layer.borderWidth = 0.5
        view.textContainerInset = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
        view.accessibilityLabel = title
        view.placeholder.text = title
        view.text = text
        return view
    }
    func updateUIView(_ view: InputView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = enabled
        view.isSelectable = enabled
        view.multiline = multiline
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        // Never overwrite marked text or reset the selection on a SwiftUI update.
        if view.markedTextRange == nil, view.text != text { view.text = text }
        view.typingAttributes[.foregroundColor] = UIColor.label
        view.placeholder.isHidden = !view.text.isEmpty
        view.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        view.refreshAppearance()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: InputView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let line = view.font?.lineHeight ?? 22
        let minimum = multiline && !compact ? 3 : 1
        let maximum = multiline && !compact ? 8 : 1
        let height = maximum == 1 ? line + 14 : view.attributedText.boundingRect(with: CGSize(width: max(1, width - 18), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height + 14
        return CGSize(width: width, height: max(CGFloat(minimum) * line + 14, min(CGFloat(maximum) * line + 14, height)))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LifeNativeTextInput
        init(_ parent: LifeNativeTextInput) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) {
            DispatchQueue.main.async { [weak view, self] in parent.focused = view?.isFirstResponder ?? false }
        }
        func textViewDidEndEditing(_ view: UITextView) {
            DispatchQueue.main.async { [weak view, self] in
                guard let view else { return }
                parent.focused = view.isFirstResponder
                textViewDidChange(view)
            }
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            DispatchQueue.main.async { [weak view] in (view as? InputView)?.revealCaret() }
        }
        func textViewDidChange(_ view: UITextView) {
            (view as? InputView)?.placeholder.isHidden = !view.text.isEmpty
            parent.text = view.text
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            parent.multiline || text != "\n"
        }
    }
    final class InputView: UITextView {
        let placeholder = UILabel()
        var multiline = false
        private var lastStyle: UIUserInterfaceStyle?
        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholder.textColor = .placeholderText
            placeholder.isUserInteractionEnabled = false
            addSubview(placeholder)
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: InputView, _: UITraitCollection) in
                view.refreshAppearance()
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            textContainer.widthTracksTextView = multiline
            if !multiline {
                let textWidth = (text as NSString).size(withAttributes: [.font: font ?? UIFont.preferredFont(forTextStyle: .body)]).width
                let width = max(bounds.width - textContainerInset.left - textContainerInset.right,
                                textWidth + 2 * textContainer.lineFragmentPadding + 2)
                if textContainer.size.width != width { textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude) }
            }
            super.layoutSubviews()
            placeholder.font = font
            placeholder.frame = CGRect(x: textContainerInset.left + textContainer.lineFragmentPadding,
                                       y: textContainerInset.top, width: max(0, bounds.width - 18), height: font?.lineHeight ?? 22)
            if !multiline { contentSize.width = max(bounds.width, textContainer.size.width + textContainerInset.left + textContainerInset.right) }
            revealCaret()
        }
        func revealCaret() {
            guard isFirstResponder, let selection = selectedTextRange else { return }
            scrollRectToVisible(caretRect(for: selection.end).insetBy(dx: -8, dy: -4), animated: false)
        }
        func refreshAppearance() {
            layer.borderColor = UIColor.separator.cgColor
            let style = traitCollection.userInterfaceStyle
            guard lastStyle != style else { return }
            lastStyle = style
            // UIKit updates composition styling during its trait pass; apply after that pass.
            DispatchQueue.main.async { [weak self] in self?.applyTextAppearance(style: style) }
        }
        private func applyTextAppearance(style: UIUserInterfaceStyle) {
            guard lastStyle == style else { return }
            let range = NSRange(location: 0, length: textStorage.length)
            let color = UIColor.label
            var markedStyle = markedTextStyle ?? [:]
            markedStyle[.foregroundColor] = color
            markedTextStyle = markedStyle
            // This is plain text: recolor existing and marked runs without changing any characters.
            // Attribute-only mutation preserves the input method's marked range and candidates.
            textStorage.addAttribute(.foregroundColor, value: color, range: range)
            typingAttributes[.foregroundColor] = color
            if let layout = textLayoutManager, let document = layout.textContentManager?.documentRange {
                layout.invalidateLayout(for: document)
                layout.ensureLayout(for: document)
                layout.addRenderingAttribute(.foregroundColor, value: color, for: document)
            }
            func redraw(_ view: UIView) {
                view.setNeedsDisplay()
                for child in view.subviews { redraw(child) }
            }
            redraw(self)
            setNeedsLayout()

        }
    }
}
#endif
