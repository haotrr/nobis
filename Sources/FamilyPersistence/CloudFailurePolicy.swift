import CloudKit

public enum CloudFailureDisposition: Equatable, Sendable { case accessLost, accountLost, retry, other }
public enum CloudFailurePolicy {
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
