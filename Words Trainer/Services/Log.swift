import Foundation

/// Lightweight diagnostic logger that prints a wall-clock timestamp on every
/// line, so logs are readable in the Xcode console without enabling metadata.
///
/// Format: `HH:mm:ss.SSS [category] message`. Uses print (not OSLog) so the
/// timestamp is always visible inline. Intended for temporary diagnostics;
/// remove call sites when the investigation is done.
enum Log {
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        print("\(formatter.string(from: Date())) [\(category)] \(message())")
    }
}
