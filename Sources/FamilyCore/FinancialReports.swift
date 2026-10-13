import Foundation
import FamilyDomain

public struct PeriodStatement: Encodable, Sendable {
    public var currency: Currency
    public var expense: Int64 = 0
    public var refund: Int64 = 0
    public var cashIncome: Int64 = 0
    public var monthlyNet: Int64 = 0
    public var nonMonthlyNet: Int64 = 0
    public var gross: Int64 = 0
    public var knownTax: Int64 = 0
    public var unknownTaxCount = 0
    public var categories: [String: Int64] = [:]
    public var consumption: [String: Int64] = [:]
    public var sourceIDs: [UUID] = []
    private enum CodingKeys: String, CodingKey { case currency, expense, refund, cashIncome, monthlyNet, nonMonthlyNet, gross, knownTax, unknownTaxCount, categories, consumption, sourceIDs, netExpense, income, surplus }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(currency, forKey: .currency); try c.encode(expense, forKey: .expense); try c.encode(refund, forKey: .refund)
        try c.encode(cashIncome, forKey: .cashIncome); try c.encode(monthlyNet, forKey: .monthlyNet); try c.encode(nonMonthlyNet, forKey: .nonMonthlyNet); try c.encode(gross, forKey: .gross)
        try c.encode(knownTax, forKey: .knownTax); try c.encode(unknownTaxCount, forKey: .unknownTaxCount)
        try c.encode(categories, forKey: .categories); try c.encode(consumption, forKey: .consumption); try c.encode(sourceIDs, forKey: .sourceIDs)
        try c.encode(netExpense, forKey: .netExpense); try c.encode(income, forKey: .income); try c.encode(surplus, forKey: .surplus)
    }
    public var netExpense: Int64 { get throws { try Money.sum([expense, -refund]) } }
    public var income: Int64 { get throws { try Money.sum([cashIncome, monthlyNet, nonMonthlyNet]) } }
    public var surplus: Int64 { get throws { try Money.sum([income, -netExpense]) } }
}
public struct FinancialReport: Encodable, Sendable {
    public let year: Int
    public let month: Int?
    public let totals: [PeriodStatement]
    public let unresolvedCount: Int
}
public struct PositionObservation: Sendable {
    public let currency: Currency
    public let ownerKey: String
    public var id: String { currency.rawValue + ownerKey }
    public let record: Record?
    public let ambiguous: Bool
}
public struct SubscriptionEstimate: Codable, Sendable {
    public let currency: Currency
    public var monthly: Int64 = 0
    public var annual: Int64 = 0
    public var actualPaid: Int64 = 0
    public var unknownPriceCount = 0
}
public struct SubscriptionCosts: Codable, Sendable {
    public let totals: [SubscriptionEstimate]
    public let activeCount: Int
    public let pausedCount: Int
    public let unresolvedCount: Int
}
public extension FamilyCore {
    func financialReport(spaceID: UUID, year: Int, month: Int? = nil, through: LocalDay? = nil) throws -> FinancialReport {
        try Self.financialReport(records: records(spaceID: spaceID), year: year, month: month, through: through)
    }
    /// Reuse one authorized projection when building several chart periods.
    static func financialReport(records: [Record], year: Int, month: Int? = nil, through: LocalDay? = nil) throws -> FinancialReport {
        _ = try LocalDay(year, month ?? 1, 1)
        let records = records.filter { !$0.deleted && $0.body.sharedDestination == nil }
        var groups: [Currency: PeriodStatement] = [:], unresolved = 0
        func inPeriod(_ b: RecordBody) -> Bool {
            if b.kind == .monthlyIncome, let i = b.incomeMonth { return i.year == year && (month == nil || i.month == month) && (through == nil || i.year < through!.year || (i.year == through!.year && (i.isNonMonthly || i.month <= through!.month))) }
            guard b.kind == .transaction, let d = b.date else { return false }
            return d.year == year && (month == nil || d.month == month) && (through.map { d <= $0 } ?? true)
        }
        for r in records where r.heads.contains(where: { inPeriod($0.body) }) {
            if r.conflicted || r.body.status == .draft { unresolved += 1; continue }
            let b = r.body
            if b.kind == .monthlyIncome, b.status == .active, let i = b.incomeMonth {
                try groups[i.net.currency, default: PeriodStatement(currency: i.net.currency)].include(income: i, id: r.id)
            } else if b.kind == .transaction, b.status == .confirmed, let money = b.money, b.transactionKind != .settlement {
                try groups[money.currency, default: PeriodStatement(currency: money.currency)].include(transaction: b, money: money, id: r.id)
            }
        }

        for g in groups.values { _ = try g.surplus }
        return FinancialReport(year: year, month: month, totals: groups.values.sorted { $0.currency.rawValue < $1.currency.rawValue }, unresolvedCount: unresolved)
    }
    /// A snapshot describes the whole space for one currency, not a transaction to sum over time.
    func positions(spaceID: UUID, through: LocalDay) throws -> [PositionObservation] {
        Self.positions(records: try records(spaceID: spaceID), through: through)
    }
    static func positions(records: [Record], through: LocalDay) -> [PositionObservation] {
        let all = records.filter { !$0.deleted && $0.body.sharedDestination == nil && $0.body.kind == .assetSnapshot }
        var groups: [Currency: [String: (day: LocalDay, records: [UUID: Record])]] = [:]
        for record in all {
            for head in record.heads {
                let body = head.body
                guard body.status == .active, let day = body.date, day <= through, let currency = body.assetPosition?.currency else { continue }
                let owner = body.financialOwner?.key ?? "legacy"
                if let current = groups[currency]?[owner], current.day > day { continue }
                if groups[currency]?[owner]?.day != day { groups[currency, default: [:]][owner] = (day, [:]) }
                groups[currency]?[owner]?.records[record.id] = record
            }
        }
        return Currency.allCases.flatMap { currency in
            (groups[currency] ?? [:]).keys.sorted().map { owner in
                let candidates = groups[currency]![owner]!.records
                let ambiguous = candidates.count != 1 || candidates.values.contains(where: \.conflicted)
                return PositionObservation(currency: currency, ownerKey: owner, record: ambiguous ? nil : candidates.values.first, ambiguous: ambiguous)
            }
        }
    }

    func subscriptionCosts(spaceID: UUID, year: Int, month: Int? = nil) throws -> SubscriptionCosts {
        try Self.subscriptionCosts(records: records(spaceID: spaceID), year: year, month: month)
    }
    static func subscriptionCosts(records: [Record], year: Int, month: Int? = nil) throws -> SubscriptionCosts {
        _ = try LocalDay(year, month ?? 1, 1)
        let all = records.filter { !$0.deleted && $0.body.sharedDestination == nil }, subscriptions = all.filter { $0.body.kind == .subscription }
        var monthly: [Currency: Decimal] = [:], annual: [Currency: Decimal] = [:], groups: [Currency: SubscriptionEstimate] = [:], unresolved = 0
        var active = 0, paused = 0
        for s in subscriptions {
            if s.conflicted { unresolved += 1; continue }
            if s.body.status == .paused { paused += 1; continue }
            guard s.body.status == .active else { continue }; active += 1
            let currency = s.body.money?.currency ?? s.body.unknownPriceCurrency ?? .CNY
            var g = groups[currency] ?? SubscriptionEstimate(currency: currency)
            if let money = s.body.money {
                guard s.body.cycleCount > 0 else { throw NobisError.validation("订阅周期无效。") }
                let factor: Decimal = switch s.body.cycleUnit { case .day: 365; case .week: Decimal(365) / 7; case .month: 12; case .year: 1 }
                let cost = Decimal(money.minor) * factor / Decimal(s.body.cycleCount)
                annual[currency, default: 0] += cost; monthly[currency, default: 0] += cost / 12
            } else { g.unknownPriceCount += 1 }
            groups[currency] = g
        }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        func subscriptionID(_ b: RecordBody) -> UUID? { b.subscriptionID ?? (b.transactionKind == .refund ? b.refundOfID.flatMap { byID[$0]?.body.subscriptionID } : nil) }
        for r in all where r.body.kind == .transaction && r.heads.contains(where: { subscriptionID($0.body) != nil && $0.body.date?.year == year && (month == nil || $0.body.date?.month == month) }) {
            if r.conflicted || r.body.status == .draft { unresolved += 1; continue }
            guard r.body.status == .confirmed, [.expense, .refund].contains(r.body.transactionKind), let money = r.body.money else { continue }
            var g = groups[money.currency] ?? SubscriptionEstimate(currency: money.currency)
            g.actualPaid = try Money.sum([g.actualPaid, money.minor * (r.body.transactionKind == .refund ? -1 : 1)]); groups[money.currency] = g
        }
        func rounded(_ value: Decimal) throws -> Int64 {
            var value = value, result = Decimal(); NSDecimalRound(&result, &value, 0, .plain)
            guard result >= 0, result <= Decimal(Int64.max) else { throw NobisError.validation("订阅预计费用超出范围。") }
            return NSDecimalNumber(decimal: result).int64Value
        }
        for currency in Array(groups.keys) { groups[currency]?.annual = try rounded(annual[currency] ?? 0); groups[currency]?.monthly = try rounded(monthly[currency] ?? 0) }
        return SubscriptionCosts(totals: groups.values.sorted { $0.currency.rawValue < $1.currency.rawValue }, activeCount: active, pausedCount: paused, unresolvedCount: unresolved)
    }
    func financialReportCSV(spaceID: UUID, year: Int, month: Int? = nil) throws -> Data {
        try Self.financialReportCSV(index: FinancialReportIndex(records: records(spaceID: spaceID)), year: year, month: month)
    }
    static func financialReportCSV(index: FinancialReportIndex, year: Int, month: Int? = nil) throws -> Data {
        let months: [Int?] = month.map { [$0] } ?? ([nil] + (1...12).map { Optional($0) })
        var rows = [["year", "month", "currency", "metric", "amount", "unresolved_count"]]
        for m in months {
            let report = try index.report(year: year, month: m)
            rows.append([String(year),m.map(String.init) ?? "", "", "report_status", "",String(report.unresolvedCount)])
            for g in report.totals {
                var values: [(String, Int64)] = try [("expense",g.expense),("refund",g.refund),("net_expense",g.netExpense),("cash_income",g.cashIncome),("monthly_net_income",g.monthlyNet),("non_monthly_net_income",g.nonMonthlyNet),("gross_income",g.gross),("known_tax",g.knownTax),("income",g.income),("surplus",g.surplus)]
                values += g.categories.sorted { $0.key < $1.key }.map { ("category:" + $0.key,$0.value) }
                values += g.consumption.sorted { $0.key < $1.key }.map { ("consumption:" + $0.key,$0.value) }
                for (name, value) in values { rows.append([String(year), m.map(String.init) ?? "", g.currency.rawValue, name, (Decimal(value) / Decimal(g.currency.factor)).description, String(report.unresolvedCount)]) }
                rows.append([String(year), m.map(String.init) ?? "", g.currency.rawValue,"unknown_tax_count",String(g.unknownTaxCount),String(report.unresolvedCount)])
            }
        }
        return CSV.encode(rows)
    }
}

private extension PeriodStatement {
    // Mutate the dictionary value in place so each appended source ID does not copy the preceding array.
    mutating func include(income: IncomeMonth, id: UUID) throws {
        if income.isNonMonthly { nonMonthlyNet = try Money.sum([nonMonthlyNet, income.net.minor]) }
        else { monthlyNet = try Money.sum([monthlyNet, income.net.minor]) }
        gross = try Money.sum([gross, income.gross.minor])
        if let tax = income.tax { knownTax = try Money.sum([knownTax, tax.minor]) } else { unknownTaxCount += 1 }
        sourceIDs.append(id)
    }
    mutating func include(transaction b: RecordBody, money: Money, id: UUID) throws {
        switch b.transactionKind {
        case .expense: expense = try Money.sum([expense, money.minor])
        case .refund: refund = try Money.sum([refund, money.minor])
        case .income: cashIncome = try Money.sum([cashIncome, money.minor])
        case .settlement: return
        }
        if [.expense, .refund].contains(b.transactionKind) {
            let amount = money.minor * (b.transactionKind == .refund ? -1 : 1)
            categories[b.category] = try Money.sum([categories[b.category] ?? 0, amount])
            let attribution = b.finance?.consumption ?? .unassigned
            let label = attribution == .personal ? "个人 · \(b.finance?.consumer ?? "未标注")" : attribution.title
            consumption[label] = try Money.sum([consumption[label] ?? 0, amount])
        }
        sourceIDs.append(id)
    }
}
