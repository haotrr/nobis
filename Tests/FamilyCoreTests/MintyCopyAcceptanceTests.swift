import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

/// Opt-in acceptance on user-provided copies; private datasets never enter the repository.
@Suite("Minty 副本隔离验收") @MainActor struct MintyCopyAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOBIS_MINTY_REVIEW_ROOT"] != nil))
    func importCopiesAndReconcile() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOBIS_MINTY_REVIEW_ROOT"]))
        let directory = root.appendingPathComponent("nobis-review-\(UUID().uuidString)")
        let model = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        model.setup(name: "副本核对", familyName: "家庭账本副本", partnerName: "另一位")
        let core = try #require(model.core)
        let recoveryDirectory = root.appendingPathComponent("nobis-recovery-\(UUID().uuidString)")
        let recoveryModel = AppModel(directory: recoveryDirectory, cloudIdentifier: nil, notificationsEnabled: false)
        recoveryModel.setup(name: "迁入测试成员", familyName: "迁入目标副本", partnerName: "目标另一位")
        let recoveryCore = try #require(recoveryModel.core)
        let uiDirectory = root.appendingPathComponent("recovery-ui-\(UUID().uuidString)")
        let uiModel = AppModel(directory: uiDirectory, cloudIdentifier: nil, notificationsEnabled: false)
        uiModel.setup(name: "迁入核对", familyName: "迁入验收家庭", partnerName: "目标另一位")
        try Data(uiDirectory.path.utf8).write(to: root.appendingPathComponent("recovery-ui-directory.txt"))
        var results: [[String: Any]] = []
        for (file, space) in [("family", try #require(model.workspace.commonID)), ("personal", try #require(model.workspace.personalID))] {
            let data = try Data(contentsOf: root.appendingPathComponent(file + ".json"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tables = try #require(json["tables"] as? [String: [[String: Any]]])
            func active(_ table: String) -> [[String: Any]] { (tables[table] ?? []).filter { $0["deleted_at"] == nil || $0["deleted_at"] is NSNull || $0["deleted_at"] as? String == "" } }
            func money(_ row: [String: Any], _ field: String) throws -> Int64 {
                try Money.parse(String(describing: try #require(row[field])), currency: .CNY).minor
            }
            let start = Date()
            let preview = try MintyMigration.preview(data)
            #expect(preview.issues.isEmpty, "副本解析应无错误：\(preview.issues)")
            guard preview.issues.isEmpty else { continue }
            if file == "personal" {
                // Upgrade a previously supported subset; stable IDs must add only the 22 recovered rows.
                let subset = try MintyMigration.preview(Data(contentsOf: root.appendingPathComponent("personal-supported.json")))
                try core.commitImport(subset, spaceID: space)
            }
            let changes = try core.importChanges(preview, spaceID: space)
            if file == "personal" { #expect(changes.count == 22) }
            try core.saveBatch(changes, spaceID: space)
            #expect(try core.commitImport(preview, spaceID: space) == 0)
            let records = try core.records(spaceID: space)
            for (table, kind) in [("expenses", RecordKind.transaction), ("income", .monthlyIncome), ("asset_snapshots", .assetSnapshot), ("projects", .project), ("subscriptions", .subscription)] {
                #expect(records.filter { $0.body.kind == kind }.count == active(table).count)
            }
            #expect(records.reduce(0) { $0 + ($1.body.budget?.items.count ?? 0) } == active("project_plan_items").count)
            let sums = try ImportInspection.totals(records.map(\.body), currency: .CNY)
            #expect(sums.expense == (try Money.sum(try active("expenses").map { try money($0, "amount") })))
            #expect(sums.monthlyNet == (try Money.sum(try active("income").map { try money($0, "post_tax") })))
            for row in active("income") {
                let sourceID = String(describing: try #require(row["id"]))
                let record = try #require(records.first { $0.body.kind == .monthlyIncome && $0.body.importSource?.originalID == sourceID })
                let income = try #require(record.body.incomeMonth)
                #expect(income.year == row["year"] as? Int && income.month == row["month"] as? Int)
                #expect(income.gross.minor == (try money(row, "pre_tax")))
                #expect(income.net.minor == (try money(row, "post_tax")))
                if let raw = row["tax_amount"] as? String, !raw.isEmpty {
                    var scaled = try #require(Decimal(string: raw)) * 100, rounded = Decimal()
                    NSDecimalRound(&rounded, &scaled, 0, .plain)
                    #expect(income.tax?.minor == NSDecimalNumber(decimal: rounded).int64Value)
                } else { #expect(income.tax == nil) }
            }
            for year in Set(active("income").compactMap { $0["year"] as? Int }) {
                let annual = try #require(core.financialReport(spaceID: space, year: year).totals.first { $0.currency == .CNY })
                let expected = try Money.sum(try active("income").filter { $0["year"] as? Int == year }.map { try money($0, "post_tax") })
                #expect(annual.monthlyNet + annual.nonMonthlyNet == expected)
                var months: Int64 = 0
                for month in 1...12 {
                    let report = try core.financialReport(spaceID: space, year: year, month: month)
                    #expect(report.totals.allSatisfy { $0.nonMonthlyNet == 0 })
                    months += report.totals.first { $0.currency == .CNY }?.monthlyNet ?? 0
                }
                #expect(months + annual.nonMonthlyNet == expected)
                let chart = try FinancialChartData.months(core: core, spaceID: space, year: year, currency: .CNY, today: LocalDay(year, 12, 31))
                #expect(try Money.sum(chart.compactMap(\.income)) == annual.monthlyNet)
                let rawMonths = Set(active("income").filter { $0["year"] as? Int == year && ($0["month"] as? Int ?? 0) > 0 }.compactMap { $0["month"] as? Int })
                #expect(Set(chart.filter { $0.income != nil }.map(\.month)) == rawMonths)

            }
            let assetFields: [AssetComponent: String] = [.deposit: "deposit", .investments: "investments", .stocks: "stocks", .realEstate: "real_estate", .lending: "lending", .providentFund: "provident_fund", .mortgage: "mortgage", .creditCard: "credit_card", .otherLiabilities: "other_liabilities"]
            for row in active("asset_snapshots") {
                let sourceID = String(describing: try #require(row["id"]))
                let record = try #require(records.first { $0.body.kind == .assetSnapshot && $0.body.importSource?.originalID == sourceID })
                for (component, field) in assetFields {
                    #expect(record.body.assetPosition?.amounts[component] == (try money(row, field)))
                }
            }
            for project in records.filter({ $0.body.kind == .project }) {
                let actual = try core.projectSpending(project.id, spaceID: space)
                #expect(actual.unresolvedCount == 0)
            }
            #expect(records.filter { $0.body.kind == .subscription }.allSatisfy { $0.body.status == .paused })
            // Explicit test-only owner confirmation on the isolated imported copy.
            let incomes = records.filter { $0.body.kind == .monthlyIncome }
            if !incomes.isEmpty {
                let member = try core.space(space).ownerID
                let changes = try core.ownershipChanges(incomes, owner: FinancialOwner(kind: .member, memberID: member), spaceID: space)
                try core.saveBatch(changes, spaceID: space)
                #expect(try core.commitImport(preview, spaceID: space) == 0)
                let currentByID = Dictionary(uniqueKeysWithValues: try core.records(spaceID: space).map { ($0.id, $0) })
                let history = try core.repository.load().revisions
                for old in incomes {
                    let current = try #require(currentByID[old.id])
                    #expect(current.body.incomeMonth == old.body.incomeMonth)
                    #expect(current.body.importSource == old.body.importSource)
                    #expect(current.body.financialOwner?.memberID == member)
                    #expect(history.filter { $0.recordID == old.id && $0.spaceID == space }.count == 2)
                }
            }
            // A synthetic same-day partition derived from an actual copy verifies comparison;
            // it is held only in memory and does not assert the user's real holding scope.
            if let baseline = records.first(where: { $0.body.kind == .assetSnapshot }) {
                let memory = MemoryRepository(try core.repository.load())
                let reviewCore = FamilyCore(repository: memory, session: core.session)
                var partition = baseline.body
                partition.importSource = nil
                partition.financialOwner = FinancialOwner(kind: .member, memberID: try core.space(space).ownerID)
                let created = try reviewCore.save(partition, spaceID: space)
                let review = try reviewCore.reconcileAssets(baselineID: baseline.id, breakdownIDs: [created.recordID], spaceID: space)
                #expect(review.matches && review.differences.count == AssetComponent.allCases.count)
                #expect(try core.record(baseline.id, spaceID: space).body.financialOwner == nil)
            }
            let targetID = try #require(file == "family" ? recoveryModel.workspace.commonID : recoveryModel.workspace.personalID)
            let sourceSpace = try core.space(space), targetSpace = try recoveryCore.space(targetID)
            var memberMap = [sourceSpace.ownerID: targetSpace.ownerID]
            if let oldPartner = sourceSpace.members.first(where: { $0.id != sourceSpace.ownerID }),
               let newPartner = targetSpace.members.first(where: { $0.id != targetSpace.ownerID }) { memberMap[oldPartner.id] = newPartner.id }
            let sourceBefore = try core.repository.load(), sourceBackup = try core.export(spaceID: space)
            try sourceBackup.write(to: root.appendingPathComponent("recovery-\(file)-source.json"))
            let merge = try recoveryCore.previewRecovery(sourceBackup, sourceSpaceID: space, targetSpaceID: targetID, members: memberMap)
            #expect(merge.conflicts == 0, "恢复合并不应有阻断：\(merge.items.filter { $0.disposition == .conflict }.map(\.detail))")
            #expect(try recoveryCore.commitRecovery(merge) == records.count)
            let migrated = try recoveryCore.records(spaceID: targetID)
            #expect(migrated.count == records.count)
            #expect(try ImportInspection.totals(migrated.map(\.body), currency: .CNY).expense == sums.expense)
            #expect(try ImportInspection.totals(migrated.map(\.body), currency: .CNY).monthlyNet == sums.monthlyNet)
            let repeatPlan = try recoveryCore.previewRecovery(sourceBackup, sourceSpaceID: space, targetSpaceID: targetID, members: memberMap)
            #expect(repeatPlan.additions == 0 && repeatPlan.conflicts == 0)
            #expect(try recoveryCore.commitImport(preview, spaceID: targetID) == 0)
            #expect(try core.repository.load() == sourceBefore)
            _ = try Backup.decode(recoveryCore.export(spaceID: targetID))
            results.append(["source": file, "records": records.count, "expenseMinor": sums.expense, "netIncomeMinor": sums.monthlyNet, "elapsedSeconds": Date().timeIntervalSince(start)])
        }
        // Reminder preferences belong only to the isolated device directory, never to imported business data.
        // Minty has no active dated tasks in this fixture. Add one explicitly marked sample only to the test store.
        var reminderSample = RecordBody(kind: .task, title: "隔离验收：静默时段样本")
        reminderSample.date = LocalDay(date: Date(), timeZone: TimeZone(identifier: "Asia/Shanghai")!).addingDays(2)
        reminderSample.timeZone = "Asia/Shanghai"
        try core.save(reminderSample, spaceID: try #require(model.workspace.commonID))
        let reminderBefore = try core.repository.load()
        var reminders = ReminderPreferences(); reminders.quietEnabled = true; reminders.quietStart = 8 * 60; reminders.quietEnd = 10 * 60
        try model.saveReminderPreferences(reminders)
        let reminderNow = Date(timeIntervalSince1970: 0), reminderZone = TimeZone(identifier: "Asia/Shanghai")!
        let reminderPlan = try model.reminderPreview(now: reminderNow, timeZone: reminderZone)
        #expect(!reminderPlan.isEmpty)
        #expect(reminderPlan.allSatisfy { reminders.adjusted($0.fireDate, deviceTimeZone: reminderZone) == $0.fireDate })
        reminders.enabled = false; try model.saveReminderPreferences(reminders)
        #expect(try model.reminderPreview(now: reminderNow).isEmpty)
        #expect(try core.repository.load() == reminderBefore)
        // Export/decode exercises the same integrity gate used by isolated backup restore.
        for space in model.workspace.ids(.all) { _ = try Backup.decode(core.export(spaceID: space)) }
        recoveryModel.refresh()
        let recovered = AppModel(directory: recoveryDirectory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(recovered.records.count == recoveryModel.records.count)
        model.refresh()
        let reopened = AppModel(directory: directory, cloudIdentifier: nil, notificationsEnabled: false)
        #expect(reopened.records.count == model.records.count)
        #expect(reopened.reminderPreferences == reminders)
        try JSONSerialization.data(withJSONObject: ["directory": directory.path, "results": results], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("acceptance.json"))
    }
}
