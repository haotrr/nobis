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
    public var invitation: CKShare.Metadata?
    public var preparedShare: CKShare?
    public var onChange: (() -> Void)?
    public var onAccessLost: ((UUID?) -> Void)?
    public let identifier: String?
    public var configured: Bool { identifier?.hasPrefix("iCloud.") == true }
    public var grant: FamilyGrant? { repository?.policy.grant }
    public var isOwner: Bool { connection?.isOwner == true }
    public var canCreateFamily: Bool { accountID != nil && connection == nil && lastImport != nil }
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
        if !configured { state = "待配置开发团队和 CloudKit 容器" }
        let token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
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
        guard let ck = ckContainer else { throw NobisError.validation("请先按 docs/cloudkit-setup.md 配置开发团队和容器，再重新构建。") }
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
            do { try await stack.open() } catch { try? stack.closeAndClearLocalCache(); throw error }
            guard ticket == epoch else { try? stack.closeAndClearLocalCache(); throw CancellationError() }
            repository = stack
        }
        repository?.identify(member)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("enabled"), options: .atomic)
    }
    private func synchronize(ticket: UUID) async throws {
        guard let stack = repository, let accountID, let ck = ckContainer else { return }
        if connection == nil {
            let roots = try stack.roots()
            guard roots.count <= 1 else { stack.block(); onChange?(); throw NobisError.validation("发现多个家庭根，请先核对数据，暂不自动选择。") }
            guard let root = roots.first else { state = lastImport == nil ? "正在检查已有家庭 · 等待首次导入完成" : "iCloud 已连接 · 可创建家庭或接受邀请"; issue = nil; onChange?(); return }
            let space = try stack.space(of: root)
            let shares = try stack.container.fetchShares(matching: [root.objectID])
            if let share = shares[root.objectID] {
                connection = descriptor(share: share, spaceID: space.id, accountID: accountID, isOwner: root.objectID.persistentStore == stack.privateStore)
            } else {
                guard space.ownerID == accountID, root.objectID.persistentStore == stack.privateStore else { throw NobisError.forbidden }
                // Root exists but sharing creation/export hasn't completed. Never create a second root.
                state = "家庭根已保存 · 请继续准备邀请"; issue = nil; onChange?(); return
            }
        }
        guard let connection, connection.accountID == accountID else { throw NobisError.forbidden }
        let database = connection.isOwner ? ck.privateCloudDatabase : ck.sharedCloudDatabase
        let remote = try await database.record(for: connection.recordID)
        guard ticket == epoch else { throw CancellationError() }
        guard let share = remote as? CKShare else { throw NobisError.forbidden }
        let grant = try verifiedGrant(share: share, connection: connection)
        let matches = try stack.roots().filter { (try? stack.space(of: $0).id) == connection.spaceID }
        guard matches.count <= 1 else { throw NobisError.conflict }
        guard let root = matches.first else {
            stack.block(); state = "正在准备家庭数据 · 等待共享根导入"; issue = nil; onChange?(); return
        }
        let rootShares = try stack.container.fetchShares(matching: [root.objectID])
        guard rootShares[root.objectID]?.recordID == share.recordID else {
            stack.block(); state = "正在准备家庭数据 · 等待共享关联导入"; onChange?(); return
        }
        try stack.authorize(grant, root: root, generation: stack.policy.generation)
        // Imports can arrive out of order. Gate the business projection until references are available.
        do { _ = try stack.load() } catch { stack.block(); onChange?(); throw error }
        self.connection?.grant = grant; try saveConnection()
        participants = participantRows(share)
        state = grant.members.count == 2 ? "已加入家庭 · 本地保存后自动同步" : "家庭已连接 · 等待另一位成员接受"
        issue = nil; onChange?()
    }
    private func verifiedGrant(share: CKShare, connection: CloudFamilyConnection) throws -> FamilyGrant {
        guard share.publicPermission == .none, share["nobisFormat"] as? String == "5",
              share["nobisSpaceID"] as? String == connection.spaceID.uuidString,
              let current = share.currentUserParticipant,
              let currentRecord = current.userIdentity.userRecordID,
              let ownerRecord = share.owner.userIdentity.userRecordID else { throw NobisError.forbidden }
        let owner = CloudIdentity.memberID(container: identifier!, userRecordName: ownerRecord.recordName)
        let me = CloudIdentity.memberID(container: identifier!, userRecordName: currentRecord.recordName)
        guard me == accountID, current.role == .owner || current.acceptanceStatus == .accepted,
              current.role == .owner || [.readOnly, .readWrite].contains(current.permission),
              connection.isOwner == (current.role == .owner) else { throw NobisError.forbidden }
        let accepted = share.participants.filter { $0.role == .owner || $0.acceptanceStatus == .accepted }
        guard accepted.count <= 2 else { throw NobisError.validation("首版仅支持两位成员。请拥有者在系统共享管理中移除多余参与者。") }
        let members = try accepted.map { participant -> Member in
            guard let record = participant.userIdentity.userRecordID else { throw NobisError.validation("参与者身份尚未导入，请稍后重试。") }
            return Member(id: CloudIdentity.memberID(container: identifier!, userRecordName: record.recordName), name: displayName(participant))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return try FamilyGrant(spaceID: connection.spaceID, accountID: me, ownerID: owner, members: members, writable: current.role == .owner || current.permission == .readWrite)
    }
    public func createFamily(name: String, memberName: String) async {
        guard !isBusy else { return }; isBusy = true; defer { finishOperation() }; let ticket = epoch
        do {
            try await ensureAccount(ticket: ticket)
            guard connection == nil, let accountID, let stack = repository else { throw NobisError.validation("已有家庭连接，不能再创建一个。") }
            guard lastImport != nil else { throw NobisError.validation("请等待首次云端导入完成，避免重复创建已有家庭。") }
            let root = try stack.createFamily(name: name, member: Member(id: accountID, name: memberName))
            try await prepare(root: root, ticket: ticket)
        } catch { handle(error, ticket: ticket) }
    }
    public func prepareInvitation() async {
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
                preparedShare = share; return
            }
            try await prepare(root: root, ticket: ticket)
        } catch { handle(error, ticket: ticket) }
    }
    private func prepare(root: NSManagedObject, ticket: UUID) async throws {
        guard let stack = repository, let accountID else { throw NobisError.forbidden }
        let space = try stack.space(of: root)
        guard space.ownerID == accountID, root.objectID.persistentStore == stack.privateStore else { throw NobisError.forbidden }
        state = "正在准备邀请 · 等待 CloudKit"
        let existing = try stack.container.fetchShares(matching: [root.objectID])[root.objectID]
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
        try saveConnection(); preparedShare = share
        try await synchronize(ticket: ticket)
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
            try await stack.container.acceptShareInvitations(from: [metadata], into: store)
            guard ticket == epoch else { throw CancellationError() }
            invitation = nil; state = "正在准备家庭数据 · 已接受邀请"
            try await synchronize(ticket: ticket)
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
        if transient {
            let retry = (error as? CKError)?.userInfo[CKErrorRetryAfterKey] as? Double ?? 30
            nextRefreshAfter = Date().addingTimeInterval(max(5, retry))
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
        if let cloud = error as? CKError {
            let retry = cloud.userInfo[CKErrorRetryAfterKey] as? Double ?? 30
            nextRefreshAfter = Date().addingTimeInterval(max(5, retry))
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
        let url = directory.appendingPathComponent("connection.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if removeEnabled {
            let enabled = directory.appendingPathComponent("enabled")
            if FileManager.default.fileExists(atPath: enabled.path) { try FileManager.default.removeItem(at: enabled) }
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("access-denied"))
        onChange?()
    }
    private func observe(_ stack: CloudFamilyRepository) {
        let remote = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: stack.container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRefresh() }
        }
        let event = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: stack.container, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  let end = event.endDate else { return }
            let succeeded = event.succeeded, isImport = event.type == .import, isExport = event.type == .export
            let message = event.error?.localizedDescription
            MainActor.assumeIsolated {
                guard let self else { return }
                if succeeded {
                    if isImport { self.lastImport = end; self.requestRefresh() }
                    if isExport { self.lastExport = end }
                } else { self.issue = message; self.requestRefresh() }
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
            self.refreshTask = nil; await self.connect()
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
