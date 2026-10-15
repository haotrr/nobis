import Foundation
import CloudKit
import FamilyDomain

/// Resolve CloudKit's current-user alias only for the server-identified current participant.
enum CloudParticipantIdentity {
    static func memberID(container: String, recordName: String, isCurrentParticipant: Bool, verifiedAccountID: UUID) throws -> UUID {
        if recordName == CKCurrentUserDefaultName {
            guard isCurrentParticipant else { throw NobisError.forbidden }
            return verifiedAccountID
        }
        return CloudIdentity.memberID(container: container, userRecordName: recordName)
    }
}
