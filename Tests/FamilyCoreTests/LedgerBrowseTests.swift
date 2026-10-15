import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence
@testable import NobisUI

@Suite("账本浏览索引与分页") @MainActor struct LedgerBrowseTests {
    @Test func numericDayOrderMatchesCanonicalDates() throws {
        var days: [LocalDay] = []
        for year in [1, 99, 999, 2024, 2025, 2026, 9999] {
            for month in 1...12 {
                for day in [1, 9, 10, 28] { days.append(try LocalDay(year, month, day)) }
            }
        }
        days.append(try LocalDay(2024, 2, 29))
        #expect(days.reversed().sorted() == days.sorted { $0.description < $1.description })
    }

    @Test func filteringPagingAndTotalsPreserveFullResult() throws {
        let f = Fixture()
        let day = try LocalDay(2026, 10, 15)
        var revisions: [Revision] = []
        for i in 0..<25 {
            var body = try f.expense(100)
            body.date = day; body.title = "午餐 \(i)"; body.category = "餐饮"
            if i == 22 { body.transactionKind = .refund }
            if i == 23 { body.status = .draft }
            if i == 24 { body.money = Money(minor: 200, currency: .USD) }
            revisions.append(Revision(spaceID: f.family.id, actorID: f.a.id, body: body))
        }
        var older = try f.expense(500); older.date = day.addingDays(-1)
        revisions.append(Revision(spaceID: f.family.id, actorID: f.a.id, body: older))
        revisions.append(Revision(spaceID: f.personal.id, actorID: f.a.id, body: older))
        // A conflicting record must match any head, including a different date/category.
        var otherHead = older; otherHead.date = day; otherHead.category = "餐饮"
        let conflictID = UUID()
        revisions.append(Revision(recordID: conflictID, spaceID: f.family.id, actorID: f.a.id, body: older))
        revisions.append(Revision(recordID: conflictID, spaceID: f.family.id, actorID: f.a.id, body: otherHead))
        revisions.append(Revision(spaceID: f.family.id, actorID: f.a.id, body: older, deleted: true))
        let records = Record.project(revisions)
        let index = LedgerBrowseIndex(records: records)
        var filter = LedgerFilter(); filter.from = day; filter.through = day
        let result = index.query(filter, spaceIDs: [f.family.id])
        let expected = records.filter { !$0.deleted && $0.latest.spaceID == f.family.id && filter.matches($0) }
        #expect(Set(result.records.map(\.id)) == Set(expected.map(\.id)))
        #expect(result.records.count == 26)
        #expect(result.pageCount == 3)
        #expect(result.page(0).count == 10 && result.page(1).count == 10 && result.page(2).count == 6)
        #expect((0..<3).flatMap { result.page($0).map(\.id) } == result.records.map(\.id))
        #expect(result.page(-1).map(\.id) == result.page(0).map(\.id))
        #expect(result.page(99).map(\.id) == result.page(2).map(\.id))
        #expect(result.hasUnresolved)
        #expect(try result.totals[.CNY]?.get().expense == 2100)
        #expect(try result.totals[.USD]?.get().expense == 200)
        for search in ["午餐 餐饮", "没有匹配"] {
            filter.search = search
            let found = index.query(filter, spaceIDs: [f.family.id])
            #expect(Set(found.records.map(\.id)) == Set(expected.filter { filter.matches($0) }.map(\.id)))
        }
        #expect(index.months(spaceIDs: [f.family.id]) == [LedgerPeriod(year: 2026, month: 10)])
    }

    @Test func cacheInvalidatesForSameIDEditsAndScopeChanges() throws {
        let f = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nobis-ledger-unit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.spaces = [f.family, f.personal]
        let original = Revision(spaceID: f.family.id, actorID: f.a.id, body: try f.expense(100))
        let personal = Revision(spaceID: f.personal.id, actorID: f.a.id, body: try f.expense(300))
        model.records = Record.project([original, personal])
        let filter = LedgerFilter()
        let first = try model.ledgerResult(filter: filter, scope: .shared)
        #expect(try model.ledgerResult(filter: filter, scope: .shared) === first)
        #expect(try model.ledgerResult(filter: filter, scope: .personal).totals[.CNY]?.get().expense == 300)
        #expect(try model.ledgerResult(filter: filter, scope: .shared) === first)
        var updated = original.body; updated.money = Money(minor: 200, currency: .CNY)
        let revision = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.a.id, body: updated)
        model.records = Record.project([original, revision, personal])
        let second = try model.ledgerResult(filter: filter, scope: .shared)
        #expect(first !== second)
        #expect(try second.totals[.CNY]?.get().expense == 200)
        model.spaces = [f.personal]
        #expect(try model.ledgerResult(filter: filter, scope: .shared).records.isEmpty)
        #expect(model.ledgerIndex.recordsByID[original.recordID] == nil)
        model.records = []
        #expect(try model.ledgerResult(filter: filter, scope: .personal).records.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOBIS_LEDGER_REVIEW_COPY"] != nil))
    func isolatedCopyMatchesLegacyAndReusesResults() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NOBIS_LEDGER_REVIEW_COPY"])
        let directory = URL(fileURLWithPath: path)
        // Caller supplies a newly copied fixture; cloud and notifications are disabled.
        let store = try CoreDataRepository(directory: directory.appendingPathComponent("Stores"))
        let before = try store.load()
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(model.ready && model.error == nil)
        let start = Date()
        let all = try model.ledgerResult(filter: LedgerFilter(), scope: .all)
        let firstSeconds = Date().timeIntervalSince(start)
        let legacyStart = Date()
        let legacy = model.records(in: .all).filter { LedgerFilter().matches($0) }.sorted {
            ($0.body.date?.description ?? "") > ($1.body.date?.description ?? "")
        }
        _ = LedgerMonthGroup.groups(model.records(in: .all).filter { $0.body.kind == .transaction })
        let legacySeconds = Date().timeIntervalSince(legacyStart)
        #expect(Set(all.records.map(\.id)) == Set(legacy.map(\.id)))
        for currency in Currency.allCases {
            let valid = legacy.filter { !$0.conflicted && $0.body.status == .confirmed && $0.body.money?.currency == currency }
            if valid.isEmpty { #expect(all.totals[currency] == nil); continue }
            let sums = try ImportInspection.totals(valid.map(\.body), currency: currency)
            #expect(try all.totals[currency]?.get().expense == sums.expense)
            #expect(try all.totals[currency]?.get().income == sums.income)
        }
        let cachedStart = Date()
        for n in 0..<100 {
            let cached = try model.ledgerResult(filter: LedgerFilter(), scope: .all)
            #expect(cached === all)
            #expect(cached.page(n % cached.pageCount).count <= 10)
        }
        let cachedSeconds = Date().timeIntervalSince(cachedStart)
        var today = LedgerFilter(); today.from = model.today; today.through = model.today
        let todays = try model.ledgerResult(filter: today, scope: .all)
        #expect(Set(todays.records.map(\.id)) == Set(legacy.filter { today.matches($0) }.map(\.id)))
        #expect(try store.load() == before)
        print("LEDGER_BENCH records=\(all.records.count) legacySeconds=\(legacySeconds) firstSeconds=\(firstSeconds) cached100PagesSeconds=\(cachedSeconds)")
    }
}
