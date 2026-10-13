import CloudKit
import NobisUI
import AppKit
final class CloudInvitationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "NobisCloudContainer") as? String, !identifier.isEmpty { NSApplication.shared.registerForRemoteNotifications() }
    }
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { NobisCloudInvitation.deliver(metadata) }
}
