import CryptoKit
import Foundation
import OSLog

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
    var syncStatus: AppUserSyncStatus = .idle

    var selectedUser: AppUser? {
        guard let selectedUserID else { return nil }
        return users.first { $0.id == selectedUserID }
    }

    private var refreshTask: Task<AppUserRefreshResult, Never>?
    private var refreshTaskID: UUID?

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
        let targetUserID = selectedUserID
        if let refreshTask {
            if syncStatus.isSyncing, syncStatus.userID == targetUserID {
                Self.logger.info("refreshFromServer joined existing task selectedUserID=\(targetUserID?.uuidString ?? "nil", privacy: .public)")
                return await refreshTask.value
            }
            Self.logger.info("refreshFromServer cancelling stale task selectedUserID=\(self.syncStatus.userID?.uuidString ?? "nil", privacy: .public)")
            refreshTask.cancel()
        }

        let taskID = UUID()
        refreshTaskID = taskID
        let task = Task { @MainActor in
            await performRefreshFromServer(targetUserID: targetUserID, taskID: taskID)
        }
        refreshTask = task
        let result = await task.value
        if refreshTaskID == taskID {
            refreshTask = nil
            refreshTaskID = nil
        }
        return result
    }

    private func performRefreshFromServer(targetUserID: UUID?, taskID: UUID) async -> AppUserRefreshResult {
        Self.logger.info("refreshFromServer started selectedUserID=\(targetUserID?.uuidString ?? "nil", privacy: .public)")
        guard syncClient.isConfigured else {
            Self.logger.warning("refreshFromServer skipped: missing sync configuration")
            bootstrapState = .missingConfiguration
            return finishSync(.missingConfiguration, userID: targetUserID, startedAt: nil, taskID: taskID)
        }

        let previousState = bootstrapState
        let startedAt = Date()
        bootstrapState = .loading
        syncStatus = .syncing(userID: targetUserID, startedAt: startedAt)
        do {
            var cachedDeckVersionIDs: [UUID] = []
            if let targetUserID {
                do {
                    let database = try ContentDatabase(userID: targetUserID)
                    cachedDeckVersionIDs = try database.cachedDeckVersionIDs()
                    try await uploadPendingEvents(database: database, selectedUserID: targetUserID)
                } catch ServerSyncError.cancelled {
                    throw ServerSyncError.cancelled
                } catch let error as CancellationError {
                    throw error
                } catch {
                    Self.logger.warning(
                        "pre-bootstrap pending upload failed; bootstrap will continue: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            let bootstrap = try await syncClient.bootstrap(
                selectedUserID: targetUserID,
                cachedDeckVersionIDs: cachedDeckVersionIDs
            )
            guard isCurrentRefreshTask(taskID) else { return .cancelled }
            let serverUsers = bootstrap.users.map(\.appUser)
            Self.logger.info("bootstrap loaded users=\(serverUsers.count, privacy: .public) assignments=\(bootstrap.assignments.count, privacy: .public)")
            users = serverUsers
            let preferredID = bootstrap.user?.id ?? targetUserID
            let resolvedUserID: UUID?
            if let preferredID, serverUsers.contains(where: { $0.id == preferredID }) {
                resolvedUserID = preferredID
            } else {
                resolvedUserID = serverUsers.first?.id
            }
            if selectedUserID == targetUserID || selectedUserID == nil {
                selectedUserID = resolvedUserID
            }
            if let resolvedUserID {
                let database = try ContentDatabase(userID: resolvedUserID)
                try database.importServerBootstrap(bootstrap, selectedUserID: resolvedUserID)
                let mediaFailureCount = try await cacheMedia(from: bootstrap, database: database)
                guard isCurrentRefreshTask(taskID) else { return .cancelled }
                try await uploadPendingEvents(database: database, selectedUserID: resolvedUserID)
                guard isCurrentRefreshTask(taskID) else { return .cancelled }
                bootstrapState = serverUsers.isEmpty ? .emptyServer : .loaded
                let activeAssignmentCount = bootstrap.assignments.filter { $0.assignmentStatus == "active" }.count
                if mediaFailureCount > 0 {
                    return finishSync(.loadedWithMediaWarnings(
                        userCount: serverUsers.count,
                        assignmentCount: bootstrap.assignments.count,
                        activeAssignmentCount: activeAssignmentCount,
                        failedMediaCount: mediaFailureCount
                    ), userID: resolvedUserID, startedAt: startedAt, taskID: taskID)
                }
            }
            bootstrapState = serverUsers.isEmpty ? .emptyServer : .loaded
            let activeAssignmentCount = bootstrap.assignments.filter { $0.assignmentStatus == "active" }.count
            let result: AppUserRefreshResult = serverUsers.isEmpty
                ? .emptyServer
                : .loaded(
                    userCount: serverUsers.count,
                    assignmentCount: bootstrap.assignments.count,
                    activeAssignmentCount: activeAssignmentCount
                )
            return finishSync(result, userID: resolvedUserID, startedAt: startedAt, taskID: taskID)
        } catch ServerSyncError.cancelled {
            Self.logger.info("refreshFromServer cancelled")
            guard isCurrentRefreshTask(taskID) else { return .cancelled }
            bootstrapState = previousState
            return finishSync(.cancelled, userID: targetUserID, startedAt: startedAt, taskID: taskID)
        } catch is CancellationError {
            Self.logger.info("refreshFromServer cancelled by task cancellation")
            guard isCurrentRefreshTask(taskID) else { return .cancelled }
            bootstrapState = previousState
            return finishSync(.cancelled, userID: targetUserID, startedAt: startedAt, taskID: taskID)
        } catch {
            guard isCurrentRefreshTask(taskID) else { return .cancelled }
            let message = error.localizedDescription
            Self.logger.error("refreshFromServer failed: \(message, privacy: .public)")
            bootstrapState = .failed(message)
            return finishSync(.failed(message), userID: targetUserID, startedAt: startedAt, taskID: taskID)
        }
    }

    func select(_ user: AppUser) {
        selectedUserID = user.id
    }

    @discardableResult
    func selectAndRefresh(_ user: AppUser) async -> AppUserRefreshResult {
        selectedUserID = user.id
        return await refreshFromServer()
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

    private func isCurrentRefreshTask(_ taskID: UUID) -> Bool {
        refreshTaskID == taskID
    }

    private func finishSync(
        _ result: AppUserRefreshResult,
        userID: UUID?,
        startedAt: Date?,
        taskID: UUID
    ) -> AppUserRefreshResult {
        guard isCurrentRefreshTask(taskID) else { return result }
        syncStatus = .finished(result: result, userID: userID, startedAt: startedAt)
        return result
    }

    private func cacheMedia(from bootstrap: ServerBootstrap, database: ContentDatabase) async throws -> Int {
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
        var failureCount = 0
        for (mediaID, deckIDs) in mediaDeckIDs {
            guard let media = mediaObjects[mediaID] else { continue }
            for deckID in deckIDs {
                do {
                    try await cacheMediaObject(media, deckID: deckID, database: database)
                } catch ServerSyncError.cancelled {
                    throw ServerSyncError.cancelled
                } catch let error as CancellationError {
                    throw error
                } catch {
                    failureCount += 1
                    Self.logger.error(
                        "cacheMediaObject failed mediaID=\(media.id.uuidString, privacy: .public) deckID=\(deckID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return failureCount
    }

    private func cacheMediaObject(_ media: ServerMediaObject, deckID: UUID, database: ContentDatabase) async throws {
        let relativePath = "media/\(media.id.uuidString.lowercased()).\(fileExtension(for: media))"
        if let existingURL = try AppDataPaths.mediaFileURL(deckID: deckID, relativePath: relativePath) {
            if media.sha256 == nil {
                let fileSize = try? existingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if media.byteSize == nil || fileSize == media.byteSize {
                    try database.updateMediaLocalPath(mediaID: media.id, localPath: relativePath)
                    return
                }
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
