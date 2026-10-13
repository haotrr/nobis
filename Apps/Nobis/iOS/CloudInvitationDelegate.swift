import CloudKit
import NobisUI
import UIKit
final class CloudInvitationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "NobisCloudContainer") as? String, !identifier.isEmpty { application.registerForRemoteNotifications() }
        return true
    }
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { NobisCloudInvitation.deliver(metadata) }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = CloudInvitationSceneDelegate.self
        if let metadata = options.cloudKitShareMetadata { NobisCloudInvitation.deliver(metadata) }
        return configuration
    }
}
final class CloudInvitationSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { NobisCloudInvitation.deliver(metadata) }
}
