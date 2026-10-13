import Foundation
import Testing
import FamilyDomain
import FamilyCore
import FamilyPersistence

@MainActor struct Fixture {
    let a = Member(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A")
    let b = Member(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "B")
    let family: Space
    let personal: Space
    let repository: MemoryRepository
    let core: FamilyCore
    init() {
        family = Space(name: "家", kind: .family, ownerID: a.id, members: [a, b])
        personal = Space(name: "个人", kind: .personal, ownerID: a.id, members: [a])
        repository = MemoryRepository(Snapshot(spaces: [family, personal]))
        core = FamilyCore(repository: repository, session: AccessSession(memberID: a.id, allowedSpaceIDs: [family.id, personal.id]))
    }
    func expense(_ minor: Int64 = 10001, currency: Currency = .CNY) throws -> RecordBody {
        var body = RecordBody(kind: .transaction, title: "晚餐", status: .confirmed)
        body.date = try LocalDay(2026, 10, 1); body.memberID = a.id; body.money = Money(minor: minor, currency: currency)
        body.splits = try body.money!.split(members: [b.id, a.id]); return body
    }
}

@Suite("金额、账本及时间") struct FinancialTests {
    @Test func decimalPrecisionAndOverflow() throws {
        #expect(try Money.parse("100.01", currency: .CNY).minor == 10001)
        #expect(try Money.parse("100", currency: .JPY).minor == 100)
        #expect(try Money.parse("1.234", currency: .KWD).minor == 1234)
        #expect(throws: NobisError.self) { try Money.parse("1.01", currency: .JPY) }
        #expect(throws: NobisError.self) { try Money.parse("1.234", currency: .CNY) }
        #expect(throws: NobisError.self) { try Money.parse("9223372036854775808", currency: .JPY) }
        #expect(throws: NobisError.self) { try Money.sum([Int64.max, 1]) }
        #expect(throws: NobisError.self) { try Money.parse("-1", currency: .CNY) }
    }
    @Test func monthEndPreservesAnchor() throws {
        let jan = try LocalDay(2026, 1, 31)
        let feb = try jan.nextCycle(unit: .month, count: 1, anchor: jan)
        #expect(feb == (try LocalDay(2026, 2, 28)))
        #expect(try feb.nextCycle(unit: .month, count: 1, anchor: jan) == LocalDay(2026, 3, 31))
        let leap = try LocalDay(2024, 2, 29)
        #expect(try leap.nextCycle(unit: .year, count: 1, anchor: leap) == LocalDay(2025, 2, 28))
        #expect(throws: NobisError.self) { try LocalDay(2026, 2, 29) }
    }
    @Test @MainActor func splitRefundAndSettlement() throws {
        let f = Fixture(); let expense = try f.expense()
        #expect(expense.splits.map(\.minor) == [5001, 5000])
        let original = try f.core.save(expense, spaceID: f.family.id)
        var refund = try f.expense(2000); refund.title = "退菜"; refund.transactionKind = .refund; refund.refundOfID = original.recordID
        try f.core.save(refund, spaceID: f.family.id)
        var summary = try #require(f.core.ledger(spaceID: f.family.id).first)
        #expect(summary.netExpense == 8001); #expect(summary.balances[f.b.id.uuidString] == -4000)
        var settlement = try f.expense(4000); settlement.transactionKind = .settlement; settlement.memberID = f.b.id; settlement.splits = [ShareAmount(memberID: f.a.id, minor: 4000)]
        let operation = UUID(), id = UUID()
        try f.core.save(settlement, spaceID: f.family.id, recordID: id, operationID: operation)
        try f.core.save(settlement, spaceID: f.family.id, recordID: id, operationID: operation)
        summary = try #require(f.core.ledger(spaceID: f.family.id).first)
        #expect(summary.netExpense == 8001); #expect(summary.balances[f.b.id.uuidString] == 0)
        #expect(try f.core.records(spaceID: f.family.id).count == 3)
        var excess = refund; excess.money = Money(minor: 9000, currency: .CNY); excess.splits = try excess.money!.split(members: [f.a.id, f.b.id])
        #expect(throws: NobisError.self) { try f.core.save(excess, spaceID: f.family.id) }
    }
    @Test @MainActor func groupedCurrencyAndCrossMonthRefund() throws {
        let f = Fixture(); let source = try f.core.save(f.expense(), spaceID: f.family.id)
        try f.core.save(f.expense(100, currency: .JPY), spaceID: f.family.id)
        var refund = try f.expense(2000); refund.date = try LocalDay(2026, 11, 1); refund.transactionKind = .refund; refund.refundOfID = source.recordID
        try f.core.save(refund, spaceID: f.family.id)
        let october = try f.core.ledger(spaceID: f.family.id, from: LocalDay(2026, 10, 1), through: LocalDay(2026, 10, 31))
        #expect(october.count == 2); #expect(october.first { $0.currency == .CNY }?.netExpense == 10001)
        let november = try f.core.ledger(spaceID: f.family.id, from: LocalDay(2026, 11, 1), through: LocalDay(2026, 11, 30))
        #expect(november.first?.netExpense == -2000)
    }
}

@Suite("空间和修订") @MainActor struct IntegrityTests {
    @Test func crossSpaceAndUntrustedSession() throws {
        let f = Fixture()
        let project = try f.core.save(RecordBody(kind: .project, title: "私人项目"), spaceID: f.personal.id)
        var task = RecordBody(kind: .task, title: "任务"); task.projectIDs = [project.recordID]
        #expect(throws: NobisError.self) { try f.core.save(task, spaceID: f.family.id) }
        let bCore = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.b.id, allowedSpaceIDs: [f.family.id, f.personal.id]))
        #expect(try bCore.spaces().count == 1)
        #expect(throws: NobisError.self) { try bCore.record(project.recordID, spaceID: f.personal.id) }
        let familyOnly = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.a.id, allowedSpaceIDs: [f.family.id]))
        #expect(throws: NobisError.self) { try familyOnly.export(spaceID: f.personal.id) }
    }
    @Test func publishingHasNoPrivateReferences() throws {
        let f = Fixture(); var task = RecordBody(kind: .task, title: "私人标题"); task.notes = "秘密来源 /private/file"; task.memberID = f.a.id
        let source = try f.core.save(task, spaceID: f.personal.id)
        let copy = try f.core.publishCopy(source.recordID, from: f.personal.id, to: f.family.id, title: "公开标题", notes: "")
        #expect(copy.recordID != source.recordID); #expect(copy.body.notes.isEmpty); #expect(copy.body.memberID == nil)
        let exported = try Backup.decode(f.core.export(spaceID: f.family.id))
        #expect(!exported.revisions.contains { $0.recordID == source.recordID })
        #expect(exported.revisions.count == 1)
    }
    @Test func versionConflictAndDeleteWins() throws {
        let f = Fixture(); let original = try f.core.save(RecordBody(kind: .task, title: "原始"), spaceID: f.family.id)
        var edit = original.body; edit.title = "离线编辑"
        let branch = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.b.id, body: edit)
        try f.core.save(original.body, spaceID: f.family.id, recordID: original.recordID, expected: [original.id], deleted: true)
        f.repository.snapshot.revisions.append(branch)
        let record = try f.core.record(original.recordID, spaceID: f.family.id)
        #expect(record.conflicted); #expect(record.deleted)
        #expect(try f.core.records(spaceID: f.family.id).isEmpty)
        #expect(throws: NobisError.self) { try f.core.save(edit, spaceID: f.family.id, recordID: original.recordID, expected: [original.id]) }
        try f.core.save(edit, spaceID: f.family.id, recordID: original.recordID, expected: Set(record.heads.map(\.id)))
        #expect(try f.core.records(spaceID: f.family.id).count == 1)
    }
    @Test func financialConflictExcluded() throws {
        let f = Fixture(); let original = try f.core.save(f.expense(), spaceID: f.family.id)
        let branch1 = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.a.id, body: try f.expense(100))
        let branch2 = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.b.id, body: try f.expense(200))
        f.repository.snapshot.revisions += [branch1, branch2]
        let summary = try #require(f.core.ledger(spaceID: f.family.id).first)
        #expect(summary.netExpense == 0); #expect(summary.unresolvedCount == 1)
    }
    @Test func renewalIsIdempotentAndNotAnExpense() throws {
        let f = Fixture(); var subscription = RecordBody(kind: .subscription, title: "订阅")
        subscription.date = try LocalDay(2026, 10, 12); subscription.billingAnchor = subscription.date; subscription.memberID = f.a.id
        try f.core.save(subscription, spaceID: f.family.id)
        try f.core.reconcileRenewals(spaceID: f.family.id, today: LocalDay(2026, 10, 11))
        let review = try #require(f.core.records(spaceID: f.family.id).first { $0.body.kind == .task })
        var edited = review.body; edited.notes = "成员修改了备注"
        try f.core.save(edited, spaceID: f.family.id, recordID: review.id, expected: Set(review.heads.map(\.id)))
        try f.core.reconcileRenewals(spaceID: f.family.id, today: LocalDay(2026, 10, 11))
        #expect(try f.core.records(spaceID: f.family.id).filter { $0.body.kind == .task }.count == 1)
        #expect(try f.core.ledger(spaceID: f.family.id).isEmpty)
    }
    @Test func backupChecksumAndIsolation() throws {
        let f = Fixture(); try f.core.save(f.expense(), spaceID: f.family.id)
        try f.core.save(RecordBody(kind: .task, title: "秘密"), spaceID: f.personal.id)
        let data = try f.core.export(spaceID: f.family.id), decoded = try Backup.decode(data)
        #expect(decoded.spaces.count == 1); #expect(decoded.revisions.count == 1)
        #expect(decoded.revisions.first?.createdAt == f.repository.snapshot.revisions.first?.createdAt)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["businessJSON"] = Data("tampered".utf8).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: NobisError.self) { try Backup.decode(tampered) }
    }
    @Test func coreDataRestartAndPhysicalStores() throws {
        let f = Fixture(); let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try CoreDataRepository(directory: url, initialSpaces: [f.family, f.personal])
        let core = FamilyCore(repository: repository, session: f.core.session)
        try core.save(f.expense(), spaceID: f.family.id)
        try core.save(RecordBody(kind: .task, title: "私密"), spaceID: f.personal.id)
        #expect(repository.container.persistentStoreCoordinator.persistentStores.count == 2)
        let reopened = try CoreDataRepository(directory: url)
        let restored = try reopened.load()
        #expect(restored.revisions.count == 2); #expect(restored.audits.count == 2)
        let verify = FamilyCore(repository: reopened, session: f.core.session)
        #expect(try verify.ledger(spaceID: f.family.id).first?.netExpense == 10001)
    }
}

@Suite("回归与恢复") @MainActor struct RegressionTests {
    @Test func completionRetryUsesOriginalOperation() throws {
        let f = Fixture(); var task = RecordBody(kind: .task, title: "完成测试", status: .completed)
        let operation = UUID(), id = UUID()
        let first = try f.core.save(task, spaceID: f.family.id, recordID: id, operationID: operation)
        let retry = try f.core.save(task, spaceID: f.family.id, recordID: id, operationID: operation)
        #expect(first.id == retry.id); #expect(first.body.completedBy == f.a.id)
        task.title = "改参重放"
        #expect(throws: NobisError.self) { try f.core.save(task, spaceID: f.family.id, recordID: id, operationID: operation) }
    }
    @Test func resolveFinancialBranchesPreservesHistory() throws {
        let f = Fixture(); let original = try f.core.save(f.expense(), spaceID: f.family.id)
        let a = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.a.id, body: try f.expense(500))
        let b = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.b.id, body: try f.expense(600))
        f.repository.snapshot.revisions += [a, b]
        try f.core.save(a.body, spaceID: f.family.id, recordID: original.recordID, expected: [a.id, b.id])
        #expect(try f.core.ledger(spaceID: f.family.id).first?.netExpense == 500)
        #expect(try f.core.history(original.recordID, spaceID: f.family.id).count == 4)
    }
    @Test func unknownSchemaRejected() throws {
        let f = Fixture(); var snapshot = f.repository.snapshot; snapshot.schemaVersion = 2
        #expect(throws: NobisError.self) { try Backup.decode(Backup.encode(snapshot)) }
    }
    @Test func futureConflictingDateStillMarksOriginalPeriodIncomplete() throws {
        let f = Fixture(); let original = try f.core.save(f.expense(), spaceID: f.family.id)
        let a = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.a.id, body: original.body)
        var changed = try f.expense(800, currency: .USD); changed.date = try LocalDay(2026, 11, 1)
        let b = Revision(recordID: original.recordID, spaceID: f.family.id, parents: [original.id], actorID: f.b.id, createdAt: Date().addingTimeInterval(1), body: changed)
        f.repository.snapshot.revisions += [a, b]
        let report = try f.core.ledger(spaceID: f.family.id, from: LocalDay(2026, 10, 1), through: LocalDay(2026, 10, 31))
        #expect(report.first { $0.currency == .CNY }?.unresolvedCount == 1)
        #expect(report.allSatisfy { $0.netExpense == 0 })
    }
    @Test func isolatedRestoreRetainsAmountsAndAudits() throws {
        let f = Fixture(); try f.core.save(f.expense(), spaceID: f.family.id)
        let backup = try f.core.export(spaceID: f.family.id), snapshot = try Backup.decode(backup)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let repository = try CoreDataRepository(directory: destination, initialSpaces: snapshot.spaces)
        try repository.save(snapshot)
        let recovered = FamilyCore(repository: repository, session: f.core.session)
        #expect(try recovered.ledger(spaceID: f.family.id).first?.netExpense == 10001)
        #expect(try repository.load().audits == snapshot.audits)
        #expect(try f.repository.load().spaces.count == 2)
        if let path = ProcessInfo.processInfo.environment["NOBIS_TEST_EXPORT"] { try backup.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
    @Test func localDatesRespectTimeZone() throws {
        let instant = Date(timeIntervalSince1970: 0)
        #expect(LocalDay(date: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == (try LocalDay(1969, 12, 31)))
        #expect(LocalDay(date: instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == (try LocalDay(1970, 1, 1)))
    }
}
