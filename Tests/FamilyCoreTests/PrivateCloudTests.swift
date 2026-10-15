import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence

@Suite("个人云隐私与历史") @MainActor struct PrivateCloudTests {
    func fixture() -> (Member, Space, URL) {
        let owner = Member(name: "haotrr")
        return (owner, Space(name: "个人云空间", kind: .personal, ownerID: owner.id, members: [owner]), FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    @Test func assetEncodingIsStableAcrossIndependentDecodes() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let amounts = Dictionary(uniqueKeysWithValues: AssetComponent.allCases.enumerated().map { ($0.element, Int64($0.offset * 100)) })
        let asset = AssetPosition(currency: .CNY, amounts: amounts)
        let baseline = try encoder.encode(asset)
        for _ in 0..<20 {
            let decoded = try JSONDecoder().decode(AssetPosition.self, from: baseline)
            #expect(decoded == asset)
            #expect(try encoder.encode(decoded) == baseline)
        }
        let legacy = try JSONSerialization.data(withJSONObject: ["currency": "CNY", "amounts": AssetComponent.allCases.reversed().flatMap { [$0.rawValue as Any, amounts[$0]! as Any] }])
        #expect(try JSONDecoder().decode(AssetPosition.self, from: legacy) == asset)
    }
    @Test func rejectsSharedSpaceAndOtherAccount() throws {
        let (owner, space, url) = fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let repo = try PrivateCloudRepository(directory: url, space: space)
        #expect(throws: NobisError.self) { try repo.requireWrite(spaceID: space.id, actorID: UUID()) }
        var other = Snapshot(spaces: [Space(id: space.id, name: "家庭", kind: .family, ownerID: owner.id, members: [owner])])
        #expect(throws: NobisError.self) { try repo.receive(other) }
        other = Snapshot(spaces: [Space(id: space.id, name: "他人", kind: .personal, ownerID: UUID(), members: [owner])])
        #expect(throws: NobisError.self) { try repo.receive(other) }
        repo.block()
        #expect(throws: NobisError.self) { try repo.load() }
        #expect(throws: NobisError.self) { try repo.save(Snapshot(spaces: [space])) }
    }
    @Test func concurrentBranchesAndTombstonesSurviveRestart() throws {
        let (owner, space, url) = fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let repo = try PrivateCloudRepository(directory: url, space: space)
        let core = FamilyCore(repository: repo, session: AccessSession(memberID: owner.id, allowedSpaceIDs: [space.id]))
        let initial = try core.save(RecordBody(kind: .task, title: "基线"), spaceID: space.id)
        var remote = try repo.load()
        var body = initial.body; body.title = "远端修改"
        let branch = Revision(recordID: initial.recordID, spaceID: space.id, parents: [initial.id], actorID: owner.id, body: body)
        remote.revisions.append(branch); remote.audits.append(AuditEvent(revision: branch, action: "update"))
        let local = try core.save(initial.body, spaceID: space.id, recordID: initial.recordID, expected: [initial.id], deleted: true)
        try repo.receive(remote)
        let projected = try #require(Record.project(repo.load().revisions).first)
        #expect(projected.deleted && Set(projected.heads.map(\.id)) == [branch.id, local.id])
        let reopened = try PrivateCloudRepository(directory: url, space: space)
        #expect(try PrivateCloudSnapshot.data(reopened.load()) == PrivateCloudSnapshot.data(repo.load()))
        #expect(throws: NobisError.self) { try reopened.save(Snapshot(spaces: [space])) }
        var forged = try repo.load(); forged.audits.removeAll()
        #expect(throws: NobisError.self) { try repo.receive(forged) }
    }
    @Test func personalWritesNeverReachFamilyRoute() throws {
        let (owner, space, url) = fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let privateRepo = try PrivateCloudRepository(directory: url, space: space)
        let family = Space(name: "D&H", kind: .family, ownerID: owner.id, members: [owner])
        let shared = MemoryRepository(Snapshot(spaces: [family]))
        let routed = RoutedRepository(local: shared, shared: privateRepo)
        let core = FamilyCore(repository: routed, session: AccessSession(memberID: owner.id, allowedSpaceIDs: [space.id, family.id]))
        try core.save(RecordBody(kind: .task, title: "私密"), spaceID: space.id)
        #expect(shared.snapshot.revisions.isEmpty)
        #expect(try privateRepo.load().revisions.count == 1)
        let before = try privateRepo.load()
        try core.save(RecordBody(kind: .task, title: "共同"), spaceID: family.id)
        #expect(try privateRepo.load() == before)
        let local = Space(name: "本地", kind: .personal, ownerID: owner.id, members: [owner])
        let workspace = LifeWorkspace(spaces: [local, space, family], cloudID: family.id, personalCloudID: space.id)
        #expect(workspace.personalID == space.id)
        #expect(workspace.ids(.personal) == [space.id, local.id])
        #expect(workspace.ids(.shared) == [family.id])
    }
}
