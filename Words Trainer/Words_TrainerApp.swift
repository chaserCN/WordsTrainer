import FirebaseCore
import SwiftUI
import UIKit

@main
struct Words_TrainerApp: App {
    @State private var settings = AppSettings.shared
    @State private var userStore = AppUserStore.shared

    init() {
        FirebaseApp.configure()
        UIRefreshControl.appearance().tintColor = UIColor(red: 0.18, green: 0.20, blue: 0.27, alpha: 1)
        FrameHitchMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(settings)
                .environment(userStore)
                .preferredColorScheme(.light)
        }
    }
}
