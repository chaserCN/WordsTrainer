import Foundation

extension UUID {
    /// Canonical form stored in `flashgame.db` and used for media folder names.
    nonisolated var databaseString: String {
        uuidString.lowercased()
    }

    nonisolated init?(databaseString: String) {
        self.init(uuidString: databaseString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
