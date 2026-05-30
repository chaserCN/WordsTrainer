import SwiftUI

@main
struct Words_TrainerApp: App {
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environment(settings)
        }
    }
}
