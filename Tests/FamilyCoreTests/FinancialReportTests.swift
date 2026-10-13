import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence

@Suite("收入、资产与财务报告") @MainActor struct FinancialReportTests {
    func income(_ net: Int64 = 8000, month: Int = 10, currency: Currency = .CNY) -> RecordBody {
        var b = RecordBody(kind: .monthlyIncome, title: "工资")
        b.incomeMonth = IncomeMonth(year: 2026, month: month, type: "工资", gross: Money(minor: 10000, currency: currency), net: Money(minor: net, currency: currency))
        return b
    }
    func asset(day: Int = 1, deposit: Int64 = 10000, debt: Int64 = 2000) throws -> RecordBody {
        var b = RecordBody(kind: .assetSnapshot, title: "快照"); b.date = try LocalDay(2026, 10, day)
        var values = Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, Int64(0)) }); values[.deposit] = deposit; values[.mortgage] = debt
        b.assetPosition = AssetPosition(currency: .CNY, amounts: values); return b
    }
    @Test func monthlyPrecisionAndTaxUnknown() throws {
        let f = Fixture(); try f.core.save(income(), spaceID: f.family.id)
        let record = try #require(f.core.records(spaceID: f.family.id).first)
        #expect(record.body.date == nil); #expect(record.body.money == nil)
        let report = try #require(f.core.financialReport(spaceID: f.family.id, year: 2026, month: 10).totals.first)
        #expect(report.monthlyNet == 8000); #expect(report.unknownTaxCount == 1)
        #expect(try report.income == 8000); #expect(try f.core.records(spaceID: f.family.id).filter { $0.body.kind == .transaction }.isEmpty)
        var b = income(); b.incomeMonth?.month = 13
        #expect(throws: NobisError.self) { try f.core.save(b, spaceID: f.family.id) }
        b = income(); b.incomeMonth?.tax = Money(minor: 1, currency: .USD)
        #expect(throws: NobisError.self) { try f.core.save(b, spaceID: f.family.id) }
    }
    @Test func monthlyYearlyRefundsAndSettlements() throws {
        let f = Fixture(); try f.core.save(income(), spaceID: f.family.id); try f.core.save(income(2000, month: 11), spaceID: f.family.id)
        var expense = try f.expense(3000); expense.category = "旅行"
        let e = try f.core.save(expense, spaceID: f.family.id)
        var refund = try f.expense(1000); refund.transactionKind = .refund; refund.refundOfID = e.recordID; refund.date = try LocalDay(2026,11,1)
        try f.core.save(refund, spaceID: f.family.id)
        var settlement = try f.expense(1000); settlement.transactionKind = .settlement; settlement.splits = [ShareAmount(memberID: f.b.id, minor: 1000)]
        try f.core.save(settlement, spaceID: f.family.id)
        let october = try #require(f.core.financialReport(spaceID: f.family.id, year: 2026, month: 10).totals.first)
        let annual = try #require(f.core.financialReport(spaceID: f.family.id, year: 2026).totals.first)
        #expect(try october.surplus == 5000); #expect(try annual.surplus == 8000)
        #expect(annual.expense == 3000); #expect(annual.refund == 1000)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(annual)) as? [String: Any])
        #expect(encoded["surplus"] as? Int == 8000)
    }
    @Test func separateCurrenciesAndConflictAcrossMonths() throws {
        let f = Fixture(); let r = try f.core.save(income(), spaceID: f.family.id)
        try f.core.save(income(2000, currency: .USD), spaceID: f.family.id)
        var first = r.body; first.incomeMonth?.net.minor = 5000
        try f.core.save(first, spaceID: f.family.id, recordID: r.recordID, expected: [r.id])
        var branch = r.body; branch.incomeMonth?.month = 11
        let revision = Revision(recordID: r.recordID, spaceID: f.family.id, parents: [r.id], actorID: f.b.id, body: branch)
        f.repository.snapshot.revisions.append(revision); f.repository.snapshot.audits.append(AuditEvent(revision: revision, action: "revise"))
        let october = try f.core.financialReport(spaceID: f.family.id, year: 2026, month: 10)
        #expect(october.unresolvedCount == 1); #expect(october.totals.count == 1); #expect(october.totals[0].currency == .USD)
        #expect(try f.core.financialReport(spaceID: f.family.id, year: 2026, month: 11).unresolvedCount == 1)
    }
    @Test func latestSnapshotNotSummedAndDuplicateIsAmbiguous() throws {
        let f = Fixture(); try f.core.save(asset(), spaceID: f.family.id); try f.core.save(asset(day: 2, deposit: 20000), spaceID: f.family.id)
        let early = try #require(f.core.positions(spaceID: f.family.id, through: LocalDay(2026,10,1)).first?.record?.body.assetPosition)
        let late = try #require(f.core.positions(spaceID: f.family.id, through: LocalDay(2026,10,31)).first?.record?.body.assetPosition)
        #expect(try early.net() == 8000); #expect(try late.net() == 18000)
        try f.core.save(asset(day: 2, deposit: 30000), spaceID: f.family.id)
        #expect(try f.core.positions(spaceID: f.family.id, through: LocalDay(2026,10,31)).first?.ambiguous == true)
        #expect(try f.core.financialReport(spaceID: f.family.id, year: 2026).totals.isEmpty)
    }
    @Test func negativeNetAssetsAndOverflow() throws {
        let f = Fixture(); let b = try asset(deposit: 100, debt: 200)
        #expect(try b.assetPosition?.net() == -100)
        try f.core.save(b, spaceID: f.family.id)
        var bad = b; bad.assetPosition?.amounts[.deposit] = Int64.max; bad.assetPosition?.amounts[.stocks] = 1
        #expect(throws: NobisError.self) { try f.core.save(bad, spaceID: f.family.id) }
        bad = b; bad.assetPosition?.amounts.removeValue(forKey: .deposit)
        #expect(throws: NobisError.self) { try f.core.save(bad, spaceID: f.family.id) }
        bad = b; bad.assetPosition?.amounts[.deposit] = -1
        #expect(throws: NobisError.self) { try f.core.save(bad, spaceID: f.family.id) }
    }
    @Test func subscriptionsEstimatedAndActualRemainSeparate() throws {
        let f = Fixture(); var s = RecordBody(kind: .subscription, title: "服务")
        s.date = try LocalDay(2026,10,1); s.billingAnchor = s.date; s.memberID = f.a.id; s.money = Money(minor: 1200, currency: .CNY)
        let subscription = try f.core.save(s, spaceID: f.family.id)
        var unknown = s; unknown.money = nil; unknown.unknownPriceCurrency = .USD
        try f.core.save(unknown, spaceID: f.family.id)
        var paused = s; paused.status = .paused; try f.core.save(paused, spaceID: f.family.id)
        var e = try f.expense(1000); e.subscriptionID = subscription.recordID; let original = try f.core.save(e, spaceID: f.family.id)
        var refund = try f.expense(200); refund.transactionKind = .refund; refund.refundOfID = original.recordID
        try f.core.save(refund, spaceID: f.family.id)
        let costs = try f.core.subscriptionCosts(spaceID: f.family.id, year: 2026, month: 10)
        #expect(costs.activeCount == 2); #expect(costs.pausedCount == 1)
        #expect(costs.totals.first { $0.currency == .CNY }?.annual == 14400)
        #expect(costs.totals.first { $0.currency == .CNY }?.monthly == 1200)
        #expect(costs.totals.first { $0.currency == .CNY }?.actualPaid == 800)
        #expect(costs.totals.first { $0.currency == .USD }?.unknownPriceCount == 1)
        #expect(try f.core.ledger(spaceID: f.family.id).first?.netExpense == 800)
    }
    @Test func reportsBackupAndPersistenceRoundTrip() throws {
        let f = Fixture(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = try CoreDataRepository(directory: url, initialSpaces: [f.family])
        let core = FamilyCore(repository: repo, session: f.core.session)
        try core.save(income(), spaceID: f.family.id); try core.save(asset(), spaceID: f.family.id)
        let snapshot = try Backup.decode(core.export(spaceID: f.family.id))
        #expect(snapshot.revisions.count == 2)
        let reopened = try CoreDataRepository(directory: url)
        let again = FamilyCore(repository: reopened, session: f.core.session)
        #expect(try again.financialReport(spaceID: f.family.id, year: 2026).totals.first?.monthlyNet == 8000)
        let csv = try CSV.parse(CSV.decode(again.financialReportCSV(spaceID: f.family.id, year: 2026)))
        #expect(csv.contains { $0.contains("surplus") && $0.contains("80") })
    }
    @Test func phaseTwoAddsOnlyDeferredRowsOnReimport() throws {
        let f = Fixture()
        let data = Data(#"{"format":"minty-nobis","version":1,"source":"family","tables":{"expenses":[{"id":1,"date":"2026-10-01","item":"车票","amount":"12.34","category":"交通"}],"income":[{"id":2,"year":2026,"month":10,"income_type":"工资","pre_tax":"100","post_tax":"80","tax_amount":null}],"asset_snapshots":[{"id":3,"snapshot_date":"2026-10-01","deposit":"100","investments":"0","stocks":"0","real_estate":"0","lending":"0","provident_fund":"0","mortgage":"20","credit_card":"0","other_liabilities":"0"}]}}"#.utf8)
        let full = try MintyMigration.preview(data); #expect(full.issues.isEmpty)
        var first = full; first.entries.removeAll { [.monthlyIncome, .assetSnapshot].contains($0.body.kind) }
        #expect(try f.core.commitImport(first, spaceID: f.family.id) == 2)
        #expect(try f.core.commitImport(full, spaceID: f.family.id) == 2)
        #expect(try f.core.commitImport(full, spaceID: f.family.id) == 0)
        #expect(try f.core.financialReport(spaceID: f.family.id, year: 2026).totals.first?.monthlyNet == 8000)
    }
}
