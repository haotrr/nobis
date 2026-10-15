import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence
import NobisUI

@Suite("Studio 账号与云端边界") @MainActor struct StudioAccountTests {
    @Test func profileBranchesConvergeWithoutRewritingBusinessHistory() throws {
        let member = Member(name: "原名"), date = Date(timeIntervalSinceReferenceDate: 1000)
        let space = Space(name: "个人", kind: .personal, ownerID: member.id, members: [member])
        var a = Snapshot(spaces: [space]), b = a
        let one = AccountProfileVersion(member: Member(id: member.id, name: "新名字", avatarData: Data([1,2])), updatedAt: date)
        let two = AccountProfileVersion(member: Member(id: member.id, name: "另一设备"), updatedAt: date.addingTimeInterval(1))
        a.account = AccountState(ownerID: member.id, profiles: [one]); b.account = AccountState(ownerID: member.id, profiles: [two])
        let ab = try PrivateCloudSnapshot.merge(local: a, remote: b, owner: member.id, spaceID: space.id)
        let ba = try PrivateCloudSnapshot.merge(local: b, remote: a, owner: member.id, spaceID: space.id)
        #expect(try PrivateCloudSnapshot.data(ab) == PrivateCloudSnapshot.data(ba))
        #expect(ab.account?.profiles.count == 2 && ab.account?.profile == two.member)
        #expect(ab.spaces[0].members == [two.member])
        #expect(ab.revisions.isEmpty)
        var forged = a; forged.account = AccountState(ownerID: UUID(), profiles: [one])
        #expect(throws: NobisError.self) { try PrivateCloudSnapshot.validate(forged, owner: member.id, spaceID: space.id) }
    }
    @Test func independentStudioRoutesPreservePrivateAccountAndRejectCrossStoreWrite() throws {
        let owner = Member(name: "本人")
        let personal = Space(name: "个人", kind: .personal, ownerID: owner.id, members: [owner])
        let a = Space(name: "A", kind: .family, ownerID: owner.id, members: [owner])
        let b = Space(name: "B", kind: .family, ownerID: owner.id, members: [owner])
        var snapshot = Snapshot(spaces: [personal]); snapshot.account = AccountState(ownerID: owner.id, profiles: [AccountProfileVersion(member: owner)])
        let p = MemoryRepository(snapshot), ra = MemoryRepository(Snapshot(spaces: [a])), rb = MemoryRepository(Snapshot(spaces: [b]))
        let router = SpaceRepositoryRouter(stores: [p, ra, rb])
        let core = FamilyCore(repository: router, session: AccessSession(memberID: owner.id, allowedSpaceIDs: [personal.id,a.id,b.id]))
        try core.save(RecordBody(kind: .task, title: "A 的内容"), spaceID: a.id)
        #expect(p.snapshot == snapshot && rb.snapshot.revisions.isEmpty)
        let work = LifeWorkspace(spaces: [personal,a,b], cloudID: b.id, personalCloudID: personal.id, cloudOnly: true)
        #expect(work.ids(.all) == [personal.id,b.id])
        #expect(work.ids(.shared) == [b.id])
        let stage = MemoryRepository(try router.load())
        let writer = FamilyCore(repository: stage, session: core.session)
        try writer.save(RecordBody(kind: .task, title: "私密"), spaceID: personal.id)
        try writer.save(RecordBody(kind: .task, title: "B"), spaceID: b.id)
        #expect(throws: NobisError.self) { try router.save(stage.snapshot) }
        #expect(p.snapshot == snapshot && rb.snapshot.revisions.isEmpty)
    }
    @Test func profileSurvivesBusinessWritesAndRejectsStaleEditor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let member = Member(name: "本人"), updatedName = "统一名称"
        let space = Space(name: "个人", kind: .personal, ownerID: member.id, members: [member])
        let repo = try PrivateCloudRepository(directory: dir, space: space)
        try repo.updateProfile(member, expected: nil)
        let changed = Member(id: member.id, name: updatedName)
        try repo.updateProfile(changed, expected: member)
        #expect(throws: NobisError.self) { try repo.updateProfile(member, expected: member) }
        let router = SpaceRepositoryRouter(stores: [repo])
        let core = FamilyCore(repository: router, session: AccessSession(memberID: member.id, allowedSpaceIDs: [space.id]))
        try core.save(RecordBody(kind: .task, title: "个人记录"), spaceID: space.id)
        let reopened = try PrivateCloudRepository(directory: dir, space: space)
        #expect(reopened.profile?.name == updatedName)
        #expect(try reopened.load().account?.profiles.count == 2)
        #expect(try reopened.load().revisions.count == 1)
    }
    @Test func deviceDraftsDoNotOverwriteAndRemovalDoesNotResurrect() throws {
        let member = Member(name: "本人")
        let space = Space(name: "个人", kind: .personal, ownerID: member.id, members: [member])
        var a = Snapshot(spaces: [space]); a.account = AccountState(ownerID: member.id)
        var b = a
        let key = UUID(), device = UUID()
        let bytes = try JSONEncoder().encode(DocumentDraft(body: RecordBody(kind: .document, title: "草稿"), spaceID: space.id, recordID: nil, expected: []))
        let old = AccountDraft(deviceID: device, key: key, kind: "DocumentDrafts", payload: bytes, updatedAt: Date(timeIntervalSinceReferenceDate: 1))
        let tombstone = AccountDraft(deviceID: device, key: key, kind: "DocumentDrafts", payload: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 2))
        let other = AccountDraft(deviceID: UUID(), key: key, kind: "DocumentDrafts", payload: bytes)
        a.account?.drafts = [old,other]; b.account?.drafts = [tombstone]
        let merged = try PrivateCloudSnapshot.merge(local: a, remote: b, owner: member.id, spaceID: space.id)
        #expect(merged.account?.drafts?.count == 2)
        #expect(merged.account?.drafts?.first(where: { $0.deviceID == device })?.payload == nil)
        #expect(merged.account?.drafts?.first(where: { $0.deviceID == other.deviceID })?.payload == bytes)
    }
    @Test func legacyLocalRecordsNeverLeakIntoCloudBrowsing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = AppModel(directory: dir, cloudIdentifier: nil, notificationsEnabled: false)
        local.setup(name: "本人", familyName: "旧库", partnerName: "")
        let id = try #require(local.workspace.personalID)
        try local.save(RecordBody(kind: .task, title: "待迁移"), spaceID: id)
        let cloud = AppModel(directory: dir, cloudIdentifier: "iCloud.test", notificationsEnabled: false)
        #expect(cloud.ready && cloud.records.isEmpty && cloud.spaces.isEmpty)
        #expect(cloud.workspace.personalID == nil)
        let reopened = try CoreDataRepository(directory: dir.appendingPathComponent("Stores"))
        #expect(try reopened.load().revisions.count == 1)
    }
}
