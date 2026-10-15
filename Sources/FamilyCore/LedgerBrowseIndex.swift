import Foundation
import FamilyDomain

/// Derived only from the current authorized projection; never persisted.
public struct LedgerBrowseIndex: Sendable {
    public let recordsByID: [UUID: Record]
    public let projects: [Record]
    public let categories: [String]
    public let consumers: [String]
    private let transactions: [Record]
    private let periodsBySpace: [UUID: Set<LedgerPeriod>]

    public init(records: [Record]) {
        let active = records.filter { !$0.deleted && $0.body.sharedDestination == nil }
        recordsByID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projects = active.filter { $0.body.kind == .project }
        // Compute tie-break keys once, rather than formatting UUIDs during each comparison.
        transactions = active.filter { $0.body.kind == .transaction }.map { record in
            (record: record, day: record.body.date, key: record.id.uuidString)
        }.sorted {
            if $0.day != $1.day {
                guard let left = $0.day else { return false }
                guard let right = $1.day else { return true }
                return left > right
            }
            return $0.key < $1.key
        }.map(\.record)
        categories = Set(transactions.map { $0.body.category }).sorted()
        consumers = Set(active.compactMap { $0.body.finance?.consumer }.filter { !$0.isEmpty }).sorted()
        var periods: [UUID: Set<LedgerPeriod>] = [:]
        for record in transactions {
            if let day = record.body.date {
                periods[record.latest.spaceID, default: []].insert(LedgerPeriod(year: day.year, month: day.month))
            }
        }
        periodsBySpace = periods
    }

    public func months(spaceIDs: Set<UUID>) -> [LedgerPeriod] {
        spaceIDs.reduce(into: Set<LedgerPeriod>()) { $0.formUnion(periodsBySpace[$1] ?? []) }
            .sorted { $0.year == $1.year ? ($0.month ?? 0) > ($1.month ?? 0) : $0.year > $1.year }
    }

    public func query(_ filter: LedgerFilter, spaceIDs: Set<UUID>) -> LedgerBrowseResult {
        let terms = filter.search.split(whereSeparator: \.isWhitespace).map(String.init)
        return LedgerBrowseResult(records: transactions.filter {
            spaceIDs.contains($0.latest.spaceID) && filter.matches($0, terms: terms)
        })
    }
}

/// Reference identity lets the UI detect a new result without comparing every record ID.
public final class LedgerBrowseResult: Sendable {
    public static let pageSize = 10
    public let records: [Record]
    public let totals: [Currency: Result<Amounts, Error>]
    public let hasUnresolved: Bool
    public struct Amounts: Sendable {
        public let expense: Int64
        public let income: Int64
    }

    init(records: [Record]) {
        self.records = records
        hasUnresolved = records.contains { $0.conflicted || $0.body.status == .draft }
        let valid = Dictionary(grouping: records.filter {
            !$0.conflicted && $0.body.status == .confirmed && $0.body.money != nil
        }, by: { $0.body.money!.currency })
        totals = valid.mapValues { entries in
            Result {
                let expense = try Money.sum(entries.filter { [.expense, .refund].contains($0.body.transactionKind) }
                    .map { ($0.body.money?.minor ?? 0) * ($0.body.transactionKind == .refund ? -1 : 1) })
                let income = try Money.sum(entries.filter { $0.body.transactionKind == .income }.compactMap { $0.body.money?.minor })
                return Amounts(expense: expense, income: income)
            }
        }
    }

    public var pageCount: Int { max(1, (records.count + Self.pageSize - 1) / Self.pageSize) }
    public func page(_ number: Int) -> [Record] {
        let current = min(max(0, number), pageCount - 1)
        return Array(records.dropFirst(current * Self.pageSize).prefix(Self.pageSize))
    }
}
