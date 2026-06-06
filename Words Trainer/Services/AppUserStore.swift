import CryptoKit
import Foundation
import Observation
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
            L10n.text("Нужно подключить устройство к серверу.")
        case .emptyServer:
            L10n.text("На сервере пока нет пользователей.")
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
    private static let maxConcurrentMediaDownloads = 4

    private enum Keys {
        static let users = "app.users"
        static let selectedUserID = "app.selectedUserID"
    }

    private enum MediaCacheScope: Hashable, Sendable {
        case deck(UUID)
        case userAvatar
    }

    private struct MediaCacheCandidate: Sendable {
        let media: ServerMediaObject
        let scope: MediaCacheScope
        let relativePath: String
    }

    private struct MediaDownloadResult: Sendable {
        let candidate: MediaCacheCandidate
        let data: Data
    }

    private enum MediaDownloadFailure: Sendable {
        case cancelled
        case failed(String)
    }

    private enum MediaDownloadOutcome: Sendable {
        case success(MediaDownloadResult)
        case failure(MediaCacheCandidate, MediaDownloadFailure)
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
    private var refreshTaskUserID: UUID?

    init(defaults: UserDefaults, syncClient: ServerSyncClient) {
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
            if refreshTaskUserID == targetUserID {
                Self.logger.info("refreshFromServer joined existing task selectedUserID=\(targetUserID?.uuidString ?? "nil", privacy: .public)")
                return await refreshTask.value
            }
            Self.logger.info("refreshFromServer cancelling stale task selectedUserID=\(self.refreshTaskUserID?.uuidString ?? "nil", privacy: .public)")
            refreshTask.cancel()
        }

        let taskID = UUID()
        refreshTaskID = taskID
        refreshTaskUserID = targetUserID
        let task = Task { @MainActor in
            await performRefreshFromServer(targetUserID: targetUserID, taskID: taskID)
        }
        refreshTask = task
        let result = await task.value
        if refreshTaskID == taskID {
            refreshTask = nil
            refreshTaskID = nil
            refreshTaskUserID = nil
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
            var bootstrapSinceRevision = "0"
            var bootstrapDeviceID: UUID?
            var preBootstrapUploadSucceeded = true
            if let targetUserID {
                do {
                    let database = try ContentDatabase(userID: targetUserID)
                    let deviceID = try database.deviceID()
                    bootstrapDeviceID = deviceID
                    bootstrapSinceRevision = try database.serverRevision()
                    cachedDeckVersionIDs = try database.cachedDeckVersionIDs()
                    Self.logger.info(
                        "bootstrap state selectedUserID=\(targetUserID.uuidString, privacy: .public) sinceRevision=\(bootstrapSinceRevision, privacy: .public) cachedDeckVersions=\(cachedDeckVersionIDs.count, privacy: .public) deviceID=\(deviceID.databaseString, privacy: .public)"
                    )
                    updateSyncProgress(.uploadingChanges, taskID: taskID)
                    try await uploadPendingEvents(
                        database: database,
                        selectedUserID: targetUserID,
                        deviceID: deviceID
                    )
                } catch ServerSyncError.cancelled {
                    throw ServerSyncError.cancelled
                } catch let error as CancellationError {
                    throw error
                } catch {
                    Self.logger.warning(
                        "pre-bootstrap pending upload failed; bootstrap will continue: \(error.localizedDescription, privacy: .public)"
                    )
                    preBootstrapUploadSucceeded = false
                }
            }

            updateSyncProgress(.loadingData, taskID: taskID)
            let bootstrap = try await syncClient.bootstrap(
                selectedUserID: targetUserID,
                cachedDeckVersionIDs: cachedDeckVersionIDs,
                sinceRevision: bootstrapSinceRevision,
                deviceID: bootstrapDeviceID
            )
            Self.logger.info("bootstrap response serverRevision=\(bootstrap.serverRevision ?? "nil", privacy: .public)")
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
                let deviceID = try database.deviceID()
                let hasCompletedInitialSync = try database.hasCompletedInitialSync()
                updateSyncProgress(.savingData, taskID: taskID)
                try database.importServerBootstrap(
                    bootstrap,
                    selectedUserID: resolvedUserID,
                    progressSnapshotIsComplete: preBootstrapUploadSucceeded
                        && !hasCompletedInitialSync
                        && bootstrapSinceRevision == "0"
                )
                try database.markInitialSyncCompleted()
                let importedServerRevision = try database.serverRevision()
                Self.logger.info("bootstrap imported localServerRevision=\(importedServerRevision, privacy: .public)")
                let mediaFailureCount = try await cacheMedia(from: bootstrap, database: database, taskID: taskID)
                try applyCachedUserAvatarURLs(from: bootstrap)
                guard isCurrentRefreshTask(taskID) else { return .cancelled }
                do {
                    updateSyncProgress(.uploadingChanges, taskID: taskID)
                    try await uploadPendingEvents(database: database, selectedUserID: resolvedUserID, deviceID: deviceID)
                } catch ServerSyncError.cancelled {
                    throw ServerSyncError.cancelled
                } catch let error as CancellationError {
                    throw error
                } catch {
                    Self.logger.warning(
                        "post-bootstrap pending upload failed; refresh will keep loaded content: \(error.localizedDescription, privacy: .public)"
                    )
                }
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
            try await uploadPendingEvents(
                database: database,
                selectedUserID: selectedUserID,
                deviceID: try database.deviceID()
            )
        } catch {
            // Keep the local outbox pending; the next foreground or manual sync will retry.
        }
    }

    private func uploadPendingEvents(database: ContentDatabase, selectedUserID: UUID, deviceID: UUID) async throws {
        while true {
            let batch = try database.pendingServerSyncBatch()
            guard !batch.isEmpty else { return }
            let response = try await syncClient.uploadEvents(batch.payload, selectedUserID: selectedUserID, deviceID: deviceID)
            try database.markServerSyncBatchUploaded(batch, response: response)
            if let serverRevision = response.serverRevision {
                Self.logger.info("uploaded pending events serverRevision=\(serverRevision, privacy: .public)")
            }
        }
    }

    private func isCurrentRefreshTask(_ taskID: UUID) -> Bool {
        refreshTaskID == taskID
    }

    private func updateSyncProgress(_ progress: AppUserSyncProgress, taskID: UUID) {
        guard isCurrentRefreshTask(taskID) else { return }
        syncStatus = syncStatus.updatingProgress(progress)
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

    private func cacheMedia(from bootstrap: ServerBootstrap, database: ContentDatabase, taskID: UUID) async throws -> Int {
        updateSyncProgress(.preparingMedia, taskID: taskID)
        let versionDeckIDs = Dictionary(
            uniqueKeysWithValues: bootstrap.assignments.compactMap { assignment -> (UUID, UUID)? in
                let versionID = assignment.currentVersionId
                guard let versionID else { return nil }
                return (versionID, assignment.deckId)
            }
        )
        var mediaScopes: [UUID: Set<MediaCacheScope>] = [:]
        for user in bootstrap.users {
            if let mediaID = user.avatarMediaId {
                mediaScopes[mediaID, default: []].insert(.userAvatar)
            }
        }
        for assignment in bootstrap.assignments {
            if let mediaID = assignment.avatarMediaId {
                mediaScopes[mediaID, default: []].insert(.deck(assignment.deckId))
            }
        }
        for card in bootstrap.content.cards {
            guard let deckID = versionDeckIDs[card.deckVersionId] else { continue }
            if let mediaID = card.imageMediaId {
                mediaScopes[mediaID, default: []].insert(.deck(deckID))
            }
            if let mediaID = card.audioWordMediaId {
                mediaScopes[mediaID, default: []].insert(.deck(deckID))
            }
        }
        for example in bootstrap.content.examples {
            guard let deckID = versionDeckIDs[example.deckVersionId] else { continue }
            if let mediaID = example.imageMediaId {
                mediaScopes[mediaID, default: []].insert(.deck(deckID))
            }
            if let mediaID = example.audioExampleMediaId {
                mediaScopes[mediaID, default: []].insert(.deck(deckID))
            }
        }

        let mediaObjects = Dictionary(
            uniqueKeysWithValues: bootstrap.media.map { ($0.id, $0) }
        )
        var failureCount = 0
        var downloadCandidates: [MediaCacheCandidate] = []
        for (mediaID, scopes) in mediaScopes {
            guard let media = mediaObjects[mediaID] else { continue }
            for scope in scopes {
                do {
                    if let candidate = try prepareMediaCacheObject(media, scope: scope, database: database) {
                        downloadCandidates.append(candidate)
                    }
                } catch ServerSyncError.cancelled {
                    throw ServerSyncError.cancelled
                } catch let error as CancellationError {
                    throw error
                } catch {
                    failureCount += 1
                    Self.logger.error(
                        "cacheMediaObject failed mediaID=\(media.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        if downloadCandidates.isEmpty {
            updateSyncProgress(.finishing, taskID: taskID)
        } else {
            updateSyncProgress(.downloadingMedia(completed: 0, total: downloadCandidates.count), taskID: taskID)
        }
        let downloadOutcomes = await downloadMediaObjects(downloadCandidates) { [weak self] completed, total in
            self?.updateSyncProgress(.downloadingMedia(completed: completed, total: total), taskID: taskID)
        }
        updateSyncProgress(.finishing, taskID: taskID)
        for outcome in downloadOutcomes {
            switch outcome {
            case .success(let result):
                do {
                    try storeDownloadedMedia(result, database: database)
                } catch ServerSyncError.cancelled {
                    throw ServerSyncError.cancelled
                } catch let error as CancellationError {
                    throw error
                } catch {
                    failureCount += 1
                    Self.logger.error(
                        "storeDownloadedMedia failed mediaID=\(result.candidate.media.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            case .failure(_, .cancelled):
                throw ServerSyncError.cancelled
            case .failure(let candidate, .failed(let message)):
                failureCount += 1
                Self.logger.error(
                    "downloadMedia failed mediaID=\(candidate.media.id.uuidString, privacy: .public): \(message, privacy: .public)"
                )
            }
        }
        return failureCount
    }

    private func prepareMediaCacheObject(
        _ media: ServerMediaObject,
        scope: MediaCacheScope,
        database: ContentDatabase
    ) throws -> MediaCacheCandidate? {
        let relativePath = "media/\(media.id.uuidString.lowercased()).\(fileExtension(for: media))"
        if let existingURL = try existingMediaFileURL(scope: scope, relativePath: relativePath) {
            if media.sha256 == nil {
                let fileSize = try? existingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if media.byteSize == nil || fileSize == media.byteSize {
                    try updateDeckMediaLocalPathIfNeeded(mediaID: media.id, scope: scope, localPath: relativePath, database: database)
                    return nil
                }
            }
            let existingData = try Data(contentsOf: existingURL)
            if Self.sha256Hex(for: existingData) == media.sha256 {
                try updateDeckMediaLocalPathIfNeeded(mediaID: media.id, scope: scope, localPath: relativePath, database: database)
                return nil
            }
        }

        return MediaCacheCandidate(media: media, scope: scope, relativePath: relativePath)
    }

    private func downloadMediaObjects(
        _ candidates: [MediaCacheCandidate],
        progress: ((Int, Int) -> Void)? = nil
    ) async -> [MediaDownloadOutcome] {
        guard !candidates.isEmpty else { return [] }
        let syncClient = syncClient
        let limit = min(Self.maxConcurrentMediaDownloads, candidates.count)

        return await withTaskGroup(of: MediaDownloadOutcome.self) { group in
            var iterator = candidates.makeIterator()
            var outcomes: [MediaDownloadOutcome] = []
            var isCancelling = false

            func addNextDownload() {
                guard let candidate = iterator.next() else { return }
                group.addTask {
                    if Task.isCancelled {
                        return .failure(candidate, .cancelled)
                    }
                    do {
                        let data = try await syncClient.downloadMedia(id: candidate.media.id)
                        if let expectedHash = candidate.media.sha256,
                           Self.sha256Hex(for: data) != expectedHash {
                            return .failure(candidate, .failed(ServerSyncError.invalidResponse("media checksum mismatch").localizedDescription))
                        }
                        return .success(MediaDownloadResult(candidate: candidate, data: data))
                    } catch ServerSyncError.cancelled {
                        return .failure(candidate, .cancelled)
                    } catch is CancellationError {
                        return .failure(candidate, .cancelled)
                    } catch {
                        return .failure(candidate, .failed(error.localizedDescription))
                    }
                }
            }

            for _ in 0..<limit {
                addNextDownload()
            }

            while let outcome = await group.next() {
                if case .failure(_, .cancelled) = outcome {
                    isCancelling = true
                    group.cancelAll()
                }
                outcomes.append(outcome)
                progress?(outcomes.count, candidates.count)
                if !isCancelling {
                    addNextDownload()
                }
            }

            return outcomes
        }
    }

    private func storeDownloadedMedia(_ result: MediaDownloadResult, database: ContentDatabase) throws {
        let candidate = result.candidate
        let media = candidate.media
        let relativePath = candidate.relativePath
        let data = result.data
        if let expectedHash = media.sha256, Self.sha256Hex(for: data) != expectedHash {
            throw ServerSyncError.invalidResponse("media checksum mismatch")
        }
        let rootURL = try mediaRootURL(scope: candidate.scope)
        let mediaDirectory = rootURL.appendingPathComponent(AppDataPaths.deckMediaFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try data.write(to: fileURL, options: .atomic)
        try updateDeckMediaLocalPathIfNeeded(
            mediaID: media.id,
            scope: candidate.scope,
            localPath: relativePath,
            database: database
        )
    }

    private func applyCachedUserAvatarURLs(from bootstrap: ServerBootstrap) throws {
        let mediaObjects = Dictionary(
            uniqueKeysWithValues: bootstrap.media.map { ($0.id, $0) }
        )
        users = try users.map { user in
            var updated = user
            guard let mediaID = user.avatarMediaID,
                  let media = mediaObjects[mediaID] else {
                updated.avatarImageURL = nil
                return updated
            }
            let relativePath = "media/\(media.id.uuidString.lowercased()).\(fileExtension(for: media))"
            updated.avatarImageURL = try AppDataPaths.appMediaFileURL(relativePath: relativePath)
            return updated
        }
    }

    private func existingMediaFileURL(scope: MediaCacheScope, relativePath: String) throws -> URL? {
        switch scope {
        case .deck(let deckID):
            try AppDataPaths.mediaFileURL(deckID: deckID, relativePath: relativePath)
        case .userAvatar:
            try AppDataPaths.appMediaFileURL(relativePath: relativePath)
        }
    }

    private func mediaRootURL(scope: MediaCacheScope) throws -> URL {
        switch scope {
        case .deck(let deckID):
            try AppDataPaths.deckFolderURL(deckID: deckID)
        case .userAvatar:
            try AppDataPaths.appMediaRootURL()
        }
    }

    private func updateDeckMediaLocalPathIfNeeded(
        mediaID: UUID,
        scope: MediaCacheScope,
        localPath: String,
        database: ContentDatabase
    ) throws {
        if case .deck = scope {
            try database.updateMediaLocalPath(mediaID: mediaID, localPath: localPath)
        }
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

    nonisolated private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func saveUsers() {
        guard let data = try? JSONEncoder().encode(users) else { return }
        defaults.set(data, forKey: Keys.users)
    }
}
