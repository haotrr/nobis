import Foundation
import Testing
import FamilyCore

@Suite("本地元数据文件保护") struct LocalMetadataFileTests {
    @Test func atomicWriteCanBeReopenedWithoutChangingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identity.json")
        let bytes = Data("{\"name\":\"保留原资料\"}".utf8)
        try bytes.write(to: url, options: LocalMetadataFile.writingOptions)
        #expect(try LocalMetadataFile.read(from: url) == bytes)
        #expect(try LocalMetadataFile.read(from: url) == bytes)
        #if os(macOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #else
        #expect(LocalMetadataFile.writingOptions.contains(.completeFileProtectionUnlessOpen))
        #endif
    }

    #if os(macOS)
    @Test func legacyProtectionPreservesContentOrLeavesUnreadableFileAlone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("legacy identity".utf8)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        if (try? Data(contentsOf: url)) != nil {
            #expect(try LocalMetadataFile.read(from: url) == bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        } else {
            #expect(throws: (any Error).self) { try LocalMetadataFile.read(from: url) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen)
            #expect(attributes[.size] as? Int == bytes.count)
        }
    }
    #endif

    @Test func failedReadDoesNotCreateReplacement() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try LocalMetadataFile.read(from: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
