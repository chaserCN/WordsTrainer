import FirebaseCore
import SwiftUI

@main
struct Words_TrainerApp: App {
    @State private var settings = AppSettings.shared

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environment(settings)
        }
    }
}
