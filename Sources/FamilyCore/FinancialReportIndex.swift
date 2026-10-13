import Foundation
import FamilyDomain

/// A value snapshot for one report evaluation; never retained across refreshes or access changes.
public struct FinancialReportIndex: Sendable {
    public let records: [Record]
    public let bodiesByID: [UUID: RecordBody]
    public let currencies: [Currency]
    public var years: [Int] { annual.keys.sorted() }
    private var annual: [Int: [Record]] = [:]
    private var monthly: [Int: [Int: [Record]]] = [:]
    public init(records: [Record]) {
        self.records = records.filter { !$0.deleted && $0.body.sharedDestination == nil }
        bodiesByID = Dictionary(uniqueKeysWithValues: self.records.map { ($0.id, $0.body) })
        currencies = Array(Set(self.records.compactMap { $0.body.money?.currency ?? $0.body.incomeMonth?.net.currency })).sorted { $0.rawValue < $1.rawValue }
        for record in self.records {
            var periods: [Int: Set<Int>] = [:]
            // Every head contributes period membership; a conflict is counted once in each affected period.
            for head in record.heads {
                let b = head.body
                if b.kind == .monthlyIncome, let income = b.incomeMonth { periods[income.year, default: []].insert(income.month) }
                else if b.kind == .transaction, let day = b.date { periods[day.year, default: []].insert(day.month) }
            }
            for (year, months) in periods {
                annual[year, default: []].append(record)
                for month in months where month > 0 { monthly[year, default: [:]][month, default: []].append(record) }
            }
        }
    }
    @MainActor public func report(year: Int, month: Int? = nil, through: LocalDay? = nil) throws -> FinancialReport {
        try FamilyCore.financialReport(records: month.map { monthly[year]?[$0] ?? [] } ?? annual[year] ?? [], year: year, month: month, through: through)
    }
}
