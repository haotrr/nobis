import Foundation
import FamilyDomain

public struct FinancialMonthPoint: Identifiable, Sendable {
    public var id: Int { month }
    public let month: Int
    public let income: Int64?
    public let expense: Int64?
    public let unresolved: Int
}
public enum FinancialChartData {
    @MainActor public static func months(core: FamilyCore, spaceID: UUID, year: Int, currency: Currency, today: LocalDay) throws -> [FinancialMonthPoint] {
        try months(records: core.records(spaceID: spaceID), year: year, currency: currency, today: today)
    }
    @MainActor public static func months(records source: [Record], year: Int, currency: Currency, today: LocalDay) throws -> [FinancialMonthPoint] {
        try months(index: FinancialReportIndex(records: source), year: year, currency: currency, today: today)
    }
    @MainActor public static func months(index: FinancialReportIndex, year: Int, currency: Currency, today: LocalDay) throws -> [FinancialMonthPoint] {
        guard year <= today.year else { return [] }
        let last = year == today.year ? today.month : 12
        let records = index.bodiesByID
        return try (1...last).map { month in
            let report = try index.report(year: year, month: month, through: today)
            let total = report.totals.first { $0.currency == currency }
            let bodies = (total?.sourceIDs ?? []).compactMap { records[$0] }
            let hasIncome = bodies.contains { $0.kind == .monthlyIncome || ($0.kind == .transaction && $0.transactionKind == .income) }
            let hasExpense = bodies.contains { $0.kind == .transaction && [.expense, .refund].contains($0.transactionKind) }
            return FinancialMonthPoint(month: month, income: hasIncome ? try total?.income : nil, expense: hasExpense ? try total?.netExpense : nil, unresolved: report.unresolvedCount)
        }
    }
    /// Exclude ambiguous dates without substituting an older record as that day's observation.
    public static func snapshots(_ records: [Record], through: LocalDay) -> [Record] {
        let eligible = records.filter { !$0.deleted && $0.body.sharedDestination == nil && $0.body.kind == .assetSnapshot }
        var groups: [LocalDay: [Currency: [UUID: Record]]] = [:]
        for record in eligible {
            for head in record.heads {
                guard head.body.status == .active, let day = head.body.date, day <= through,
                      let currency = head.body.assetPosition?.currency else { continue }
                groups[day, default: [:]][currency, default: [:]][record.id] = record
            }
        }
        return groups.keys.sorted().flatMap { day in
            Currency.allCases.compactMap { currency -> Record? in
                guard let candidates = groups[day]?[currency], candidates.count == 1,
                      let record = candidates.values.first, !record.conflicted else { return nil }
                return record
            }
        }
    }
    public static func changes(from: AssetPosition, to: AssetPosition) throws -> [AssetComponent: Int64] {
        guard from.currency == to.currency else { throw NobisError.validation("不能跨币种比较资产。") }
        try from.validate(); try to.validate()
        return try Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { component in
            (component, try Money.sum([to.amounts[component] ?? 0, -(from.amounts[component] ?? 0)]))
        })
    }
}
