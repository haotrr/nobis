import SwiftUI
import NobisUI

@main struct NobisApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(CloudInvitationDelegate.self) private var cloudDelegate
    #else
    @UIApplicationDelegateAdaptor(CloudInvitationDelegate.self) private var cloudDelegate
    #endif
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup { NobisRootView(model: model) }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
