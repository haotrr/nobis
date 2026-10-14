import SwiftUI

/// Brand colors from the sRGB icon master. AccentColor supplies appearance variants.
enum NobisTheme {
    // Explicit asset lookup keeps the brand independent of the macOS accent preference.
    static let accent = Color("AccentColor", bundle: .main)
    // Native segmented / prominent controls draw white labels in both appearances.
    static let controlFill = Color(.sRGB, red: 196.0 / 255, green: 55.0 / 255, blue: 45.0 / 255)
    static let brand = Color(.sRGB, red: 253.0 / 255, green: 94.0 / 255, blue: 83.0 / 255)
    static let onBrand = Color(.sRGB, red: 0.16, green: 0.06, blue: 0.05)
}
