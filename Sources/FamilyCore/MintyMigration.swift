import Foundation
import FamilyDomain

/// Reads the portable package produced from a user-selected Minty database copy.
public enum MintyMigration {
    public static func preview(_ data: Data) throws -> ImportPreview {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["format"] as? String == "minty-nobis", root["version"] as? Int == 1,
              let source = root["source"] as? String, !source.isEmpty,
              let tables = root["tables"] as? [String: [[String: Any]]] else { throw NobisError.validation("不是有效的 Minty 迁移包。") }
        var result = ImportPreview()
        func text(_ row: [String: Any], _ key: String) -> String { guard let v = row[key], !(v is NSNull) else { return "" }; return v as? String ?? String(describing: v) }
        func key(_ table: String, _ row: [String: Any]) -> String { let uuid = text(row,"uuid"); return "minty:\(source):\(table):\(uuid.isEmpty ? text(row,"id") : uuid)" }
        func id(_ table: String, _ row: [String: Any]) -> UUID { LedgerImport.stableID(key(table,row)) }
        func amount(_ row: [String: Any], _ field: String) throws -> Money {
            do { return try Money.parse(text(row,field), currency: .CNY) }
            catch {
                let label = ["pre_tax": "税前金额", "post_tax": "税后金额", "tax_amount": "税额", "amount": "支出金额", "budget_amount": "预算", "planned_amount": "计划金额"][field] ?? field
                throw NobisError.validation("\(label)：\(error.localizedDescription) 不会自动舍入，请核对来源数据。")
            }
        }
        func active(_ table: String) -> [[String: Any]] { (tables[table] ?? []).filter { text($0,"deleted_at").isEmpty } }
        let projects = active("projects"), expenses = active("expenses"), plans = active("project_plan_items")
        var projectMap: [String: UUID] = [:], subscriptionMap: [String: UUID] = [:]
        for r in projects { guard !text(r,"id").isEmpty, projectMap[text(r,"id")] == nil else { throw NobisError.validation("项目 ID 缺失或重复。") }; projectMap[text(r,"id")] = id("projects",r) }
        func append(_ table: String, _ r: [String: Any], _ b: RecordBody) {
            var body = b; body.importSource = ImportSource(key: key(table,r), originalID: text(r,"id"), originalCreatedAt: text(r,"created_at"))
            result.entries.append(ImportEntry(id: id(table,r), body: body, row: result.entries.count + 1))
        }
        for r in projects.sorted(by: { text($0,"parent_id").isEmpty && !text($1,"parent_id").isEmpty }) {
            do {
                var b = RecordBody(kind: .project, title: text(r,"name"), status: text(r,"status") == "active" ? .active : .completed)
                if !text(r,"start_date").isEmpty { b.date = try LedgerImport.day(text(r,"start_date")) }
                if !text(r,"end_date").isEmpty { b.endDate = try LedgerImport.day(text(r,"end_date")) }
                if !text(r,"parent_id").isEmpty { guard let parent = projectMap[text(r,"parent_id")] else { throw NobisError.validation("父项目不存在。") }; b.parentProjectID = parent }
                b.budget = ProjectBudget(limit: try amount(r,"budget_amount"), items: try plans.filter { text($0,"project_id") == text(r,"id") }.map { p in
                    BudgetItem(id: id("project_plan_items",p), name: text(p,"name"), amount: try amount(p,"planned_amount"), notes: text(p,"notes"))
                })
                try b.validateFinance(); append("projects",r,b)
            } catch { result.issues.append("项目 \(text(r,"id"))：\(error.localizedDescription)") }
        }
        for r in active("subscriptions") {
            do {
                guard let expense = expenses.first(where: { text($0,"id") == text(r,"expense_id") }) else { throw NobisError.validation("订阅缺少原支出。") }
                var b = RecordBody(kind: .subscription, title: text(expense,"item"), status: .paused)
                b.money = try amount(expense,"amount"); b.finance = FinanceDetails(); b.notes = text(r,"notes")
                let cycles = ["月付": 1, "季付": 3, "半年付": 6, "年付": 12]
                guard let months = cycles[text(r,"billing_cycle")] else { throw NobisError.validation("未知订阅周期。") }
                b.cycleUnit = .month; b.cycleCount = months
                b.date = try LedgerImport.day(text(r,"renewal_date").isEmpty ? text(expense,"date") : text(r,"renewal_date")); b.billingAnchor = b.date
                subscriptionMap[text(r,"expense_id")] = id("subscriptions",r); append("subscriptions",r,b)
            } catch { result.issues.append("订阅 \(text(r,"id"))：\(error.localizedDescription)") }
        }
        for r in expenses {
            do {
                var b = RecordBody(kind: .transaction, title: text(r,"item"), status: .confirmed)
                b.money = try amount(r,"amount"); b.date = try LedgerImport.day(text(r,"date")); b.category = text(r,"category"); b.notes = text(r,"remark")
                guard !b.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (b.money?.minor ?? -1) >= 0 else { throw NobisError.validation("支出须有名称和非负金额。") }
                if b.money?.minor == 0 { result.warnings.append("支出 \(text(r,"id"))：保留零元历史记录，不产生付款或成员欠款。") }
                b.finance = FinanceDetails(); b.finance?.originalRecorder = text(r,"recorded_by")
                if !text(r,"attribution_kind").isEmpty {
                    guard let kind = ConsumptionKind(rawValue: text(r,"attribution_kind")) else { throw NobisError.validation("消费归属无效。") }
                    b.finance?.consumption = kind; b.finance?.consumer = text(r,"attribution_member")
                }
                if !text(r,"project_id").isEmpty { guard let project = projectMap[text(r,"project_id")] else { throw NobisError.validation("关联项目不存在。") }; b.projectIDs = [project] }
                if !text(r,"plan_item_id").isEmpty {
                    guard let p = plans.first(where: { text($0,"id") == text(r,"plan_item_id") && text($0,"project_id") == text(r,"project_id") }) else { throw NobisError.validation("计划项与项目不匹配。") }
                    b.finance?.planItemID = id("project_plan_items",p)
                }
                b.subscriptionID = subscriptionMap[text(r,"id")]
                try b.validateFinance(); append("expenses",r,b)
            } catch { result.issues.append("支出 \(text(r,"id"))：\(error.localizedDescription)") }
        }
        for r in active("income") {
            do {
                guard !text(r,"id").isEmpty || !text(r,"uuid").isEmpty,
                      let year = Int(text(r,"year")), let month = Int(text(r,"month")) else { throw NobisError.validation("收入须有来源 ID 和有效年月。") }
                let gross = try amount(r,"pre_tax"), net = try amount(r,"post_tax")
                let rawTax = text(r,"tax_amount")
                var tax: Money?, normalization: String?
                if !rawTax.isEmpty {
                    do { tax = try amount(r,"tax_amount") }
                    catch {
                        // Minty's repository calculates max(preTax - postTax, 0) using Double.
                        // Recover only sub-cent binary noise matching that exact relationship.
                        let expected = max(gross.minor - net.minor, 0)
                        let exact = Decimal(expected) / 100
                        guard rawTax.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                              let value = Decimal(string: rawTax, locale: Locale(identifier: "en_US_POSIX")),
                              abs(value - exact) <= Decimal(string: "0.00000001")! else { throw error }
                        tax = Money(minor: expected, currency: .CNY)
                        normalization = "Minty 税额原值 \(rawTax)；按原税前减税后关系恢复为 \(tax!.formatted)，仅消除浮点尾差。"
                    }
                }
                let income = IncomeMonth(year: year, month: month, type: text(r,"income_type"), gross: gross, net: net, tax: tax)
                var b = RecordBody(kind: .monthlyIncome, title: "\(income.periodTitle) · \(income.type)")
                if let normalization { b.notes = normalization; result.warnings.append("收入 \(text(r,"id"))：" + normalization) }
                if income.isNonMonthly { result.warnings.append("收入 \(text(r,"id"))：非月度收入仅计入 \(year) 年年报，不分配月份。") }
                b.incomeMonth = income; try b.validateStatement(); append("income",r,b)
            } catch { result.issues.append("收入 \(text(r,"id"))：\(error.localizedDescription)") }
        }
        let fields: [AssetComponent: String] = [.deposit:"deposit",.investments:"investments",.stocks:"stocks",.realEstate:"real_estate",.lending:"lending",.providentFund:"provident_fund",.mortgage:"mortgage",.creditCard:"credit_card",.otherLiabilities:"other_liabilities"]
        for r in active("asset_snapshots") {
            do {
                guard !text(r,"id").isEmpty || !text(r,"uuid").isEmpty else { throw NobisError.validation("资产快照缺少来源 ID。") }
                var b = RecordBody(kind: .assetSnapshot, title: "资产快照 · \(text(r,"snapshot_date"))")
                b.date = try LedgerImport.day(text(r,"snapshot_date"))
                var values: [AssetComponent: Int64] = [:]
                for (component, field) in fields { values[component] = try amount(r,field).minor }
                b.assetPosition = AssetPosition(currency: .CNY, amounts: values); try b.validateStatement(); append("asset_snapshots",r,b)
            } catch { result.issues.append("资产快照 \(text(r,"id"))：\(error.localizedDescription)") }
        }
        var categoryNames = Set(expenses.map { text($0,"category") })
        for config in active("config") where text(config,"key") == "categories.expense" {
            guard let names = try JSONSerialization.jsonObject(with: Data(text(config,"value").utf8)) as? [String] else { throw NobisError.validation("支出分类配置格式无效。") }
            categoryNames.formUnion(names)
        }
        for category in categoryNames.filter({ !$0.isEmpty }).sorted() {
            var b = RecordBody(kind: .category, title: category)
            let key = "minty:\(source):category:\(category)"; b.importSource = ImportSource(key: key, originalID: category)
            result.entries.append(ImportEntry(id: LedgerImport.stableID(key), body: b, row: 0))
        }
        for plan in plans where projectMap[text(plan,"project_id")] == nil { result.issues.append("计划项 \(text(plan,"id")) 缺少所属项目，不能静默丢弃。") }
        let otherConfig = active("config").filter { text($0, "key") != "categories.expense" }.count
        if otherConfig > 0 { result.retained.append("其他配置 \(otherConfig) 条，仅保留在源文件") }
        let colored = projects.filter { !text($0, "color").isEmpty }.count
        if colored > 0 { result.retained.append("\(colored) 个项目的原颜色尚未映射") }
        if !plans.isEmpty { result.retained.append("计划项的原排序字段仅保留在源文件") }
        result.skipped = tables.values.flatMap { $0 }.filter { !text($0,"deleted_at").isEmpty }.count
        if result.skipped > 0 { result.retained.append("已删除记录 \(result.skipped) 条，不进入有效记录") }
        result.warnings += ["同来源记录可去重；不同账本中复制过的账单需另外核对。", "支出不推断付款人，不生成成员欠款。收入与资产的持有归属待确认。", "订阅初始暂停，核对周期、续费日期与付款信息后再启用。"]
        return result
    }
}
