import AppKit
import CoreText

/// Registers editor fonts for this process only (nothing is installed into the user's font library), so
/// themes can refer to them by PostScript name. Fonts come from the `MDTEXTKIT_FONTS_DIR` environment
/// variable and from `registerFonts(in:)` calls made by the host application.
@MainActor
public enum SFFontLoader {
    public static let fontsDirectoryEnvironmentKey = "MDTEXTKIT_FONTS_DIR"
    private static var registeredDirectories = Set<URL>()

    /// Registers every .otf/.ttf file in `directory`; returns the registered file names.
    @discardableResult
    public static func registerFonts(in directory: URL) -> [String] {
        let dir = directory.standardizedFileURL
        guard !registeredDirectories.contains(dir) else { return [] }
        registeredDirectories.insert(dir)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
        var names: [String] = []
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                names.append(url.deletingPathExtension().lastPathComponent)
            }
        }
        return names
    }

    /// Registers the directory named by `MDTEXTKIT_FONTS_DIR`, if set.
    @discardableResult
    public static func registerFontsFromEnvironment() -> [String] {
        guard let path = ProcessInfo.processInfo.environment[fontsDirectoryEnvironmentKey], !path.isEmpty else { return [] }
        return registerFonts(in: URL(fileURLWithPath: path))
    }
}
