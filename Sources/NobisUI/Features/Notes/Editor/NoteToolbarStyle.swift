import SwiftUI

/// Shared geometry for command and menu labels; menus add only a disclosure arrow.
struct NoteToolbarLabel: View {
    var symbol: String? = nil
    var title: String? = nil
    var destructive = false
    var menu = false
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @ScaledMetric(relativeTo: .body) private var iconSize = 16

    private var height: CGFloat {
        #if os(iOS)
        max(44, iconSize + 20)
        #else
        max(32, iconSize + 16)
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: iconSize, weight: .regular))
                    .frame(width: iconSize + 4)
                    .accessibilityHidden(title != nil)
            }
            if let title { Text(title).font(.body).fixedSize() }
            if menu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: height, minHeight: height)
        .foregroundStyle(destructive ? Color.red : selected ? NobisTheme.accent : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? NobisTheme.accent.opacity(0.12) : Color.primary.opacity(hovering && isEnabled ? 0.07 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
    }
}

struct NoteToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
        }
    }
}

/// Keep native menus while rendering their triggers with the same command geometry.
extension View {
    func noteToolbarControls() -> some View {
        self.buttonStyle(NoteToolbarButtonStyle())
            #if os(macOS)
            .menuStyle(.button)
            #endif
            .menuIndicator(.hidden)
    }
}
