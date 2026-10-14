import Foundation

/// `info.json` of a TextBundle (spec version 2, https://textbundle.org/spec/).
/// Unknown keys are preserved verbatim so other apps' metadata survives a
/// round trip, as the spec's cooperation rule requires.
public struct TextBundleInfo: Equatable {
    public static let markdownType = "net.daringfireball.markdown"
    public static let plainTextType = "public.plain-text"
    public static let standardKeys: Set<String> = ["version", "type", "transient", "creatorURL", "creatorIdentifier", "sourceURL"]

    public var version: Int = 2
    public var type: String = TextBundleInfo.markdownType
    public var transient: Bool? = nil
    public var creatorURL: String? = nil
    public var creatorIdentifier: String? = nil
    public var sourceURL: String? = nil
    /// Every non-standard top-level key (app namespaces such as `com.example.app`).
    public var extra: [String: Any] = [:]

    public init() {}

    public init(jsonObject: [String: Any]) {
        version = (jsonObject["version"] as? NSNumber)?.intValue ?? 1
        type = (jsonObject["type"] as? String) ?? TextBundleInfo.markdownType
        transient = (jsonObject["transient"] as? NSNumber)?.boolValue
        creatorURL = jsonObject["creatorURL"] as? String
        creatorIdentifier = jsonObject["creatorIdentifier"] as? String
        sourceURL = jsonObject["sourceURL"] as? String
        extra = jsonObject.filter { !TextBundleInfo.standardKeys.contains($0.key) }
    }

    public var jsonObject: [String: Any] {
        var o: [String: Any] = extra
        o["version"] = version
        o["type"] = type
        if let t = transient { o["transient"] = t }
        if let c = creatorURL { o["creatorURL"] = c }
        if let c = creatorIdentifier { o["creatorIdentifier"] = c }
        if let s = sourceURL { o["sourceURL"] = s }
        return o
    }

    /// App-specific sub-dictionary (`info.json[bundleIdentifier]`), created on first access.
    public subscript(namespace id: String) -> [String: Any] {
        get { (extra[id] as? [String: Any]) ?? [:] }
        set { extra[id] = newValue }
    }

    public static func == (a: TextBundleInfo, b: TextBundleInfo) -> Bool {
        NSDictionary(dictionary: a.jsonObject).isEqual(to: b.jsonObject)
    }

    /// Preferred extension for `text.*` given the type UTI.
    public var preferredTextExtension: String {
        switch type {
        case TextBundleInfo.markdownType: return "md"
        case "net.ia.markdown", "com.unknown.markdown": return "markdown"
        case TextBundleInfo.plainTextType: return "txt"
        case "net.multimarkdown.text": return "mmd"
        case "org.textbundle.fountain", "com.quoteunquoteapps.fountain": return "fountain"
        default: return "txt"
        }
    }
}

public enum TextBundleError: LocalizedError {
    case notABundle(URL)
    case missingTextFile(URL)
    case invalidInfo(URL)
    case zipFailed(String)
    case assetNameConflict(String)

    public var errorDescription: String? {
        switch self {
        case .notABundle(let u): return "\(u.lastPathComponent) is not a .textbundle or .textpack"
        case .missingTextFile(let u): return "\(u.lastPathComponent) contains no text.* file"
        case .invalidInfo(let u): return "\(u.lastPathComponent)/info.json is not a JSON object"
        case .zipFailed(let m): return "ZIP operation failed: \(m)"
        case .assetNameConflict(let n): return "An asset named \(n) already exists"
        }
    }
}

/// `TextBundle.framework`. Reads and writes `.textbundle` packages and
/// `.textpack` ZIP containers. Assets live under `assets/` and are referenced
/// from the text with relative paths (`![](assets/photo.png)`).
public final class TextBundle {
    public static let packageExtension = "textbundle"
    public static let compressedExtension = "textpack"
    public static let packageUTI = "org.textbundle.package"
    public static let compressedUTI = "org.textbundle.compressed"
    public static let infoFileName = "info.json"
    public static let assetsFolderName = "assets"

    public var info: TextBundleInfo
    public var text: String
    /// `text.<ext>` — kept from the source bundle so re-saving does not rename the file.
    public var textFileName: String
    /// Where this bundle was read from (nil for an in-memory bundle).
    public private(set) var url: URL?
    /// Assets added in memory and not yet written: relative path -> data.
    public private(set) var pendingAssets: [String: Data] = [:]
    private var removedAssets: Set<String> = []
    private var tempUnpackDirectory: URL?

    public init(text: String, info: TextBundleInfo = TextBundleInfo()) {
        self.text = text
        self.info = info
        self.textFileName = "text." + info.preferredTextExtension
    }

    deinit {
        if let t = tempUnpackDirectory { try? FileManager.default.removeItem(at: t) }
    }

    // MARK: Reading

    public static func isTextBundle(_ url: URL) -> Bool { url.pathExtension.lowercased() == packageExtension }
    public static func isTextPack(_ url: URL) -> Bool { url.pathExtension.lowercased() == compressedExtension }

    public convenience init(contentsOf url: URL) throws {
        let fm = FileManager.default
        var bundleURL = url
        var temp: URL?
        if TextBundle.isTextPack(url) {
            let dir = fm.temporaryDirectory.appendingPathComponent("textpack-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try TextBundle.runDitto(["-x", "-k", url.path, dir.path])
            bundleURL = try TextBundle.locateBundle(in: dir)
            temp = dir
        } else {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw TextBundleError.notABundle(url) }
        }

        let infoURL = bundleURL.appendingPathComponent(TextBundle.infoFileName)
        var info = TextBundleInfo()
        if let data = try? Data(contentsOf: infoURL) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TextBundleError.invalidInfo(bundleURL) }
            info = TextBundleInfo(jsonObject: obj)
        }
        guard let textURL = TextBundle.locateTextFile(in: bundleURL) else { throw TextBundleError.missingTextFile(bundleURL) }
        let text = try String(contentsOf: textURL, encoding: .utf8)
        self.init(text: text, info: info)
        self.textFileName = textURL.lastPathComponent
        self.url = bundleURL
        self.tempUnpackDirectory = temp
    }

    /// Either the directory itself (info.json at root) or the first `*.textbundle` inside it.
    private static func locateBundle(in dir: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(infoFileName).path) { return dir }
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let b = items.first(where: { isTextBundle($0) }) { return b }
        if let b = items.first(where: { fm.fileExists(atPath: $0.appendingPathComponent(infoFileName).path) }) { return b }
        throw TextBundleError.notABundle(dir)
    }

    /// `text.*` with any extension; prefers markdown-ish extensions when several exist.
    private static func locateTextFile(in bundle: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []
        let candidates = items.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == "text" }
        let priority = ["md", "markdown", "mdown", "mmd", "txt", "text", "fountain"]
        return candidates.sorted { a, b in
            let ia = priority.firstIndex(of: a.pathExtension.lowercased()) ?? 99
            let ib = priority.firstIndex(of: b.pathExtension.lowercased()) ?? 99
            return ia < ib
        }.first
    }

    // MARK: Assets

    public var assetsDirectoryURL: URL? { url?.appendingPathComponent(TextBundle.assetsFolderName, isDirectory: true) }

    /// Relative paths (`assets/x.png`) of every asset: on disk plus pending, minus removed.
    public var assetPaths: [String] {
        var names: [String] = []
        if let dir = assetsDirectoryURL, let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            names = items.filter { !$0.hasPrefix(".") }.map { "\(TextBundle.assetsFolderName)/\($0)" }
        }
        names = names.filter { !removedAssets.contains($0) }
        names.append(contentsOf: pendingAssets.keys)
        return Array(Set(names)).sorted()
    }

    /// Adds an in-memory asset and returns the relative path to reference it from the text.
    @discardableResult
    public func addAsset(_ data: Data, preferredName: String) throws -> String {
        var name = TextBundle.sanitizedAssetName(preferredName)
        let existing = Set(assetPaths)
        var attempt = 1
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while existing.contains("\(TextBundle.assetsFolderName)/\(name)") {
            attempt += 1
            name = ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)"
        }
        let rel = "\(TextBundle.assetsFolderName)/\(name)"
        pendingAssets[rel] = data
        removedAssets.remove(rel)
        return rel
    }

    @discardableResult
    public func addAsset(contentsOf fileURL: URL) throws -> String {
        try addAsset(Data(contentsOf: fileURL), preferredName: fileURL.lastPathComponent)
    }

    public func removeAsset(_ relativePath: String) {
        pendingAssets.removeValue(forKey: relativePath)
        removedAssets.insert(relativePath)
    }

    public func data(forAsset relativePath: String) -> Data? {
        if let d = pendingAssets[relativePath] { return d }
        guard !removedAssets.contains(relativePath), let u = url?.appendingPathComponent(relativePath) else { return nil }
        return try? Data(contentsOf: u)
    }

    /// Resolves a relative reference from the text (`assets/x.png`) to a file URL.
    public func assetURL(for relativePath: String) -> URL? {
        guard relativePath.hasPrefix(TextBundle.assetsFolderName + "/"), !removedAssets.contains(relativePath) else { return nil }
        return url?.appendingPathComponent(relativePath)
    }

    /// Lowercase, no path separators, no spaces — the spec recommends lowercase names for iOS.
    public static func sanitizedAssetName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let s = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return s.isEmpty ? "asset" : s
    }

    // MARK: Writing

    /// Writes the package to `destination` (a `.textbundle` directory). An existing bundle is
    /// updated in place; metadata of other apps in its info.json is preserved unless the existing
    /// bundle is marked transient.
    public func write(to destination: URL, creatorIdentifier: String? = nil, creatorURL: URL? = nil) throws {
        let fm = FileManager.default
        var dest = destination
        if dest.pathExtension.lowercased() != TextBundle.packageExtension { dest = dest.appendingPathExtension(TextBundle.packageExtension) }

        // Cooperation rule: keep foreign metadata of the bundle we overwrite.
        if let existingData = try? Data(contentsOf: dest.appendingPathComponent(TextBundle.infoFileName)),
           let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            let existing = TextBundleInfo(jsonObject: obj)
            if existing.transient != true {
                for (k, v) in existing.extra where info.extra[k] == nil { info.extra[k] = v }
            }
        }
        if let c = creatorIdentifier { info.creatorIdentifier = c }
        if let c = creatorURL { info.creatorURL = c.absoluteString }
        info.version = max(info.version, 2)
        if !textFileName.lowercased().hasPrefix("text.") { textFileName = "text." + info.preferredTextExtension }

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        // Remove stale text.* files with another extension (e.g. type changed from txt to md).
        for item in (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? [] {
            let n = item.lastPathComponent
            if n.lowercased().hasPrefix("text."), n != textFileName { try? fm.removeItem(at: item) }
        }
        let infoData = try JSONSerialization.data(withJSONObject: info.jsonObject, options: [.prettyPrinted, .sortedKeys])
        try infoData.write(to: dest.appendingPathComponent(TextBundle.infoFileName), options: .atomic)
        try text.write(to: dest.appendingPathComponent(textFileName), atomically: true, encoding: .utf8)

        let assetsDir = dest.appendingPathComponent(TextBundle.assetsFolderName, isDirectory: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        // Copy existing assets when saving to a new location.
        if let src = assetsDirectoryURL, src.standardizedFileURL != assetsDir.standardizedFileURL,
           let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
            for item in items {
                let rel = "\(TextBundle.assetsFolderName)/\(item.lastPathComponent)"
                guard !removedAssets.contains(rel), pendingAssets[rel] == nil else { continue }
                let target = assetsDir.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item, to: target)
            }
        }
        for rel in removedAssets {
            let target = dest.appendingPathComponent(rel)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        }
        for (rel, data) in pendingAssets {
            try data.write(to: dest.appendingPathComponent(rel), options: .atomic)
        }
        pendingAssets.removeAll()
        removedAssets.removeAll()
        url = dest
    }

    /// Writes a `.textpack`: the `.textbundle` directory zipped with itself as the top-level entry.
    public func writePack(to destination: URL, creatorIdentifier: String? = nil, creatorURL: URL? = nil) throws {
        let fm = FileManager.default
        var dest = destination
        if dest.pathExtension.lowercased() != TextBundle.compressedExtension { dest = dest.appendingPathExtension(TextBundle.compressedExtension) }
        let staging = fm.temporaryDirectory.appendingPathComponent("textpack-write-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let bundleName = dest.deletingPathExtension().lastPathComponent + "." + TextBundle.packageExtension
        let bundleURL = staging.appendingPathComponent(bundleName, isDirectory: true)
        let originalURL = url
        try write(to: bundleURL, creatorIdentifier: creatorIdentifier, creatorURL: creatorURL)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try TextBundle.runDitto(["-c", "-k", "--keepParent", bundleURL.path, dest.path])
        url = originalURL
    }

    // MARK: ZIP via ditto (macOS ships ditto, which handles the standard ZIP format)

    private static func runDitto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TextBundleError.zipFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
