import Foundation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum AppBackgroundSync {
    /// Holds the in-flight work Task so the background-task expiration handler
    /// can cancel it. Main-actor isolated; the expiration handler is invoked on
    /// the main thread, matching `run`'s isolation.
    @MainActor
    private final class TaskBox {
        var task: Task<Void, Never>?
    }

    static func run(_ operation: @escaping @MainActor () async -> Void) {
        #if canImport(UIKit)
        var taskID: UIBackgroundTaskIdentifier = .invalid
        // Box the work Task so the expiration handler can cancel it. Without
        // this, iOS reclaims the background time (e.g. an incoming call pulls
        // the app to the background) while `operation` keeps running, and the
        // system kills the process mid-write — leaving sync state half-applied.
        // Cancelling lets the sync stop cooperatively (it observes
        // Task.isCancelled / CancellationError) and unwind cleanly.
        let workBox = TaskBox()

        taskID = UIApplication.shared.beginBackgroundTask(withName: "Upload study progress") {
            workBox.task?.cancel()
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }

        workBox.task = Task {
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
