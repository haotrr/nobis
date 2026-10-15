import Foundation
import Observation
import CloudKit
import CryptoKit
import FamilyDomain
import FamilyCore

/// Explicitly enabled private database transport; no CKShare or family references exist here.
/// One asset is committed with a change tag, so partial history is never published.
@MainActor @Observable public final class PrivateCloudController {
    public private(set) var repository: PrivateCloudRepository?
    public private(set) var enabled: Bool
    public private(set) var isBusy = false
    public private(set) var status = "个人内容仅保存在此设备"
    public private(set) var issue: String?
    public private(set) var lastSync: Date?
    public var onChange: (() -> Void)?
    public var onAccessLost: ((UUID?) -> Void)?
    public var spaceID: UUID? { repository?.spaceID }
    public var accountID: UUID? { repository?.ownerID }
    public var configured: Bool { identifier?.hasPrefix("iCloud.") == true }
    private let directory: URL
    private let identifier: String?
    private var generation = UUID()
    private var lastDigest: String?
    private var retryAfter = Date.distantPast
    @ObservationIgnored private var observer: NSObjectProtocol?
    public init(directory: URL, identifier: String?) {
        self.directory = directory.appendingPathComponent(CloudIdentity.namespace(identifier ?? "unconfigured"))
        self.identifier = identifier
        enabled = FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("enabled").path)
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.invalidate() }
        }
    }
    private func invalidate() {
        let old = spaceID
        generation = UUID(); repository?.block(); repository = nil; lastDigest = nil
        status = "个人 iCloud 身份待核对"; onAccessLost?(old); onChange?()
    }
    public func enable(name: String) async {
        guard configured else { issue = "当前应用未配置 iCloud"; return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("enabled"), options: LocalMetadataFile.writingOptions)
            enabled = true
            await sync(name: name)
        } catch { issue = error.localizedDescription }
    }
    public func sync(name: String) async {
        guard enabled, !isBusy, Date() >= retryAfter, let identifier else { return }
        isBusy = true; defer { isBusy = false }
        let ticket = generation
        do {
            let container = CKContainer(identifier: identifier)
            let availability = try await container.accountStatus()
            guard ticket == generation else { return }
            guard availability == .available else {
                if availability == .noAccount || availability == .restricted { invalidate() }
                throw NobisError.validation("请检查个人 iCloud 账户是否可用。")
            }
            let user = try await container.userRecordID()
            guard ticket == generation else { return }
            let owner = CloudIdentity.memberID(container: identifier, userRecordName: user.recordName)
            if let existing = accountID, existing != owner { invalidate(); return }
            let id = CloudIdentity.memberID(container: identifier, userRecordName: "private-space-v1|" + user.recordName)
            let space = Space(id: id, name: "个人云空间", kind: .personal, ownerID: owner, members: [Member(id: owner, name: name)])
            if repository == nil {
                let cache = try PrivateCloudRepository(directory: directory.appendingPathComponent(owner.uuidString), space: space)
                cache.onSave = { [weak self] in
                    guard let self else { return }
                    self.status = "个人内容已保存 · 等待上传"
                    Task { await self.sync(name: name) }
                }
                repository = cache
                onChange?()
            }
            guard let repository else { return }
            status = "正在同步个人私密内容"
            let db = container.privateCloudDatabase
            let zone = CKRecordZone.ID(zoneName: "NobisPersonalV1", ownerName: CKCurrentUserDefaultName)
            _ = try await db.save(CKRecordZone(zoneID: zone))
            guard ticket == generation else { return }
            let recordID = CKRecord.ID(recordName: "personal-snapshot-v1", zoneID: zone)
            for attempt in 0..<3 {
                var remoteRecord: CKRecord?
                do {
                    let metadata = try await db.records(for: [recordID], desiredKeys: ["digest"])
                    guard let entry = metadata[recordID] else { throw NobisError.corruptBackup }
                    let record = try entry.get()
                    guard record.share == nil, record.parent == nil, record.recordType == "NobisPersonalSnapshot" else { throw NobisError.forbidden }
                    if let lastDigest, record["digest"] as? String == lastDigest {
                        // The verified payload is already cached. Avoid downloading the asset on every foreground tick.
                        remoteRecord = record
                    } else { remoteRecord = try await db.record(for: recordID) }
                }
                catch let error as CKError where error.code == .unknownItem { remoteRecord = nil }
                guard ticket == generation else { return }
                if let remoteRecord, remoteRecord["digest"] as? String != lastDigest {
                    guard remoteRecord.share == nil, remoteRecord.parent == nil,
                          remoteRecord.recordType == "NobisPersonalSnapshot",
                          let asset = remoteRecord["payload"] as? CKAsset, let url = asset.fileURL else { throw NobisError.forbidden }
                    let bytes = try Data(contentsOf: url)
                    guard bytes.count <= 40_000_000 else { throw NobisError.validation("个人云数据超过当前同步容量。") }
                    guard remoteRecord["digest"] as? String == Self.digest(bytes) else { throw NobisError.corruptBackup }
                    let remote = try JSONDecoder().decode(Snapshot.self, from: bytes)
                    let before = try PrivateCloudSnapshot.data(repository.load())
                    try repository.receive(remote)
                    let changed = try before != PrivateCloudSnapshot.data(repository.load())
                    lastDigest = Self.digest(try PrivateCloudSnapshot.data(remote))
                    if changed { onChange?() }
                } else if remoteRecord == nil { lastDigest = nil }
                let bytes = try PrivateCloudSnapshot.data(repository.load())
                let digest = Self.digest(bytes)
                if digest == lastDigest { break }
                guard bytes.count <= 40_000_000 else { throw NobisError.validation("个人云数据超过当前同步容量，本地内容已保留。") }
                let temporary = directory.appendingPathComponent("upload-\(UUID().uuidString).json")
                try bytes.write(to: temporary, options: LocalMetadataFile.writingOptions)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let record = remoteRecord ?? CKRecord(recordType: "NobisPersonalSnapshot", recordID: recordID)
                record["payload"] = CKAsset(fileURL: temporary)
                record["digest"] = digest as CKRecordValue
                do {
                    let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                    guard let saved = result.saveResults[recordID] else { throw NobisError.validation("个人云保存没有返回确认。") }
                    _ = try saved.get()
                    guard ticket == generation else { return }
                    lastDigest = digest
                    // A save may have arrived while the upload was suspended. Never mark those writes as synced.
                    if try Self.digest(PrivateCloudSnapshot.data(repository.load())) == digest { break }
                } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
            }
            guard ticket == generation else { return }
            lastSync = Date(); issue = nil
            status = try Self.digest(PrivateCloudSnapshot.data(repository.load())) == lastDigest
                ? "个人 iCloud 已同步 · 仅自己" : "个人内容已保存 · 等待上传"
        } catch {
            guard ticket == generation else { return }
            if let cloudError = error as? CKError, [.notAuthenticated, .permissionFailure].contains(cloudError.code) { invalidate(); return }
            issue = error.localizedDescription; status = "个人同步待重试 · 本地内容已保留"
            retryAfter = Date().addingTimeInterval((error as? CKError)?.retryAfterSeconds ?? 5)
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
