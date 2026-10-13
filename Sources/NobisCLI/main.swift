import Foundation
import FamilyDomain
import FamilyCore

@main struct NobisCLI {
    @MainActor static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.contains("--help") || args.isEmpty {
                print("""
                nobis <spaces.list|projects.list|records.get|ledger.summary|finance.report|subscriptions.costs|subscriptions.upcoming> --export <backup.json> [--space <UUID>] [--id <UUID>] [--from YYYY-MM-DD] [--through YYYY-MM-DD] [--year YYYY] [--month M]
                Read-only v0.1 example. Reads only an explicitly exported, checksum-verified file. Never opens the App database.
                """); return
            }
            func option(_ name: String) -> String? { guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }; return args[index + 1] }
            guard let path = option("--export") else { throw NobisError.validation("需要 --export <备份文件>；不允许直接打开应用数据库。") }
            let snapshot = try Backup.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            let command = args[0]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            var responseScope = "export_catalog"
            func respond<T: Encodable>(_ data: T, sources: [UUID] = []) throws {
                let result = Response(data: data, sources: sources, warnings: ["仅反映所提供的导出文件；不是实时云端数据。"], observed_at: Date(), sync_observation: "offline_export", api_version: 2, visibility_scope: responseScope)
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            }
            if command == "spaces.list" { try respond(snapshot.spaces); return }
            guard let raw = option("--space"), let id = UUID(uuidString: raw), let space = snapshot.spaces.first(where: { $0.id == id }) else { throw NobisError.forbidden }
            responseScope = space.kind == .personal ? "personal" : "shared"
            let core = FamilyCore(repository: MemoryRepository(snapshot), session: AccessSession(memberID: space.ownerID, allowedSpaceIDs: [id]))
            func day(_ key: String) throws -> LocalDay? {
                guard let value = option(key) else { return nil }
                let parts = value.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3 else { throw NobisError.validation("日期格式为 YYYY-MM-DD。") }; return try LocalDay(parts[0], parts[1], parts[2])
            }
            switch command {
            case "projects.list": try respond(core.records(spaceID: id).filter { $0.body.kind == .project && $0.body.sharedDestination == nil }.flatMap(\.heads))
            case "records.get":
                guard let raw = option("--id"), let recordID = UUID(uuidString: raw) else { throw NobisError.validation("需要 --id。") }
                let record = try core.record(recordID, spaceID: id); try respond(record.heads, sources: [record.id])
            case "ledger.summary":
                let values = try core.ledger(spaceID: id, from: day("--from"), through: day("--through")); try respond(values, sources: values.flatMap(\.sourceIDs))
            case "finance.report", "subscriptions.costs":
                guard let value = option("--year"), let year = Int(value) else { throw NobisError.validation("需要 --year。") }
                let month: Int?
                if let raw = option("--month") { guard let parsed = Int(raw) else { throw NobisError.validation("月份无效。") }; month = parsed } else { month = nil }
                if command == "finance.report" { let report = try core.financialReport(spaceID: id, year: year, month: month); try respond(report, sources: report.totals.flatMap(\.sourceIDs)) }
                else { try respond(core.subscriptionCosts(spaceID: id, year: year, month: month)) }
            case "subscriptions.upcoming":
                let from = try day("--from") ?? LocalDay(date: Date()), through = try day("--through") ?? from.addingDays(30)
                guard through >= from else { throw NobisError.validation("结束日期早于开始日期。") }
                let values = try core.records(spaceID: id).filter { $0.body.sharedDestination == nil && $0.body.kind == .subscription && $0.body.status == .active && !$0.conflicted && $0.body.date.map { $0 >= from && $0 <= through } == true }
                try respond(values.flatMap(\.heads), sources: values.map(\.id))
            default: throw NobisError.validation("不支持的命令。首版仅提供只读接口。")
            }
        } catch {
            let value = error as? NobisError
            let output = ["error": value?.code ?? "SERVICE_UNAVAILABLE", "message": error.localizedDescription]
            if let data = try? JSONEncoder().encode(output) { print(String(decoding: data, as: UTF8.self)) }
            FileHandle.standardError.write(Data("nobis: 请求未完成\n".utf8))
            exit(value?.code == "FORBIDDEN" ? 3 : 2)
        }
    }
}
private struct Response<T: Encodable>: Encodable {
    let data: T; let sources: [UUID]; let warnings: [String]; let observed_at: Date; let sync_observation: String; let api_version: Int; let visibility_scope: String
}
