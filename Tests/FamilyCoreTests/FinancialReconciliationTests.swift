import Foundation
import Testing
import FamilyDomain
import FamilyCore

@Suite("成员映射与资产核对") @MainActor struct FinancialReconciliationTests {
    private func asset(_ amount: Int64, owner: FinancialOwner? = nil, day: Int = 1, currency: Currency = .CNY) throws -> RecordBody {
        var body = RecordBody(kind: .assetSnapshot, title: "核对快照")
        body.date = try LocalDay(2026, 10, day); body.financialOwner = owner
        var values = Dictionary(uniqueKeysWithValues: AssetComponent.allCases.map { ($0, Int64(0)) }); values[.deposit] = amount
        body.assetPosition = AssetPosition(currency: currency, amounts: values)
        return body
    }
    @Test func ownershipKeepsSourceFingerprintHistoryAndReimport() throws {
        let f = Fixture()
        let data = Data("""
        {"format":"minty-nobis","version":1,"source":"copy","tables":{"income":[{"id":1,"year":2026,"month":0,"income_type":"奖金","pre_tax":"100","post_tax":"90"}]}}
        """.utf8)
        let preview = try MintyMigration.preview(data)
        try f.core.commitImport(preview, spaceID: f.family.id)
        let original = try #require(f.core.records(spaceID: f.family.id).first)
        let owner = FinancialOwner(kind: .member, memberID: f.a.id)
        let changes = try f.core.ownershipChanges([original], owner: owner, spaceID: f.family.id)
        try f.core.saveBatch(changes, spaceID: f.family.id)
        let current = try f.core.record(original.id, spaceID: f.family.id)
        #expect(current.body.financialOwner == owner)
        #expect(current.body.incomeMonth == original.body.incomeMonth)
        #expect(current.body.importSource == original.body.importSource)
        #expect(try f.core.history(original.id, spaceID: f.family.id).count == 2)
        #expect(try f.core.commitImport(preview, spaceID: f.family.id) == 0)
        #expect(throws: NobisError.self) { try f.core.ownershipChanges([original], owner: owner, spaceID: f.family.id) }
        #expect(throws: NobisError.self) { try f.core.ownershipChanges([current], owner: FinancialOwner(kind: .joint), spaceID: f.family.id) }
        #expect(throws: NobisError.self) { try f.core.ownershipChanges([current], owner: FinancialOwner(kind: .member, memberID: UUID()), spaceID: f.family.id) }
        #expect(throws: NobisError.self) { try f.core.ownershipChanges([current], owner: owner, spaceID: f.personal.id) }
    }
    @Test func sameDateOwnerCollisionAndStaleChangesAreRejected() throws {
        let f = Fixture(), owner = FinancialOwner(kind: .member, memberID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let a = try f.core.save(asset(100), spaceID: f.family.id)
        let b = try f.core.save(asset(200), spaceID: f.family.id)
        let records = try f.core.records(spaceID: f.family.id)
        #expect(throws: NobisError.self) { try f.core.ownershipChanges(records, owner: owner, spaceID: f.family.id) }
        let selected = try f.core.record(a.recordID, spaceID: f.family.id)
        let changes = try f.core.ownershipChanges([selected], owner: owner, spaceID: f.family.id)
        try f.core.saveBatch(changes, spaceID: f.family.id)
        #expect(throws: NobisError.self) { try f.core.ownershipChanges([f.core.record(b.recordID, spaceID: f.family.id)], owner: owner, spaceID: f.family.id) }
    }
    @Test func assetsCompareEveryComponentWithoutChangingRecords() throws {
        let f = Fixture()
        let baseline = try f.core.save(asset(100), spaceID: f.family.id)
        let a = try f.core.save(asset(60, owner: FinancialOwner(kind: .member, memberID: f.a.id)), spaceID: f.family.id)
        let b = try f.core.save(asset(40, owner: FinancialOwner(kind: .member, memberID: f.b.id)), spaceID: f.family.id)
        let before = f.repository.snapshot
        let result = try f.core.reconcileAssets(baselineID: baseline.recordID, breakdownIDs: [a.recordID,b.recordID], spaceID: f.family.id)
        #expect(result.matches && result.differences.count == 9)
        #expect(try result.totals.net() == 100)
        #expect(f.repository.snapshot == before)
        let partial = try f.core.reconcileAssets(baselineID: baseline.recordID, breakdownIDs: [a.recordID], spaceID: f.family.id)
        #expect(!partial.matches && partial.differences[.deposit] == -40)
        var equalNet = try asset(110, owner: FinancialOwner(kind: .joint)); equalNet.assetPosition?.amounts[.creditCard] = 10
        let other = try f.core.save(equalNet, spaceID: f.family.id)
        let mismatch = try f.core.reconcileAssets(baselineID: baseline.recordID, breakdownIDs: [other.recordID], spaceID: f.family.id)
        #expect(try mismatch.totals.net() == 100)
        #expect(!mismatch.matches)
    }
    @Test func assetsRejectDifferentDatesCurrenciesAndDuplicateOwners() throws {
        let f = Fixture(), owner = FinancialOwner(kind: .joint)
        let baseline = try f.core.save(asset(100), spaceID: f.family.id)
        let wrongDay = try f.core.save(asset(100, owner: owner, day: 2), spaceID: f.family.id)
        let wrongCurrency = try f.core.save(asset(100, owner: owner, currency: .USD), spaceID: f.family.id)
        let first = try f.core.save(asset(50, owner: owner), spaceID: f.family.id)
        let second = try f.core.save(asset(50, owner: owner), spaceID: f.family.id)
        for ids in [Set([wrongDay.recordID]), Set([wrongCurrency.recordID]), Set([first.recordID,second.recordID]), Set([first.recordID]), Set([baseline.recordID]), Set<UUID>()] {
            #expect(throws: NobisError.self) { try f.core.reconcileAssets(baselineID: baseline.recordID, breakdownIDs: ids, spaceID: f.family.id) }
        }
    }
    @Test func memberMappingIsExplicitRoleAwareAndReadOnly() throws {
        let f = Fixture(), a = Member(name: "A"), b = Member(name: "B")
        let target = Space(name: "新家庭", kind: .family, ownerID: a.id, members: [a,b])
        f.repository.snapshot.spaces.append(target)
        let core = FamilyCore(repository: f.repository, session: AccessSession(memberID: f.a.id, allowedSpaceIDs: [f.family.id,target.id], memberIDsBySpace: [target.id:a.id]))
        try core.save(f.expense(), spaceID: f.family.id)
        let before = f.repository.snapshot
        #expect(throws: NobisError.self) { try core.previewMemberMapping(from: f.family.id, to: target.id, mapping: [:]) }
        #expect(throws: NobisError.self) { try core.previewMemberMapping(from: f.family.id, to: target.id, mapping: [f.a.id:a.id,f.b.id:a.id]) }
        #expect(throws: NobisError.self) { try core.previewMemberMapping(from: f.family.id, to: target.id, mapping: [f.a.id:a.id,f.b.id:UUID()]) }
        let preview = try core.previewMemberMapping(from: f.family.id, to: target.id, mapping: [f.a.id:a.id,f.b.id:b.id])
        #expect(preview.referencedRecords == 1 && preview.responsibilityOrPayerCount == 1 && preview.splitCount == 1)
        #expect(preview.financialOwnerCount == 0)
        #expect(f.repository.snapshot == before)
        #expect(try JSONDecoder().decode(MemberMappingPreview.self, from: JSONEncoder().encode(preview)).mapping == preview.mapping)
    }
}
