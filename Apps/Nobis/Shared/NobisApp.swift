import SwiftUI
import NobisUI

@main struct NobisApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(CloudInvitationDelegate.self) private var cloudDelegate
    #else
    @UIApplicationDelegateAdaptor(CloudInvitationDelegate.self) private var cloudDelegate
    #endif
    @State private var model = makeModel()
    private static func makeModel() -> AppModel {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let path = Bundle.main.object(forInfoDictionaryKey: "NobisReviewDirectory") as? String, path.hasPrefix("/") {
            return AppModel(directory: URL(fileURLWithPath: path), cloudIdentifier: nil, notificationsEnabled: false)
        }
        if let index = arguments.firstIndex(of: "--nobis-review-directory"), arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
            return AppModel(directory: URL(fileURLWithPath: arguments[index + 1]), cloudIdentifier: nil, notificationsEnabled: false)
        }
        #endif
        return AppModel()
    }
    var body: some Scene {
        WindowGroup { NobisRootView(model: model) }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
