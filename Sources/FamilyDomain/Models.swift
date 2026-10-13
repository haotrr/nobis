import Foundation

public enum NobisError: Error, LocalizedError, Equatable, Sendable {
    case forbidden, validation(String), conflict, unsupportedVersion, notFound, corruptBackup
    public var errorDescription: String? {
        switch self {
        case .forbidden, .notFound: "无权访问或记录不可用。"
        case .validation(let message): message
        case .conflict: "记录已有新版本，请查看差异后重新保存。"
        case .unsupportedVersion: "数据版本较新，请升级 Nobis。"
        case .corruptBackup: "备份校验失败，原有数据未改动。"
        }
    }
    public var code: String {
        switch self {
        case .forbidden, .notFound: "FORBIDDEN"
        case .validation: "VALIDATION_FAILED"
        case .conflict: "CONFLICT"
        case .unsupportedVersion: "UNSUPPORTED_VERSION"
        case .corruptBackup: "VALIDATION_FAILED"
        }
    }
}

public struct LocalDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public init(_ year: Int, _ month: Int, _ day: Int) throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = c.date(from: DateComponents(year: year, month: month, day: day)),
              c.component(.year, from: date) == year, c.component(.month, from: date) == month,
              c.component(.day, from: date) == day, (1...9999).contains(year) else {
            throw NobisError.validation("日期无效。")
        }
        self.year = year; self.month = month; self.day = day
    }
    public init(date: Date, timeZone: TimeZone = .current) {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        year = c.component(.year, from: date); month = c.component(.month, from: date); day = c.component(.day, from: date)
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
    public func date(timeZone: TimeZone = .current) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        return c.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    public func addingDays(_ count: Int) -> Self {
        let c = Calendar(identifier: .gregorian)
        return LocalDay(date: c.date(byAdding: .day, value: count, to: date())!)
    }
    public func nextCycle(unit: CycleUnit, count: Int, anchor: LocalDay) throws -> LocalDay {
        guard (1...120).contains(count) else { throw NobisError.validation("周期须在 1–120 之间。") }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        if unit == .day || unit == .week {
            return LocalDay(date: c.date(byAdding: .day, value: count * (unit == .week ? 7 : 1), to: date(timeZone: c.timeZone))!, timeZone: c.timeZone)
        }
        let first = try LocalDay(year, month, 1).date(timeZone: c.timeZone)
        guard let target = c.date(byAdding: unit == .month ? .month : .year, value: count, to: first),
              let days = c.range(of: .day, in: .month, for: target) else { throw NobisError.validation("日期超出范围。") }
        let targetMonth = unit == .year ? anchor.month : c.component(.month, from: target)
        let targetYear = c.component(.year, from: target)
        let monthStart = try LocalDay(targetYear, targetMonth, 1).date(timeZone: c.timeZone)
        let maxDay = c.range(of: .day, in: .month, for: monthStart)?.count ?? days.count
        return try LocalDay(targetYear, targetMonth, min(anchor.day, maxDay))
    }
}

public enum Currency: String, Codable, CaseIterable, Sendable { case CNY, USD, EUR, GBP, JPY, HKD, TWD, KRW, KWD
    public var scale: Int { self == .JPY || self == .KRW ? 0 : self == .KWD ? 3 : 2 }
    public var factor: Int64 { scale == 0 ? 1 : scale == 3 ? 1000 : 100 }
}
public struct Money: Codable, Equatable, Sendable {
    public var minor: Int64
    public var currency: Currency
    public init(minor: Int64, currency: Currency) { self.minor = minor; self.currency = currency }
    public static func parse(_ text: String, currency: Currency) throws -> Money {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              (raw.split(separator: ".", omittingEmptySubsequences: false).last?.count ?? 0) <= (raw.contains(".") ? currency.scale : Int.max),
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { throw NobisError.validation("金额格式无效，\(currency.rawValue) 支持 \(currency.scale) 位小数。") }
        let scaled = value * Decimal(currency.factor)
        guard scaled <= Decimal(Int64.max) else { throw NobisError.validation("金额超出范围。") }
        return Money(minor: NSDecimalNumber(decimal: scaled).int64Value, currency: currency)
    }
    public var formatted: String {
        let value = Decimal(minor) / Decimal(currency.factor)
        let f = NumberFormatter(); f.numberStyle = .decimal; f.minimumFractionDigits = currency.scale; f.maximumFractionDigits = currency.scale
        return "\(currency.rawValue) \(f.string(from: NSDecimalNumber(decimal: value)) ?? value.description)"
    }
    public static func sum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { a, b in
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw NobisError.validation("金额合计超出范围。") }; return value
        }
    }
    public func split(members: [UUID]) throws -> [ShareAmount] {
        let ids = Array(Set(members)).sorted { $0.uuidString < $1.uuidString }
        guard minor > 0, !ids.isEmpty else { throw NobisError.validation("分摊金额及成员不能为空。") }
        let quotient = minor / Int64(ids.count), remainder = minor % Int64(ids.count)
        return ids.enumerated().map { ShareAmount(memberID: $0.element, minor: quotient + (Int64($0.offset) < remainder ? 1 : 0)) }
    }
}
public struct ShareAmount: Codable, Equatable, Sendable {
    public var memberID: UUID; public var minor: Int64
    public init(memberID: UUID, minor: Int64) { self.memberID = memberID; self.minor = minor }
}
public enum SpaceKind: String, Codable, Sendable { case personal, family }
public struct Member: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID; public var name: String
    public var avatarData: Data?
    public init(id: UUID = UUID(), name: String, avatarData: Data? = nil) { self.id = id; self.name = name; self.avatarData = avatarData }
}
public struct Space: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID; public var name: String; public let kind: SpaceKind
    public let ownerID: UUID; public var members: [Member]
    public init(id: UUID = UUID(), name: String, kind: SpaceKind, ownerID: UUID, members: [Member]) {
        self.id = id; self.name = name; self.kind = kind; self.ownerID = ownerID; self.members = members
    }
}
public enum RecordKind: String, Codable, CaseIterable, Sendable {
    case project, task, subscription, event, transaction, category, monthlyIncome, assetSnapshot, document, comment
    public var title: String { switch self { case .document: "笔记"; case .comment: "评注"; case .project: "项目"; case .task: "待办"; case .subscription: "订阅"; case .event: "日程"; case .monthlyIncome: "月度收入"; case .assetSnapshot: "资产快照"; case .category: "分类"; case .transaction: "收支" } }
    public var icon: String { switch self { case .document: "doc.text"; case .comment: "text.bubble"; case .project: "square.stack.3d.up"; case .task: "checkmark.circle"; case .subscription: "repeat"; case .event: "calendar"; case .monthlyIncome: "banknote"; case .assetSnapshot: "chart.pie"; case .category: "tag"; case .transaction: "creditcard" } }
}
public enum RecordStatus: String, Codable, CaseIterable, Sendable {
    case active, completed, archived, paused, cancelled, draft, confirmed, voided
    public var title: String { switch self { case .active: "进行中"; case .completed: "已完成"; case .archived: "已归档"; case .paused: "已暂停"; case .cancelled: "已取消"; case .draft: "草稿"; case .confirmed: "已确认"; case .voided: "已作废" } }
}
public enum CycleUnit: String, Codable, CaseIterable, Sendable { case day, week, month, year
    public var title: String { switch self { case .day: "天"; case .week: "周"; case .month: "月"; case .year: "年" } }
}
public enum TransactionKind: String, Codable, CaseIterable, Sendable { case expense, income, refund, settlement
    public var title: String { switch self { case .expense: "支出"; case .income: "收入"; case .refund: "退款"; case .settlement: "成员结算" } }
}
/// Each revision contains a complete, validated payload; revisions are never edited in place.
public struct RecordBody: Codable, Equatable, Sendable {
    public var kind: RecordKind
    public var title: String
    public var status: RecordStatus
    public var notes: String = ""
    public var noteGroup: String?
    public var isPinned: Bool?
    public var referenceIDs: [UUID]?
    public var documentQuote: String?
    public var projectIDs: [UUID] = []
    public var date: LocalDay?
    public var endDate: LocalDay?
    public var startAt: Date?
    public var endAt: Date?
    public var timeZone: String = TimeZone.current.identifier
    public var allDay: Bool = true
    public var location: String = ""
    public var memberID: UUID?
    public var money: Money?
    public var unknownPriceCurrency: Currency?
    public var cycleUnit: CycleUnit = .month
    public var cycleCount: Int = 1
    public var billingAnchor: LocalDay?
    public var reminderDays: [Int] = [7, 1]
    public var transactionKind: TransactionKind = .expense
    public var splits: [ShareAmount] = []
    public var refundOfID: UUID?
    public var subscriptionID: UUID?
    public var relatedRecordID: UUID?
    public var occurrenceKey: String?
    public var category: String = "日常"
    public var account: String = "默认账户"
    public var financialOwner: FinancialOwner?
    public var sharedDestination: SharedDestination?
    public var incomeMonth: IncomeMonth?
    public var assetPosition: AssetPosition?
    public var finance: FinanceDetails?
    public var budget: ProjectBudget?
    public var parentProjectID: UUID?
    public var importSource: ImportSource?
    public var completedBy: UUID?
    public var completedAt: Date?
    public init(kind: RecordKind, title: String, status: RecordStatus = .active) { self.kind = kind; self.title = title; self.status = status }
}
public struct Revision: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let recordID: UUID
    public let spaceID: UUID
    public let parents: [UUID]
    public let operationID: UUID
    public let actorID: UUID
    public let createdAt: Date
    public let body: RecordBody
    public let deleted: Bool
    public init(id: UUID = UUID(), recordID: UUID = UUID(), spaceID: UUID, parents: [UUID] = [], operationID: UUID = UUID(), actorID: UUID, createdAt: Date = Date(), body: RecordBody, deleted: Bool = false) {
        self.id = id; self.recordID = recordID; self.spaceID = spaceID; self.parents = parents; self.operationID = operationID; self.actorID = actorID; self.createdAt = createdAt; self.body = body; self.deleted = deleted
    }
}
public struct Record: Identifiable, Sendable {
    public var id: UUID { latest.recordID }
    public let heads: [Revision]
    public var latest: Revision { heads.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }.last! }
    public var body: RecordBody { latest.body }
    public var conflicted: Bool { heads.count > 1 }
    public var deleted: Bool { heads.contains { $0.deleted } }
    public static func project(_ revisions: [Revision]) -> [Record] {
        Dictionary(grouping: revisions, by: \.recordID).values.compactMap { versions in
            let parents = Set(versions.flatMap(\.parents))
            let unique = Dictionary(grouping: versions, by: \.id).compactMap { $0.value.first }
            let heads = unique.filter { !parents.contains($0.id) }
            return heads.isEmpty ? nil : Record(heads: heads)
        }.sorted { $0.latest.createdAt > $1.latest.createdAt }
    }
}
public struct AuditEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID; public let spaceID: UUID; public let actorID: UUID; public let targetID: UUID; public let revisionID: UUID; public let operationID: UUID; public let action: String; public let date: Date
    public init(revision: Revision, action: String) { id = UUID(); spaceID = revision.spaceID; actorID = revision.actorID; targetID = revision.recordID; revisionID = revision.id; operationID = revision.operationID; self.action = action; date = revision.createdAt }
}
public struct Snapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var spaces: [Space]
    public var revisions: [Revision]
    public var audits: [AuditEvent]
    public init(spaces: [Space] = [], revisions: [Revision] = [], audits: [AuditEvent] = []) { self.spaces = spaces; self.revisions = revisions; self.audits = audits }
}
public struct AccessSession: Sendable {
    public let memberID: UUID; public let allowedSpaceIDs: Set<UUID>
    public let memberIDsBySpace: [UUID: UUID]
    public init(memberID: UUID, allowedSpaceIDs: Set<UUID>, memberIDsBySpace: [UUID: UUID] = [:]) {
        self.memberID = memberID; self.allowedSpaceIDs = allowedSpaceIDs; self.memberIDsBySpace = memberIDsBySpace
    }
    public func actorID(in spaceID: UUID) -> UUID { memberIDsBySpace[spaceID] ?? memberID }
}
