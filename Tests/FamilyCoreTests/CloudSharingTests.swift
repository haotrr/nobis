import Foundation
import CoreData
import CloudKit
import Testing
import FamilyDomain
import FamilyCore
@testable import FamilyPersistence

@Suite("CloudKit 身份与访问策略") struct CloudAccessTests {
    @Test func identityIsStableAcrossDevicesButScopedToContainer() {
        let a = CloudIdentity.memberID(container: "iCloud.a", userRecordName: "_userA")
        #expect(a == CloudIdentity.memberID(container: "iCloud.a", userRecordName: "_userA"))
        #expect(a != CloudIdentity.memberID(container: "iCloud.b", userRecordName: "_userA"))
        #expect(a != CloudIdentity.memberID(container: "iCloud.a", userRecordName: "_userB"))
    }
    @Test func currentUserAliasRequiresServerCurrentParticipant() throws {
        let account = CloudIdentity.memberID(container: "iCloud.test", userRecordName: "real-user")
        #expect(try CloudParticipantIdentity.memberID(container: "iCloud.test", recordName: CKCurrentUserDefaultName, isCurrentParticipant: true, verifiedAccountID: account) == account)
        #expect(throws: NobisError.self) {
            try CloudParticipantIdentity.memberID(container: "iCloud.test", recordName: CKCurrentUserDefaultName, isCurrentParticipant: false, verifiedAccountID: account)
        }
        let other = try CloudParticipantIdentity.memberID(container: "iCloud.test", recordName: "other-user", isCurrentParticipant: true, verifiedAccountID: account)
        #expect(other != account)
    }
    @Test func nameEqualityDoesNotGrantMembership() {
        let a = Member(name: "同名"), b = Member(name: "同名")
        #expect(throws: NobisError.self) { try FamilyGrant(spaceID: UUID(), accountID: b.id, ownerID: a.id, members: [a], writable: true) }
    }
    @Test func invitedButUnmappedOrThirdMemberCannotOpenFamily() throws {
        let a = Member(name: "A"), b = Member(name: "B"), c = Member(name: "C")
        #expect(throws: NobisError.self) { try FamilyGrant(spaceID: UUID(), accountID: b.id, ownerID: a.id, members: [a], writable: true) }
        #expect(throws: NobisError.self) { try FamilyGrant(spaceID: UUID(), accountID: b.id, ownerID: a.id, members: [a, b, c], writable: true) }
        #expect(throws: NobisError.self) { try FamilyGrant(spaceID: UUID(), accountID: a.id, ownerID: a.id, members: [a, a], writable: true) }
    }
    @Test func staleNetworkCompletionCannotRestoreRevokedGrant() throws {
        let a = Member(name: "A"), spaceID = UUID()
        var policy = FamilyAccessPolicy(); policy.identify(a.id); let ticket = policy.generation
        let grant = try FamilyGrant(spaceID: spaceID, accountID: a.id, ownerID: a.id, members: [a], writable: true)
        try policy.authorize(grant, generation: ticket); try policy.requireWrite(spaceID: spaceID, actorID: a.id)
        policy.revoke()
        #expect(throws: NobisError.self) { try policy.authorize(grant, generation: ticket) }
        #expect(throws: NobisError.self) { try policy.requireWrite(spaceID: spaceID, actorID: a.id) }
    }
    @Test func accountSwitchAndReadOnlyPreventWrite() throws {
        let a = Member(name: "A"), b = Member(name: "B"), space = UUID()
        var policy = FamilyAccessPolicy(); policy.identify(a.id)
        try policy.authorize(FamilyGrant(spaceID: space, accountID: a.id, ownerID: a.id, members: [a], writable: false), generation: policy.generation)
        #expect(throws: NobisError.self) { try policy.requireWrite(spaceID: space, actorID: a.id) }
        policy.identify(b.id); #expect(policy.grant == nil)
        #expect(throws: NobisError.self) { try policy.requireWrite(spaceID: space, actorID: b.id) }
    }
    @Test func retryRespectsServerBackoffAndDoesNotRetryPermanentFailures() {
        #expect(CloudFailurePolicy.retryDelay(for: CKError(.networkUnavailable)) == 30)
        #expect(CloudFailurePolicy.retryDelay(for: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0])) == 120)
        #expect(CloudFailurePolicy.retryDelay(for: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: -1.0])) == 5)
        #expect(CloudFailurePolicy.retryDelay(for: CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: Double.infinity])) == 30)
        for code: CKError.Code in [.permissionFailure, .notAuthenticated, .quotaExceeded, .badContainer, .unknownItem] {
            #expect(CloudFailurePolicy.retryDelay(for: CKError(code)) == nil)
        }
    }
    @Test func transientErrorsAreNotRevocation() {
        for code: CKError.Code in [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable] {
            #expect(CloudFailurePolicy.classify(CKError(code)) == .retry)
        }
        for code: CKError.Code in [.unknownItem, .zoneNotFound, .permissionFailure] { #expect(CloudFailurePolicy.classify(CKError(code)) == .accessLost) }
        #expect(CloudFailurePolicy.classify(CKError(.notAuthenticated)) == .accountLost)
        #expect(CloudFailurePolicy.classify(CKError(.quotaExceeded)) == .other)
    }
}

@Suite("共享持久化与主应用路由") @MainActor struct CloudRepositoryTests {
    private func makeCloud(at url: URL) async throws -> (CloudFamilyRepository, Member, Space) {
        let repo = CloudFamilyRepository(directory: url, identifier: nil)
        try await repo.open()
        let member = Member(name: "云端本人"); repo.identify(member.id)
        let root = try repo.createFamily(name: "共享测试", member: member)
        let space = try repo.space(of: root)
        try repo.authorize(FamilyGrant(spaceID: space.id, accountID: member.id, ownerID: member.id, members: [member], writable: true), root: root, generation: repo.policy.generation)
        return (repo, member, space)
    }
    @Test func mainAppSessionUsesVerifiedActorWithoutMigratingLocalRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let (cloud, account, family) = try await makeCloud(at: url.appendingPathComponent("Cloud"))
        let localMember = Member(name: "本地本人"), personal = Space(name: "个人", kind: .personal, ownerID: UUID(), members: [])
        let localSpace = Space(id: personal.id, name: "个人", kind: .personal, ownerID: localMember.id, members: [localMember])
        let local = try CoreDataRepository(directory: url.appendingPathComponent("Local"), initialSpaces: [localSpace])
        let route = RoutedRepository(local: local, shared: cloud)
        let core = FamilyCore(repository: route, session: AccessSession(memberID: localMember.id, allowedSpaceIDs: [localSpace.id, family.id], memberIDsBySpace: [family.id: account.id]))
        let privateRevision = try core.save(RecordBody(kind: .task, title: "私人任务"), spaceID: localSpace.id)
        let sharedRevision = try core.save(RecordBody(kind: .task, title: "共享任务"), spaceID: family.id)
        #expect(privateRevision.actorID == localMember.id); #expect(sharedRevision.actorID == account.id)
        #expect(try cloud.load().revisions.count == 1); #expect(try local.load().revisions.count == 1)
        let stranger = FamilyCore(repository: cloud, session: AccessSession(memberID: localMember.id, allowedSpaceIDs: [family.id]))
        #expect(try stranger.spaces().isEmpty)
        cloud.block()
        #expect(try core.spaces().map(\.id) == [localSpace.id])
        #expect(throws: NobisError.self) { try core.save(RecordBody(kind: .task, title: "撤权前打开的草稿"), spaceID: family.id) }
        #expect(try core.records(spaceID: localSpace.id).count == 1)
        try cloud.closeAndClearLocalCache()
    }
    @Test func rootOwnerMustMatchVerifiedShareOwner() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let (repo, member, space) = try await makeCloud(at: url)
        let other = Member(name: "另一个人"), root = try #require(repo.roots().first)
        repo.block(); repo.identify(member.id)
        let forged = try FamilyGrant(spaceID: space.id, accountID: member.id, ownerID: other.id, members: [member, other], writable: true)
        #expect(throws: NobisError.self) { try repo.authorize(forged, root: root, generation: repo.policy.generation) }
        try repo.closeAndClearLocalCache()
    }
    @Test func partialImportsDoNotBecomeZeroOrPartialLedger() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let (repo, member, space) = try await makeCloud(at: url)
        let root = try #require(repo.roots().first), context = repo.container.viewContext
        let revision = Revision(spaceID: space.id, actorID: member.id, body: RecordBody(kind: .task, title: "先到的业务记录"))
        let object = NSEntityDescription.insertNewObject(forEntityName: "RecordRevision", into: context)
        context.assign(object, to: try #require(repo.privateStore)); object.setValue(root, forKey: "root"); object.setValue(try JSONEncoder().encode(revision), forKey: "payload")
        try context.save()
        #expect(throws: NobisError.self) { try repo.load() }
        let audit = NSEntityDescription.insertNewObject(forEntityName: "AuditEvent", into: context)
        context.assign(audit, to: try #require(repo.privateStore)); audit.setValue(root, forKey: "root"); audit.setValue(try JSONEncoder().encode(AuditEvent(revision: revision, action: "create")), forKey: "payload")
        try context.save(); #expect(try repo.load().revisions.count == 1)
        try repo.closeAndClearLocalCache()
    }
    @Test func localCacheWipeLeavesPersonalSQLiteUntouched() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = Fixture()
        let local = try CoreDataRepository(directory: url.appendingPathComponent("Local"), initialSpaces: [f.personal])
        let core = FamilyCore(repository: local, session: f.core.session)
        try core.save(RecordBody(kind: .task, title: "保留个人数据"), spaceID: f.personal.id)
        let (cloud, _, _) = try await makeCloud(at: url.appendingPathComponent("Cloud"))
        try cloud.closeAndClearLocalCache()
        try CloudFamilyRepository.clearDetachedCache(directory: url.appendingPathComponent("Cloud"))
        #expect(try cloud.load().spaces.isEmpty)
        #expect(try local.load().revisions.first?.body.title == "保留个人数据")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Cloud/family-shared.sqlite").path))
    }
    @Test func readOnlyRepositoryRejectsStaleWriterSession() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let (repo, member, space) = try await makeCloud(at: url)
        let core = FamilyCore(repository: repo, session: AccessSession(memberID: member.id, allowedSpaceIDs: [space.id]))
        let root = try #require(repo.roots().first)
        try repo.authorize(FamilyGrant(spaceID: space.id, accountID: member.id, ownerID: member.id, members: [member], writable: false), root: root, generation: repo.policy.generation)
        #expect(try core.spaces().count == 1)
        #expect(throws: NobisError.self) { try core.save(RecordBody(kind: .task, title: "不应写入"), spaceID: space.id) }
        try repo.closeAndClearLocalCache()
    }
    @Test func offlineBranchesDeletionAndRestartPreserveCloudHistory() async throws {
        // Simulates remote Core Data imports; it does not claim to exercise CloudKit transport.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let (repo, member, space) = try await makeCloud(at: url)
        let session = AccessSession(memberID: member.id, allowedSpaceIDs: [space.id])
        let core = FamilyCore(repository: repo, session: session)
        let initial = try core.save(RecordBody(kind: .task, title: "初始"), spaceID: space.id)
        var remoteBody = initial.body; remoteBody.title = "离线设备修改"
        let remote = Revision(recordID: initial.recordID, spaceID: space.id, parents: [initial.id], actorID: member.id, body: remoteBody)
        var localBody = initial.body; localBody.title = "在线设备修改"
        let local = try core.save(localBody, spaceID: space.id, recordID: initial.recordID, expected: [initial.id])
        let root = try #require(repo.roots().first), store = try #require(repo.privateStore)
        func importRevision(_ revision: Revision) throws {
            let context = repo.container.viewContext
            for (entity, payload, id) in [
                ("RecordRevision", try JSONEncoder().encode(revision), revision.id),
                ("AuditEvent", try JSONEncoder().encode(AuditEvent(revision: revision, action: "update")), UUID())
            ] {
                let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
                context.assign(object, to: store)
                object.setValue(root, forKey: "root"); object.setValue(id.uuidString, forKey: "logicalID"); object.setValue(payload, forKey: "payload")
            }
            try context.save()
        }
        try importRevision(remote)
        let conflict = try #require(Record.project(repo.load().revisions).first)
        #expect(conflict.conflicted)
        #expect(Set(conflict.heads.map(\.id)) == [local.id, remote.id])
        #expect(throws: NobisError.self) {
            try core.save(localBody, spaceID: space.id, recordID: initial.recordID, expected: [local.id])
        }
        let resolved = try core.save(localBody, spaceID: space.id, recordID: initial.recordID, expected: [local.id, remote.id])
        let removed = try core.save(resolved.body, spaceID: space.id, recordID: initial.recordID, expected: [resolved.id], deleted: true)
        let staleEdit = Revision(recordID: initial.recordID, spaceID: space.id, parents: [resolved.id], actorID: member.id, body: remoteBody)
        try importRevision(staleEdit)
        let deleted = try #require(Record.project(repo.load().revisions).first)
        #expect(deleted.deleted)
        #expect(Set(deleted.heads.map(\.id)) == [removed.id, staleEdit.id])
        let expectedIDs = Set(try repo.load().revisions.map(\.id))
        // Close without deleting, then reopen the physical cloud stores.
        repo.container.viewContext.reset()
        for store in repo.container.persistentStoreCoordinator.persistentStores {
            try repo.container.persistentStoreCoordinator.remove(store)
        }
        let reopened = CloudFamilyRepository(directory: url, identifier: nil)
        try await reopened.open(); reopened.identify(member.id)
        let reloadedRoot = try #require(reopened.roots().first)
        try reopened.authorize(FamilyGrant(spaceID: space.id, accountID: member.id, ownerID: member.id, members: [member], writable: true), root: reloadedRoot, generation: reopened.policy.generation)
        #expect(Set(try reopened.load().revisions.map(\.id)) == expectedIDs)
        #expect(try Record.project(reopened.load().revisions).first?.deleted == true)
        try reopened.closeAndClearLocalCache()
    }
    @Test func pendingRootIsNotVisibleBeforeIdentityMapping() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let (repo, _, _) = try await makeCloud(at: url)
        repo.block()
        #expect(try repo.roots().count == 1)
        #expect(try repo.load().spaces.isEmpty)
        try repo.closeAndClearLocalCache()
    }
}
