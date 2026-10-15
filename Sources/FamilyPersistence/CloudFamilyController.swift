import Foundation
import Observation
import CloudKit
import CoreData
import FamilyDomain
import FamilyCore

public struct CloudFamilyConnection: Codable, Sendable {
    public let spaceID: UUID
    public let accountID: UUID
    public let shareName: String
    public let zoneName: String
    public let zoneOwner: String
    public let isOwner: Bool
    public let invitationURL: URL?
    public var grant: FamilyGrant?
    public var recordID: CKRecord.ID { CKRecord.ID(recordName: shareName, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwner)) }
}
public struct CloudFamilyParticipant: Identifiable {
    public let id = UUID()
    public let participant: CKShare.Participant
    public let name: String
    public let status: String
    public let isOwner: Bool
}

@MainActor @Observable public final class CloudFamilyController {
    public private(set) var repository: CloudFamilyRepository?
    public private(set) var state = "尚未连接 iCloud"
    public private(set) var issue: String?
    public private(set) var isBusy = false
    public private(set) var accountID: UUID?
    public private(set) var connection: CloudFamilyConnection?
    public private(set) var participants: [CloudFamilyParticipant] = []
    public private(set) var lastImport: Date?
    public private(set) var lastExport: Date?
    public private(set) var syncProgress = CloudSyncProgress()
    private var syncFailures: [String: String] = [:]
    private var syncStateIssue: String?
    public var syncIssue: String? { syncStateIssue ?? syncFailures.values.sorted().first }
    private var importedStores: Set<String> = []
    private var hasFinishedInitialImport: Bool {
        guard let repository else { return false }
        let ids = repository.container.persistentStoreCoordinator.persistentStores.map(\.identifier)
        return ids.count == 2 && Set(ids).isSubset(of: importedStores)
    }
    public private(set) var hasUnpreparedFamily = false
    public private(set) var pendingInvitationCount = 0
    private var activeImports: Set<UUID> = []
    private var activeExports: Set<UUID> = []
    public var syncStatus: String {
        if syncIssue != nil { return "云端传输未完成 · 本机内容已保留" }
        if !activeExports.isEmpty { return "正在上传到 iCloud" }
        if !activeImports.isEmpty { return "正在接收 iCloud 更新" }
        if syncProgress.hasPendingWrites { return "已保存到本机 · 等待上传" }
        if issue != nil { return "连接需检查 · 本机内容已保留" }
        if grant != nil { return "已连接 iCloud" }
        return state
    }
    public var membershipDescription: String {
        guard let grant else { return "尚未连接云家庭" }
        return grant.members.count > 1 ? "两人共同使用 · iCloud 同步" : "自己的设备间同步"
    }
    public var invitation: CKShare.Metadata?
    public var preparedShare: CKShare?
    public var onChange: (() -> Void)?
    public var onAccessLost: ((UUID?) -> Void)?
    public let identifier: String?
    public var configured: Bool { identifier?.hasPrefix("iCloud.") == true }
    public var grant: FamilyGrant? { repository?.policy.grant }
    public var isOwner: Bool { connection?.isOwner == true }
    public var canCreateFamily: Bool { accountID != nil && connection == nil && hasFinishedInitialImport && !hasUnpreparedFamily }
    public var enabled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("enabled").path) }
    public var ckContainer: CKContainer? { identifier.map { CKContainer(identifier: $0) } }
    private let directory: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var queuedShare: CKShare?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var nextRefreshAfter = Date.distantPast
    public init(directory: URL, identifier: String?) {
        self.identifier = identifier?.isEmpty == false ? identifier : nil
        self.directory = directory.appendingPathComponent(CloudIdentity.namespace(identifier ?? "unconfigured"))
        if let data = try? LocalMetadataFile.read(from: self.directory.appendingPathComponent("connection.json")) { connection = try? JSONDecoder().decode(CloudFamilyConnection.self, from: data) }
        if FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("access-denied").path) { connection?.grant = nil }
        if let data = try? LocalMetadataFile.read(from: self.directory.appendingPathComponent("sync-progress.json")),
           let progress = try? JSONDecoder().decode(CloudSyncProgress.self, from: data) { syncProgress = progress }
        if !configured { state = "待配置开发团队和 CloudKit 容器" }
        let token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.accountChanged() }
        }
        observers.append(token)
    }
    public func receive(_ metadata: CKShare.Metadata) {
        guard configured, metadata.containerIdentifier == identifier,
              metadata.share["nobisFormat"] as? String == "5",
              let raw = metadata.share["nobisSpaceID"] as? String, UUID(uuidString: raw) != nil,
              metadata.share.publicPermission == .none else {
            issue = "邀请不属于当前 Nobis 容器，或应用尚未配置 CloudKit。"; return
        }
        invitation = metadata
    }
    public func reportSharingError(_ message: String) { issue = message; state = "系统共享操作未完成" }
    public func connect() async {
        guard !isBusy else { refreshAgain = true; return }
        refreshTask?.cancel(); refreshTask = nil
        nextRefreshAfter = Date().addingTimeInterval(5)
        isBusy = true; defer { finishOperation() }
        let ticket = epoch
        do {
            try await ensureAccount(ticket: ticket)
            try await synchronize(ticket: ticket)
        } catch { handle(error, ticket: ticket) }
    }
    private func ensureAccount(ticket: UUID) async throws {
        guard let ck = ckContainer else { throw NobisError.validation("请先按 docs/guides/cloudkit-setup.md 配置开发团队和容器，再重新构建。") }
        let status = try await ck.accountStatus()
        guard ticket == epoch else { throw CancellationError() }
        guard status == .available else {
            if status == .noAccount || status == .restricted {
                accountChanged()
                throw NobisError.validation(status == .noAccount ? "请先在系统设置登录 iCloud。" : "当前 iCloud 账户受到系统限制。")
            }
            throw CKError(.accountTemporarilyUnavailable)
        }
        let userID = try await ck.userRecordID()
        guard ticket == epoch else { throw CancellationError() }
        let member = CloudIdentity.memberID(container: identifier!, userRecordName: userID.recordName)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("access-denied").path) { try clearLocalAccess(removeEnabled: false) }
        if let old = accountID ?? connection?.accountID, old != member {
            try clearLocalAccess(removeEnabled: false)
        }
        accountID = member
        if repository == nil {
            let stack = CloudFamilyRepository(directory: directory.appendingPathComponent("Stores"), identifier: identifier)
            observe(stack)
            stack.onLocalSave = { [weak self] store in
                guard let self else { return }
                self.syncProgress.saved(store: store, at: Date())
                self.saveSyncProgress()
            }
            do { try await stack.open() } catch { try? stack.closeAndClearLocalCache(); throw error }
            guard ticket == epoch else { try? stack.closeAndClearLocalCache(); throw CancellationError() }
            repository = stack
        }
        repository?.identify(member)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("enabled"), options: .atomic)
    }
    private func synchronize(ticket: UUID, participantMetadata suppliedMetadata: CKShare.Metadata? = nil) async throws {
        guard let stack = repository, let accountID, let ck = ckContainer else { return }
        if connection == nil {
            hasUnpreparedFamily = false
            let roots = try stack.roots()
            guard roots.count <= 1 else { stack.block(); onChange?(); throw NobisError.validation("发现多个家庭根，请先核对数据，暂不自动选择。") }
            guard let root = roots.first else { state = !hasFinishedInitialImport ? "正在检查已有家庭 · 等待首次导入完成" : "iCloud 已连接 · 可创建家庭或接受邀请"; issue = nil; onChange?(); return }
            let space = try stack.space(of: root)
            let shares = try stack.container.fetchShares(matching: [root.objectID])
            if let share = shares[root.objectID] {
                connection = descriptor(share: share, spaceID: space.id, accountID: accountID, isOwner: root.objectID.persistentStore == stack.privateStore)
            } else {
                guard space.ownerID == accountID, root.objectID.persistentStore == stack.privateStore else { throw NobisError.forbidden }
                // Root exists but sharing creation/export hasn't completed. Never create a second root.
                hasUnpreparedFamily = true
                state = "云家庭已保存 · 继续完成连接"; issue = nil; onChange?(); return
            }
        }
        guard let connection, connection.accountID == accountID else { throw NobisError.forbidden }
        let matches = try stack.roots().filter { (try? stack.space(of: $0).id) == connection.spaceID }
        guard matches.count <= 1 else { throw NobisError.conflict }
        guard let root = matches.first else {
            stack.block(); state = "正在准备家庭数据 · 等待共享根导入"; issue = nil; onChange?(); return
        }
        let rootShares = try stack.container.fetchShares(matching: [root.objectID])
        guard let localShare = rootShares[root.objectID] else {
            stack.block(); state = "正在准备家庭数据 · 等待共享关联导入"; onChange?(); return
        }
        let share: CKShare
        var participantMetadata = suppliedMetadata
        if connection.isOwner {
            let remote = try await ck.privateCloudDatabase.record(for: connection.recordID)
            guard ticket == epoch else { throw CancellationError() }
            guard let remoteShare = remote as? CKShare else { throw NobisError.forbidden }
            share = remoteShare
        } else {
            // Core Data owns the shared-zone import. Reading the CKShare directly from
            // CKDatabase can race that import immediately after invitation acceptance.
            if localShare.currentUserParticipant?.acceptanceStatus == .accepted {
                share = localShare
            } else if let url = connection.invitationURL {
                let metadata = try await ck.shareMetadata(for: url)
                guard ticket == epoch else { throw CancellationError() }
                participantMetadata = metadata
                share = metadata.share
            } else {
                stack.block(); state = "正在核验家庭成员身份 · 等待共享元数据"; onChange?(); return
            }
        }
        guard localShare.recordID == share.recordID, share.recordID == connection.recordID else { throw NobisError.forbidden }
        let grant = try verifiedGrant(share: share, connection: connection, participantMetadata: participantMetadata)
        try stack.authorize(grant, root: root, generation: stack.policy.generation)
        // Imports can arrive out of order. Gate the business projection until references are available.
        do { _ = try stack.load() } catch { stack.block(); onChange?(); throw error }
        self.connection?.grant = grant; try saveConnection()
        hasUnpreparedFamily = false
        participants = participantRows(share)
        pendingInvitationCount = share.participants.filter { $0.role != .owner && $0.acceptanceStatus != .accepted }.count
        state = grant.members.count == 2 ? "两人已连接 · 自动同步" : pendingInvitationCount > 0 ? "跨设备同步已连接 · 邀请等待接受" : "跨设备同步已连接 · 可邀请另一位"
        issue = nil; onChange?()
    }
    private func verifiedGrant(share: CKShare, connection: CloudFamilyConnection, participantMetadata: CKShare.Metadata? = nil) throws -> FamilyGrant {
        guard share.publicPermission == .none else { throw NobisError.validation("共享权限核验失败：不是私有共享。") }
        let format = share["nobisFormat"] as? String
        let shareSpaceID = share["nobisSpaceID"] as? String
        if connection.isOwner || format != nil || shareSpaceID != nil {
            guard format == "5", shareSpaceID == connection.spaceID.uuidString else {
                throw NobisError.validation("共享格式尚未就绪，请拥有者继续准备邀请。")
            }
        }
        guard let current = share.currentUserParticipant,
              let currentRecord = current.userIdentity.userRecordID,
              let ownerRecord = share.owner.userIdentity.userRecordID else {
            throw NobisError.validation("共享身份尚未就绪，请稍后检查同步状态。")
        }
        guard let accountID else { throw NobisError.forbidden }
        if let participantMetadata {
            guard participantMetadata.containerIdentifier == identifier,
                  participantMetadata.share.recordID == share.recordID,
                  participantMetadata.participantStatus == .accepted,
                  participantMetadata.participantRole == current.role else {
                throw NobisError.validation("共享邀请尚未由当前 iCloud 账户接受。")
            }
        }
        let owner = try CloudParticipantIdentity.memberID(container: identifier!, recordName: ownerRecord.recordName,
            isCurrentParticipant: share.owner == current, verifiedAccountID: accountID)
        let me = try CloudParticipantIdentity.memberID(container: identifier!, recordName: currentRecord.recordName,
            isCurrentParticipant: true, verifiedAccountID: accountID)
        guard me == accountID else { throw NobisError.validation("共享身份与当前 iCloud 账户不一致。") }
        let acceptedCurrent = current.role == .owner || current.acceptanceStatus == .accepted || participantMetadata?.participantStatus == .accepted
        let currentPermission = participantMetadata?.participantPermission ?? current.permission
        guard acceptedCurrent,
              current.role == .owner || [.readOnly, .readWrite].contains(currentPermission),
              connection.isOwner == (current.role == .owner) else {
            throw NobisError.validation("共享角色或接受状态尚未通过核验。")
        }
        let accepted = share.participants.filter { $0.role == .owner || $0.acceptanceStatus == .accepted || ($0 == current && acceptedCurrent) }
        guard accepted.count <= 2 else { throw NobisError.validation("首版仅支持两位成员。请拥有者在系统共享管理中移除多余参与者。") }
        let members = try accepted.map { participant -> Member in
            guard let record = participant.userIdentity.userRecordID else { throw NobisError.validation("参与者身份尚未导入，请稍后重试。") }
            return Member(id: try CloudParticipantIdentity.memberID(container: identifier!, recordName: record.recordName, isCurrentParticipant: participant == current, verifiedAccountID: accountID), name: displayName(participant))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return try FamilyGrant(spaceID: connection.spaceID, accountID: me, ownerID: owner, members: members, writable: current.role == .owner || currentPermission == .readWrite)
    }
    public func createFamily(name: String, memberName: String) async {
        guard !isBusy else { return }; isBusy = true; defer { finishOperation() }; let ticket = epoch
        do {
            try await ensureAccount(ticket: ticket)
            guard connection == nil, let accountID, let stack = repository else { throw NobisError.validation("已有家庭连接，不能再创建一个。") }
            guard hasFinishedInitialImport else { throw NobisError.validation("请等待首次云端导入完成，避免重复创建已有家庭。") }
            let root = try stack.createFamily(name: name, member: Member(id: accountID, name: memberName))
            try await prepare(root: root, ticket: ticket, presentInvitation: false)
        } catch { handle(error, ticket: ticket) }
    }
    public func prepareInvitation(presentInvitation: Bool = true) async {
        guard !isBusy else { return }; isBusy = true; defer { finishOperation() }; let ticket = epoch
        do {
            try await ensureAccount(ticket: ticket)
            guard let stack = repository else { throw NobisError.forbidden }
            let roots = try stack.roots()
            guard roots.count == 1, let root = roots.first else { throw NobisError.validation("家庭数据尚未到齐，请稍后重试。") }
            if let connection {
                guard connection.isOwner, let ck = ckContainer else { throw NobisError.forbidden }
                guard let share = try await ck.privateCloudDatabase.record(for: connection.recordID) as? CKShare else { throw NobisError.forbidden }
                guard ticket == epoch else { throw CancellationError() }
                try await prepare(root: root, ticket: ticket, existingShare: share, presentInvitation: presentInvitation); return
            }
            try await prepare(root: root, ticket: ticket, presentInvitation: presentInvitation)
        } catch { handle(error, ticket: ticket) }
    }
    private func prepare(root: NSManagedObject, ticket: UUID, existingShare: CKShare? = nil, presentInvitation: Bool = true) async throws {
        guard let stack = repository, let accountID else { throw NobisError.forbidden }
        let space = try stack.space(of: root)
        guard space.ownerID == accountID, root.objectID.persistentStore == stack.privateStore else { throw NobisError.forbidden }
        state = "正在准备邀请 · 等待 CloudKit"
        let existing = try existingShare ?? stack.container.fetchShares(matching: [root.objectID])[root.objectID]
        let share: CKShare
        if let existing { share = existing } else { (_, share, _) = try await stack.container.share([root], to: nil) }
        guard ticket == epoch else { throw CancellationError() }
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = space.name as CKRecordValue
        share["nobisFormat"] = "5" as CKRecordValue; share["nobisSpaceID"] = space.id.uuidString as CKRecordValue
        guard let store = stack.privateStore else { throw NobisError.forbidden }
        try await stack.container.persistUpdatedShare(share, in: store)
        guard ticket == epoch else { throw CancellationError() }
        connection = descriptor(share: share, spaceID: space.id, accountID: accountID, isOwner: true)
        try saveConnection()
        try await synchronize(ticket: ticket)
        if presentInvitation { preparedShare = share }
    }
    public func acceptInvitation() async {
        guard !isBusy, let metadata = invitation else { return }; isBusy = true; defer { finishOperation() }; let ticket = epoch
        do {
            try await ensureAccount(ticket: ticket)
            guard let stack = repository, let store = stack.sharedStore, let accountID,
                  let raw = metadata.share["nobisSpaceID"] as? String, let spaceID = UUID(uuidString: raw) else { throw NobisError.forbidden }
            guard connection == nil || connection?.spaceID == spaceID else { throw NobisError.validation("已经连接一个家庭，请先退出后再加入。") }
            guard try stack.roots().allSatisfy({ (try? stack.space(of: $0).id) == spaceID }) else { throw NobisError.validation("已有另一家庭根，不能混入新的邀请。") }
            connection = descriptor(share: metadata.share, spaceID: spaceID, accountID: accountID, isOwner: false)
            try saveConnection()
            let acceptedMetadata: CKShare.Metadata
            if metadata.participantStatus == .accepted {
                acceptedMetadata = metadata
            } else {
                let accepted = try await stack.container.acceptShareInvitations(from: [metadata], into: store)
                guard let result = accepted.first(where: { $0.share.recordID == metadata.share.recordID }) else {
                    throw NobisError.validation("CloudKit 未返回已接受的家庭邀请，请稍后重试。")
                }
                acceptedMetadata = result
            }
            guard ticket == epoch else { throw CancellationError() }
            invitation = nil; state = "正在准备家庭数据 · 已接受邀请"
            try await synchronize(ticket: ticket, participantMetadata: acceptedMetadata)
        } catch { handle(error, ticket: ticket) }
    }
    public func retryInvitation() async {
        guard let url = connection?.invitationURL, let ck = ckContainer, !isBusy else { await connect(); return }
        do { receive(try await ck.shareMetadata(for: url)) } catch { issue = error.localizedDescription }
    }
    /// Required after system sharing UI mutates a CKShare; refresh the local Core Data share cache.
    public func shareDidSave(_ share: CKShare) async {
        if isBusy { queuedShare = share; return }
        guard !isBusy, let stack = repository, let connection,
              share.recordID == connection.recordID,
              let store = connection.isOwner ? stack.privateStore : stack.sharedStore else { return }
        isBusy = true; defer { finishOperation() }; let ticket = epoch
        do { try await stack.container.persistUpdatedShare(share, in: store); guard ticket == epoch else { return }; try await synchronize(ticket: ticket) }
        catch { handle(error, ticket: ticket) }
    }
    public func revoke(_ participant: CKShare.Participant) async {
        guard !isBusy, let connection, connection.isOwner, let ck = ckContainer, let stack = repository, let store = stack.privateStore else { return }
        isBusy = true; defer { finishOperation() }; let ticket = epoch
        do {
            guard let share = try await ck.privateCloudDatabase.record(for: connection.recordID) as? CKShare else { throw NobisError.forbidden }
            guard ticket == epoch, share.currentUserParticipant?.role == .owner,
                  let target = share.participants.first(where: { $0.isEqual(participant) }), target.role != .owner else { throw NobisError.forbidden }
            share.removeParticipant(target)
            try await stack.container.persistUpdatedShare(share, in: store)
            guard ticket == epoch else { return }; preparedShare = nil
            try await synchronize(ticket: ticket)
        } catch { handle(error, ticket: ticket) }
    }
    public func leave() async {
        guard !isBusy, let connection, !connection.isOwner, let ck = ckContainer else { return }
        isBusy = true; defer { finishOperation() }; let ticket = epoch
        do {
            try await ensureAccount(ticket: ticket)
            guard self.connection?.accountID == connection.accountID, accountID == connection.accountID else { throw NobisError.forbidden }
            // Deleting a share as a participant leaves it; do not delete its record zone or business objects.
            _ = try await ck.sharedCloudDatabase.deleteRecord(withID: connection.recordID)
            guard ticket == epoch else { return }
            epoch = UUID()
            do { try clearLocalAccess(removeEnabled: true); state = "已退出家庭 · 此设备共享缓存已清理" }
            catch { state = "已退出家庭 · 缓存清理需重试"; issue = error.localizedDescription }
        } catch { handle(error, ticket: ticket) }
    }
    public func systemStoppedSharing() async {
        // This callback reports a completed server-side stop. Immediately deny cached access, without another server mutation.
        epoch = UUID()
        do { try clearLocalAccess(removeEnabled: true); state = "系统共享已停止 · 此设备共享缓存已清理" }
        catch { state = "共享访问已关闭 · 缓存清理需重试"; issue = error.localizedDescription }
    }
    private func handle(_ error: Error, ticket: UUID) {
        guard ticket == epoch, !(error is CancellationError) else { return }
        let disposition = CloudFailurePolicy.classify(error)
        if disposition == .accountLost { accountChanged(); return }
        if disposition == .accessLost, connection != nil {
            epoch = UUID()
            do { try clearLocalAccess(removeEnabled: true); state = "家庭访问已失效 · 此设备共享缓存已清理" }
            catch { state = "访问已关闭 · 缓存清理需重试"; issue = error.localizedDescription }
            return
        }
        let transient = disposition == .retry
        if let delay = CloudFailurePolicy.retryDelay(for: error) {
            nextRefreshAfter = Date().addingTimeInterval(delay)
            // finishOperation schedules this even when the cached grant path returns early.
            refreshAgain = true
        }
        if transient, let connection, let cached = connection.grant, cached.accountID == accountID, let stack = repository,
           let root = try? stack.roots().first(where: { (try? stack.space(of: $0).id) == cached.spaceID }) {
            do {
                try stack.authorize(cached, root: root, generation: stack.policy.generation)
                _ = try stack.load(); state = "离线 · 使用上次已核验的家庭权限"; issue = error.localizedDescription; onChange?(); return
            } catch { stack.block() }
        } else if !transient {
            repository?.block(); self.connection?.grant = nil; try? saveConnection()
        }
        state = "连接未就绪"; issue = error.localizedDescription; onChange?()
    }
    private func accountChanged() {
        epoch = UUID(); repository?.block(); accountID = nil; preparedShare = nil; invitation = nil
        onAccessLost?(connection?.spaceID); onChange?()
        do { try clearLocalAccess(removeEnabled: false); state = "iCloud 账户发生变化 · 请重新连接" }
        catch { state = "账户访问已关闭 · 缓存清理需重试"; issue = error.localizedDescription }
    }
    private func clearLocalAccess(removeEnabled: Bool) throws {
        let lost = connection?.spaceID
        refreshTask?.cancel(); refreshTask = nil; refreshAgain = false; queuedShare = nil
        preparedShare = nil; participants = []
        repository?.block(); onAccessLost?(lost); onChange?()
        // A durable deny marker prevents a cleanup failure from restoring old offline permissions next launch.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("access-denied"), options: .atomic)
        self.connection?.grant = nil; try saveConnection()
        for observer in observers.dropFirst() { NotificationCenter.default.removeObserver(observer) }
        observers = Array(observers.prefix(1))
        try repository?.closeAndClearLocalCache()
        try CloudFamilyRepository.clearDetachedCache(directory: directory.appendingPathComponent("Stores"))
        repository = nil; accountID = nil; participants = []; connection = nil; preparedShare = nil
        lastImport = nil; lastExport = nil
        activeImports = []; activeExports = []; syncProgress = CloudSyncProgress(); syncFailures = [:]; syncStateIssue = nil; importedStores = []
        hasUnpreparedFamily = false; pendingInvitationCount = 0
        saveSyncProgress()
        let url = directory.appendingPathComponent("connection.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if removeEnabled {
            let enabled = directory.appendingPathComponent("enabled")
            if FileManager.default.fileExists(atPath: enabled.path) { try FileManager.default.removeItem(at: enabled) }
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("access-denied"))
        onChange?()
    }
    private func saveSyncProgress() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(syncProgress).write(to: directory.appendingPathComponent("sync-progress.json"), options: LocalMetadataFile.writingOptions)
            syncStateIssue = nil
        } catch { syncStateIssue = "同步状态记录未保存，业务内容仍保留在本机。" }
    }
    private func observe(_ stack: CloudFamilyRepository) {
        let ticket = epoch
        // Never synchronously dispatch Core Data notifications to main: share() may wait on that queue.
        let remote = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: stack.container.persistentStoreCoordinator, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == ticket else { return }
                self.requestRefresh()
            }
        }
        let event = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: stack.container, queue: nil) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            let end = event.endDate, start = event.startDate, id = event.identifier, store = event.storeIdentifier
            let succeeded = event.succeeded, isImport = event.type == .import, isExport = event.type == .export
            let failureKey = "\(store):\(event.type.rawValue)"
            let error = event.error
            Task { @MainActor [weak self] in
                guard let self, self.epoch == ticket else { return }
                if end == nil {
                    if isImport { self.activeImports.insert(id) }
                    if isExport { self.activeExports.insert(id) }
                    return
                }
                self.activeImports.remove(id); self.activeExports.remove(id)
                guard let end else { return }
                if succeeded {
                    if isImport { self.importedStores.insert(store); self.lastImport = end; self.syncProgress.imported(at: end) }
                    if isExport {
                        self.lastExport = end
                        self.syncProgress.exported(store: store, started: start, ended: end, succeeded: true)
                    }
                    self.syncFailures.removeValue(forKey: failureKey)
                    if isImport || isExport { self.saveSyncProgress(); self.requestRefresh() }
                } else {
                    self.syncFailures[failureKey] = error?.localizedDescription ?? "云端传输未完成，请稍后重试。"
                    if let error, let delay = CloudFailurePolicy.retryDelay(for: error) {
                        self.nextRefreshAfter = max(self.nextRefreshAfter, Date().addingTimeInterval(delay))
                    }
                    self.requestRefresh()
                }
            }
        }
        observers += [remote, event]
    }
    private func requestRefresh() {
        if isBusy { refreshAgain = true; return }
        guard refreshTask == nil else { return }
        let delay = max(1, nextRefreshAfter.timeIntervalSinceNow)
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.refreshTask = nil
            // A later CloudKit event may extend the backoff while this task sleeps.
            if self.nextRefreshAfter > Date() { self.requestRefresh(); return }
            await self.connect()
        }
    }
    private func finishOperation() {
        isBusy = false
        if let share = queuedShare { queuedShare = nil; Task { await shareDidSave(share) }; return }
        if refreshAgain { refreshAgain = false; requestRefresh() }
    }
    private func saveConnection() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let connection { try JSONEncoder().encode(connection).write(to: directory.appendingPathComponent("connection.json"), options: LocalMetadataFile.writingOptions) }
    }
    private func descriptor(share: CKShare, spaceID: UUID, accountID: UUID, isOwner: Bool) -> CloudFamilyConnection {
        CloudFamilyConnection(spaceID: spaceID, accountID: accountID, shareName: share.recordID.recordName, zoneName: share.recordID.zoneID.zoneName, zoneOwner: share.recordID.zoneID.ownerName, isOwner: isOwner, invitationURL: share.url)
    }
    private func displayName(_ participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let name = PersonNameComponentsFormatter().string(from: components)
            if !name.isEmpty { return name }
        }
        return participant.role == .owner ? "家庭拥有者" : "家庭成员"
    }
    private func participantRows(_ share: CKShare) -> [CloudFamilyParticipant] {
        share.participants.map { CloudFamilyParticipant(participant: $0, name: displayName($0), status: $0.role == .owner ? "拥有者" : $0.acceptanceStatus == .accepted ? "已接受" : "等待接受", isOwner: $0.role == .owner) }
    }
}
