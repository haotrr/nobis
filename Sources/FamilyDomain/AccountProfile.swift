import Foundation

/// One account profile, independently versioned from Studio membership and ledger history.
public struct AccountProfileVersion: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let member: Member
    public let updatedAt: Date
    public init(id: UUID = UUID(), member: Member, updatedAt: Date = Date()) {
        self.id = id; self.member = member; self.updatedAt = updatedAt
    }
}
public struct AccountState: Codable, Equatable, Sendable {
    public let ownerID: UUID
    public var profiles: [AccountProfileVersion]
    public var drafts: [AccountDraft]?
    public init(ownerID: UUID, profiles: [AccountProfileVersion] = []) { self.ownerID = ownerID; self.profiles = profiles }
    public var profile: Member? {
        profiles.max { a, b in a.updatedAt == b.updatedAt ? a.id.uuidString < b.id.uuidString : a.updatedAt < b.updatedAt }?.member
    }
}
/// Membership is scoped to a Studio; account identity and profile are not.
public struct StudioMembership: Equatable, Sendable {
    public let studioID: UUID
    public let accountID: UUID
    public let isOwner: Bool
    public let writable: Bool
    public init(studioID: UUID, accountID: UUID, isOwner: Bool, writable: Bool) {
        self.studioID = studioID; self.accountID = accountID; self.isOwner = isOwner; self.writable = writable
    }
}

/// Draft copies are isolated by device and key, so concurrent edits never overwrite each other.
public struct AccountDraft: Codable, Equatable, Sendable, Identifiable {
    public let deviceID: UUID
    public let key: UUID
    public let kind: String
    public let payload: Data?
    public let updatedAt: Date
    public var id: String { "\(deviceID):\(kind):\(key)" }
    public init(deviceID: UUID, key: UUID, kind: String, payload: Data?, updatedAt: Date = Date()) {
        self.deviceID = deviceID; self.key = key; self.kind = kind; self.payload = payload; self.updatedAt = updatedAt
    }
}
