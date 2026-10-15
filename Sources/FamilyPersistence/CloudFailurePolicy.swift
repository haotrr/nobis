import Foundation
import CloudKit

public enum CloudFailureDisposition: Equatable, Sendable { case accessLost, accountLost, retry, other }
public enum CloudFailurePolicy {
    /// Only transient failures retry automatically; never turn revocation into a retry loop.
    public static func retryDelay(for error: Error) -> TimeInterval? {
        guard classify(error) == .retry else { return nil }
        let requested = (error as? CKError)?.userInfo[CKErrorRetryAfterKey] as? Double
        guard let requested, requested.isFinite else { return 30 }
        return max(5, requested)
    }
    public static func classify(_ error: Error) -> CloudFailureDisposition {
        guard let error = error as? CKError else { return .other }
        switch error.code {
        case .unknownItem, .zoneNotFound, .permissionFailure: return .accessLost
        case .notAuthenticated: return .accountLost
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable: return .retry
        default: return .other
        }
    }
}
