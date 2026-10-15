import Foundation

/// Observations, not delivery receipts. A later local write cannot be acknowledged by an older export.
public struct CloudSyncProgress: Codable, Equatable, Sendable {
    public private(set) var pendingWrites: [String: Date] = [:]
    public private(set) var lastUpload: Date?
    public private(set) var lastDownload: Date?
    public init() {}
    public mutating func saved(store: String, at date: Date) { pendingWrites[store] = date }
    public mutating func exported(store: String, started: Date, ended: Date, succeeded: Bool) {
        guard succeeded else { return }
        lastUpload = max(lastUpload ?? .distantPast, ended)
        if let write = pendingWrites[store], write <= started { pendingWrites.removeValue(forKey: store) }
    }
    public mutating func imported(at date: Date) { lastDownload = max(lastDownload ?? .distantPast, date) }
    public var hasPendingWrites: Bool { !pendingWrites.isEmpty }
}
