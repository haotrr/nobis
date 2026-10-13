import Foundation
import FamilyDomain
@testable import FamilyCore

// Frozen pre-index implementation: correctness oracle and same-process benchmark baseline.
@MainActor enum LegacyReportScan {
    static func report(records: [Record], year: Int, month: Int? = nil, through: LocalDay? = nil) throws -> FinancialReport {
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
                var g = groups[i.net.currency] ?? PeriodStatement(currency: i.net.currency)
                if i.isNonMonthly { g.nonMonthlyNet = try Money.sum([g.nonMonthlyNet, i.net.minor]) }
                else { g.monthlyNet = try Money.sum([g.monthlyNet, i.net.minor]) }
                g.gross = try Money.sum([g.gross, i.gross.minor])
                if let tax = i.tax { g.knownTax = try Money.sum([g.knownTax, tax.minor]) } else { g.unknownTaxCount += 1 }
                g.sourceIDs.append(r.id); groups[g.currency] = g
            } else if b.kind == .transaction, b.status == .confirmed, let money = b.money {
                var g = groups[money.currency] ?? PeriodStatement(currency: money.currency)
                switch b.transactionKind {
                case .expense: g.expense = try Money.sum([g.expense, money.minor])
                case .refund: g.refund = try Money.sum([g.refund, money.minor])
                case .income: g.cashIncome = try Money.sum([g.cashIncome, money.minor])
                case .settlement: continue
                }
                if [.expense, .refund].contains(b.transactionKind) {
                    let amount = money.minor * (b.transactionKind == .refund ? -1 : 1)
                    g.categories[b.category] = try Money.sum([g.categories[b.category] ?? 0, amount])
                    let attribution = b.finance?.consumption ?? .unassigned
                    let label = attribution == .personal ? "个人 · \(b.finance?.consumer ?? "未标注")" : attribution.title
                    g.consumption[label] = try Money.sum([g.consumption[label] ?? 0, amount])
                }
                g.sourceIDs.append(r.id); groups[g.currency] = g
            }
        }
        for g in groups.values { _ = try g.surplus }
        return FinancialReport(year: year, month: month, totals: groups.values.sorted { $0.currency.rawValue < $1.currency.rawValue }, unresolvedCount: unresolved)
    }
    static func csv(year: Int, month: Int? = nil, query: (Int, Int?) throws -> FinancialReport) throws -> Data {
        let months: [Int?] = month.map { [$0] } ?? ([nil] + (1...12).map { Optional($0) })
        var rows = [["year", "month", "currency", "metric", "amount", "unresolved_count"]]
        for m in months {
            let report = try query(year, m)
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
