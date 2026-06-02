import Foundation
import CryptoKit
import OSLog

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
    case cancelled
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
        case .cancelled:
            "Синхронизация была прервана. Попробуйте ещё раз."
        case .failed(let message):
            message
        }
    }
}

@MainActor
@Observable
final class AppUserStore {
    static let shared = AppUserStore(defaults: .standard, syncClient: ServerSyncClient.shared)
    private static let logger = Logger(subsystem: "com.uniweb.wordtrainer.Words-Trainer", category: "AppUserStore")

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
        Self.logger.info("refreshFromServer started selectedUserID=\(self.selectedUserID?.uuidString ?? "nil", privacy: .public)")
        guard syncClient.isConfigured else {
            Self.logger.warning("refreshFromServer skipped: missing sync configuration")
            bootstrapState = .missingConfiguration
            return .missingConfiguration
        }

        let previousState = bootstrapState
        bootstrapState = .loading
        do {
            let bootstrap = try await syncClient.bootstrap(selectedUserID: selectedUserID)
            let serverUsers = bootstrap.users.map(\.appUser)
            Self.logger.info("bootstrap loaded users=\(serverUsers.count, privacy: .public) assignments=\(bootstrap.assignments.count, privacy: .public)")
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
                try await cacheMedia(from: bootstrap, database: database)
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
        } catch ServerSyncError.cancelled {
            Self.logger.info("refreshFromServer cancelled")
            bootstrapState = previousState
            return .cancelled
        } catch is CancellationError {
            Self.logger.info("refreshFromServer cancelled by task cancellation")
            bootstrapState = previousState
            return .cancelled
        } catch {
            let message = error.localizedDescription
            Self.logger.error("refreshFromServer failed: \(message, privacy: .public)")
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

    private func cacheMedia(from bootstrap: ServerBootstrap, database: ContentDatabase) async throws {
        let versionDeckIDs = Dictionary(
            uniqueKeysWithValues: bootstrap.assignments.compactMap { assignment -> (UUID, UUID)? in
                let versionID = assignment.deckVersionId ?? assignment.currentVersionId
                guard let versionID else { return nil }
                return (versionID, assignment.deckId)
            }
        )
        var mediaDeckIDs: [UUID: Set<UUID>] = [:]
        for assignment in bootstrap.assignments {
            if let mediaID = assignment.avatarMediaId {
                mediaDeckIDs[mediaID, default: []].insert(assignment.deckId)
            }
        }
        for card in bootstrap.content.cards {
            guard let deckID = versionDeckIDs[card.deckVersionId] else { continue }
            if let mediaID = card.imageMediaId {
                mediaDeckIDs[mediaID, default: []].insert(deckID)
            }
            if let mediaID = card.audioWordMediaId {
                mediaDeckIDs[mediaID, default: []].insert(deckID)
            }
        }
        for example in bootstrap.content.examples {
            guard let deckID = versionDeckIDs[example.deckVersionId] else { continue }
            if let mediaID = example.imageMediaId {
                mediaDeckIDs[mediaID, default: []].insert(deckID)
            }
            if let mediaID = example.audioExampleMediaId {
                mediaDeckIDs[mediaID, default: []].insert(deckID)
            }
        }

        let mediaObjects = Dictionary(
            uniqueKeysWithValues: bootstrap.media.map { ($0.id, $0) }
        )
        for (mediaID, deckIDs) in mediaDeckIDs {
            guard let media = mediaObjects[mediaID] else { continue }
            for deckID in deckIDs {
                try await cacheMediaObject(media, deckID: deckID, database: database)
            }
        }
    }

    private func cacheMediaObject(_ media: ServerMediaObject, deckID: UUID, database: ContentDatabase) async throws {
        let relativePath = "media/\(media.id.uuidString.lowercased()).\(fileExtension(for: media))"
        if let existingURL = try AppDataPaths.mediaFileURL(deckID: deckID, relativePath: relativePath) {
            if media.sha256 == nil {
                try database.updateMediaLocalPath(mediaID: media.id, localPath: relativePath)
                return
            }
            let existingData = try Data(contentsOf: existingURL)
            if sha256Hex(for: existingData) == media.sha256 {
                try database.updateMediaLocalPath(mediaID: media.id, localPath: relativePath)
                return
            }
        }

        let data = try await syncClient.downloadMedia(id: media.id)
        if let expectedHash = media.sha256, sha256Hex(for: data) != expectedHash {
            throw ServerSyncError.invalidResponse
        }
        let deckURL = try AppDataPaths.deckFolderURL(deckID: deckID)
        let mediaDirectory = deckURL.appendingPathComponent(AppDataPaths.deckMediaFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let fileURL = deckURL.appendingPathComponent(relativePath)
        try data.write(to: fileURL, options: .atomic)
        try database.updateMediaLocalPath(mediaID: media.id, localPath: relativePath)
    }

    private func fileExtension(for media: ServerMediaObject) -> String {
        switch media.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3":
            "mp3"
        case "audio/wav", "audio/wave", "audio/x-wav":
            "wav"
        case "audio/mp4", "audio/aac":
            "m4a"
        case "image/jpeg", "image/jpg":
            "jpg"
        case "image/png":
            "png"
        case "image/webp":
            "webp"
        default:
            "bin"
        }
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func saveUsers() {
        guard let data = try? JSONEncoder().encode(users) else { return }
        defaults.set(data, forKey: Keys.users)
    }
}
