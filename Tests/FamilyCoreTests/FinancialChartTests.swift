import Foundation
import Testing
import FamilyDomain
import FamilyCore

@Suite("财务图表口径") @MainActor struct FinancialChartTests {
    @Test func missingZeroFutureAndSeparateIncomeCoverage() throws {
        let f = Fixture()
        var expense = RecordBody(kind: .transaction, title: "零元", status: .confirmed)
        expense.category = ""; expense.finance = FinanceDetails(); expense.money = Money(minor: 0, currency: .CNY); expense.date = try LocalDay(2026, 2, 1)
        try f.core.save(expense, spaceID: f.family.id)
        expense.money?.minor = 200; expense.date = try LocalDay(2026, 3, 21)
        try f.core.save(expense, spaceID: f.family.id)
        var income = RecordBody(kind: .monthlyIncome, title: "非月度")
        income.incomeMonth = IncomeMonth(year: 2026, month: 0, type: "奖金", gross: Money(minor: 500, currency: .CNY), net: Money(minor: 500, currency: .CNY))
        try f.core.save(income, spaceID: f.family.id)
        let points = try FinancialChartData.months(core: f.core, spaceID: f.family.id, year: 2026, currency: .CNY, today: LocalDay(2026, 3, 20))
        #expect(points.count == 3)
        #expect(points[0].expense == nil && points[0].income == nil)
        #expect(points[1].expense == 0 && points[1].income == nil)
        #expect(points[2].expense == nil)
        #expect(try FinancialChartData.months(core: f.core, spaceID: f.family.id, year: 2027, currency: .CNY, today: LocalDay(2026, 3, 20)).isEmpty)
        #expect(try f.core.financialReport(spaceID: f.family.id, year: 2026).totals.first?.nonMonthlyNet == 500)
        var filter = LedgerFilter(); filter.category = ""; filter.transactionKinds = [.expense, .refund]
        let record = try #require(f.core.records(spaceID: f.family.id).first { $0.body.kind == .transaction })
        #expect(filter.matches(record))
        expense.transactionKind = .income; expense.date = try LocalDay(2026, 2, 1)
        let cash = try f.core.save(expense, spaceID: f.family.id)
        #expect(try !filter.matches(f.core.record(cash.recordID, spaceID: f.family.id)))
    }
    @Test func snapshotCutoffDuplicatesAndComponentDeltas() throws {
        let f = Fixture()
        var body = RecordBody(kind: .assetSnapshot, title: "快照")
        body.assetPosition = AssetPosition(currency: .CNY, amounts: Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, Int64(0)) }))
        body.date = try LocalDay(2026, 1, 1)
        let before = body.assetPosition!
        try f.core.save(body, spaceID: f.family.id)
        body.date = try LocalDay(2026, 3, 1); body.assetPosition?.amounts[.deposit] = 1000; body.assetPosition?.amounts[.creditCard] = 300
        try f.core.save(body, spaceID: f.family.id)
        let changes = try FinancialChartData.changes(from: before, to: body.assetPosition!)
        #expect(changes[.deposit] == 1000 && changes[.creditCard] == 300)
        let records = try f.core.records(spaceID: f.family.id)
        #expect(try FinancialChartData.snapshots(records, through: LocalDay(2026, 2, 28)).count == 1)
        try f.core.save(body, spaceID: f.family.id)
        #expect(try FinancialChartData.snapshots(f.core.records(spaceID: f.family.id), through: LocalDay(2026, 3, 31)).count == 1)
        var other = before; other.currency = .USD
        #expect(throws: NobisError.self) { try FinancialChartData.changes(from: before, to: other) }
    }
}
