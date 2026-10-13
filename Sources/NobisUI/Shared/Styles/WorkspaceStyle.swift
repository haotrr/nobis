import SwiftUI
import FamilyDomain
import FamilyCore

/// Small, mutually exclusive choices stay visible instead of opening a menu.
struct DirectSelection<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    var showsTitle = true
    let label: (Value) -> String
    @Environment(\.colorScheme) private var scheme
    private var selectionColor: Color { scheme == .dark ? Color(red: 0.65, green: 0.82, blue: 0.73) : Color(red: 0.24, green: 0.43, blue: 0.36) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle { Text(title).font(.callout).foregroundStyle(.secondary) }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        Button { selection = option } label: {
                            HStack {
                                Text(label(option)).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: selection == option ? "checkmark.circle.fill" : "circle")
                                    .accessibilityHidden(true)
                            }.padding(.horizontal, 12).padding(.vertical, 8)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == option ? selectionColor : Color.primary)
                        .background(selection == option ? selectionColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityAddTraits(selection == option ? [.isSelected] : [])
                    }
                }
            } else {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in Text(label(option)).tag(option) }
                }.pickerStyle(.segmented).labelsHidden()
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct VisibilityControl: View {
    @Binding var scope: LifeScope
    var inlineOnly = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if inlineOnly { inlineControl }
            else {
                ViewThatFits(in: .horizontal) {
                    if !dynamicTypeSize.isAccessibilitySize { inlineControl }
                    selection(showsTitle: true)
                }
            }
        }.accessibilityValue(scope.title)
    }
    private var inlineControl: some View {
        HStack(spacing: 12) {
            Text("可见范围").font(.callout).foregroundStyle(.secondary).fixedSize()
            selection(showsTitle: false).frame(width: 240)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func selection(showsTitle: Bool) -> some View {
        DirectSelection(title: "可见范围", selection: $scope, options: LifeScope.allCases, showsTitle: showsTitle) { value in
            value == .all ? "全部" : value.title
        }
    }
}

/// Short screens and accessibility text keep controls in the content scroll flow.
struct WorkspaceScopeHeader: View {
    @Binding var scope: LifeScope
    var showArchived: Binding<Bool>?
    var scrolling = true
    var archivedTitle = "显示已完成与归档"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var needsScrolling: Bool {
        #if os(iOS)
        dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact
        #else
        dynamicTypeSize.isAccessibilitySize
        #endif
    }

    var body: some View {
        if scrolling == needsScrolling {
            ViewThatFits(in: .horizontal) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 24) {
                        if let showArchived { ArchivedRecordsToggle(isOn: showArchived, title: archivedTitle).fixedSize() }
                        Spacer(minLength: 0)
                        VisibilityControl(scope: $scope, inlineOnly: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    VisibilityControl(scope: $scope).frame(maxWidth: .infinity, alignment: .trailing)
                    if let showArchived { ArchivedRecordsToggle(isOn: showArchived, title: archivedTitle) }
                }
            }
            .padding(.horizontal, scrolling ? 0 : 24).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background { if !scrolling { NobisSurface.canvas } }
            .overlay(alignment: .bottom) { if !scrolling { Divider().opacity(0.5) } }
        }
    }
}

private struct WorkspaceScopeBar: ViewModifier {
    @Binding var scope: LifeScope
    var showArchived: Binding<Bool>?
    var archivedTitle: String
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            WorkspaceScopeHeader(scope: $scope, showArchived: showArchived, scrolling: false, archivedTitle: archivedTitle)
        }
    }
}

extension View {
    func workspaceScope(_ scope: Binding<LifeScope>, showArchived: Binding<Bool>? = nil, archivedTitle: String = "显示已完成与归档") -> some View {
        modifier(WorkspaceScopeBar(scope: scope, showArchived: showArchived, archivedTitle: archivedTitle))
    }

    @ViewBuilder func editorDimensions(width: CGFloat = 560, height: CGFloat = 520, embedded: Bool = false) -> some View {
        #if os(macOS)
        if embedded { self } else { frame(minWidth: 350, idealWidth: width, minHeight: height) }
        #else
        self
        #endif
    }

    @ViewBuilder func touchTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        #endif
    }
}

struct InlineIssue: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("操作未完成：\(message)")
    }
}

struct WorkspaceCreateAction: ToolbarContent {
    let title: String
    let action: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: action) { Label(title, systemImage: "plus") }.help(title)
        }
    }
}

struct WorkspaceEmptyState: View {
    let title: String
    let icon: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action).nobisGlassButton(prominent: true)
        }
    }
}

struct ArchivedRecordsToggle: View {
    @Binding var isOn: Bool
    var title = "显示已完成与归档"
    var body: some View {
        Toggle(title, isOn: $isOn).font(.callout)
    }
}

/// Write permissions are separate from the read-only scope filter.
struct RecordVisibilityField: View {
    let model: AppModel
    @Binding var spaceID: UUID?
    var editable: Bool
    var inherited = false
    var body: some View {
        if editable {
            LabeledContent("可见性") {
                DirectSelection(title: "可见性", selection: $spaceID,
                options: [model.workspace.commonID, model.workspace.personalID].compactMap { $0 }.map { Optional($0) }, showsTitle: false) { id in
                    model.spaces.first { $0.id == id }.map { space in
                        space.kind == .personal ? (space.members.first { $0.id == space.ownerID }?.name ?? space.name) : space.name
                    } ?? "不可用"
                }.disabled(inherited)
            }
        }
        if let spaceID {
            ResourceOwnership(model: model, spaceID: spaceID, detailed: true)
        }
        if inherited { Text("可见性继承关联记录。").font(.caption).foregroundStyle(.secondary) }
        else if !editable { Text("分享请从详情操作。").font(.caption).foregroundStyle(.secondary) }
    }
}

struct EditorHeading: View {
    let kind: RecordKind
    let editing: Bool
    var body: some View {
        LifeSheetHeading(title: (editing ? "编辑" : "新建") + kind.title, icon: kind.icon)
    }
}

/// The shared, quiet canvas used by the five everyday workspaces.
struct LifeBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark
            ? [Color(red: 0.12, green: 0.18, blue: 0.21), Color(red: 0.16, green: 0.18, blue: 0.17), Color(red: 0.23, green: 0.19, blue: 0.16)]
            : [Color(red: 0.80, green: 0.88, blue: 0.92), Color(red: 0.91, green: 0.93, blue: 0.91), Color(red: 0.98, green: 0.89, blue: 0.79)],
            startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}

private struct LifeCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background(NobisSurface.card.opacity(reduceTransparency || contrast == .increased ? 1 : scheme == .dark ? 0.94 : 0.83), in: RoundedRectangle(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(contrast == .increased ? Color.primary.opacity(0.45) : Color.white.opacity(scheme == .dark ? 0.10 : 0.65), lineWidth: 1) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.08 : 0.025), radius: 16, y: 6)
    }
}

extension View {
    func lifeCard() -> some View { modifier(LifeCardSurface()) }
}

struct LifePage<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }.frame(maxWidth: 980).padding(geometry.size.width < 560 ? 16 : 24).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
            .environment(\.lifeCompact, geometry.size.width < 560)
        }.background { LifeBackground() }
            .lifeInlineNavigationTitle()
            .tint(scheme == .dark ? Color(red: 0.65, green: 0.82, blue: 0.73) : Color(red: 0.24, green: 0.43, blue: 0.36))
    }
}

struct LifeSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    @Environment(\.lifeCompact) private var compact
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.tint).accessibilityAddTraits(.isHeader)
            content
        }.padding(compact ? 16 : 24).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
            .labeledContentStyle(LifeDetailLabelStyle())
    }
}

struct LifeScopeControls: View {
    @Binding var scope: LifeScope
    var archived: Binding<Bool>?
    var archivedTitle = "显示已完成与归档"
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                VisibilityControl(scope: $scope)
                Spacer(minLength: 12)
                if let archived { ArchivedRecordsToggle(isOn: archived, title: archivedTitle) }
            }
            VStack(alignment: .leading, spacing: 12) {
                VisibilityControl(scope: $scope)
                if let archived { ArchivedRecordsToggle(isOn: archived, title: archivedTitle) }
            }
        }.padding(.vertical, 4)
    }
}

/// Track the active input so rotation can keep it above the keyboard.
private struct LifeFocusedFieldKey: PreferenceKey {
    static let defaultValue: UUID? = nil
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        value = nextValue() ?? value
    }
}

/// Detail pages keep content near the top and share the workspace canvas.
struct LifeDetail<Content: View>: View {
    @State private var focusedField: UUID?
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { geometry in
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(geometry.size.width < 560 ? 12 : 20).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
            .environment(\.lifeCompact, geometry.size.width < 560)
            .onPreferenceChange(LifeFocusedFieldKey.self) {
                focusedField = $0
                DispatchQueue.main.async { if let focusedField { proxy.scrollTo(focusedField, anchor: .center) } }
            }
            .onChange(of: geometry.size) { _, _ in
                // Scroll only after the rotation/keyboard layout has settled.
                DispatchQueue.main.async {
                    if let focusedField { proxy.scrollTo(focusedField, anchor: .center) }
                }
            }
        }
        }.background { LifeBackground() }
            .lifeInlineNavigationTitle()
            .tint(scheme == .dark ? Color(red: 0.65, green: 0.82, blue: 0.73) : Color(red: 0.24, green: 0.43, blue: 0.36))
    }
}

/// A card keeps native form label alignment while sharing the workspace surface.
struct LifeFormSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        LifeSection(title: title, icon: icon) {
            LifeFormFields { content }
        }
    }
}

struct LifeSheetHeading: View {
    let title: String
    let icon: String
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        HStack(spacing: textSize.isAccessibilitySize ? 0 : 12) {
            if !textSize.isAccessibilitySize { Image(systemName: icon).font(.title2).foregroundStyle(.tint).accessibilityHidden(true) }
            Text(title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 24).padding(.vertical, 18).background(.regularMaterial)
    }
}

/// Keep the value and its controls together instead of splitting a Stepper across form columns.
struct LifeIntegerControl: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String
    let label: String
    private var targetSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }
    var body: some View {
        HStack(spacing: 10) {
            Button { value -= 1 } label: { Image(systemName: "minus").frame(width: targetSize, height: targetSize).contentShape(Rectangle()) }
                .disabled(value <= range.lowerBound).accessibilityLabel("减少" + label)
            Text("\(String(value)) \(suffix)").monospacedDigit().fixedSize()
                .accessibilityLabel("\(label)，\(value) \(suffix)")
            Button { value += 1 } label: { Image(systemName: "plus").frame(width: targetSize, height: targetSize).contentShape(Rectangle()) }
                .disabled(value >= range.upperBound).accessibilityLabel("增加" + label)
        }.buttonStyle(.borderless)
    }
}

struct LifeFormFields<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.columns).labeledContentStyle(.automatic)
        #else
        VStack(alignment: .leading, spacing: 16) { content }
            .textFieldStyle(.roundedBorder)
            .labeledContentStyle(LifeFormLabelStyle())
        #endif
    }
}

private struct LifeCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var lifeCompact: Bool {
        get { self[LifeCompactKey.self] }
        set { self[LifeCompactKey.self] = newValue }
    }
}

/// Detail metadata stacks in narrow inspectors instead of squeezing both columns.
struct LifeDetailLabelStyle: LabeledContentStyle {
    @Environment(\.lifeCompact) private var compact
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                configuration.label.font(.callout).foregroundStyle(.secondary)
                configuration.content
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                configuration.label.foregroundStyle(.secondary)
                Spacer(minLength: 8)
                configuration.content.multilineTextAlignment(.trailing)
            }
        }
    }
}

struct LifeAdaptiveRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { content }
            VStack(alignment: .leading, spacing: 12) { content }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Form controls retain their labels; only a row that cannot fit stacks vertically.
struct LifeFormLabelStyle: LabeledContentStyle {
    @Environment(\.dynamicTypeSize) private var textSize
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            if !textSize.isAccessibilitySize {
            HStack(spacing: 12) {
                configuration.label.fixedSize().foregroundStyle(.secondary)
                Spacer(minLength: 8)
                configuration.content.fixedSize(horizontal: true, vertical: false)
            }
            }
            VStack(alignment: .leading, spacing: 8) {
                configuration.label.foregroundStyle(.secondary)
                configuration.content
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LifePicker<Selection: Hashable, Content: View>: View {
    let title: String
    var selectedTitle: String?
    @Binding var selection: Selection
    @ViewBuilder let content: Content
    init(_ title: String, selection: Binding<Selection>, selectedTitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.selectedTitle = selectedTitle
        self.title = title; _selection = selection; self.content = content()
    }
    var body: some View {
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                menu.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                menu.fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        #else
        Picker(title, selection: $selection) { content }
        #endif
    }
    @ViewBuilder private var menu: some View {
        if let selectedTitle {
            Menu {
                Picker(title, selection: $selection) { content }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedTitle).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).fixedSize()
                }.multilineTextAlignment(.leading)
            }.buttonStyle(.plain).foregroundStyle(.tint)
                .accessibilityLabel(title).accessibilityValue(selectedTitle)
        } else {
            Picker(title, selection: $selection) { content }
                .labelsHidden().pickerStyle(.menu)
        }
    }
}

struct LifeTextField: View {
    @State private var fieldID = UUID()
    @State private var focused = false
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title; _text = text; self.axis = axis
    }
    var body: some View {
        #if os(iOS)
        let layout = verticalSizeClass == .compact ? AnyLayout(HStackLayout(alignment: .center, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        layout {
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1...Int.max).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: verticalSizeClass == .compact ? 260 : nil, alignment: .leading)
                .layoutPriority(1)
            LifeNativeTextInput(title: title, text: $text, multiline: axis == .vertical,
                                compact: verticalSizeClass == .compact || (focused && dynamicTypeSize.isAccessibilitySize),
                                focused: $focused)
                .frame(minWidth: verticalSizeClass == .compact ? 180 : nil, minHeight: 36)
                .accessibilityLabel(title)
                .id(fieldID)
                .preference(key: LifeFocusedFieldKey.self, value: focused ? fieldID : nil)
        }
        #else
        TextField(title, text: $text, axis: axis)
        #endif
    }
}

private extension View {
    @ViewBuilder func lifeInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// Keep disabled actions legible in both appearances without stacking native opacity.
extension View {
    func lifePrimaryAction() -> some View {
        buttonStyle(LifePrimaryActionStyle())
    }
}

private struct LifePrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(isEnabled ? Color(red: 0.24, green: 0.43, blue: 0.36) : Color.primary.opacity(0.08), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// In landscape, a single toolbar leaves the keyboard's remaining height for the form.
struct LifeEditorChrome: ViewModifier {
    let title: String
    let icon: String
    var embedded = false
    let cancel: () -> Void
    let save: () -> Void
    var hasChanges = true
    var saveTitle = "保存"
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var keyboardVisible = false
    #endif
    private var compact: Bool {
        #if os(iOS)
        verticalSizeClass == .compact || (keyboardVisible && dynamicTypeSize.isAccessibilitySize)
        #else
        false
        #endif
    }
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                if compact && !embedded {
                    HStack(spacing: 12) {
                        Button("取消", action: cancel).frame(minHeight: 44).keyboardShortcut(.cancelAction)
                        Spacer(minLength: 0)
                        Text(title).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        Button(saveTitle, action: save).lifePrimaryAction().disabled(!hasChanges)
                            .keyboardShortcut(.return, modifiers: .command)
                    }.font(.body).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .buttonStyle(.borderless).padding(.horizontal, 12).background(.regularMaterial)
                } else if !embedded {
                    LifeSheetHeading(title: title, icon: icon)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !compact || embedded {
                    InspectorEditorActions(cancel: cancel, save: save, hasChanges: hasChanges, saveTitle: saveTitle)
                }
            }
    }
}
