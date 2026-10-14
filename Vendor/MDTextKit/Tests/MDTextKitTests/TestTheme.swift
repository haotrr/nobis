import Foundation
import SFThemeKit

/// The demo's Default theme, loaded from the source tree: the kit itself bundles no theme.
enum TestTheme {
    @MainActor static func makeManager() -> SFThemeManager {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MDTextKitDemo/Themes/Default.theme")
        let theme = (try? SFTheme(contentsOf: url)) ?? SFTheme(name: "Empty", jsonObject: [:])
        return SFThemeManager(theme: theme)
    }
}
