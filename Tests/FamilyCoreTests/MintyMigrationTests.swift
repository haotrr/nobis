import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence

@Suite("Minty 迁入与账务扩展") @MainActor struct MintyMigrationTests {
    func ledgerOnly(_ f: Fixture, _ minor: Int64 = 1234) throws -> RecordBody {
        var b = try f.expense(minor); b.finance = FinanceDetails(); b.memberID = nil; b.splits = []; return b
    }
    @Test func persistenceRoundTripAndOldBackupEnvelope() throws {
        let f = Fixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try CoreDataRepository(directory: directory, initialSpaces: [f.family])
        let core = FamilyCore(repository: repository, session: f.core.session)
        let preview = try LedgerImport.csv(Data("date,item,amount,category\n2026-10-01,车票,12.34,交通".utf8))
        try core.commitImport(preview, spaceID: f.family.id)
        let reopened = try CoreDataRepository(directory: directory)
        let restoredCore = FamilyCore(repository: reopened, session: f.core.session)
        #expect(try restoredCore.ledger(spaceID: f.family.id).first?.balances.isEmpty == true)
        #expect(try restoredCore.commitImport(preview, spaceID: f.family.id) == 0)
        let backup = try f.core.export(spaceID: f.family.id)
        var object = try #require(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        var manifest = try #require(object["manifest"] as? [String: Any]); manifest["schemaVersion"] = 1; object["manifest"] = manifest
        #expect(try Backup.decode(JSONSerialization.data(withJSONObject: object)).spaces == [f.family])
    }
    @Test func ledgerOnlyNeverCreatesDebtAndRefundIsBounded() throws {
        let f = Fixture(), b = try ledgerOnly(f)
        let original = try f.core.save(b, spaceID: f.family.id)
        var refund = b; refund.transactionKind = .refund; refund.refundOfID = original.recordID; refund.money?.minor = 234
        try f.core.save(refund, spaceID: f.family.id)
        let summary = try #require(f.core.ledger(spaceID: f.family.id).first)
        #expect(summary.netExpense == 1000); #expect(summary.balances.isEmpty)
        refund.money?.minor = 1200
        #expect(throws: NobisError.self) { try f.core.save(refund, spaceID: f.family.id) }
        var invalid = b; invalid.splits = [ShareAmount(memberID: f.a.id, minor: 1234)]
        #expect(throws: NobisError.self) { try f.core.save(invalid, spaceID: f.family.id) }
        invalid = b; invalid.transactionKind = .settlement
        #expect(throws: NobisError.self) { try f.core.save(invalid, spaceID: f.family.id) }
        #expect(try Backup.decode(f.core.export(spaceID: f.family.id)).revisions.count == 2)
    }
    @Test func oldPayloadKeepsSettlementMeaning() throws {
        let f = Fixture(), body = try f.expense()
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(RecordBody.self, from: data)
        #expect(decoded.finance == nil); #expect(decoded.accountingMode == .sharedSettlement)
        try f.core.save(decoded, spaceID: f.family.id)
        #expect(try f.core.ledger(spaceID: f.family.id).first?.balances[f.b.id.uuidString] == -5000)
    }
    @Test func confirmedMetadataEditableFinancialFactsLocked() throws {
        let f = Fixture(); let revision = try f.core.save(ledgerOnly(f), spaceID: f.family.id)
        var b = revision.body; b.category = "旅行"; b.finance?.consumption = .personal; b.finance?.consumer = "Diane"
        let updated = try f.core.save(b, spaceID: f.family.id, recordID: revision.recordID, expected: [revision.id])
        b.money?.minor += 1
        #expect(throws: NobisError.self) { try f.core.save(b, spaceID: f.family.id, recordID: revision.recordID, expected: [updated.id]) }
        #expect(try f.core.history(revision.recordID, spaceID: f.family.id).count == 2)
    }
    @Test func budgetCountsMultiProjectExpenseOnceAndIncludesChild() throws {
        let f = Fixture(); var p = RecordBody(kind: .project, title: "旅行")
        let item = BudgetItem(name: "交通", amount: Money(minor: 5000, currency: .CNY)); p.budget = ProjectBudget(limit: item.amount, items: [item])
        let parent = try f.core.save(p, spaceID: f.family.id)
        var child = RecordBody(kind: .project, title: "重庆"); child.parentProjectID = parent.recordID
        let c = try f.core.save(child, spaceID: f.family.id)
        var b = try ledgerOnly(f); b.projectIDs = [parent.recordID, c.recordID]; b.finance?.planItemID = item.id
        // Simulate a pre-single-project persisted revision; new writes may no longer create it.
        let legacy = Revision(spaceID: f.family.id, actorID: f.a.id, body: b)
        f.repository.snapshot.revisions.append(legacy); f.repository.snapshot.audits.append(AuditEvent(revision: legacy, action: "legacy"))
        let summary = try f.core.projectSpending(parent.recordID, spaceID: f.family.id)
        #expect(summary.actual[.CNY] == 1234); #expect(summary.itemActual[item.id] == 1234)
        p.budget?.items = []
        #expect(throws: NobisError.self) { try f.core.save(p, spaceID: f.family.id, recordID: parent.recordID, expected: [parent.id]) }
        var grandchild = child; grandchild.parentProjectID = c.recordID
        #expect(throws: NobisError.self) { try f.core.save(grandchild, spaceID: f.family.id) }
    }
    @Test func batchFailureIsAtomic() throws {
        let f = Fixture(); let b = try ledgerOnly(f); var invalid = b; invalid.money?.minor = -1
        #expect(throws: NobisError.self) { try f.core.saveBatch([RecordChange(body: b), RecordChange(body: invalid)], spaceID: f.family.id) }
        #expect(f.repository.snapshot.revisions.isEmpty); #expect(f.repository.snapshot.audits.isEmpty)
    }
    @Test func csvQuotesNewlinesAndBadRows() throws {
        let rows = [["date","item","amount","category","remark"],["2026-10-01","餐厅, \"A\"","12.34","餐饮","第一行\n第二行"]]
        #expect(try CSV.parse(CSV.decode(CSV.encode(rows))) == rows)
        let parsed = try LedgerImport.csv(CSV.encode(rows))
        #expect(parsed.entries.count == 1); #expect(parsed.entries[0].body.money?.minor == 1234)
        let bad = try LedgerImport.csv(Data("date,item,amount,category\n2026-02-30,错误,1.00,日常\n2026-10-01,精度,1.234,日常".utf8))
        #expect(bad.issues.count == 2); #expect(bad.entries.isEmpty)
        #expect(throws: NobisError.self) { try CSV.parse("a,\"b") }
    }
    @Test func platformCSVSkipsIncomeAndRequiresExplicitReview() throws {
        let rows = [["微信支付账单"],["交易时间","交易类型","交易对方","收/支","金额(元)","交易单号"],["2026-10-01 12:00:00","餐饮","餐厅","支出","¥12.34","WX1"],["2026-10-01 12:01:00","转账","朋友","收入","100","WX2"]]
        let preview = try LedgerImport.csv(CSV.encode(rows))
        #expect(preview.entries.count == 1); #expect(preview.skipped == 1)
        #expect(preview.entries[0].body.memberID == nil)
    }
    @Test func importIdempotencyAndChangedSourceRejected() throws {
        let f = Fixture()
        let rows = [["date","item","amount","category","uuid"],["2026-10-01","晚餐","12.34","餐饮","one"]]
        let preview = try LedgerImport.csv(CSV.encode(rows))
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 1)
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 0)
        var changed = preview; changed.entries[0].body.money?.minor += 1
        #expect(throws: NobisError.self) { try f.core.commitImport(changed, spaceID: f.family.id) }
        #expect(try f.core.commitImport(preview, spaceID: f.personal.id) == 1)
        #expect(try f.core.ledger(spaceID: f.family.id).first?.netExpense == 1234)
    }
    @Test func invalidPreviewCannotPartiallyCommit() throws {
        let f = Fixture()
        let preview = try LedgerImport.csv(Data("date,item,amount,category\n2026-10-01,正常,1,日常\n2026-10-02,错误,no,日常".utf8))
        #expect(throws: NobisError.self) { try f.core.commitImport(preview, spaceID: f.family.id) }
        #expect(f.repository.snapshot.revisions.isEmpty)
    }
    @Test func mergePreservesHistoryAndMovesPlanItems() throws {
        let f = Fixture(); var source = RecordBody(kind: .project, title: "旅行一")
        let item = BudgetItem(name: "住宿", amount: Money(minor: 5000, currency: .CNY)); source.budget = ProjectBudget(limit: item.amount, items: [item])
        let a = try f.core.save(source, spaceID: f.family.id), b = try f.core.save(RecordBody(kind: .project, title: "旅行二"), spaceID: f.family.id)
        var expense = try ledgerOnly(f); expense.projectIDs = [a.recordID]; expense.finance?.planItemID = item.id
        let e = try f.core.save(expense, spaceID: f.family.id)
        try f.core.mergeProject(a.recordID, into: b.recordID, spaceID: f.family.id)
        #expect(try f.core.record(e.recordID, spaceID: f.family.id).body.projectIDs == [b.recordID])
        #expect(try f.core.record(a.recordID, spaceID: f.family.id).body.status == .archived)
        #expect(try f.core.history(e.recordID, spaceID: f.family.id).count == 2)
        #expect(try Backup.decode(f.core.export(spaceID: f.family.id)).revisions.count == 6)
    }
    @Test func filtersIntersectAndExportEscapes() throws {
        let f = Fixture(); var b = try ledgerOnly(f); b.title = "餐厅, A"; b.category = "餐饮"
        let r = try f.core.save(b, spaceID: f.family.id); let record = try f.core.record(r.recordID, spaceID: f.family.id)
        var filter = LedgerFilter(); filter.category = "餐饮"; filter.minimum = 1000; filter.currency = .CNY
        #expect(filter.matches(record)); filter.minimum = 2000; #expect(!filter.matches(record))
        let csv = try CSV.parse(CSV.decode(LedgerImport.expenseCSV([record])))
        #expect(csv[1][1] == "餐厅, A"); #expect(csv[1][2] == "12.34")
    }
    @Test func mintyPackageRetainsRelationshipsAndDefersOtherTables() throws {
        let f = Fixture()
        let data = Data(#"{"format":"minty-nobis","version":1,"source":"family","tables":{"projects":[{"id":1,"name":"重庆","budget_amount":"500.00","start_date":"2026-10-01","status":"active"}],"project_plan_items":[{"id":2,"project_id":1,"name":"交通","planned_amount":"100.00"}],"expenses":[{"id":3,"date":"2026-10-01","item":"车票","amount":"12.34","category":"交通","project_id":1,"plan_item_id":2,"recorded_by":"Hao","attribution_kind":"personal","attribution_member":"Diane"}],"income":[{"id":4,"year":2026,"month":10,"income_type":"工资","pre_tax":"110","post_tax":"100"}],"asset_snapshots":[]}}"#.utf8)
        let preview = try MintyMigration.preview(data)
        #expect(preview.issues.isEmpty)
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 4)
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 0)
        let expense = try #require(f.core.records(spaceID: f.family.id).first { $0.body.kind == .transaction })
        #expect(expense.body.finance?.originalRecorder == "Hao"); #expect(expense.body.memberID == nil)
        let project = try #require(f.core.records(spaceID: f.family.id).first { $0.body.kind == .project })
        #expect(expense.body.projectIDs == [project.id]); #expect(expense.body.finance?.planItemID == project.body.budget?.items.first?.id)
        #expect(try f.core.ledger(spaceID: f.family.id).first?.balances.isEmpty == true)
        #expect(preview.entries.contains { $0.body.kind == .monthlyIncome && $0.body.incomeMonth?.net.minor == 10000 })
    }
}
