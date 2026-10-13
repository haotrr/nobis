import Foundation
import CryptoKit
import CoreFoundation
import FamilyDomain

public enum CSV {
    public static func decode(_ data: Data) throws -> String {
        if let value = String(data: data, encoding: .utf8) { return value.replacingOccurrences(of: "\u{FEFF}", with: "") }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let value = String(data: data, encoding: String.Encoding(rawValue: gb)) else { throw NobisError.validation("文件须为 UTF-8 或 GBK CSV。") }
        return value
    }
    public static func parse(_ text: String) throws -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," || c == "\n" {
                row.append(field); field = ""; closed = false
                if c == "\n" { if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }
            } else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed, c != "\"" else { throw NobisError.validation("CSV 引号格式无效。") }
                field.append(c)
            }
            i += 1
        }
        guard !quoted else { throw NobisError.validation("CSV 引号未闭合。") }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
    public static func encode(_ rows: [[String]]) -> Data {
        let string = rows.map { $0.map { cell in "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n")
        return Data(("\u{FEFF}" + string + "\r\n").utf8)
    }
}
public struct ImportEntry: Identifiable, Sendable {
    public var id: UUID
    public var body: RecordBody
    public var row: Int
}
public struct ImportPreview: Sendable {
    public var entries: [ImportEntry] = []
    public var issues: [String] = []
    public var warnings: [String] = []
    public var skipped = 0
    public var retained: [String] = []
    public var categories: [String] { Array(Set(entries.filter { $0.body.kind == .transaction }.map { $0.body.category })).sorted() }
    public init() {}
}
public enum LedgerImport {
    public static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public static func day(_ string: String) throws -> LocalDay {
        let pieces = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { throw NobisError.validation("日期须为 YYYY-MM-DD。") }
        return try LocalDay(pieces[0], pieces[1], pieces[2])
    }
    public static func csv(_ data: Data) throws -> ImportPreview {
        let rows = try CSV.parse(CSV.decode(data))
        guard let index = rows.firstIndex(where: { row in row.map { $0.trimmingCharacters(in: .whitespaces) }.contains("date") || row.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "交易时间" }) }) else { throw NobisError.validation("未找到支出 CSV 表头。") }
        let header = rows[index].map { $0.trimmingCharacters(in: .whitespaces) }
        guard Set(header.filter { !$0.isEmpty }).count == header.filter({ !$0.isEmpty }).count else { throw NobisError.validation("CSV 表头有重复列。") }
        let platform = header.contains("交易时间")
        if header.contains("accounting_mode") { throw NobisError.validation("Nobis 明细 CSV 用于核对，不是完整恢复格式；请使用 JSON 备份恢复，避免丢失付款人与分摊关系。") }
        let required = platform ? ["交易时间", "收/支", header.contains("金额(元)") ? "金额(元)" : "金额"] : ["date", "item", "amount", "category"]
        guard required.allSatisfy(header.contains) else { throw NobisError.validation("缺少必要列：\(required.filter { !header.contains($0) }.joined(separator: "、"))") }
        var result = ImportPreview(), occurrences: [String: Int] = [:]
        for (offset, row) in rows.dropFirst(index + 1).enumerated() {
            let number = index + offset + 2
            func value(_ names: String...) -> String { for name in names { if let col = header.firstIndex(of: name), col < row.count { return row[col].trimmingCharacters(in: .whitespaces) } }; return "" }
            if platform && value("收/支") != "支出" { result.skipped += 1; continue }
            do {
                guard row.count == header.count else { throw NobisError.validation("列数与表头不一致。") }
                if !platform && !value("transaction_kind").isEmpty && value("transaction_kind") != "expense" { throw NobisError.validation("本批导入仅接收支出；收入、退款和结算须另行核对。") }
                if !platform && !value("status").isEmpty && value("status") != "confirmed" { result.skipped += 1; continue }
                let paymentStatus = value("交易状态", "当前状态")
                if platform && !paymentStatus.isEmpty && !["交易成功", "支付成功", "已支付", "已完成"].contains(paymentStatus) {
                    throw NobisError.validation("交易状态为「\(paymentStatus)」，请核对退款或关闭交易后单独处理。")
                }
                let currencyText = value("currency")
                guard let currency = currencyText.isEmpty ? Currency.CNY : Currency(rawValue: currencyText) else { throw NobisError.validation("未知币种。") }
                let amount = value("amount", "金额(元)", "金额").replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "").trimmingCharacters(in: .whitespaces)
                var b = RecordBody(kind: .transaction, title: value("item", "交易对方"), status: .confirmed)
                b.money = try Money.parse(amount, currency: currency); b.date = try day(value("date", "交易时间"))
                b.category = value("category", "交易分类", "交易类型"); if b.category.isEmpty { b.category = "其他" }
                b.notes = value("remark", "商品说明", "商品")
                b.finance = FinanceDetails(); b.finance?.originalRecorder = value("recorded_by")
                let attribution = value("attribution_kind")
                if !attribution.isEmpty { guard let kind = ConsumptionKind(rawValue: attribution) else { throw NobisError.validation("未知消费归属。") }; b.finance?.consumption = kind; b.finance?.consumer = value("attribution_member") }
                try b.validateFinance()
                guard !b.title.isEmpty, (b.money?.minor ?? 0) > 0 else { throw NobisError.validation("名称和正数金额必填。") }
                let external = value("source_key", "uuid", "record_id", "交易订单号", "交易单号")
                let content = [b.date!.description, b.title, amount, currency.rawValue, b.category, b.notes].joined(separator: "\u{1F}")
                let base = external.isEmpty ? "csv:" + stableID(content).uuidString : "csv-id:" + (platform ? (header.contains("交易分类") ? "alipay:" : "wechat:") : "generic:") + external
                occurrences[base, default: 0] += 1
                if !external.isEmpty && occurrences[base]! > 1 { throw NobisError.validation("文件内交易 ID 重复。") }
                let key = base + (external.isEmpty ? ":\(occurrences[base]!)" : "")
                b.importSource = ImportSource(key: key, originalID: external)
                result.entries.append(ImportEntry(id: stableID(key), body: b, row: number))
            } catch { result.issues.append("第 \(number) 行：\(error.localizedDescription)") }
        }
        result.warnings.append("导入支出只记收支，不推断付款人或生成成员欠款。无交易 ID 的 CSV 按内容及同内容出现次数去重，内容变化后需人工核对。")
        return result
    }
    public static func expenseCSV(_ records: [Record]) throws -> Data {
        guard !records.contains(where: \.conflicted) else { throw NobisError.conflict }
        let header = ["date","item","amount","currency","category","remark","transaction_kind","status","record_id","source_key","recorded_by","attribution_kind","attribution_member","project_ids","accounting_mode"]
        return CSV.encode([header] + records.filter { !$0.deleted && $0.body.kind == .transaction }.map { r in
            let b = r.body
            return [b.date?.description ?? "", b.title, b.money.map { (Decimal($0.minor) / Decimal($0.currency.factor)).description } ?? "", b.money?.currency.rawValue ?? "", b.category, b.notes, b.transactionKind.rawValue, b.status.rawValue, r.id.uuidString, b.importSource?.key ?? "", b.finance?.originalRecorder ?? "", b.finance?.consumption.rawValue ?? "unassigned", b.finance?.consumer ?? "", b.projectIDs.map(\.uuidString).joined(separator: ";"), b.accountingMode.rawValue]
        })
    }
}
public extension FamilyCore {
    private func sourceFingerprint(_ body: RecordBody) throws -> String {
        var value = body; value.importSource?.fingerprint = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Enum-keyed dictionaries encode as alternating arrays; sortedKeys cannot sort those.
        guard var json = try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] else { throw NobisError.validation("来源记录编码无效。") }
        if let asset = value.assetPosition, var position = json["assetPosition"] as? [String: Any] {
            position["amounts"] = Dictionary(uniqueKeysWithValues: asset.amounts.map { ($0.key.rawValue, $0.value) })
            json["assetPosition"] = position
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .fragmentsAllowed])
        return "v2:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func importChanges(_ preview: ImportPreview, spaceID: UUID, categoryMap: [String: String] = [:]) throws -> [RecordChange] {
        guard preview.issues.isEmpty else { throw NobisError.validation("请修正全部错误后重新导入。") }
        guard Set(preview.entries.map(\.id)).count == preview.entries.count else { throw NobisError.validation("迁移记录 ID 重复。") }
        let existing = try records(spaceID: spaceID, includeDeleted: true)
        let sources = Dictionary(grouping: existing, by: { $0.body.importSource?.key })
        var seen = Set<String>(), changes: [RecordChange] = []
        for entry in preview.entries {
            var body = entry.body
            if body.kind == .transaction, let mapped = categoryMap[body.category] { guard !mapped.trimmingCharacters(in: .whitespaces).isEmpty else { throw NobisError.validation("分类不能为空。") }; body.category = mapped }
            guard let source = body.importSource, seen.insert(source.key).inserted else { throw NobisError.validation("迁移来源 ID 重复。") }
            // A changed source must not silently replace an already reviewed record.
            let matches = sources[source.key] ?? []
            guard matches.count <= 1 else { throw NobisError.validation("同一来源存在多条记录：\(body.title)。请先核对重复来源。") }
            if let old = matches.first {
                guard !old.conflicted else { throw NobisError.conflict }
                if let fingerprint = old.body.importSource?.fingerprint, fingerprint != (try sourceFingerprint(entry.body)) {
                    // Legacy fingerprints were order-dependent for asset dictionaries. Compare the
                    // immutable initial import, never the edited current body, before accepting it.
                    let initial = try repository.load().revisions.filter { $0.recordID == old.id && $0.spaceID == spaceID && $0.parents.isEmpty && $0.body.importSource?.key == source.key }
                    let matchesLegacy: Bool
                    if !fingerprint.hasPrefix("v2:"), initial.count == 1, entry.body.kind == .assetSnapshot {
                        matchesLegacy = try sourceFingerprint(initial[0].body) == sourceFingerprint(entry.body)
                    } else {
                        var legacy = entry.body; legacy.importSource?.fingerprint = nil
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        let hash = SHA256.hash(data: try encoder.encode(legacy)).map { String(format: "%02x", $0) }.joined()
                        matchesLegacy = !fingerprint.hasPrefix("v2:") && fingerprint == hash
                    }
                    guard matchesLegacy else { throw NobisError.validation("来源记录已变化：\(body.title)。请核对已有记录，不能静默覆盖或跳过。") }
                }
                continue
            }
            body.importSource?.fingerprint = try sourceFingerprint(entry.body)
            if body.kind == .category {
                body.title = categoryMap[body.title] ?? body.title
                if existing.contains(where: { $0.body.kind == .category && $0.body.title == body.title && !$0.deleted && $0.body.status == .active }) || changes.contains(where: { $0.body.kind == .category && $0.body.title == body.title }) { continue }
            }
            changes.append(RecordChange(id: LedgerImport.stableID(spaceID.uuidString + ":" + entry.id.uuidString), body: body))
        }
        // Remap all package-local UUIDs to the destination namespace, including already imported parents.
        let mapping = Dictionary(uniqueKeysWithValues: preview.entries.map { entry in
            // Restored records may use a recovery namespace; links must follow the actual
            // destination record identified by source, not a newly guessed UUID.
            let existingID = entry.body.importSource.flatMap { sources[$0.key]?.first?.id }
            return (entry.id, existingID ?? LedgerImport.stableID(spaceID.uuidString + ":" + entry.id.uuidString))
        })
        return changes.map { change in
            var b = change.body
            b.projectIDs = b.projectIDs.map { mapping[$0] ?? $0 }
            b.parentProjectID = b.parentProjectID.map { mapping[$0] ?? $0 }
            b.subscriptionID = b.subscriptionID.map { mapping[$0] ?? $0 }
            return RecordChange(id: change.id, body: b)
        }
    }
    @discardableResult func commitImport(_ preview: ImportPreview, spaceID: UUID, categoryMap: [String: String] = [:]) throws -> Int {
        let changes = try importChanges(preview, spaceID: spaceID, categoryMap: categoryMap)
        try saveBatch(changes, spaceID: spaceID)
        return changes.count
    }
}
