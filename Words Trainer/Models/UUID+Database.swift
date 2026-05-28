import Foundation

extension UUID {
    /// Canonical form stored in `flashgame.db` and used for media folder names.
    var databaseString: String {
        uuidString.lowercased()
    }

    init?(databaseString: String) {
        self.init(uuidString: databaseString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
