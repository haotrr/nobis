import Foundation
import FamilyDomain

@MainActor public protocol Repository {
    func load() throws -> Snapshot
    /// Must atomically save business revisions and their audit events.
    func save(_ snapshot: Snapshot) throws
    func requireWrite(spaceID: UUID, actorID: UUID) throws
}
public extension Repository { func requireWrite(spaceID: UUID, actorID: UUID) throws {} }
@MainActor public final class MemoryRepository: Repository {
    public var snapshot: Snapshot
    public init(_ snapshot: Snapshot = Snapshot()) { self.snapshot = snapshot }
    public func load() throws -> Snapshot { snapshot }
    public func save(_ snapshot: Snapshot) throws { self.snapshot = snapshot }
}

public struct LedgerSummary: Codable, Sendable {
    public let currency: Currency
    public var expense: Int64 = 0
    public var refund: Int64 = 0
    public var income: Int64 = 0
    public var netExpense: Int64 = 0
    public var unresolvedCount: Int = 0
    public var sourceIDs: [UUID] = []
    public var balances: [String: Int64] = [:]
    public init(currency: Currency) { self.currency = currency }
}

@MainActor public final class FamilyCore {
    public let repository: any Repository
    public let session: AccessSession
    // Only the short-lived, isolated batch core uses this projection. Live repositories
    // always reload, so remote revisions and access changes cannot be hidden by a cache.
    private var batchSpaceID: UUID?
    private var batchProjection: [UUID: Record] = [:]
    func prepareBatchProjection(spaceID: UUID) throws {
        precondition(repository is MemoryRepository)
        batchProjection = Dictionary(uniqueKeysWithValues: try records(spaceID: spaceID, includeDeleted: true).map { ($0.id, $0) })
        batchSpaceID = spaceID
    }
    public init(repository: any Repository, session: AccessSession) { self.repository = repository; self.session = session }
    public func spaces() throws -> [Space] { try repository.load().spaces.filter { space in session.allowedSpaceIDs.contains(space.id) && space.members.contains { $0.id == session.actorID(in: space.id) } && (space.kind != .personal || space.ownerID == session.actorID(in: space.id)) } }
    public func space(_ id: UUID) throws -> Space {
        guard let value = try spaces().first(where: { $0.id == id }) else { throw NobisError.forbidden }; return value
    }
    public func records(spaceID: UUID, includeDeleted: Bool = false) throws -> [Record] {
        _ = try space(spaceID)
        if batchSpaceID == spaceID {
            return batchProjection.values.filter { includeDeleted || !$0.deleted }.sorted { $0.latest.createdAt > $1.latest.createdAt }
        }
        return Record.project(try repository.load().revisions.filter { $0.spaceID == spaceID }).filter { includeDeleted || !$0.deleted }
    }
    public func record(_ id: UUID, spaceID: UUID) throws -> Record {
        if batchSpaceID == spaceID {
            _ = try space(spaceID)
            guard let value = batchProjection[id] else { throw NobisError.notFound }
            return value
        }
        guard let value = try records(spaceID: spaceID, includeDeleted: true).first(where: { $0.id == id }) else { throw NobisError.notFound }; return value
    }
    public func history(_ id: UUID, spaceID: UUID) throws -> [Revision] {
        _ = try space(spaceID)
        return try repository.load().revisions.filter { $0.spaceID == spaceID && $0.recordID == id }.sorted { $0.createdAt > $1.createdAt }
    }
    @discardableResult public func save(_ body: RecordBody, spaceID: UUID, recordID: UUID = UUID(), expected: Set<UUID> = [], operationID: UUID = UUID(), deleted: Bool = false) throws -> Revision {
        let space = try space(spaceID)
        let actorID = session.actorID(in: spaceID)
        try repository.requireWrite(spaceID: spaceID, actorID: actorID)
        var snapshot = try repository.load()
        if let previous = snapshot.revisions.first(where: { $0.operationID == operationID }) {
            var comparable = body
            if comparable.kind == .task, comparable.status == .completed, comparable.completedAt == nil {
                comparable.completedAt = previous.body.completedAt; comparable.completedBy = previous.body.completedBy
            }
            guard previous.spaceID == spaceID, previous.recordID == recordID, previous.body == comparable, previous.deleted == deleted, Set(previous.parents) == expected, previous.actorID == actorID else { throw NobisError.validation("同一操作标识不能用于不同内容。") }
            return previous
        }
        // Record IDs cannot be used to relocate or overwrite an object in another space.
        guard !snapshot.revisions.contains(where: { $0.recordID == recordID && $0.spaceID != spaceID }) else { throw NobisError.forbidden }
        let current = batchSpaceID == spaceID ? batchProjection[recordID] : try records(spaceID: spaceID, includeDeleted: true).first { $0.id == recordID }
        guard Set(current?.heads.map(\.id) ?? []) == expected else { throw NobisError.conflict }
        if let current {
            guard current.body.kind == body.kind else { throw NobisError.validation("记录类型不可更改。") }
            if current.deleted && !deleted {
                guard let date = current.heads.filter(\.deleted).map(\.createdAt).max(), Date().timeIntervalSince(date) <= 30 * 86400 else { throw NobisError.validation("已超过 30 天恢复窗口。") }
            }
            if body.kind == .transaction, !current.conflicted, current.body.status == .confirmed, !body.hasSameFinancialFacts(as: current.body), body.status != .voided {
                throw NobisError.validation("已确认账单请先作废，再创建修订记录。")
            }
        }
        guard !(deleted && body.kind == .transaction) else { throw NobisError.validation("账单须作废并保留历史，不能删除。") }
        if deleted, body.kind == .project,
           try records(spaceID: spaceID).contains(where: { $0.body.projectIDs.contains(recordID) || $0.body.parentProjectID == recordID }) { throw NobisError.validation("项目仍有关联记录，请归档项目。") }
        if body.projectIDs.count > 1 && Set(body.projectIDs) != Set(current?.body.projectIDs ?? []) {
            throw NobisError.validation("请选择一个所属项目；旧多项目关联可保留，核对后再调整。")
        }
        if current?.body.sharedDestination != nil { throw NobisError.validation("这是已分享的只读来源，请编辑共同版本。") }
        try validateDocument(body, current: current, spaceID: spaceID, deleted: deleted)
        try validate(body, space: space, recordID: recordID)
        if body.kind == .transaction, body.status == .voided {
            guard !body.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NobisError.validation("请在备注中填写作废原因。") }
            guard !(try records(spaceID: spaceID)).contains(where: { $0.body.refundOfID == recordID && $0.body.status == .confirmed }) else { throw NobisError.validation("请先作废关联退款，再作废原支出。") }
        }
        var payload = body
        if body.kind == .task && body.status == .completed && current?.body.status != .completed {
            payload.completedAt = Date(); payload.completedBy = actorID
        } else if body.kind == .task && body.status != .completed {
            payload.completedAt = nil; payload.completedBy = nil
        }
        let revision = Revision(recordID: recordID, spaceID: spaceID, parents: expected.sorted { $0.uuidString < $1.uuidString }, operationID: operationID, actorID: actorID, body: payload, deleted: deleted)
        snapshot.revisions.append(revision); snapshot.audits.append(AuditEvent(revision: revision, action: deleted ? "delete" : current == nil ? "create" : "revise"))
        try repository.save(snapshot)
        if batchSpaceID == spaceID {
            // Expected heads were checked above; this revision replaces all current heads.
            batchProjection[recordID] = Record.project([revision]).first
        }
        return revision
    }
    func validate(_ body: RecordBody, space: Space, recordID: UUID) throws {
        guard !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.title.count <= 200, body.notes.count <= 20_000 else { throw NobisError.validation("标题不能为空且最多 200 字，备注最多 20,000 字。") }
        guard (body.noteGroup?.count ?? 0) <= 40, (body.referenceIDs?.count ?? 0) <= 30 else { throw NobisError.validation("分组最多 40 字，相关内容最多 30 条。") }
        for id in body.referenceIDs ?? [] {
            guard id != recordID else { throw NobisError.validation("不能关联自身。") }
            let target = try record(id, spaceID: space.id)
            guard target.body.kind != .comment else { throw NobisError.validation("请关联评注所在的笔记。") }
        }
        try body.validateFinance()
        try body.validateStatement()
        if let member = body.financialOwner?.memberID, !space.members.contains(where: { $0.id == member }) { throw NobisError.validation("财务归属人不属于此范围。") }
        if body.sharedDestination != nil && space.kind != .personal { throw NobisError.validation("分享来源只能保留在私密库。") }
        if body.kind == .category && body.status == .active {
            guard !(try records(spaceID: space.id)).contains(where: { $0.id != recordID && $0.body.kind == .category && $0.body.status == .active && $0.body.title == body.title }) else { throw NobisError.validation("此分类已存在。") }
        }
        if let parent = body.parentProjectID {
            let record = try record(parent, spaceID: space.id)
            guard parent != recordID, record.body.kind == .project, !record.deleted, !record.conflicted, record.body.parentProjectID == nil,
                  !(try records(spaceID: space.id)).contains(where: { $0.body.parentProjectID == recordID }) else { throw NobisError.validation("项目最多两层，不能循环关联。") }
        }
        if body.kind == .project {
            let itemIDs = Set(body.budget?.items.map(\.id) ?? [])
            let referenced = try records(spaceID: space.id).filter { $0.body.projectIDs.contains(recordID) && $0.body.status != .voided }
            guard referenced.allSatisfy({ r in r.body.finance?.planItemID.map { itemIDs.contains($0) } ?? true }) else { throw NobisError.validation("计划项仍有关联账单，请先调整账单计划项。") }
        }
        if let plan = body.finance?.planItemID {
            guard body.kind == .transaction, try body.projectIDs.contains(where: { id in try record(id, spaceID: space.id).body.budget?.items.contains { $0.id == plan && $0.amount.currency == body.money?.currency } == true }) else { throw NobisError.validation("计划项须属于所选项目，且与账单币种一致。") }
        }
        let members = Set(space.members.map(\.id))
        if let member = body.memberID, !members.contains(member) { throw NobisError.forbidden }
        for date in [body.date, body.endDate, body.billingAnchor].compactMap({ $0 }) { _ = try LocalDay(date.year, date.month, date.day) }
        if let start = body.date, let end = body.endDate, end < start { throw NobisError.validation("结束日期不能早于开始日期。") }
        for projectID in body.projectIDs {
            let project = try record(projectID, spaceID: space.id)
            guard project.body.kind == .project, !project.deleted else { throw NobisError.validation("项目不可用。") }
        }
        if let sourceID = body.subscriptionID {
            let source = try record(sourceID, spaceID: space.id)
            guard source.body.kind == .subscription, !source.deleted else { throw NobisError.validation("关联订阅不可用。") }
        }
        if let related = body.relatedRecordID { _ = try record(related, spaceID: space.id) }
        guard TimeZone(identifier: body.timeZone) != nil else { throw NobisError.validation("时区无效。") }
        let statuses: Set<RecordStatus> = switch body.kind {
        case .project: [.draft, .active, .completed, .archived]
        case .comment: [.active, .completed]
        case .document, .category, .monthlyIncome, .assetSnapshot: [.active, .archived]
        case .task: [.active, .completed, .cancelled]
        case .event: [.active, .cancelled]
        case .subscription: [.active, .paused, .cancelled, .archived]
        case .transaction: [.draft, .confirmed, .voided]
        }
        guard statuses.contains(body.status) else { throw NobisError.validation("记录状态不适用于此类型。") }
        if body.kind == .subscription {
            guard body.date != nil, body.billingAnchor != nil, (1...120).contains(body.cycleCount), (body.memberID != nil || (body.status == .paused && body.accountingMode == .ledgerOnly)),
                  body.reminderDays.allSatisfy({ (0...365).contains($0) }) else { throw NobisError.validation("请填写计费日期、付款人和有效周期。") }
            if let money = body.money, money.minor < 0 { throw NobisError.validation("价格不能为负。") }
        }
        if body.kind == .event {
            if body.allDay { guard body.date != nil else { throw NobisError.validation("请选择日程日期。") } }
            else { guard let start = body.startAt, let end = body.endAt, end > start else { throw NobisError.validation("日程结束时间须晚于开始时间。") } }
        }
        if body.kind == .transaction {
            guard let money = body.money, body.hasValidTransactionAmount, body.date != nil else { throw NobisError.validation("账单须包含有效金额、币种和发生日；零元仅用于只记收支的支出记录。") }
            let payer = body.memberID
            if body.accountingMode == .sharedSettlement && payer == nil { throw NobisError.validation("参与成员结算须指定付款人。") }
            guard Set(body.splits.map(\.memberID)).count == body.splits.count, body.splits.allSatisfy({ members.contains($0.memberID) && $0.minor >= 0 }) else { throw NobisError.validation("分摊成员或金额无效。") }
            if body.accountingMode == .sharedSettlement && body.transactionKind != .income {
                guard try Money.sum(body.splits.map(\.minor)) == money.minor else { throw NobisError.validation("分摊合计必须等于账单金额。") }
            }
            if body.transactionKind == .settlement {
                guard body.splits.count == 1, body.splits[0].memberID != payer else { throw NobisError.validation("结算需要另一位收款成员。") }
            }
            if body.transactionKind == .refund {
                guard let source = body.refundOfID else { throw NobisError.validation("退款须关联原支出。") }
                let original = try record(source, spaceID: space.id)
                guard !original.deleted, !original.conflicted, original.body.kind == .transaction, original.body.transactionKind == .expense,
                      original.body.status == .confirmed, original.body.money?.currency == money.currency, original.body.memberID == payer, original.body.accountingMode == body.accountingMode else { throw NobisError.validation("请选择同币种、同付款人且已确认的原支出。") }
                let refunds = try records(spaceID: space.id).filter { $0.id != recordID && $0.body.refundOfID == source && $0.body.status == .confirmed }
                guard !refunds.contains(where: \.conflicted) else { throw NobisError.conflict }
                let total = try Money.sum(refunds.compactMap { $0.body.money?.minor } + [money.minor])
                guard total <= (original.body.money?.minor ?? 0) else { throw NobisError.validation("累计退款不能超过原支出。") }
                for share in body.splits {
                    let already = try Money.sum(refunds.flatMap { $0.body.splits }.filter { $0.memberID == share.memberID }.map(\.minor) + [share.minor])
                    guard already <= (original.body.splits.first { $0.memberID == share.memberID }?.minor ?? 0) else { throw NobisError.validation("成员退款不能超过原分摊金额。") }
                }
            } else if body.refundOfID != nil { throw NobisError.validation("仅退款可以引用原支出。") }
        }
    }
    public func ledger(spaceID: UUID, from: LocalDay? = nil, through: LocalDay? = nil) throws -> [LedgerSummary] {
        if let from, let through, through < from { throw NobisError.validation("统计结束日期早于开始日期。") }
        let entries = try records(spaceID: spaceID).filter { record in
            record.body.sharedDestination == nil && record.body.kind == .transaction && record.heads.contains { revision in
                revision.body.date.map { (from == nil || $0 >= from!) && (through == nil || $0 <= through!) } ?? true
            }
        }
        var groups: [Currency: LedgerSummary] = [:]
        for record in entries {
            if record.conflicted {
                for currency in Set(record.heads.compactMap { $0.body.money?.currency }) {
                    var group = groups[currency] ?? LedgerSummary(currency: currency)
                    group.unresolvedCount += 1; groups[currency] = group
                }
                continue
            }
            guard let money = record.body.money else { continue }
            var group = groups[money.currency] ?? LedgerSummary(currency: money.currency)
            if record.conflicted || record.body.status == .draft { group.unresolvedCount += 1; groups[money.currency] = group; continue }
            guard record.body.status == .confirmed else { continue }
            group.sourceIDs.append(record.id)
            switch record.body.transactionKind {
            case .expense: group.expense = try Money.sum([group.expense, money.minor])
            case .refund: group.refund = try Money.sum([group.refund, money.minor])
            case .income: group.income = try Money.sum([group.income, money.minor])
            case .settlement: break
            }
            if let payer = record.body.memberID, record.body.accountingMode == .sharedSettlement, record.body.transactionKind != .income {
                let sign: Int64 = record.body.transactionKind == .refund ? -1 : 1
                group.balances[payer.uuidString] = try Money.sum([group.balances[payer.uuidString] ?? 0, sign * money.minor])
                for split in record.body.splits {
                    group.balances[split.memberID.uuidString] = try Money.sum([group.balances[split.memberID.uuidString] ?? 0, -sign * split.minor])
                }
            }
            group.netExpense = try Money.sum([group.expense, -group.refund])
            groups[money.currency] = group
        }
        return groups.values.sorted { $0.currency.rawValue < $1.currency.rawValue }
    }
    /// Catch up on foreground; the same subscription + occurrence never creates two review tasks.
    public func reconcileRenewals(spaceID: UUID, today: LocalDay = LocalDay(date: Date())) throws {
        let records = try records(spaceID: spaceID, includeDeleted: true).filter { $0.body.sharedDestination == nil }
        for subscription in records where !subscription.deleted && !subscription.conflicted && subscription.body.kind == .subscription && subscription.body.status == .active {
            guard let due = subscription.body.date, due <= today.addingDays(subscription.body.reminderDays.max() ?? 0) else { continue }
            let key = "renewal:\(subscription.id.uuidString):\(due)"
            if records.contains(where: { $0.body.kind == .task && ($0.body.occurrenceKey == key || $0.body.notes == key) }) { continue }
            var task = RecordBody(kind: .task, title: "复核续费 · \(subscription.body.title)")
            task.date = due; task.memberID = subscription.body.memberID; task.subscriptionID = subscription.id; task.projectIDs = subscription.body.projectIDs
            task.occurrenceKey = key; task.notes = "确认继续订阅、已取消或需要处理。此任务不表示已经扣款。"
            try save(task, spaceID: spaceID)
        }
    }
    public func publishCopy(_ recordID: UUID, from sourceSpace: UUID, to targetSpace: UUID, title: String, notes: String) throws -> Revision {
        let source = try record(recordID, spaceID: sourceSpace)
        guard try space(sourceSpace).kind == .personal, try space(targetSpace).kind == .family,
              [.task, .project, .event].contains(source.body.kind) else { throw NobisError.validation("仅支持发布任务、项目和日程的公开副本。") }
        var body = RecordBody(kind: source.body.kind, title: title)
        body.notes = notes; body.date = source.body.date; body.endDate = source.body.endDate
        body.startAt = source.body.startAt; body.endAt = source.body.endAt; body.allDay = source.body.allDay; body.timeZone = source.body.timeZone
        // No source ID, notes, member mapping, related record or project reference is copied implicitly.
        return try save(body, spaceID: targetSpace)
    }
}
