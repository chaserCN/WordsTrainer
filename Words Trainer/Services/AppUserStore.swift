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

enum AppUserBootstrapState: Equatable {
    case idle
    case loading
    case loaded
    case missingConfiguration
    case failed(String)

    var message: String? {
        switch self {
        case .idle, .loading, .loaded:
            nil
        case .missingConfiguration:
            "Нужно подключить устройство к серверу."
        case .failed(let message):
            message
        }
    }
}

@MainActor
@Observable
final class AppUserStore {
    static let shared = AppUserStore(defaults: .standard, syncClient: ServerSyncClient.shared)

    private enum Keys {
        static let users = "app.users"
        static let selectedUserID = "app.selectedUserID"
    }

    private let defaults: UserDefaults
    private let syncClient: ServerSyncClient

    var users: [AppUser] {
        didSet { saveUsers() }
    }

    var selectedUserID: UUID? {
        didSet {
            if let selectedUserID {
                defaults.set(selectedUserID.uuidString, forKey: Keys.selectedUserID)
            } else {
                defaults.removeObject(forKey: Keys.selectedUserID)
            }
        }
    }

    var bootstrapState: AppUserBootstrapState = .idle

    var selectedUser: AppUser? {
        guard let selectedUserID else { return nil }
        return users.first { $0.id == selectedUserID }
    }

    private init(defaults: UserDefaults, syncClient: ServerSyncClient) {
        self.defaults = defaults
        self.syncClient = syncClient
        if let data = defaults.data(forKey: Keys.users),
           let decoded = try? JSONDecoder().decode([AppUser].self, from: data) {
            users = decoded
        } else {
            users = []
        }

        if let rawID = defaults.string(forKey: Keys.selectedUserID),
           let id = UUID(uuidString: rawID),
           users.contains(where: { $0.id == id }) {
            selectedUserID = id
        } else {
            selectedUserID = users.first?.id
        }
    }

    func refreshFromServer() async {
        guard syncClient.isConfigured else {
            bootstrapState = users.isEmpty ? .missingConfiguration : .loaded
            return
        }

        bootstrapState = .loading
        do {
            let bootstrap = try await syncClient.bootstrap(selectedUserID: selectedUserID)
            let serverUsers = bootstrap.users.map(\.appUser)
            users = serverUsers
            let preferredID = bootstrap.user?.id ?? selectedUserID
            if let preferredID, serverUsers.contains(where: { $0.id == preferredID }) {
                selectedUserID = preferredID
            } else {
                selectedUserID = serverUsers.first?.id
            }
            bootstrapState = serverUsers.isEmpty ? .missingConfiguration : .loaded
        } catch {
            bootstrapState = .failed(error.localizedDescription)
        }
    }

    func select(_ user: AppUser) {
        selectedUserID = user.id
    }

    private func saveUsers() {
        guard let data = try? JSONEncoder().encode(users) else { return }
        defaults.set(data, forKey: Keys.users)
    }
}
