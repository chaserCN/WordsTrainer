import FirebaseCore
import SwiftUI

@main
struct Words_TrainerApp: App {
    @State private var settings = AppSettings.shared
    @State private var userStore = AppUserStore.shared

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(settings)
                .environment(userStore)
        }
    }
}
