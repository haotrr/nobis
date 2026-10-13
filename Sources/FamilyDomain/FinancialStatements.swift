import Foundation

public struct IncomeMonth: Codable, Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var type: String
    public var gross: Money
    public var net: Money
    public var tax: Money?
    public init(year: Int, month: Int, type: String, gross: Money, net: Money, tax: Money? = nil) {
        self.year = year; self.month = month; self.type = type; self.gross = gross; self.net = net; self.tax = tax
    }
    public func validate() throws {
        _ = try LocalDay(year, month, 1)
        guard !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, type.count <= 100,
              gross.currency == net.currency, gross.minor >= 0, net.minor >= 0,
              tax.map({ $0.currency == gross.currency && $0.minor >= 0 }) ?? true else { throw NobisError.validation("收入类型必填，税前、税后及税额须为同币种非负金额。") }
    }
}
public enum AssetComponent: String, Codable, CaseIterable, Sendable {
    case deposit, investments, stocks, realEstate, lending, providentFund, mortgage, creditCard, otherLiabilities
    public var liability: Bool { [.mortgage, .creditCard, .otherLiabilities].contains(self) }
    public var title: String { switch self {
    case .deposit: "存款"; case .investments: "投资理财"; case .stocks: "股票"; case .realEstate: "房产"; case .lending: "借出款"; case .providentFund: "公积金"; case .mortgage: "房贷"; case .creditCard: "信用卡负债"; case .otherLiabilities: "其他负债"
    } }
}
public struct AssetPosition: Codable, Equatable, Sendable {
    public var currency: Currency
    public var amounts: [AssetComponent: Int64]
    public init(currency: Currency, amounts: [AssetComponent: Int64]) { self.currency = currency; self.amounts = amounts }
    public func validate() throws {
        guard Set(amounts.keys) == Set(AssetComponent.allCases), amounts.values.allSatisfy({ $0 >= 0 }) else { throw NobisError.validation("资产快照须填写全部资产及负债项目，未持有填零。") }
        _ = try assets(); _ = try liabilities(); _ = try net()
    }
    public func assets() throws -> Int64 { try Money.sum(amounts.filter { !$0.key.liability }.map(\.value)) }
    public func liabilities() throws -> Int64 { try Money.sum(amounts.filter { $0.key.liability }.map(\.value)) }
    public func net() throws -> Int64 { try Money.sum([assets(), -liabilities()]) }
}
public extension RecordBody {
    func validateStatement() throws {
        if let owner = financialOwner {
            guard [.monthlyIncome, .assetSnapshot].contains(kind),
                  (owner.kind == .member) == (owner.memberID != nil),
                  kind != .monthlyIncome || owner.kind == .member else { throw NobisError.validation("财务归属无效。") }
        }
        if kind == .monthlyIncome {
            guard let incomeMonth, assetPosition == nil, money == nil, date == nil else { throw NobisError.validation("月度收入保留年月，不创建虚构的发生日或重复收入流水。") }
            try incomeMonth.validate()
        } else if incomeMonth != nil { throw NobisError.validation("月度收入字段不适用于此类型。") }
        if kind == .assetSnapshot {
            guard let assetPosition, date != nil, money == nil else { throw NobisError.validation("资产快照须包含日期及资产负债明细。") }
            try assetPosition.validate()
        } else if assetPosition != nil { throw NobisError.validation("资产字段不适用于此类型。") }
    }
}

public struct FinancialOwner: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case member, joint }
    public var kind: Kind
    public var memberID: UUID?
    public init(kind: Kind, memberID: UUID? = nil) { self.kind = kind; self.memberID = memberID }
    public var key: String { kind == .joint ? "joint" : memberID?.uuidString ?? "unknown" }
}
public struct SharedDestination: Codable, Equatable, Sendable {
    public var spaceID: UUID
    public var recordID: UUID
    public init(spaceID: UUID, recordID: UUID) { self.spaceID = spaceID; self.recordID = recordID }
}
