import Foundation

/// Owns a block observer and removes it on release, so a main-actor owner needs no deinit of its own.
public final class MDNotificationToken {
    private let token: any NSObjectProtocol

    public init(_ token: any NSObjectProtocol) { self.token = token }

    deinit { NotificationCenter.default.removeObserver(token) }
}
