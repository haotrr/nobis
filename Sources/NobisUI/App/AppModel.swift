import Foundation
import SwiftUI
import UserNotifications
import CloudKit
import FamilyDomain
import FamilyCore
import FamilyPersistence

@MainActor @Observable public final class AppModel {
    public var spaces: [Space] = []
    public var selectedSpaceID: UUID?
    /// Shared only by the ledger and its financial reports; other pages own their filters.
    public var browsingScope: LifeScope = .shared {
        didSet { if browsingScope != oldValue { recordPanel.close() } }
    }
    public var projectScope: LifeScope = .all { didSet { if oldValue != projectScope { recordPanel.close() } } }
    public var noteScope: LifeScope = .all
    public var scheduleScope: LifeScope = .all { didSet { if oldValue != scheduleScope { recordPanel.close() } } }
    public private(set) var today = LocalDay(date: Date())
    public var records: [Record] = []
    public var summaries: [LedgerSummary] = []
    public var error: String?
    public var notice: String?
    public var legacyMigrationStatus: String?
    private var bootstrapMember: Member?
    public var cloudOnly: Bool { cloud.configured }
    public var accountProfile: Member? { privateCloud.repository?.profile ?? (cloudOnly ? nil : bootstrapMember) }
    public var studioMemberships: [StudioMembership] {
        guard let grant = cloud.grant else { return [] }
        return [StudioMembership(studioID: grant.spaceID, accountID: grant.accountID, isOwner: grant.ownerID == grant.accountID, writable: grant.writable)]
    }
    public var ready = false
    public var setupRequired = false
    public var showingCloudSetup = false
    public var startupDiagnostic = ""
    public var readComments: Set<UUID> = []
    public var draftStore: DocumentDraftStore { DocumentDraftStore(directory: directory.appendingPathComponent("DocumentDrafts")) }
    public var notificationStatus = "尚未启用"
    public private(set) var reminderPreferences = ReminderPreferences()
    public private(set) var reminderSettingsError: String?
    public var isReminderPreviewOnly: Bool { !notificationsEnabled }
    private var notificationGeneration = 0
    private var schedulingNotifications = false
    private var permissionRequested = false
    private var displayedSpaceID: UUID?
    public var core: FamilyCore?
    public let directory: URL
    public let privateCloud: PrivateCloudController
    public let cloud: CloudFamilyController
    public var accessEpoch = UUID()
    public let recordPanel = RecordPanelState()
    var localRepository: CoreDataRepository?
    var memberID: UUID?
    private let notificationsEnabled: Bool
    public init(directory: URL? = nil, cloudIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "NobisCloudContainer") as? String, notificationsEnabled: Bool = true) {
        self.notificationsEnabled = notificationsEnabled
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nobis", isDirectory: true)
        privateCloud = PrivateCloudController(directory: self.directory.appendingPathComponent("PrivateCloud"), identifier: cloudIdentifier)
        cloud = CloudFamilyController(directory: self.directory.appendingPathComponent("CloudFamily"), identifier: cloudIdentifier)
        do {
            let identityURL = self.directory.appendingPathComponent("identity.json")
            if FileManager.default.fileExists(atPath: identityURL.path) {
                let member = try JSONDecoder().decode(Member.self, from: LocalMetadataFile.read(from: identityURL))
                try open(member: member)
            } else { setupRequired = true }
        } catch { recordStartupFailure(error) }
        if let data = try? LocalMetadataFile.read(from: self.directory.appendingPathComponent("CommentReads.json")), let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) { readComments = ids }
        let reminderURL = self.directory.appendingPathComponent("ReminderPreferences.json")
        if FileManager.default.fileExists(atPath: reminderURL.path) {
            do {
                let value = try JSONDecoder().decode(ReminderPreferences.self, from: LocalMetadataFile.read(from: reminderURL))
                try value.validate(); reminderPreferences = value
            } catch {
                reminderPreferences.enabled = false
                reminderSettingsError = "提醒设置读取失败，请核对并重新保存：\(error.localizedDescription)"
            }
        }
        privateCloud.onChange = { [weak self] in self?.rebind() }
        privateCloud.onAccessLost = { [weak self] id in
            if let id { self?.invalidateCloudUI(spaceID: id) } else { self?.rebind() }
        }
        cloud.onChange = { [weak self] in self?.rebind() }
        cloud.onAccessLost = { [weak self] id in self?.invalidateCloudUI(spaceID: id) }
        NobisCloudInvitation.receive = { [weak self] metadata in self?.cloud.receive(metadata) }
        if let pending = NobisCloudInvitation.pending { NobisCloudInvitation.pending = nil; cloud.receive(pending) }
        if cloud.enabled { Task { await cloud.connect() } }
    }
    public func updateAccountProfile(_ member: Member, expected: Member?) throws {
        guard let personal = privateCloud.repository else { throw NobisError.validation("请先连接个人 iCloud。") }
        try personal.updateProfile(member, expected: expected)
        rebind(); notice = "个人资料已保存，正在同步到你的设备与 Studio。"
    }
    public func updateStudioName(_ name: String, expected: Space) throws {
        guard let repository = cloud.repository, let grant = cloud.grant,
              let member = expected.members.first(where: { $0.id == grant.accountID }) else { throw NobisError.forbidden }
        try repository.updateDisplay(name: name, member: member, expected: expected)
        rebind()
    }
    private func publishAccountProfile() {
        guard let profile = privateCloud.repository?.profile, let repository = cloud.repository,
              let grant = cloud.grant, grant.accountID == profile.id, grant.writable else { return }
        do {
            guard let space = try repository.load().spaces.first,
                  space.members.first(where: { $0.id == profile.id }) != profile else { return }
            try repository.updateDisplay(name: space.name, member: profile, expected: space)
        } catch { notice = "个人资料已保存，Studio 展示资料待同步：" + error.localizedDescription }
    }
    public func retryOpening() {
        error = nil
        do {
            let member = try JSONDecoder().decode(Member.self, from: LocalMetadataFile.read(from: directory.appendingPathComponent("identity.json")))
            try open(member: member)
            if ready { startupDiagnostic = "" }
        } catch { recordStartupFailure(error) }
    }
    private func recordStartupFailure(_ failure: Error) {
        let ns = failure as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        startupDiagnostic = "打开本地资料失败 · \(ns.domain) \(ns.code)" + (underlying.map { " · \($0.domain) \($0.code)" } ?? "")
        error = failure.localizedDescription
    }
    public func unreadComments(for documentID: UUID) -> Int {
        let roots = Set(activeRecords.filter { $0.body.kind == .comment && $0.body.relatedRecordID == documentID }.map(\.id))
        return activeRecords.filter { record in
            record.body.kind == .comment && (record.body.relatedRecordID == documentID || record.body.relatedRecordID.map(roots.contains) == true) &&
            record.latest.actorID != core?.session.actorID(in: record.latest.spaceID) && !readComments.contains(record.latest.id)
        }.count
    }
    public func markCommentsRead(_ comments: [Record]) {
        let updated = readComments.union(comments.map { $0.latest.id })
        guard updated != readComments else { return }
        perform {
            try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("CommentReads.json"), options: LocalMetadataFile.writingOptions)
            readComments = updated
        }
    }
    private func open(member: Member) throws {
        let hasLegacy = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Stores/spaces.json").path)
        let repository = cloudOnly && !hasLegacy ? nil : try CoreDataRepository(directory: directory.appendingPathComponent("Stores"))
        localRepository = repository; memberID = member.id; bootstrapMember = member
        ready = true; setupRequired = false; rebind(initialSnapshot: try repository?.load())
    }
    public var localMemberName: String { accountProfile?.name ?? bootstrapMember?.name ?? "我" }
    public func rebind() { rebind(initialSnapshot: nil) }
    private func rebind(initialSnapshot: Snapshot?) {
        guard let memberID else { return }
        records = []; summaries = []
        perform {
            let localSpaces = cloudOnly ? [] : try localRepository?.loadSpaces() ?? []
            var routes: [any Repository] = cloudOnly ? [] : [localRepository].compactMap { $0 }
            var ids = Set(localSpaces.map(\.id)); var mapping: [UUID: UUID] = [:]
            if let shared = cloud.repository, let grant = cloud.grant {
                routes.append(shared)
                ids.insert(grant.spaceID); mapping[grant.spaceID] = grant.accountID
            }
            if let personal = privateCloud.repository {
                routes.append(personal)
                ids.insert(personal.spaceID); mapping[personal.spaceID] = personal.ownerID
            }
            let repository = SpaceRepositoryRouter(stores: routes)
            core = FamilyCore(repository: repository, session: AccessSession(memberID: memberID, allowedSpaceIDs: ids, memberIDsBySpace: mapping))
            spaces = try core!.spaces().sorted { a, b in a.kind == b.kind ? a.name < b.name : a.kind == .personal }
            selectedSpaceID = workspace.commonID
            refresh(initialSnapshot: !cloudOnly && cloud.repository == nil && privateCloud.repository == nil ? initialSnapshot : nil)
            publishAccountProfile()
        }
    }
    private func invalidateCloudUI(spaceID: UUID?) {
        if let id = spaceID ?? cloud.grant?.spaceID {
            do {
                try draftStore.remove(spaceID: id)
                try DocumentDraftStore(directory: directory.appendingPathComponent("CommentDrafts")).remove(spaceID: id)
            } catch { self.error = "访问已关闭，但本机草稿清理未完成：" + error.localizedDescription }
        }
        recordPanel.reset()
        accessEpoch = UUID(); records = []; summaries = []; notice = nil
        rebind()
        Task {
            let center = UNUserNotificationCenter.current()
            let prefix = spaceID.map { "nobis:\($0):" }
            let pending = await center.pendingNotificationRequests()
            let ids = pending.filter { prefix.map($0.identifier.hasPrefix) ?? false }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: ids)
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter { item in prefix.map(item.request.identifier.hasPrefix) ?? false }.map { $0.request.identifier })
        }
    }
    public func visibility(for spaceID: UUID) -> String {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return "空间访问已关闭" }
        if space.kind == .personal { return spaceID == privateCloud.spaceID ? "仅自己 · 个人 iCloud" : "仅自己 · 本地" }
        return cloud.grant?.spaceID == spaceID ? cloud.membershipDescription : "仅此设备 · 本地共同空间"
    }
    public func canWrite(spaceID: UUID) -> Bool { cloud.grant?.spaceID != spaceID || cloud.grant?.writable == true }

    public var saveStatus: String { cloud.enabled ? cloud.syncStatus : "仅保存在此设备" }
    public func setupAndConnect(name: String, familyName: String) {
        setup(name: name, familyName: familyName, partnerName: "")
        if ready { showingCloudSetup = true; Task { await privateCloud.enable(name: localMemberName) } }
    }
    public func setup(name: String, familyName: String, partnerName: String, demo: Bool = false) {
        perform {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { throw NobisError.validation("请填写 1–80 字的称呼。") }
            let me = Member(name: name), partner = Member(name: partnerName.isEmpty ? "另一位成员（待连接）" : partnerName)
            let personal = Space(name: "我的空间", kind: .personal, ownerID: me.id, members: [me])
            let family = Space(name: familyName.isEmpty ? "我们的家" : familyName, kind: .family, ownerID: me.id, members: [me, partner])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !cloudOnly { _ = try CoreDataRepository(directory: directory.appendingPathComponent("Stores"), initialSpaces: [personal, family]) }
            try JSONEncoder().encode(me).write(to: directory.appendingPathComponent("identity.json"), options: LocalMetadataFile.writingOptions)
            try open(member: me)
            if demo && !cloudOnly { try seed(space: family, me: me); selectedSpaceID = family.id; refresh() }
        }
    }
    public var selectedSpace: Space? { spaces.first { $0.id == selectedSpaceID } }
    public var visibility: String { selectedSpaceID.map { visibility(for: $0) } ?? "未选择空间" }
    public var workspace: LifeWorkspace { LifeWorkspace(spaces: spaces, cloudID: cloud.grant?.spaceID, personalCloudID: privateCloud.spaceID, cloudOnly: cloudOnly) }
    public var activeRecords: [Record] { records.filter { !$0.deleted && $0.body.sharedDestination == nil } }
    public func records(in scope: LifeScope) -> [Record] { activeRecords.filter { workspace.ids(scope).contains($0.latest.spaceID) } }
    public func space(for record: Record) -> Space? { spaces.first { $0.id == record.latest.spaceID } }
    public func report(in scope: LifeScope) throws -> (core: FamilyCore, spaceID: UUID) {
        guard let core else { throw NobisError.forbidden }
        if scope == .all && !pendingShares.isEmpty { throw NobisError.validation("有分享待完成，请在设置中核对后查看全部合计。") }
        return try core.reportView(spaceIDs: workspace.ids(scope))
    }
    public func refresh(now: Date = Date(), timeZone: TimeZone = .current) {
        refresh(initialSnapshot: nil, now: now, timeZone: timeZone)
    }
    private func refresh(initialSnapshot: Snapshot?, now: Date = Date(), timeZone: TimeZone = .current) {
        today = LocalDay(date: now, timeZone: timeZone)
        guard let core, let id = selectedSpaceID else {
            records = []; summaries = []; displayedSpaceID = nil
            return
        }
        do {
            let ids = workspace.ids(.all)
            let updatedRecords = try core.workspaceRecords(spaceIDs: ids, renewingSpaceIDs: Set(ids.filter { canWrite(spaceID: $0) }), today: today, initialSnapshot: initialSnapshot)
            let updatedSummaries = try FamilyCore.ledger(records: updatedRecords.filter { $0.latest.spaceID == id })
            records = updatedRecords; summaries = updatedSummaries; displayedSpaceID = id
            Task { await updateNotifications(requestPermission: false) }
        } catch {
            let accessFailure = (error as? NobisError) == .forbidden || (error as? NobisError) == .notFound
            if !cloud.enabled && !accessFailure && displayedSpaceID == id {
                self.error = "刷新失败，显示上次成功加载的内容：" + error.localizedDescription
            } else {
                records = []; summaries = []; displayedSpaceID = nil
                self.error = error.localizedDescription
            }
        }
    }
    public func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
    public func save(_ body: RecordBody, spaceID: UUID, existing: Record? = nil, deleted: Bool = false, expected: Set<UUID>? = nil, recordID: UUID? = nil) throws {
        guard let core else { throw NobisError.validation("空间尚未就绪。") }
        if let existing, pendingShares.contains(where: { $0.sources.contains { $0.recordID == existing.id } }) {
            throw NobisError.validation("此记录正在分享，请先在设置中完成分享核对。")
        }
        try core.save(body, spaceID: spaceID, recordID: existing?.id ?? recordID ?? UUID(), expected: expected ?? Set(existing?.heads.map(\.id) ?? []), deleted: deleted)
        if privateCloud.spaceID == spaceID { notice = "已保存到个人空间，iCloud 将私密同步" }
        else { notice = cloud.grant?.spaceID == spaceID ? "已保存到本机，iCloud 将自动上传" : "已保存在此设备" }
        refresh()
    }
    public var pendingShares: [SharingPlan] {
        let path = directory.appendingPathComponent("SharingPlans")
        return ((try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(SharingPlan.self, from: LocalMetadataFile.read(from: $0)) }
    }
    public func share(_ plan: SharingPlan) throws {
        guard let core else { throw NobisError.forbidden }
        let folder = directory.appendingPathComponent("SharingPlans")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = folder.appendingPathComponent("\(plan.id).json")
        try JSONEncoder().encode(plan).write(to: journal, options: LocalMetadataFile.writingOptions)
        do { try core.commitSharing(plan) } catch {
            // A rejected preview has no destination and can be discarded; uncertain writes retain the journal.
            if let snapshot = try? core.repository.load(), !snapshot.revisions.contains(where: { Set(plan.operationIDs.values).contains($0.operationID) }) {
                try? FileManager.default.removeItem(at: journal)
            }
            refresh(); throw error
        }
        try FileManager.default.moveItem(at: journal, to: folder.appendingPathComponent("\(plan.id).completed"))
        notice = "共同版本已保存在此设备；连接后同步。原私密历史仅保留在此设备。"
        refresh()
    }
    public func changeStatus(_ record: Record, to status: RecordStatus) {
        perform {
            guard !record.conflicted else { throw NobisError.conflict }
            var body = record.body; body.status = status
            try save(body, spaceID: record.latest.spaceID, existing: record)
        }
    }
    public func advance(_ record: Record) {
        perform {
            guard !record.conflicted, let due = record.body.date, let anchor = record.body.billingAnchor else { throw NobisError.conflict }
            var body = record.body
            body.date = try due.nextCycle(unit: body.cycleUnit, count: body.cycleCount, anchor: anchor)
            try save(body, spaceID: record.latest.spaceID, existing: record)
            notice = "已更新下次计费日期；如已付款，请另记账单。"
        }
    }
    public func saveReminderPreferences(_ value: ReminderPreferences) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("ReminderPreferences.json"), options: LocalMetadataFile.writingOptions)
        reminderPreferences = value; reminderSettingsError = nil
        notificationGeneration += 1
    }
    public func reminderPreview(_ preferences: ReminderPreferences? = nil, now: Date = Date(), timeZone: TimeZone = .current) throws -> [PlannedReminder] {
        guard let core else { return [] }
        let ids = workspace.ids(.all)
        let records = try spaces.filter { ids.contains($0.id) }.flatMap { try core.records(spaceID: $0.id) }
        return try ReminderPlanning.plan(records: records, preferences: preferences ?? reminderPreferences, now: now, deviceTimeZone: timeZone)
    }
    public func updateNotifications(requestPermission: Bool) async {
        notificationGeneration += 1
        permissionRequested = permissionRequested || requestPermission
        guard !schedulingNotifications else { return }
        schedulingNotifications = true
        defer { schedulingNotifications = false }
        // Coalesce overlapping refreshes; only this worker may replace pending requests.
        while true {
            let generation = notificationGeneration
            let request = permissionRequested; permissionRequested = false
            await scheduleNotifications(requestPermission: request, generation: generation)
            if generation == notificationGeneration { break }
        }
    }
    private func scheduleNotifications(requestPermission: Bool, generation: Int) async {
        guard notificationsEnabled else {
            notificationStatus = "隔离验证：仅预览，不发送系统通知"
            return
        }
        let ticket = accessEpoch
        let center = UNUserNotificationCenter.current()
        func current() -> Bool { ticket == accessEpoch && generation == notificationGeneration }
        do {
            let pending = await center.pendingNotificationRequests()
            guard current() else { return }
            if !reminderPreferences.enabled || reminderSettingsError != nil {
                center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("nobis:") }.map(\.identifier))
                notificationStatus = "此设备不接收提醒，应用内待办仍保留"
                return
            }
            if requestPermission { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            guard current() else { return }
            let settings = await center.notificationSettings()
            guard current() else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("nobis:") }.map(\.identifier))
                notificationStatus = "系统通知未授权，应用内待办仍保留"; return
            }
            let planned = try reminderPreview()
            let update = ReminderScheduleUpdate(planned: planned, pendingIDs: pending.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers: update.removingIDs)
            for item in update.scheduling {
                guard current() else { return }
                let content = UNMutableNotificationContent(); content.title = item.title; content.body = item.body; content.sound = .default
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireDate)
                components.timeZone = calendar.timeZone
                try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                if !current() { center.removePendingNotificationRequests(withIdentifiers: [item.id]); return }
            }
            notificationStatus = "此设备已安排 \(min(planned.count, 60)) 条提醒" + (planned.count > 60 ? "，其余在打开应用时补算" : "")
        } catch { if current() { notificationStatus = "提醒更新失败"; self.error = "提醒调度失败：\(error.localizedDescription)" } }
    }
    private func seed(space: Space, me: Member) throws {
        guard let core else { return }
        var project = RecordBody(kind: .project, title: "一起去京都")
        project.notes = "慢一点，把时间留给散步。"; project.date = LocalDay(date: Date()).addingDays(30); project.endDate = LocalDay(date: Date()).addingDays(35)
        let trip = try core.save(project, spaceID: space.id)
        var task = RecordBody(kind: .task, title: "选一家能看见庭院的住处")
        task.projectIDs = [trip.recordID]; task.memberID = me.id; task.date = LocalDay(date: Date()).addingDays(2)
        try core.save(task, spaceID: space.id)
        var subscription = RecordBody(kind: .subscription, title: "Apple Music 家庭")
        subscription.money = Money(minor: 1700, currency: .CNY); subscription.date = LocalDay(date: Date()).addingDays(5); subscription.billingAnchor = subscription.date; subscription.memberID = me.id
        try core.save(subscription, spaceID: space.id)
        var expense = RecordBody(kind: .transaction, title: "周末一起做饭", status: .confirmed)
        expense.date = LocalDay(date: Date()); expense.memberID = me.id; expense.money = Money(minor: 10001, currency: .CNY); expense.splits = try expense.money!.split(members: space.members.map(\.id))
        try core.save(expense, spaceID: space.id)
    }
}
