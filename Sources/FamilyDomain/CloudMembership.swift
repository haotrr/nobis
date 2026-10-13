import Foundation
import CryptoKit

/// Derived only from CloudKit's user record identifier, never a supplied name or email.
public enum CloudIdentity {
    public static func memberID(container: String, userRecordName: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data("Nobis.member.v1|\(container)|\(userRecordName)".utf8)))
        var bytes = Array(hash.prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    public static func namespace(_ container: String) -> String { SHA256.hash(data: Data(container.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
}

public struct FamilyGrant: Codable, Equatable, Sendable {
    public let spaceID: UUID
    public let accountID: UUID
    public let ownerID: UUID
    public let members: [Member]
    public let writable: Bool
    public let verifiedAt: Date
    public init(spaceID: UUID, accountID: UUID, ownerID: UUID, members: [Member], writable: Bool, verifiedAt: Date = Date()) throws {
        let ids = Set(members.map(\.id))
        guard members.count <= 2, ids.count == members.count, ids.contains(accountID), ids.contains(ownerID) else { throw NobisError.forbidden }
        self.spaceID = spaceID; self.accountID = accountID; self.ownerID = ownerID; self.members = members; self.writable = writable; self.verifiedAt = verifiedAt
    }
}

/// Account changes and definitive revocations invalidate access even when an editor retains its old session.
public struct FamilyAccessPolicy: Sendable {
    public private(set) var accountID: UUID?
    public private(set) var grant: FamilyGrant?
    public private(set) var generation = UUID()
    public init() {}
    public mutating func identify(_ accountID: UUID) {
        if self.accountID != accountID { invalidate(); self.accountID = accountID }
    }
    public mutating func authorize(_ grant: FamilyGrant, generation: UUID) throws {
        guard generation == self.generation, accountID == grant.accountID else { throw NobisError.forbidden }
        _ = try FamilyGrant(spaceID: grant.spaceID, accountID: grant.accountID, ownerID: grant.ownerID, members: grant.members, writable: grant.writable, verifiedAt: grant.verifiedAt)
        self.grant = grant
    }
    public mutating func invalidate() { grant = nil; accountID = nil; generation = UUID() }
    public mutating func revoke() { grant = nil; generation = UUID() }
    public func requireWrite(spaceID: UUID, actorID: UUID) throws {
        guard let grant, grant.spaceID == spaceID, grant.accountID == actorID, grant.writable else { throw NobisError.forbidden }
    }
}
