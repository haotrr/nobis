import Foundation
import Testing
import FamilyCore
import FamilyDomain
@testable import FamilyPersistence
@testable import NobisUI

@Suite("云同步反馈") struct CloudSyncProgressTests {
    @Test func exportCannotAcknowledgeLaterWriteOrAnotherStore() throws {
        var progress = CloudSyncProgress()
        let start = Date(timeIntervalSince1970: 100)
        progress.saved(store: "private", at: start)
        progress.exported(store: "shared", started: start, ended: start.addingTimeInterval(2), succeeded: true)
        #expect(progress.hasPendingWrites)
        progress.saved(store: "private", at: start.addingTimeInterval(1))
        progress.exported(store: "private", started: start, ended: start.addingTimeInterval(2), succeeded: true)
        #expect(progress.hasPendingWrites)
        progress.exported(store: "private", started: start.addingTimeInterval(3), ended: start.addingTimeInterval(4), succeeded: false)
        #expect(progress.hasPendingWrites)
        progress = try JSONDecoder().decode(CloudSyncProgress.self, from: JSONEncoder().encode(progress))
        #expect(progress.hasPendingWrites)
        progress.exported(store: "private", started: start.addingTimeInterval(3), ended: start.addingTimeInterval(4), succeeded: true)
        #expect(!progress.hasPendingWrites)
        #expect(progress.lastUpload == start.addingTimeInterval(4))
    }
    @Test func importsDoNotAcknowledgeLocalWrites() {
        var progress = CloudSyncProgress()
        let date = Date()
        progress.saved(store: "private", at: date)
        progress.imported(at: date.addingTimeInterval(5))
        progress.imported(at: date)
        #expect(progress.hasPendingWrites)
        #expect(progress.lastDownload == date.addingTimeInterval(5))
    }
    @Test @MainActor func cloudFirstRunDoesNotCreateIndependentLocalSpaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: "iCloud.test", notificationsEnabled: false)
        model.setup(name: "本人", familyName: "Studio", partnerName: "")
        #expect(model.ready)
        #expect(model.spaces.isEmpty)
        #expect(model.selectedSpaceID == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Stores/spaces.json").path))
        let reloaded = AppModel(directory: directory, cloudIdentifier: "iCloud.test", notificationsEnabled: false)
        #expect(reloaded.ready && reloaded.spaces.isEmpty)
        #expect(throws: NobisError.self) { try reloaded.core?.save(RecordBody(kind: .task, title: "不可写入未知空间"), spaceID: UUID()) }
    }
}
