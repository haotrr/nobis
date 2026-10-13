import Foundation

/// Device metadata follows the platform's protection policy, independent of UI state.
public enum LocalMetadataFile {
    public static var writingOptions: Data.WritingOptions {
        #if os(macOS)
        // Matches the normal macOS file protection class. UnlessOpen can become
        // unreadable even in an unlocked desktop session on affected systems.
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic, .completeFileProtectionUnlessOpen]
        #endif
    }

    public static func read(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        #if os(macOS)
        // Migrate only a readable legacy file; never replace an inaccessible file
        // or reconstruct identity/catalog data from defaults.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        }
        #endif
        return data
    }
}
