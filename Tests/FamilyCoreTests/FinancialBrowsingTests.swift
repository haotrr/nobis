import Foundation
import CryptoKit
import Testing
import FamilyDomain
@testable import FamilyCore

@Suite("迁入核对与历史浏览") @MainActor struct FinancialBrowsingTests {
    @Test func reviewSeparatesNewAndExistingAndDoesNotSumSnapshots() throws {
        let f = Fixture()
        let preview = try LedgerImport.csv(Data("date,item,amount,category,uuid\n2026-09-30,晚餐,10.25,餐饮,a\n2026-10-01,车票,20,交通,b".utf8))
        var first = preview; first.entries = [preview.entries[0]]
        try f.core.commitImport(first, spaceID: f.family.id)
        let changes = try f.core.importChanges(preview, spaceID: f.family.id)
        let group = try #require(ImportInspection(preview: preview, changes: changes).groups.first)
        #expect(group.existingCount == 1)
        #expect(group.additions?.count == 1)
        #expect(try ImportInspection.totals(group.bodies, currency: .CNY).expense == 3025)
        #expect(try ImportInspection.totals(try #require(group.additions), currency: .CNY).expense == 2000)
        #expect(try ImportInspection.totals(group.bodies, currency: .USD).expense == 0)
        var asset = RecordBody(kind: .assetSnapshot, title: "快照")
        asset.assetPosition = AssetPosition(currency: .CNY, amounts: [.deposit: 999_00])
        let totals = try ImportInspection.totals([asset, asset], currency: .CNY)
        #expect(totals.expense == 0 && totals.income == 0 && totals.monthlyNet == 0)
        #expect(ImportInspection(preview: preview, changes: nil).groups.first?.existingCount == nil)
    }
    @Test func incomeKindsKeepDistinctAmountsAndCombinedReport() throws {
        let f = Fixture()
        var monthly = RecordBody(kind: .monthlyIncome, title: "工资")
        monthly.incomeMonth = IncomeMonth(year: 2026, month: 9, type: "工资", gross: Money(minor: 10000, currency: .CNY), net: Money(minor: 8000, currency: .CNY))
        var cash = RecordBody(kind: .transaction, title: "其他收入", status: .confirmed)
        cash.transactionKind = .income; cash.money = Money(minor: 2000, currency: .CNY); cash.date = try LocalDay(2026, 9, 20); cash.finance = FinanceDetails()
        try f.core.save(monthly, spaceID: f.family.id); try f.core.save(cash, spaceID: f.family.id)
        let sums = try ImportInspection.totals([cash, monthly], currency: .CNY)
        #expect(sums.income == 2000 && sums.monthlyNet == 8000 && sums.gross == 10000)
        #expect(try f.core.financialReport(spaceID: f.family.id, year: 2026, month: 9).totals.first?.income == 10000)
    }
    @Test func realSourceEdgeCasesPreserveMeaningAndBackup() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "format": "minty-nobis", "version": 1, "source": "edge-cases", "tables": [
                "income": [
                    ["id": 1, "year": 2026, "month": 0, "income_type": "奖金", "pre_tax": "100", "post_tax": "90"],
                    ["id": 2, "year": 2026, "month": 1, "income_type": "工资", "pre_tax": "100", "post_tax": "90", "tax_amount": "9.99999999999999"]
                ],
                "expenses": [["id": 3, "date": "2026-01-01", "item": "零元", "amount": "0", "category": "其他"]]
            ]
        ])
        let preview = try MintyMigration.preview(data)
        #expect(preview.issues.isEmpty)
        let f = Fixture()
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 4)
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 0)
        let annual = try #require(f.core.financialReport(spaceID: f.family.id, year: 2026).totals.first)
        let january = try #require(f.core.financialReport(spaceID: f.family.id, year: 2026, month: 1).totals.first)
        #expect(annual.nonMonthlyNet == 9000 && annual.monthlyNet == 9000)
        #expect(try annual.income == 18000)
        #expect(january.nonMonthlyNet == 0 && january.monthlyNet == 9000)
        #expect(annual.knownTax == 1000 && annual.unknownTaxCount == 1)
        let records = try f.core.records(spaceID: f.family.id)
        #expect(records.first { $0.body.incomeMonth?.month == 0 }?.body.date == nil)
        #expect(records.contains { $0.body.notes.contains("9.99999999999999") })
        let snapshot = try Backup.decode(Backup.encode(f.repository.snapshot))
        #expect(snapshot.revisions.count == f.repository.snapshot.revisions.count)
        let csv = try CSV.decode(f.core.financialReportCSV(spaceID: f.family.id, year: 2026))
        #expect(try CSV.parse(csv).contains { $0.count > 4 && $0[3] == "non_monthly_net_income" && $0[4] == "90" })
        var zero = try #require(records.first { $0.body.kind == .transaction }?.body)
        zero.transactionKind = .income
        #expect(throws: NobisError.self) { try f.core.save(zero, spaceID: f.family.id) }
        zero.transactionKind = .expense; zero.finance = FinanceDetails(mode: .sharedSettlement)
        #expect(throws: NobisError.self) { try f.core.save(zero, spaceID: f.family.id) }
    }
    @Test func genuinePrecisionAndInvalidMonthsStillBlockTheWholeBatch() throws {
        for tax in ["9.999", "9.99000000000001", "NaN", "-0.000000000001"] {
            let data = try JSONSerialization.data(withJSONObject: ["format": "minty-nobis", "version": 1, "source": "invalid", "tables": ["income": [["id": 1, "year": 2026, "month": 0, "income_type": "奖金", "pre_tax": "100", "post_tax": "90", "tax_amount": tax]]]])
            let preview = try MintyMigration.preview(data)
            #expect(preview.issues.count == 1)
            let f = Fixture()
            #expect(throws: NobisError.self) { try f.core.commitImport(preview, spaceID: f.family.id) }
            #expect(f.repository.snapshot.revisions.isEmpty)
        }
        for month in [-1, 13] {
            let income = IncomeMonth(year: 2026, month: month, type: "奖金", gross: Money(minor: 100, currency: .CNY), net: Money(minor: 90, currency: .CNY))
            #expect(throws: NobisError.self) { try income.validate() }
        }
    }
    @Test func assetSourceFingerprintIsStableAcrossParsingAndLegacyImports() throws {
        let f = Fixture()
        var asset = RecordBody(kind: .assetSnapshot, title: "快照")
        asset.date = try LocalDay(2026, 1, 1)
        asset.assetPosition = AssetPosition(currency: .CNY, amounts: Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, Int64(100)) }))
        asset.importSource = ImportSource(key: "minty:copy:asset_snapshots:one", originalID: "1")
        var preview = ImportPreview()
        preview.entries = [ImportEntry(id: UUID(), body: asset, row: 1)]
        let encoded = try JSONEncoder().encode(preview.entries[0].body)
        try f.core.commitImport(preview, spaceID: f.family.id)
        for _ in 0..<5 {
            preview.entries[0].body = try JSONDecoder().decode(RecordBody.self, from: encoded)
            #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 0)
        }
        let legacyFixture = Fixture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyHash = SHA256.hash(data: try encoder.encode(asset)).map { String(format: "%02x", $0) }.joined()
        asset.importSource?.fingerprint = legacyHash
        let original = try legacyFixture.core.save(asset, spaceID: legacyFixture.family.id)
        var edited = asset; edited.assetPosition?.amounts[.deposit] = 200
        try legacyFixture.core.save(edited, spaceID: legacyFixture.family.id, recordID: original.recordID, expected: [original.id])
        #expect(try legacyFixture.core.commitImport(preview, spaceID: legacyFixture.family.id) == 0)
        preview.entries[0].body.assetPosition?.amounts[.deposit] = 200
        #expect(throws: NobisError.self) { try legacyFixture.core.commitImport(preview, spaceID: legacyFixture.family.id) }
    }
    @Test func monthsSortAcrossYearsAndPeriodHonorsLeapYear() throws {
        let f = Fixture()
        func record(_ day: LocalDay?) -> Record {
            var body = RecordBody(kind: .transaction, title: "账单"); body.date = day
            return Record.project([Revision(spaceID: f.family.id, actorID: f.a.id, body: body)])[0]
        }
        let old = record(try LocalDay(2025, 12, 31)), new = record(try LocalDay(2026, 1, 1)), undated = record(nil)
        let groups = LedgerMonthGroup.groups([old, undated, new])
        #expect(groups.map(\.id) == ["2026-01", "2025-12", ""])
        #expect(groups.first?.records.first?.id == new.id)
        #expect(try LedgerPeriod(year: 2024, month: 2).bounds().through == LocalDay(2024, 2, 29))
        #expect(try LedgerPeriod(year: 2026).bounds().through == LocalDay(2026, 12, 31))
    }
}
