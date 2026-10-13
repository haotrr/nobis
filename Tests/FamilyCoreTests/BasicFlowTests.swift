import Foundation
import Testing
import FamilyDomain
import FamilyCore

@Suite("基础数据流程") @MainActor struct BasicFlowTests {
    @Test func batchSeesEarlierChangesAndRollsBackEntireInvalidBatch() throws {
        let f = Fixture(), projectID = UUID(), expenseID = UUID()
        let project = RecordBody(kind: .project, title: "旅行")
        var expense = try f.expense(); expense.projectIDs = [projectID]
        try f.core.saveBatch([RecordChange(id: projectID, body: project), RecordChange(id: expenseID, body: expense)], spaceID: f.family.id)
        #expect(try f.core.projectSpending(projectID, spaceID: f.family.id).actual[.CNY] == expense.money?.minor)
        let before = f.repository.snapshot
        var invalid = expense; invalid.projectIDs = [UUID()]
        #expect(throws: NobisError.self) {
            try f.core.saveBatch([RecordChange(body: project), RecordChange(body: invalid)], spaceID: f.family.id)
        }
        #expect(f.repository.snapshot == before)
        let current = try f.core.record(expenseID, spaceID: f.family.id)
        var edited = expense; edited.notes = "已核对"
        let change = RecordChange(id: expenseID, expected: Set(current.heads.map(\.id)), body: edited)
        #expect(throws: NobisError.self) { try f.core.saveBatch([change, change], spaceID: f.family.id) }
        #expect(f.repository.snapshot == before)
        #expect(throws: NobisError.self) { try f.core.saveBatch([RecordChange(id: expenseID, body: expense)], spaceID: f.personal.id) }
        #expect(f.repository.snapshot == before)
    }

    @Test func batchRefundsRespectCumulativeLimit() throws {
        let f = Fixture()
        let original = try f.core.save(f.expense(10000), spaceID: f.family.id)
        var refund = try f.expense(6000)
        refund.transactionKind = .refund; refund.refundOfID = original.recordID
        let before = f.repository.snapshot
        #expect(throws: NobisError.self) {
            try f.core.saveBatch([RecordChange(body: refund), RecordChange(body: refund)], spaceID: f.family.id)
        }
        #expect(f.repository.snapshot == before)
        try f.core.saveBatch([RecordChange(body: refund)], spaceID: f.family.id)
        #expect(try f.core.ledger(spaceID: f.family.id).first?.netExpense == 4000)
    }

    @Test func noOpImportDoesNotWriteAndDuplicateSourcesAreRejected() throws {
        let f = Fixture()
        let repository = CountingRepository(snapshot: f.repository.snapshot)
        let core = FamilyCore(repository: repository, session: f.core.session)
        let preview = try LedgerImport.csv(Data("date,item,amount,category,uuid\n2026-10-01,晚餐,10,餐饮,a".utf8))
        #expect(try core.commitImport(preview, spaceID: f.family.id) == 1)
        let writes = repository.writes
        #expect(try core.commitImport(preview, spaceID: f.family.id) == 0)
        #expect(repository.writes == writes)
        let imported = try #require(core.records(spaceID: f.family.id).first)
        try core.save(imported.body, spaceID: f.family.id)
        #expect(throws: NobisError.self) { try core.importChanges(preview, spaceID: f.family.id) }
    }

    @Test func ledgerSearchMatchesTermsAcrossFieldsAndSameConflictBranch() throws {
        let f = Fixture()
        var body = try f.expense(); body.account = "银行卡"; body.finance = FinanceDetails()
        body.splits = []; body.finance?.consumer = "小明"; body.finance?.consumption = .personal
        let revision = try f.core.save(body, spaceID: f.family.id)
        let record = try f.core.record(revision.recordID, spaceID: f.family.id)
        var filter = LedgerFilter(); filter.search = "  晚餐\n小明 银行卡 "
        #expect(filter.matches(record))
        filter.search = "晚餐 小红"; #expect(!filter.matches(record))
        filter.search = " \n "; #expect(filter.matches(record))
        var other = body; other.title = "车票"; other.account = "现金"
        let branch = Revision(recordID: revision.recordID, spaceID: f.family.id, actorID: f.a.id, body: other)
        let conflict = try #require(Record.project([revision, branch]).first)
        filter.search = "车票 银行卡"; #expect(!filter.matches(conflict))
        filter.search = "车票 现金"; #expect(filter.matches(conflict))
    }
}

@MainActor private final class CountingRepository: Repository {
    var snapshot: Snapshot
    var writes = 0
    init(snapshot: Snapshot) { self.snapshot = snapshot }
    func load() throws -> Snapshot { snapshot }
    func save(_ snapshot: Snapshot) throws { writes += 1; self.snapshot = snapshot }
}
