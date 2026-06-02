import Foundation

struct AppUser: Identifiable, Codable, Hashable, Sendable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let id: UUID
    var displayName: String
    var avatarMediaID: UUID?
    var avatarImageURL: URL?
    var accentHue: Double

    var initials: String {
        let parts = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        let value = String(parts).uppercased()
        return value.isEmpty ? "U" : value
    }
}
