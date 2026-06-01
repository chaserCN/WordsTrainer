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
    case emptyServer
    case failed(String)

    var message: String? {
        switch self {
        case .idle, .loading, .loaded:
            nil
        case .missingConfiguration:
            "Нужно подключить устройство к серверу."
        case .emptyServer:
            "На сервере пока нет пользователей."
        case .failed(let message):
            message
        }
    }
}

enum AppUserRefreshResult: Equatable {
    case loaded(userCount: Int, assignmentCount: Int, activeAssignmentCount: Int)
    case missingConfiguration
    case emptyServer
    case failed(String)

    var message: String? {
        switch self {
        case .loaded(let userCount, let assignmentCount, let activeAssignmentCount):
            if userCount == 0 {
                nil
            } else if assignmentCount == 0 {
                "Пользователи загружены, но выбранному пользователю пока не назначены колоды."
            } else if activeAssignmentCount == 0 {
                "Колоды загружены, но все назначения сейчас неактивны."
            } else {
                "Синхронизация выполнена."
            }
        case .missingConfiguration:
            "Нужно настроить SERVER_BASE_URL и HOUSEHOLD_SYNC_TOKEN."
        case .emptyServer:
            "Сервер доступен, но пользователей пока нет."
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

    @discardableResult
    func refreshFromServer() async -> AppUserRefreshResult {
        guard syncClient.isConfigured else {
            bootstrapState = .missingConfiguration
            return .missingConfiguration
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
            if let selectedUserID {
                let database = try ContentDatabase(userID: selectedUserID)
                try database.importServerBootstrap(bootstrap, selectedUserID: selectedUserID)
                try await uploadPendingEvents(database: database, selectedUserID: selectedUserID)
            }
            bootstrapState = serverUsers.isEmpty ? .emptyServer : .loaded
            let activeAssignmentCount = bootstrap.assignments.filter { $0.assignmentStatus == "active" }.count
            return serverUsers.isEmpty
                ? .emptyServer
                : .loaded(
                    userCount: serverUsers.count,
                    assignmentCount: bootstrap.assignments.count,
                    activeAssignmentCount: activeAssignmentCount
                )
        } catch {
            let message = error.localizedDescription
            bootstrapState = .failed(message)
            return .failed(message)
        }
    }

    func select(_ user: AppUser) {
        selectedUserID = user.id
    }

    func syncPendingEventsToServer() async {
        guard syncClient.isConfigured,
              let selectedUserID else { return }
        do {
            let database = try ContentDatabase(userID: selectedUserID)
            try await uploadPendingEvents(database: database, selectedUserID: selectedUserID)
        } catch {
            // Keep the local outbox pending; the next foreground or manual sync will retry.
        }
    }

    private func uploadPendingEvents(database: ContentDatabase, selectedUserID: UUID) async throws {
        while true {
            let batch = try database.pendingServerSyncBatch()
            guard !batch.isEmpty else { return }
            _ = try await syncClient.uploadEvents(batch.payload, selectedUserID: selectedUserID)
            try database.markServerSyncBatchUploaded(batch)
        }
    }

    private func saveUsers() {
        guard let data = try? JSONEncoder().encode(users) else { return }
        defaults.set(data, forKey: Keys.users)
    }
}
