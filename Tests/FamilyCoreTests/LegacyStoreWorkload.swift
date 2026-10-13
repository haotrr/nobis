import Foundation
import CoreData
@testable import FamilyDomain
import FamilyCore
import FamilyPersistence

/// Frozen pre-optimization read/projection paths, used only as a benchmark oracle.
@MainActor enum LegacyStoreWorkload {
    static func load(_ repository: CoreDataRepository) throws -> Snapshot {
        let context = repository.container.viewContext, decoder = JSONDecoder()
        var result = Snapshot()
        for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SpaceRoot")) {
            result.spaces.append(try decoder.decode(Space.self, from: object.value(forKey: "payload") as! Data))
        }
        for entity in ["RecordRevision", "AuditEvent"] {
            for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) {
                let data = object.value(forKey: "payload") as! Data
                if entity == "RecordRevision" { result.revisions.append(try decoder.decode(Revision.self, from: data)) }
                else { result.audits.append(try decoder.decode(AuditEvent.self, from: data)) }
            }
        }
        return result
    }
    static func project(_ revisions: [Revision]) -> [Record] {
        Dictionary(grouping: revisions, by: \.recordID).values.compactMap { versions in
            let parents = Set(versions.flatMap(\.parents))
            let unique = Dictionary(grouping: versions, by: \.id).compactMap { $0.value.first }
            let heads = unique.filter { !parents.contains($0.id) }
            return heads.isEmpty ? nil : Record(heads: heads)
        }.sorted { $0.latest.createdAt > $1.latest.createdAt }
    }
    static func ledger(records: [Record], from: LocalDay? = nil, through: LocalDay? = nil) throws -> [LedgerSummary] {
        if let from, let through, through < from { throw NobisError.validation("统计结束日期早于开始日期。") }
        let entries = records.filter { record in
            record.body.sharedDestination == nil && record.body.kind == .transaction && record.heads.contains { revision in
                revision.body.date.map { (from == nil || $0 >= from!) && (through == nil || $0 <= through!) } ?? true
            }
        }
        var groups: [Currency: LedgerSummary] = [:]
        for record in entries {
            if record.conflicted {
                for currency in Set(record.heads.compactMap { $0.body.money?.currency }) {
                    var group = groups[currency] ?? LedgerSummary(currency: currency)
                    group.unresolvedCount += 1; groups[currency] = group
                }
                continue
            }
            guard let money = record.body.money else { continue }
            var group = groups[money.currency] ?? LedgerSummary(currency: money.currency)
            if record.conflicted || record.body.status == .draft { group.unresolvedCount += 1; groups[money.currency] = group; continue }
            guard record.body.status == .confirmed else { continue }
            group.sourceIDs.append(record.id)
            switch record.body.transactionKind {
            case .expense: group.expense = try Money.sum([group.expense, money.minor])
            case .refund: group.refund = try Money.sum([group.refund, money.minor])
            case .income: group.income = try Money.sum([group.income, money.minor])
            case .settlement: break
            }
            if let payer = record.body.memberID, record.body.accountingMode == .sharedSettlement, record.body.transactionKind != .income {
                let sign: Int64 = record.body.transactionKind == .refund ? -1 : 1
                group.balances[payer.uuidString] = try Money.sum([group.balances[payer.uuidString] ?? 0, sign * money.minor])
                for split in record.body.splits {
                    group.balances[split.memberID.uuidString] = try Money.sum([group.balances[split.memberID.uuidString] ?? 0, -sign * split.minor])
                }
            }
            group.netExpense = try Money.sum([group.expense, -group.refund])
            groups[money.currency] = group
        }
        return groups.values.sorted { $0.currency.rawValue < $1.currency.rawValue }
    }
}
