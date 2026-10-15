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
    @Test @MainActor func firstRunConnectKeepsExistingRecordsLocal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: "iCloud.test", notificationsEnabled: false)
        model.setupAndConnect(name: "本人", familyName: "本地共同空间")
        #expect(model.ready)
        #expect(model.showingCloudSetup)
        #expect(!model.cloud.enabled)
        let id = try #require(model.selectedSpaceID)
        try model.save(RecordBody(kind: .task, title: "未上传的本地记录"), spaceID: id)
        #expect(model.cloud.repository == nil)
        #expect(model.visibility(for: id) == "仅此设备 · 本地共同空间")
        let reloaded = AppModel(directory: directory, cloudIdentifier: "iCloud.test", notificationsEnabled: false)
        #expect(reloaded.records.count == 1)
        #expect(!reloaded.showingCloudSetup)
    }
}
