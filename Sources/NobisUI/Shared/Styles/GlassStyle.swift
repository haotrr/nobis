import SwiftUI

/// Glass belongs to controls above the content; record cards stay opaque for reading.
private struct NobisGlassSurface: ViewModifier {
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(NobisSurface.card, in: RoundedRectangle(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
        } else if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
        }
    }
}

private struct NobisGlassButton: ViewModifier {
    var prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            content.lifePrimaryAction()
        } else if #available(macOS 26.0, iOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.buttonStyle(.glass).tint(.gray)
        } else {
            content.lifeSecondaryAction()
        }
    }
}

struct NobisGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else { content() }
    }
}

extension View {
    func nobisGlass(radius: CGFloat = 20) -> some View { modifier(NobisGlassSurface(radius: radius)) }
    func nobisGlassButton(prominent: Bool = false) -> some View { modifier(NobisGlassButton(prominent: prominent)) }
}
