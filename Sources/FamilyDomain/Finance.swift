import Foundation

public enum AccountingMode: String, Codable, CaseIterable, Sendable {
    case ledgerOnly, sharedSettlement
    public var title: String { self == .ledgerOnly ? "只记收支" : "参与成员结算" }
}
public enum ConsumptionKind: String, Codable, CaseIterable, Sendable { case unassigned, family, personal
    public var title: String { switch self { case .unassigned: "未标注"; case .family: "家庭"; case .personal: "个人" } }
}
public struct FinanceDetails: Codable, Equatable, Sendable {
    public var mode: AccountingMode
    public var consumption: ConsumptionKind = .unassigned
    /// Historical names are descriptive labels, never authentication identities.
    public var consumer: String = ""
    public var originalRecorder: String = ""
    public var planItemID: UUID?
    public init(mode: AccountingMode = .ledgerOnly) { self.mode = mode }
}
public struct BudgetItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var amount: Money
    public var notes: String
    public init(id: UUID = UUID(), name: String, amount: Money, notes: String = "") { self.id = id; self.name = name; self.amount = amount; self.notes = notes }
}
public struct ProjectBudget: Codable, Equatable, Sendable {
    public var limit: Money
    public var items: [BudgetItem]
    public init(limit: Money, items: [BudgetItem] = []) { self.limit = limit; self.items = items }
}
public struct ImportSource: Codable, Equatable, Sendable {
    public var key: String
    public var originalID: String
    public var fingerprint: String?
    public var originalCreatedAt: String?
    public init(key: String, originalID: String, originalCreatedAt: String? = nil) { self.key = key; self.originalID = originalID; self.originalCreatedAt = originalCreatedAt }
}
public extension RecordBody {
    // Missing metadata means pre-migration Nobis behavior; never reinterpret existing balances.
    var accountingMode: AccountingMode { finance?.mode ?? .sharedSettlement }
    func validateFinance() throws {
        if let finance {
            guard finance.consumer.count <= 100, finance.originalRecorder.count <= 100,
                  (finance.consumption == .personal) == !finance.consumer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NobisError.validation("个人消费须填写归属称呼；其他归属不能附带人名。") }
        }
        if kind == .transaction, accountingMode == .ledgerOnly {
            guard splits.isEmpty, transactionKind != .settlement else { throw NobisError.validation("只记收支不能包含分摊或成员结算。") }
        }
        if let budget {
            guard kind == .project, budget.limit.minor >= 0, Set(budget.items.map(\.id)).count == budget.items.count,
                  budget.items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount.minor > 0 && $0.amount.currency == budget.limit.currency }) else { throw NobisError.validation("预算及计划项须使用同一币种，计划金额必须大于零。") }
            _ = try Money.sum(budget.items.map { $0.amount.minor })
        }
        if parentProjectID != nil && kind != .project { throw NobisError.validation("仅项目可以设置父项目。") }
    }
}

public extension RecordBody {
    func hasSameFinancialFacts(as other: RecordBody) -> Bool {
        kind == other.kind && status == other.status && money == other.money && date == other.date && memberID == other.memberID && splits == other.splits && transactionKind == other.transactionKind && refundOfID == other.refundOfID && accountingMode == other.accountingMode && account == other.account && importSource == other.importSource
    }
}
