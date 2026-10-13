import Foundation
import FamilyDomain

public extension FamilyCore {
    /// One authorized snapshot per refresh. Only actual renewal additions trigger a second read.
    func workspaceRecords(spaceIDs: Set<UUID>, renewingSpaceIDs: Set<UUID> = [], today: LocalDay = LocalDay(date: Date()), initialSnapshot: Snapshot? = nil) throws -> [Record] {
        // Only the synchronous open path supplies its just-decoded snapshot; it is consumed once.
        var firstSnapshot = initialSnapshot
        func read() throws -> [Record] {
            let snapshot: Snapshot
            if let initial = firstSnapshot { snapshot = initial; firstSnapshot = nil }
            else { snapshot = try repository.load() }
            guard spaceIDs.isSubset(of: Set(authorizedSpaces(in: snapshot).map(\.id))) else { throw NobisError.forbidden }
            let bySpace = Dictionary(grouping: snapshot.revisions.filter { spaceIDs.contains($0.spaceID) }, by: \.spaceID)
            return bySpace.values.flatMap { Record.project($0) }.sorted { $0.latest.createdAt > $1.latest.createdAt }
        }
        let records = try read()
        let bySpace = Dictionary(grouping: records, by: { $0.latest.spaceID })
        var changed = false
        for spaceID in spaceIDs.intersection(renewingSpaceIDs) {
            let source = (bySpace[spaceID] ?? []).filter { $0.body.sharedDestination == nil }
            let known = Set(source.filter { $0.body.kind == .task }.flatMap { [$0.body.occurrenceKey, $0.body.notes].compactMap { $0 } })
            var additions: [RecordChange] = []
            for subscription in source where !subscription.deleted && !subscription.conflicted && subscription.body.kind == .subscription && subscription.body.status == .active {
                guard let due = subscription.body.date, due <= today.addingDays(subscription.body.reminderDays.max() ?? 0) else { continue }
                let key = "renewal:\(subscription.id.uuidString):\(due)"
                guard !known.contains(key) else { continue }
                var task = RecordBody(kind: .task, title: "复核续费 · \(subscription.body.title)")
                task.date = due; task.memberID = subscription.body.memberID; task.subscriptionID = subscription.id; task.projectIDs = subscription.body.projectIDs
                task.occurrenceKey = key; task.notes = "确认继续订阅、已取消或需要处理。此任务不表示已经扣款。"
                additions.append(RecordChange(body: task))
            }
            if !additions.isEmpty { try saveBatch(additions, spaceID: spaceID); changed = true }
        }
        return changed ? try read() : records
    }
}
