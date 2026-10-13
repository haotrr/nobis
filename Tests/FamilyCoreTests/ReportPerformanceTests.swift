import Foundation
import Testing
import FamilyDomain
@testable import FamilyCore
import FamilyPersistence

@MainActor private final class ReportCountingRepository: Repository {
    let base: any Repository
    var reads = 0
    init(_ base: any Repository) { self.base = base }
    func load() throws -> Snapshot { reads += 1; return try base.load() }
    func save(_ snapshot: Snapshot) throws { try base.save(snapshot) }
    func requireWrite(spaceID: UUID, actorID: UUID) throws { try base.requireWrite(spaceID: spaceID, actorID: actorID) }
}

@Suite("报表索引与大库") @MainActor struct ReportPerformanceTests {
    private func canonical(_ report: FinancialReport) throws -> Data {
        var value = report
        value = FinancialReport(year: value.year, month: value.month, totals: value.totals.map { total in
            var sorted = total; sorted.sourceIDs.sort { $0.uuidString < $1.uuidString }; return sorted
        }, unresolvedCount: value.unresolvedCount)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    @Test func indexMatchesFullScanWithConflictingPeriods() throws {
        let f = Fixture()
        var b = RecordBody(kind: .transaction, title: "边界", status: .confirmed)
        b.money = Money(minor: 100, currency: .CNY); b.finance = FinanceDetails(); b.date = try LocalDay(2025, 12, 31)
        let first = try f.core.save(b, spaceID: f.family.id)
        b.date = try LocalDay(2026, 1, 1)
        let branch = Revision(recordID: first.recordID, spaceID: f.family.id, actorID: f.family.ownerID, body: b)
        f.repository.snapshot.revisions.append(branch)
        var income = RecordBody(kind: .monthlyIncome, title: "非月度")
        income.incomeMonth = IncomeMonth(year: 2026, month: 0, type: "奖金", gross: Money(minor: 10, currency: .USD), net: Money(minor: 10, currency: .USD))
        try f.core.save(income, spaceID: f.family.id)
        b.status = .draft; try f.core.save(b, spaceID: f.family.id)
        let records = try f.core.records(spaceID: f.family.id), index = FinancialReportIndex(records: records)
        for year in [2025, 2026, 2027] {
            for month: Int? in [nil, 1, 12] {
                for through: LocalDay? in [nil, try LocalDay(2026, 1, 1)] {
                    #expect(try canonical(index.report(year: year, month: month, through: through)) == canonical(LegacyReportScan.report(records: records, year: year, month: month, through: through)))
                }
            }
        }
        #expect(try index.report(year: 2025, month: 12).unresolvedCount == 1)
        #expect(try index.report(year: 2026, month: 1).unresolvedCount == 2)
    }
    @Test func annualExportReadsOnceAndRefreshesAuthorizationAndData() throws {
        let f = Fixture()
        // The wrapper uses the same source as this session.
        let repository = ReportCountingRepository(f.repository)
        let core = FamilyCore(repository: repository, session: f.core.session)
        _ = try core.financialReportCSV(spaceID: f.family.id, year: 2026)
        #expect(repository.reads == 1)
        var b = RecordBody(kind: .transaction, title: "新数据", status: .confirmed)
        b.money = Money(minor: 765, currency: .CNY); b.finance = FinanceDetails(); b.date = try LocalDay(2026, 1, 1)
        try f.core.save(b, spaceID: f.family.id)
        #expect(try core.financialReport(spaceID: f.family.id, year: 2026).totals.first?.expense == 765)
        f.repository.snapshot.spaces.removeAll { $0.id == f.family.id }
        #expect(throws: NobisError.self) { try core.financialReportCSV(spaceID: f.family.id, year: 2026) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOBIS_MINTY_PERFORMANCE_ROOT"] != nil))
    func tenThousandMintyDerivedRecords() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOBIS_MINTY_PERFORMANCE_ROOT"]))
        let preview = try MintyMigration.preview(Data(contentsOf: root.appendingPathComponent("personal.json")))
        #expect(preview.issues.isEmpty)
        let templates: [RecordBody] = preview.entries.compactMap { entry in
            let b = entry.body
            if b.kind == .monthlyIncome && b.status == .active { return b }
            if b.kind == .transaction && b.status == .confirmed && (b.transactionKind == .expense || b.transactionKind == .income) { return b }
            return nil
        }
        #expect(!templates.isEmpty)
        let f = Fixture(), count = 12_000
        var snapshot = Snapshot(spaces: [f.family])
        for n in 0..<count {
            var b = templates[n % templates.count]
            b.projectIDs = []; b.referenceIDs = nil; b.memberID = nil; b.splits = []; b.importSource = nil
            b.subscriptionID = nil; b.refundOfID = nil; b.financialOwner = nil; b.finance?.planItemID = nil
            let r = Revision(spaceID: f.family.id, actorID: f.family.ownerID, createdAt: Date(timeIntervalSince1970: Double(n)), body: b)
            snapshot.revisions.append(r); snapshot.audits.append(AuditEvent(revision: r, action: "performance-fixture"))
        }
        let directory = root.appendingPathComponent("performance-\(UUID())")
        let store = try CoreDataRepository(directory: directory, initialSpaces: [f.family])
        try store.save(snapshot)
        let repository = ReportCountingRepository(store), core = FamilyCore(repository: repository, session: f.core.session)
        let source = try core.records(spaceID: f.family.id)
        #expect(source.count == count)
        let index = FinancialReportIndex(records: source)
        var legacy: [Data] = [], indexed: [Data] = []
        // Same process, same records, all original years and 12 months; include index construction cost.
        let before = Date()
        for year in index.years { for month: Int? in [nil] + (1...12).map(Optional.some) { legacy.append(try canonical(LegacyReportScan.report(records: source, year: year, month: month))) } }
        let legacySeconds = Date().timeIntervalSince(before), optimizedStart = Date()
        let rebuilt = FinancialReportIndex(records: source)
        for year in rebuilt.years { for month: Int? in [nil] + (1...12).map(Optional.some) { indexed.append(try canonical(rebuilt.report(year: year, month: month))) } }
        let indexedSeconds = Date().timeIntervalSince(optimizedStart)
        #expect(legacy == indexed)
        let busiestYear = try #require(index.years.max { left, right in
            source.filter { $0.body.date?.year == left || $0.body.incomeMonth?.year == left }.count < source.filter { $0.body.date?.year == right || $0.body.incomeMonth?.year == right }.count
        })
        repository.reads = 0; let legacyExportStart = Date()
        let legacyCSV = try LegacyReportScan.csv(year: busiestYear) { year, month in
            // Match the old public API's separate authorization read and projection read.
            _ = try core.space(f.family.id)
            return try LegacyReportScan.report(records: core.records(spaceID: f.family.id), year: year, month: month)
        }
        let legacyExportSeconds = Date().timeIntervalSince(legacyExportStart), legacyReads = repository.reads
        repository.reads = 0; let exportStart = Date()
        let csv = try core.financialReportCSV(spaceID: f.family.id, year: busiestYear)
        let exportSeconds = Date().timeIntervalSince(exportStart), exportReads = repository.reads
        #expect(exportReads == 1 && legacyReads == 26)
        #expect(csv == legacyCSV)
        #expect(try CSV.parse(CSV.decode(csv)).count > 13)
        let reopened = try CoreDataRepository(directory: directory)
        #expect(try reopened.load() == store.load())
        _ = try Backup.decode(core.export(spaceID: f.family.id))
        let output: [String: Any] = ["records": count, "years": index.years, "reportsCompared": legacy.count,
            "legacyReportsSeconds": legacySeconds, "indexedReportsSeconds": indexedSeconds,
            "legacyCSVSeconds": legacyExportSeconds, "indexedCSVSeconds": exportSeconds,
            "legacyRepositoryReads": legacyReads, "indexedRepositoryReads": exportReads, "directory": directory.path]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report-performance.json"))
    }
}
