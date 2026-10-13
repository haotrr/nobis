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
        func amount(_ row: [String: Any], _ field: String) throws -> Money { try Money.parse(text(row,field), currency: .CNY) }
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
                let income = IncomeMonth(year: year, month: month, type: text(r,"income_type"), gross: try amount(r,"pre_tax"), net: try amount(r,"post_tax"), tax: text(r,"tax_amount").isEmpty ? nil : try amount(r,"tax_amount"))
                var b = RecordBody(kind: .monthlyIncome, title: "\(year)-\(String(format: "%02d", month)) · \(income.type)")
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
        let deferred = ["config"].map { "\($0)：\(tables[$0]?.count ?? 0) 条" }.joined(separator: "，")
        result.warnings += ["本批迁入项目、预算计划项、支出、月度收入、资产快照、消费归属、分类及暂停状态的订阅。\(deferred) 保留于原始迁移包，尚未进入 Nobis 业务视图。", "原始金额按 CNY 精确转换，超过两位小数的金额报错，不自动舍入。订阅须核对付款人及计费日期后再启用。"]
        result.skipped = tables.values.flatMap { $0 }.filter { !text($0,"deleted_at").isEmpty }.count
        return result
    }
}
