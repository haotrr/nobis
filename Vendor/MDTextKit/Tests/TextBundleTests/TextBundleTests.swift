import XCTest
@testable import TextBundle

final class TextBundleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tb-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testWriteAndReadBundle() throws {
        let b = TextBundle(text: "# Hi\n\n![](assets/pic.png)\n")
        let rel = try b.addAsset(Data([0x89, 0x50, 0x4E, 0x47]), preferredName: "Pic.PNG")
        XCTAssertEqual(rel, "assets/pic.png")
        b.info[namespace: "com.example.mdtextkit"] = ["version": 1, "tags": ["a", "b"]]
        let dest = tmp.appendingPathComponent("note.textbundle")
        try b.write(to: dest, creatorIdentifier: "com.example.mdtextkit", creatorURL: URL(string: "file:///Applications/MDTextKitDemo.app"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("info.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("text.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("assets/pic.png").path))

        let r = try TextBundle(contentsOf: dest)
        XCTAssertEqual(r.text, b.text)
        XCTAssertEqual(r.info.version, 2)
        XCTAssertEqual(r.info.type, TextBundleInfo.markdownType)
        XCTAssertEqual(r.info.creatorIdentifier, "com.example.mdtextkit")
        XCTAssertEqual(r.info[namespace: "com.example.mdtextkit"]["version"] as? Int, 1)
        XCTAssertEqual(r.assetPaths, ["assets/pic.png"])
        XCTAssertEqual(r.data(forAsset: "assets/pic.png")?.count, 4)
        XCTAssertEqual(r.assetURL(for: "assets/pic.png")?.lastPathComponent, "pic.png")
    }

    func testForeignMetadataIsPreservedOnOverwrite() throws {
        let dest = tmp.appendingPathComponent("shared.textbundle")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let foreign: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown",
                                      "com.example.otherapp": ["version": 1, "modificationDate": "2026-01-01"]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: dest.appendingPathComponent("info.json"))
        try "old".write(to: dest.appendingPathComponent("text.markdown"), atomically: true, encoding: .utf8)

        let mine = TextBundle(text: "new")
        try mine.write(to: dest, creatorIdentifier: "com.example.mdtextkit")
        let r = try TextBundle(contentsOf: dest)
        XCTAssertEqual(r.text, "new")
        XCTAssertEqual(r.info[namespace: "com.example.otherapp"]["version"] as? Int, 1, "other apps' metadata must survive")
        XCTAssertEqual(r.info.creatorIdentifier, "com.example.mdtextkit")
        // stale text.markdown replaced by text.md
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("text.markdown").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("text.md").path))
    }

    func testReadKeepsTextFileNameAndTransientOverwrite() throws {
        let dest = tmp.appendingPathComponent("ia.textbundle")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 2, "transient": true, "com.other": ["x": 1]]).write(to: dest.appendingPathComponent("info.json"))
        try "body".write(to: dest.appendingPathComponent("text.markdown"), atomically: true, encoding: .utf8)
        let r = try TextBundle(contentsOf: dest)
        XCTAssertEqual(r.textFileName, "text.markdown")
        XCTAssertEqual(r.info.transient, true)
        // a transient bundle may be overwritten without keeping foreign keys
        let mine = TextBundle(text: "replaced")
        try mine.write(to: dest)
        let again = try TextBundle(contentsOf: dest)
        XCTAssertNil(again.info.extra["com.other"])
        XCTAssertEqual(again.text, "replaced")
    }

    func testTextPackRoundTrip() throws {
        let b = TextBundle(text: "packed **text**")
        try b.addAsset(Data("hello".utf8), preferredName: "a.txt")
        let pack = tmp.appendingPathComponent("note.textpack")
        try b.writePack(to: pack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pack.path))
        let r = try TextBundle(contentsOf: pack)
        XCTAssertEqual(r.text, "packed **text**")
        XCTAssertEqual(r.assetPaths, ["assets/a.txt"])
        XCTAssertEqual(String(data: r.data(forAsset: "assets/a.txt")!, encoding: .utf8), "hello")
    }

    func testAssetNameCollisionAndSanitizing() throws {
        let b = TextBundle(text: "")
        XCTAssertEqual(try b.addAsset(Data(), preferredName: "My Photo.JPG"), "assets/my-photo.jpg")
        XCTAssertEqual(try b.addAsset(Data(), preferredName: "my photo.jpg"), "assets/my-photo-2.jpg")
        XCTAssertEqual(TextBundle.sanitizedAssetName("../../etc/passwd"), "passwd")
    }

    func testErrors() {
        XCTAssertThrowsError(try TextBundle(contentsOf: tmp.appendingPathComponent("missing.textbundle")))
        let empty = tmp.appendingPathComponent("empty.textbundle")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TextBundle(contentsOf: empty)) { e in
            guard case TextBundleError.missingTextFile = e else { return XCTFail("wrong error \(e)") }
        }
    }
}
