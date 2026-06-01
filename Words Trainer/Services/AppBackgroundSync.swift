import Foundation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum AppBackgroundSync {
    static func run(_ operation: @escaping @MainActor () async -> Void) {
        #if canImport(UIKit)
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Upload study progress") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }

        Task {
            await operation()
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        #else
        Task {
            await operation()
        }
        #endif
    }
}
