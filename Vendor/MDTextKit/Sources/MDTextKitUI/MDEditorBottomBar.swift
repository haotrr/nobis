import AppKit

/// Native floating format toolbar (bottom-right of the editor): a vibrancy-backed pill of bordered
/// symbol buttons wired to the editor's format actions.
@MainActor public final class MDEditorBottomBar: NSVisualEffectView {
    public struct Item {
        public let symbol: String
        public let tooltip: String
        public let action: Selector
        public let menu: NSMenu?
        public init(_ symbol: String, _ tooltip: String, _ action: Selector, menu: NSMenu? = nil) {
            self.symbol = symbol; self.tooltip = tooltip; self.action = action; self.menu = menu
        }
    }

    public private(set) var buttons: [NSButton] = []
    private let stack = NSStackView()

    public init(items: [Item], target: AnyObject) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for item in items {
            let b: NSButton
            if let menu = item.menu {
                let pop = NSPopUpButton(frame: .zero, pullsDown: true)
                pop.menu = menu
                let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                title.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)
                menu.insertItem(title, at: 0)
                pop.bezelStyle = .texturedRounded
                pop.toolTip = item.tooltip
                b = pop
            } else {
                b = NSButton(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)!, target: target, action: item.action)
                b.bezelStyle = .texturedRounded
                b.toolTip = item.tooltip
            }
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            stack.addArrangedSubview(b)
            buttons.append(b)
        }
    }

    public required init?(coder: NSCoder) { fatalError() }

    public var fittingWidth: CGFloat { stack.fittingSize.width }

    /// The bar floats over the editor: wheel events must keep scrolling the note underneath.
    public override func scrollWheel(with event: NSEvent) {
        if let scroll = superview?.subviews.compactMap({ $0 as? NSScrollView }).first { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
