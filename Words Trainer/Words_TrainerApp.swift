import SwiftData
import SwiftUI

@main
struct Words_TrainerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            DeckRecord.self,
            CardRecord.self,
            CardProgressRecord.self,
            DeckDailyUsageRecord.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            DeckListView()
        }
        .modelContainer(sharedModelContainer)
    }
}
