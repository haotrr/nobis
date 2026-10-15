import Foundation
import CoreData
import Testing
import FamilyDomain
@testable import FamilyCore
import FamilyPersistence
@testable import NobisUI

@MainActor private final class LoadingCounter: Repository {
    var snapshot: Snapshot
    var loads = 0
    init(_ snapshot: Snapshot) { self.snapshot = snapshot }
    func load() throws -> Snapshot { loads += 1; return snapshot }
    func loadSpaces() throws -> [Space] { snapshot.spaces }
    func save(_ value: Snapshot) throws { snapshot = value }
}

@Suite("首次加载与长历史") @MainActor struct LargeStoreLoadingTests {
    private func heads(_ records: [Record]) -> [UUID: Set<UUID>] { Dictionary(uniqueKeysWithValues: records.map { ($0.id, Set($0.heads.map(\.id))) }) }
    @Test func projectionPreservesDuplicatesConflictsTombstonesAndLongChains() throws {
        let f = Fixture(); var revisions: [Revision] = []
        let root = Revision(spaceID: f.family.id, actorID: f.a.id, body: RecordBody(kind: .task, title: "长历史"))
        revisions.append(root)
        for n in 0..<2000 {
            revisions.append(Revision(recordID: root.recordID, spaceID: f.family.id, parents: [revisions.last!.id], actorID: f.a.id, createdAt: Date(timeIntervalSince1970: Double(n)), body: root.body))
        }
        let fork = Revision(recordID: root.recordID, spaceID: f.family.id, parents: [root.id], actorID: f.b.id, body: root.body, deleted: true)
        revisions += [fork, fork, root]
        let projected = Record.project(revisions)
        #expect(heads(projected) == heads(LegacyStoreWorkload.project(revisions)))
        #expect(projected.count == 1 && projected[0].deleted && projected[0].conflicted)
        #expect(Set(projected[0].heads.map(\.id)) == [fork.id, revisions[2000].id])
    }
    @Test func refreshReadsOnceAndRenewalsRemainIdempotent() throws {
        let f = Fixture(), repo = LoadingCounter(Fixture().repository.snapshot)
        repo.snapshot = f.repository.snapshot
        let core = FamilyCore(repository: repo, session: f.core.session)
        _ = try core.workspaceRecords(spaceIDs: [f.family.id, f.personal.id], renewingSpaceIDs: [f.family.id])
        #expect(repo.loads == 1)
        var b = RecordBody(kind: .subscription, title: "续费")
        b.date = try LocalDay(2026, 10, 13); b.billingAnchor = b.date; b.memberID = f.a.id
        try core.save(b, spaceID: f.family.id)
        let first = try core.workspaceRecords(spaceIDs: [f.family.id], renewingSpaceIDs: [f.family.id], today: LocalDay(2026, 10, 13))
        #expect(first.filter { $0.body.kind == .task }.count == 1)
        repo.loads = 0
        _ = try core.workspaceRecords(spaceIDs: [f.family.id], renewingSpaceIDs: [f.family.id], today: LocalDay(2026, 10, 13))
        #expect(repo.loads == 1)
        repo.snapshot.spaces.removeAll { $0.id == f.family.id }
        #expect(throws: NobisError.self) { try core.workspaceRecords(spaceIDs: [f.family.id]) }
    }
    @Test func bulkReadRejectsDirtyStateAndImmutableHistoryCannotBeReplaced() throws {
        let f = Fixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("nobis-load-regression-\(UUID())")
        let store = try CoreDataRepository(directory: directory, initialSpaces: [f.family])
        let r = Revision(spaceID: f.family.id, actorID: f.a.id, body: RecordBody(kind: .task, title: "保留历史"))
        let original = Snapshot(spaces: [f.family], revisions: [r], audits: [AuditEvent(revision: r, action: "create")])
        try store.save(original)
        #expect(try store.load() == original)
        var replacement = original; replacement.revisions = []
        #expect(throws: NobisError.self) { try store.save(replacement) }
        replacement = original; replacement.revisions.append(r)
        #expect(throws: NobisError.self) { try store.save(replacement) }
        let object = try #require(store.container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "RecordRevision")).first)
        object.setValue(Data("invalid".utf8), forKey: "payload")
        #expect(throws: NobisError.self) { try store.load() }
        store.container.viewContext.rollback()
        #expect(try store.load() == original)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOBIS_LARGE_STORE_ROOT"] != nil))
    func hundredThousandRecordsAndHundredRevisionChains() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOBIS_LARGE_STORE_ROOT"]))
        let preview = try MintyMigration.preview(Data(contentsOf: root.appendingPathComponent("personal.json")))
        let templates: [RecordBody] = preview.entries.compactMap { entry in
            let body = entry.body
            guard body.kind == .transaction, body.status == .confirmed, body.transactionKind == .expense else { return nil }
            return body
        }
        _ = try #require(templates.first)
        var results: [[String: Any]] = []
        for (name, count, depth) in [("100k-records", 100_000, 1), ("long-history", 1_000, 100)] {
            try autoreleasepool {
                let f = Fixture(), directory = root.appendingPathComponent("loading-\(name)-\(UUID())")
                var snapshot = Snapshot(spaces: [f.family])
                for n in 0..<count {
                    var b = templates[n % templates.count]
                    b.projectIDs = []; b.referenceIDs = nil; b.memberID = nil; b.splits = []; b.importSource = nil
                    b.subscriptionID = nil; b.refundOfID = nil; b.financialOwner = nil; b.finance?.planItemID = nil
                    let id = UUID(); var parents: [UUID] = []
                    for version in 0..<depth {
                        let r = Revision(recordID: id, spaceID: f.family.id, parents: parents, actorID: f.a.id, createdAt: Date(timeIntervalSince1970: Double(n * depth + version)), body: b)
                        snapshot.revisions.append(r); snapshot.audits.append(AuditEvent(revision: r, action: "performance-fixture")); parents = [r.id]
                    }
                }
                let store = try CoreDataRepository(directory: directory, initialSpaces: [f.family])
                try store.save(snapshot)
                let oldStore = try CoreDataRepository(directory: directory)
                let oldStart = Date(); let old = try LegacyStoreWorkload.load(oldStore)
                let oldRead = Date().timeIntervalSince(oldStart)
                let newStore = try CoreDataRepository(directory: directory)
                let start = Date(); let loaded = try newStore.load()
                let read = Date().timeIntervalSince(start)
                #expect(Dictionary(uniqueKeysWithValues: loaded.revisions.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: old.revisions.map { ($0.id, $0) }))
                #expect(Dictionary(uniqueKeysWithValues: loaded.audits.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: old.audits.map { ($0.id, $0) }))
                let oldProjectionStart = Date(); let oldRecords = LegacyStoreWorkload.project(old.revisions)
                let oldProjection = Date().timeIntervalSince(oldProjectionStart)
                let projectionStart = Date(); let records = Record.project(loaded.revisions)
                let projection = Date().timeIntervalSince(projectionStart)
                #expect(records.count == count && heads(records) == heads(oldRecords))
                let oldSummaryStart = Date(); let oldSummaries = try LegacyStoreWorkload.ledger(records: oldRecords)
                let oldSummarySeconds = Date().timeIntervalSince(oldSummaryStart)
                let summaryStart = Date(); let summaries = try FamilyCore.ledger(records: records)
                let summarySeconds = Date().timeIntervalSince(summaryStart)
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                #expect(try encoder.encode(summaries) == encoder.encode(oldSummaries))
                #expect(summaries.first?.expense == (try Money.sum(records.compactMap { $0.body.money?.minor })))
                let backupStart = Date()
                let backup = try Backup.encode(loaded)
                let backupURL = root.appendingPathComponent("large-backup-\(name).json")
                try backup.write(to: backupURL, options: .atomic)
                #expect(try Backup.decode(Data(contentsOf: backupURL)) == loaded)
                let backupSeconds = Date().timeIntervalSince(backupStart)
                // A real append exercises the linear immutable-history guard with 100,000 existing revisions.
                let extra = Revision(spaceID: f.family.id, actorID: f.a.id, body: RecordBody(kind: .task, title: "隔离追加样本"))
                var appended = loaded; appended.revisions.append(extra); appended.audits.append(AuditEvent(revision: extra, action: "create"))
                let saveStart = Date(); try newStore.save(appended); let saveSeconds = Date().timeIntervalSince(saveStart)
                let reopened = try CoreDataRepository(directory: directory)
                #expect(try reopened.load().revisions.count == count * depth + 1)
                // Preparing a GUI fixture is isolated, with no notifications or cloud identifiers.
                let ui = root.appendingPathComponent("loading-ui-\(name)-\(UUID())")
                try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: directory, to: ui.appendingPathComponent("Stores"))
                try JSONEncoder().encode(f.a).write(to: ui.appendingPathComponent("identity.json"))
                let appStart = Date(); let model = AppModel(directory: ui, cloudIdentifier: nil, notificationsEnabled: false)
                let appSeconds = Date().timeIntervalSince(appStart)
                #expect(model.ready && model.error == nil && model.records.count == count + 1)
                results.append(["case": name, "records": count, "revisions": count * depth, "legacyReadSeconds": oldRead, "bulkReadSeconds": read,
                    "legacyProjectionSeconds": oldProjection, "projectionSeconds": projection, "ledgerSeconds": summarySeconds, "legacyLedgerSeconds": oldSummarySeconds,
                    "appendSeconds": saveSeconds, "appInitializationSeconds": appSeconds, "uiDirectory": ui.path,
                    "backupBytes": backup.count, "backupRoundTripSeconds": backupSeconds])
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("large-store-performance.json"))
            }
        }
    }
}
