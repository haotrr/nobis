import Foundation
import FamilyDomain

/// A review groups business records, not raw database rows. Plan items remain inside projects.
public struct ImportInspection: Sendable {
    public struct Group: Identifiable, Sendable {
        public var id: RecordKind { kind }
        public let kind: RecordKind
        public let bodies: [RecordBody]
        public let additions: [RecordBody]?
        public var existingCount: Int? { additions.map { bodies.count - $0.count } }
        public var planCount: Int { bodies.reduce(0) { $0 + ($1.budget?.items.count ?? 0) } }
    }
    public let groups: [Group]
    public init(preview: ImportPreview, changes: [RecordChange]?) {
        groups = RecordKind.allCases.compactMap { kind in
            let bodies = preview.entries.filter { $0.body.kind == kind }.map(\.body)
            guard !bodies.isEmpty else { return nil }
            return Group(kind: kind, bodies: bodies, additions: changes.map { $0.filter { $0.body.kind == kind }.map(\.body) })
        }
    }
    /// Snapshot balances and project budgets must not be summed across dates or hierarchies.
    public static func totals(_ bodies: [RecordBody], currency: Currency) throws -> (expense: Int64, income: Int64, monthlyNet: Int64, gross: Int64) {
        let transactions = bodies.filter { $0.kind == .transaction && $0.status == .confirmed && $0.money?.currency == currency }
        let months = bodies.compactMap(\.incomeMonth).filter { $0.net.currency == currency }
        return (
            try Money.sum(transactions.filter { [.expense, .refund].contains($0.transactionKind) }.map { ($0.money?.minor ?? 0) * ($0.transactionKind == .refund ? -1 : 1) }),
            try Money.sum(transactions.filter { $0.transactionKind == .income }.compactMap { $0.money?.minor }),
            try Money.sum(months.map { $0.net.minor }),
            try Money.sum(months.map { $0.gross.minor })
        )
    }
}

public struct LedgerPeriod: Hashable, Sendable {
    public let year: Int
    public let month: Int?
    public init(year: Int, month: Int? = nil) { self.year = year; self.month = month }
    public var title: String { month.map { "\(year) 年 \($0) 月" } ?? "\(year) 年" }
    public func bounds() throws -> (from: LocalDay, through: LocalDay) {
        let start = try LocalDay(year, month ?? 1, 1)
        let end = try start.nextCycle(unit: .month, count: month == nil ? 12 : 1, anchor: start).addingDays(-1)
        return (start, end)
    }
}

public struct LedgerMonthGroup: Identifiable, Sendable {
    public let id: String
    public let period: LedgerPeriod?
    public let records: [Record]
    public static func groups(_ records: [Record]) -> [Self] {
        Dictionary(grouping: records) { record in
            record.body.date.map { String(format: "%04d-%02d", $0.year, $0.month) } ?? ""
        }.sorted { $0.key > $1.key }.map { key, values in
            let date = values.first?.body.date
            return Self(id: key, period: date.map { LedgerPeriod(year: $0.year, month: $0.month) }, records: values.sorted {
                let left = $0.body.date?.description ?? "", right = $1.body.date?.description ?? ""
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            })
        }
    }
}
