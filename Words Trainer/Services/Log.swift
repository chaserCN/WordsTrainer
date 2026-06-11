import Foundation

/// Lightweight diagnostic logger that prints a wall-clock timestamp on every
/// line, so logs are readable in the Xcode console without enabling metadata.
///
/// Format: `HH:mm:ss.SSS [category] message`. Uses print (not OSLog) so the
/// timestamp is always visible inline.
///
/// Debug-only: in release builds `log` compiles to an empty body and, because
/// `message` is an @autoclosure, the message string is never even constructed,
/// so there is zero runtime cost in production.
enum Log {
    #if DEBUG
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    #endif

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("\(formatter.string(from: Date())) [\(category)] \(message())")
        #endif
    }
}
