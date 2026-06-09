import Foundation
import FSRS
import OSLog
import SQLite3

nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated private enum SyncMetadataKey {
    static let serverRevision = "server_revision"
    static let deviceID = "device_id"
    static let initialSyncCompleted = "initial_sync_completed"
}

nonisolated private let contentDatabaseSetupLock = NSLock()
nonisolated(unsafe) private var contentDatabaseSetupPaths: Set<String> = []

nonisolated private enum WeakCardFilter {
    static let minimumFailureRate = 0.25
}

nonisolated enum UserStudySettingsDefaults {
    static let randomCardCount = 30
    static let minimumRandomCardCount = 1
}

struct ContentCacheCleanupResult {
    let removedDeckIDs: [UUID]
}

struct PendingProgressSnapshot {
    let senseID: UUID
    let updatedAt: Date
}

struct PendingPracticeReviewSnapshot {
    let id: UUID
}

struct PendingMatchingRecordSnapshot {
    let deckID: UUID
    let achievedAt: Date
}

struct PendingMatchingAttemptSnapshot {
    let id: UUID
}

struct PendingDeckPreferenceSnapshot {
    let deckID: UUID
    let updatedAt: Date
}

struct PendingServerSyncBatch {
    let payload: ServerSyncEventsPayload
    let reviewIDs: [UUID]
    let practiceReviewIDs: [UUID]
    let progressSenseIDs: [UUID]
    let matchingDeckIDs: [UUID]
    let matchingAttemptIDs: [UUID]
    let deckPreferenceDeckIDs: [UUID]
    let practiceReviewSnapshots: [PendingPracticeReviewSnapshot]
    let progressSnapshots: [PendingProgressSnapshot]
    let matchingSnapshots: [PendingMatchingRecordSnapshot]
    let matchingAttemptSnapshots: [PendingMatchingAttemptSnapshot]
    let deckPreferenceSnapshots: [PendingDeckPreferenceSnapshot]

    var isEmpty: Bool {
        payload.isEmpty
            && reviewIDs.isEmpty
            && practiceReviewIDs.isEmpty
            && progressSenseIDs.isEmpty
            && matchingDeckIDs.isEmpty
            && matchingAttemptIDs.isEmpty
            && deckPreferenceDeckIDs.isEmpty
    }

    var diagnosticSummary: String {
        "reviews=\(reviewIDs.count) practice=\(practiceReviewIDs.count) progress=\(progressSenseIDs.count) matching=\(matchingDeckIDs.count) attempts=\(matchingAttemptIDs.count) prefs=\(deckPreferenceDeckIDs.count)"
    }

    var diagnosticFingerprint: String {
        let parts = [
            reviewIDs.map(\.uuidString).sorted().joined(separator: ","),
            practiceReviewIDs.map(\.uuidString).sorted().joined(separator: ","),
            progressSnapshots.map { "\($0.senseID.uuidString)@\(Int($0.updatedAt.timeIntervalSince1970 * 1000))" }.sorted().joined(separator: ","),
            matchingSnapshots.map { "\($0.deckID.uuidString)@\(Int($0.achievedAt.timeIntervalSince1970 * 1000))" }.sorted().joined(separator: ","),
            matchingAttemptIDs.map(\.uuidString).sorted().joined(separator: ","),
            deckPreferenceSnapshots.map { "\($0.deckID.uuidString)@\(Int($0.updatedAt.timeIntervalSince1970 * 1000))" }.sorted().joined(separator: ","),
        ]
        return parts.joined(separator: "|")
    }
}

/// Read/write access to `Documents/Data/flashgame.db` (content + study progress).
nonisolated final class ContentDatabase {
    private static let logger = Logger(subsystem: "com.uniweb.wordtrainer.Words-Trainer", category: "Outbox")

    enum OpenMode {
        case readWrite
        case readOnly
    }

    private var db: OpaquePointer?
    private let userID: UUID
    var currentUserID: UUID { userID }

    init(userID: UUID, mode: OpenMode = .readWrite) throws {
        self.userID = userID
        _ = try AppDataPaths.dataDirectoryURL()
        let path = try AppDataPaths.databaseURL().path
        let flags: Int32
        switch mode {
        case .readWrite:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            throw ContentDatabaseError.openFailed
        }
        sqlite3_busy_timeout(db, 5_000)
        try configureConnection(mode: mode)
        if mode == .readWrite {
            try prepareSchemaIfNeeded(path: path)
        }
    }

    convenience init(userID: UUID, readOnly: Bool) throws {
        try self.init(userID: userID, mode: readOnly ? .readOnly : .readWrite)
    }

    private func configureConnection(mode: OpenMode) throws {
        guard sqlite3_exec(db, "PRAGMA busy_timeout = 5000", nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        switch mode {
        case .readWrite:
            guard sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        case .readOnly:
            guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func prepareSchemaIfNeeded(path: String) throws {
        contentDatabaseSetupLock.lock()
        defer { contentDatabaseSetupLock.unlock() }
        guard !contentDatabaseSetupPaths.contains(path) else { return }
        guard sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try executeMigrations()
        try normalizeUUIDColumns()
        try AppDataPaths.normalizeDeckMediaFolders()
        contentDatabaseSetupPaths.insert(path)
    }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_exec(db, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        do {
            let value = try body()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            return value
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func journalMode() throws -> String {
        let sql = "PRAGMA journal_mode"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let mode = textColumn(statement, index: 0) else {
            throw ContentDatabaseError.queryFailed
        }
        return mode
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    static func databaseExists() -> Bool {
        guard let url = try? AppDataPaths.databaseURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func loadDecks() throws -> [DeckContent] {
        let deckRows = try fetchDeckRows()
        return try deckRows.map { row in
            DeckContent(
                id: row.id,
                contentVersionID: row.contentVersionID,
                status: row.status,
                title: row.title,
                avatarSystemName: row.avatarSystemName,
                avatarImageURL: resolveMediaURL(deckID: row.id, mediaID: row.avatarMediaID),
                languageCode: row.languageCode,
                newCardsPerDay: row.newCardsPerDay,
                reviewCardsPerDay: row.reviewCardsPerDay,
                deckGroupID: row.deckGroupID,
                deckGroupTitle: row.deckGroupTitle,
                deckGroupSortOrder: row.deckGroupSortOrder,
                deckSortOrder: row.deckSortOrder,
                cards: try fetchCards(deckID: row.id)
            )
        }
    }

    func importServerBootstrap(
        _ bootstrap: ServerBootstrap,
        selectedUserID: UUID,
        progressSnapshotIsComplete: Bool = true
    ) throws {
        let versionDeckIDs = Dictionary(
            uniqueKeysWithValues: bootstrap.assignments.compactMap { assignment -> (UUID, UUID)? in
                let versionID = assignment.currentVersionId
                guard let versionID else { return nil }
                return (versionID, assignment.deckId)
            }
        )
        let importedContentVersionIDs = Set(
            bootstrap.content.cards.map(\.deckVersionId)
                + bootstrap.content.senses.map(\.deckVersionId)
                + bootstrap.content.examples.map(\.deckVersionId)
                + bootstrap.content.sentenceQuestions.map(\.deckVersionId)
                + bootstrap.content.forms.map(\.deckVersionId)
                + bootstrap.content.distractors.map(\.deckVersionId)
        )
        let decksWithImportedContent = Set(importedContentVersionIDs.compactMap { versionDeckIDs[$0] })

        try beginTransaction()
        do {
            try replaceAssignments(bootstrap.assignments, selectedUserID: selectedUserID)
            try upsertMediaObjects(bootstrap.media)
            for deckID in decksWithImportedContent {
                try deleteDeckContent(deckID: deckID)
            }
            try upsertDecks(bootstrap.assignments)
            try upsertServerDeckPreferences(bootstrap.assignments, selectedUserID: selectedUserID)
            try upsertServerUserSettings(bootstrap.userSettings, selectedUserID: selectedUserID)
            try upsertCards(bootstrap.content.cards, versionDeckIDs: versionDeckIDs)
            try upsertSenses(bootstrap.content.senses)
            try upsertExamples(bootstrap.content.examples)
            try upsertSentenceQuestions(bootstrap.content.sentenceQuestions)
            try upsertForms(bootstrap.content.forms)
            try upsertDistractors(bootstrap.content.distractors)
            try markContentVersionsImported(importedContentVersionIDs, versionDeckIDs: versionDeckIDs)
            try applyStudyDataResets(bootstrap.studyDataResets, selectedUserID: selectedUserID)
            try upsertServerProgress(bootstrap.progress)
            if progressSnapshotIsComplete {
                try deleteSyncedProgressMissingFromServerSnapshot(bootstrap.progress)
            }
            try upsertServerReviews(bootstrap.reviews, selectedUserID: selectedUserID)
            try upsertServerPracticeReviews(bootstrap.practiceReviews, selectedUserID: selectedUserID)
            try upsertServerMatchingRecords(bootstrap.matchingRecords, selectedUserID: selectedUserID)
            try upsertServerMatchingAttempts(bootstrap.matchingAttempts, selectedUserID: selectedUserID)
            try rebuildDerivedStats(selectedUserID: selectedUserID)
            try commitTransaction()
            try cleanupUnusedContentCache()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    func importServerChanges(_ changes: ServerSyncChanges, selectedUserID: UUID) throws {
        let versionDeckIDs = Dictionary(
            uniqueKeysWithValues: changes.assignments.compactMap { assignment -> (UUID, UUID)? in
                let versionID = assignment.currentVersionId
                guard let versionID else { return nil }
                return (versionID, assignment.deckId)
            }
        )
        let importedContentVersionIDs = Set(
            changes.content.cards.map(\.deckVersionId)
                + changes.content.senses.map(\.deckVersionId)
                + changes.content.examples.map(\.deckVersionId)
                + changes.content.sentenceQuestions.map(\.deckVersionId)
                + changes.content.forms.map(\.deckVersionId)
                + changes.content.distractors.map(\.deckVersionId)
        )
        let decksWithImportedContent = Set(importedContentVersionIDs.compactMap { versionDeckIDs[$0] })

        try beginTransaction()
        do {
            try upsertAssignments(changes.assignments, selectedUserID: selectedUserID)
            try upsertMediaObjects(changes.media)
            for deckID in decksWithImportedContent {
                try deleteDeckContent(deckID: deckID)
            }
            try upsertDecks(changes.assignments)
            try upsertServerDeckPreferences(changes.assignments, selectedUserID: selectedUserID)
            try upsertServerUserSettings(changes.userSettings, selectedUserID: selectedUserID)
            try upsertCards(changes.content.cards, versionDeckIDs: versionDeckIDs)
            try upsertSenses(changes.content.senses)
            try upsertExamples(changes.content.examples)
            try upsertSentenceQuestions(changes.content.sentenceQuestions)
            try upsertForms(changes.content.forms)
            try upsertDistractors(changes.content.distractors)
            try markContentVersionsImported(importedContentVersionIDs, versionDeckIDs: versionDeckIDs)
            try applyStudyDataResets(changes.studyDataResets, selectedUserID: selectedUserID)
            try upsertServerProgress(changes.progress)
            try upsertServerReviews(changes.reviews, selectedUserID: selectedUserID)
            try upsertServerPracticeReviews(changes.practiceReviews, selectedUserID: selectedUserID)
            try upsertServerMatchingRecords(changes.matchingRecords, selectedUserID: selectedUserID)
            try upsertServerMatchingAttempts(changes.matchingAttempts, selectedUserID: selectedUserID)
            try rebuildDerivedStats(selectedUserID: selectedUserID)
            try commitTransaction()
            try cleanupUnusedContentCache()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    func serverRevision() throws -> String {
        try syncMetadataValue(SyncMetadataKey.serverRevision) ?? "0"
    }

    func setServerRevision(_ revision: String) throws {
        try setSyncMetadata(SyncMetadataKey.serverRevision, value: revision, selectedUserID: userID)
    }

    func deviceID() throws -> UUID {
        if let value = try syncMetadataValue(SyncMetadataKey.deviceID),
           let id = UUID(databaseString: value) {
            return id
        }
        let id = UUID()
        try setSyncMetadata(SyncMetadataKey.deviceID, value: id.databaseString, selectedUserID: userID)
        return id
    }

    func hasCompletedInitialSync() throws -> Bool {
        try syncMetadataValue(SyncMetadataKey.initialSyncCompleted) == "1"
    }

    func markInitialSyncCompleted() throws {
        try setSyncMetadata(SyncMetadataKey.initialSyncCompleted, value: "1", selectedUserID: userID)
    }

    @discardableResult
    func cleanupUnusedContentCache() throws -> ContentCacheCleanupResult {
        let orphanDeckIDs = try fetchDeckIDsWithoutAssignments()
        guard !orphanDeckIDs.isEmpty else {
            try deleteUnreferencedMediaObjects()
            return ContentCacheCleanupResult(removedDeckIDs: [])
        }

        try beginTransaction()
        do {
            try deleteRowsForDecksWithoutAssignments()
            try deleteUnreferencedMediaObjects()
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }

        for deckID in orphanDeckIDs {
            let folderURL = try AppDataPaths.deckFolderURL(deckID: deckID)
            if FileManager.default.fileExists(atPath: folderURL.path) {
                try FileManager.default.removeItem(at: folderURL)
            }
        }
        return ContentCacheCleanupResult(removedDeckIDs: orphanDeckIDs)
    }

    func cachedDeckVersionIDs() throws -> [UUID] {
        let sql = """
        SELECT decks.id, decks.content_version_id
        FROM decks
        JOIN user_deck_assignments ON user_deck_assignments.deck_id = decks.id
        WHERE user_deck_assignments.user_id = ?
          AND decks.content_version_id IS NOT NULL
        ORDER BY decks.content_version_id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)

        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let deckID = uuidColumn(statement, index: 0),
                  let versionID = uuidColumn(statement, index: 1) else {
                continue
            }
            if try cachedDeckMediaIsComplete(deckID: deckID) {
                ids.append(versionID)
            }
        }
        return ids
    }

    func contentVersionID(deckID: UUID) throws -> UUID? {
        let sql = "SELECT content_version_id FROM decks WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: deckID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return uuidColumn(statement, index: 0)
    }

    func mediaObjects(ids mediaIDs: Set<UUID>) throws -> [ServerMediaObject] {
        guard !mediaIDs.isEmpty else { return [] }
        var results: [ServerMediaObject] = []
        let sql = """
        SELECT id, storage_key, sha256, mime_type, byte_size, width, height
        FROM media_objects
        WHERE id = ?
        """
        for mediaID in mediaIDs {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: mediaID)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let id = uuidColumn(statement, index: 0) else { continue }
            results.append(ServerMediaObject(
                id: id,
                storageKey: textColumn(statement, index: 1),
                sha256: textColumn(statement, index: 2),
                mimeType: textColumn(statement, index: 3),
                byteSize: intColumn(statement, index: 4),
                width: intColumn(statement, index: 5),
                height: intColumn(statement, index: 6)
            ))
        }
        return results
    }

    private func cachedDeckMediaIsComplete(deckID: UUID) throws -> Bool {
        let mediaIDs = try referencedMediaIDs(deckID: deckID)
        guard !mediaIDs.isEmpty else { return true }
        let sql = """
        SELECT local_path, storage_key
        FROM media_objects
        WHERE id = ?
        LIMIT 1
        """
        for mediaID in mediaIDs {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            let isAvailable: Bool = try {
                defer { sqlite3_finalize(statement) }
                try bind(statement, index: 1, uuid: mediaID)
                guard sqlite3_step(statement) == SQLITE_ROW else { return false }
                let reference = textColumn(statement, index: 0) ?? textColumn(statement, index: 1)
                guard let reference,
                      let url = resolveMediaReference(reference, deckID: deckID),
                      FileManager.default.fileExists(atPath: url.path) else {
                    return false
                }
                return true
            }()
            guard isAvailable else { return false }
        }
        return true
    }

    private func referencedMediaIDs(deckID: UUID) throws -> Set<UUID> {
        let sql = """
        SELECT media_id
        FROM (
            SELECT avatar_media_id AS media_id FROM decks WHERE id = ?
            UNION
            SELECT audio_word_media_id AS media_id FROM cards WHERE deck_id = ?
            UNION
            SELECT card_senses.image_media_id AS media_id FROM card_senses
            JOIN cards ON cards.id = card_senses.card_id
            WHERE cards.deck_id = ?
            UNION
            SELECT sentence_questions.audio_answer_media_id AS media_id FROM sentence_questions
            JOIN cards ON cards.id = sentence_questions.card_id
            WHERE cards.deck_id = ?
        )
        WHERE media_id IS NOT NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        for index in 1...4 {
            try bind(statement, index: Int32(index), uuid: deckID)
        }
        var ids: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = uuidColumn(statement, index: 0) {
                ids.insert(id)
            }
        }
        return ids
    }

    func updateMediaLocalPath(mediaID: UUID, localPath: String) throws {
        let sql = "UPDATE media_objects SET local_path = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, text: localPath)
        try bind(statement, index: 2, uuid: mediaID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func updateDeckStatus(deckID: UUID, status: ContentStatus) throws {
        try setDeckUserEnabled(status.isActive, deckID: deckID)
    }

    func setDeckUserEnabled(_ isEnabled: Bool, deckID: UUID, updatedAt: Date = .now) throws {
        let sql = """
        INSERT INTO user_deck_preferences (user_id, deck_id, is_enabled, updated_at, synced_at)
        VALUES (?, ?, ?, ?, NULL)
        ON CONFLICT(user_id, deck_id) DO UPDATE SET
            is_enabled = excluded.is_enabled,
            updated_at = excluded.updated_at,
            synced_at = NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)
        guard sqlite3_bind_int(statement, 3, isEnabled ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_double(statement, 4, updatedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func progressMap(deckID: UUID) throws -> [UUID: CardProgress] {
        let sql = """
        SELECT sense_id, fsrs_data, updated_at
        FROM sense_progress
        WHERE user_id = ? AND deck_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)

        var map: [UUID: CardProgress] = [:]
        var repairs: [CardProgress] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let senseID = uuidColumn(statement, index: 0),
                  let blob = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: blob, count: length)
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            do {
                let fsrsCard = try JSONDecoder().decode(Card.self, from: data)
                map[senseID] = CardProgress(senseID: senseID, fsrsCard: fsrsCard, updatedAt: updatedAt)
            } catch {
                let repaired = CardProgress.newSense(senseID: senseID, now: .now)
                map[senseID] = repaired
                repairs.append(repaired)
            }
        }
        sqlite3_finalize(statement)

        for repair in repairs {
            try saveProgress(deckID: deckID, progress: repair)
        }
        return map
    }

    func dailyUsage(deckID: UUID, dayKey: String) throws -> DeckDailyUsage? {
        let sql = """
        SELECT new_cards_studied FROM deck_daily_usage
        WHERE user_id = ? AND deck_id = ? AND day_key = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)
        try bind(statement, index: 3, text: dayKey)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_int(statement, 0))
        return DeckDailyUsage(dayKey: dayKey, newCardsStudied: count)
    }

    func deckID(forCardID cardID: UUID) throws -> UUID? {
        let sql = "SELECT deck_id FROM cards WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: cardID)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return uuidColumn(statement, index: 0)
    }

    func hasPassedNewStudyReview(deckID: UUID, cardID: UUID, dayKey: String) throws -> Bool {
        let sql = """
        SELECT 1
        FROM study_reviews
        WHERE user_id = ?
          AND deck_id = ?
          AND card_id = ?
          AND was_new = 1
          AND outcome IN ('remembered', 'correct')
          AND strftime('%Y-%m-%d', reviewed_at, 'unixepoch', 'localtime', '-4 hours') = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)
        try bind(statement, index: 3, uuid: cardID)
        try bind(statement, index: 4, text: dayKey)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func saveProgress(deckID: UUID, progress: CardProgress) throws {
        let fsrsData = try JSONEncoder().encode(progress.fsrsCard)
        let sql = """
        INSERT INTO sense_progress (user_id, sense_id, card_id, deck_id, fsrs_data, updated_at, synced_at)
        SELECT ?, ?, card_id, ?, ?, ?, NULL
        FROM card_senses
        WHERE id = ?
        ON CONFLICT(user_id, sense_id) DO UPDATE SET
            card_id = excluded.card_id,
            deck_id = excluded.deck_id,
            fsrs_data = excluded.fsrs_data,
            updated_at = excluded.updated_at,
            synced_at = NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: progress.senseID)
        try bind(statement, index: 3, uuid: deckID)
        try fsrsData.withUnsafeBytes { raw in
            guard sqlite3_bind_blob(statement, 4, raw.baseAddress, Int32(fsrsData.count), sqliteTransient) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
        try bind(statement, index: 6, uuid: progress.senseID)
        guard sqlite3_bind_double(statement, 5, progress.updatedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func saveDailyUsage(deckID: UUID, usage: DeckDailyUsage) throws {
        let sql = """
        INSERT INTO deck_daily_usage (user_id, deck_id, day_key, new_cards_studied)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id, deck_id, day_key) DO UPDATE SET
            new_cards_studied = excluded.new_cards_studied
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)
        try bind(statement, index: 3, text: usage.dayKey)
        guard sqlite3_bind_int(statement, 4, Int32(usage.newCardsStudied)) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func saveStudyReview(_ event: StudyReviewEvent) throws {
        let deckVersionID = try event.deckVersionID ?? contentVersionID(deckID: event.deckID)
        let sql = """
        INSERT INTO study_reviews (
            id, user_id, card_id, sense_id, deck_id, deck_version_id, mode, outcome, source, reviewed_at,
            duration_ms, was_new, previous_state, new_state, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: event.id)
        try bind(statement, index: 2, uuid: userID)
        try bind(statement, index: 3, uuid: event.cardID)
        try bind(statement, index: 4, uuid: event.senseID)
        try bind(statement, index: 5, uuid: event.deckID)
        try bind(statement, index: 6, uuid: deckVersionID)
        try bind(statement, index: 7, text: event.mode.rawValue)
        try bind(statement, index: 8, text: event.outcome.databaseValue)
        try bind(statement, index: 9, text: event.source.rawValue)
        guard sqlite3_bind_double(statement, 10, event.reviewedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        if let durationMS = event.durationMS {
            guard sqlite3_bind_int(statement, 11, Int32(durationMS)) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        } else {
            guard sqlite3_bind_null(statement, 11) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
        guard sqlite3_bind_int(statement, 12, event.wasNew ? 1 : 0) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 13, text: event.previousState)
        try bind(statement, index: 14, text: event.newState)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }

        try refreshDailyUsage(deckID: event.deckID, dayKey: DeckDailyUsage.dayKey(for: event.reviewedAt))
    }

    func savePracticeReview(_ event: PracticeReviewEvent) throws {
        let deckVersionID = try event.deckVersionID ?? contentVersionID(deckID: event.deckID)
        let sql = """
        INSERT INTO practice_reviews (
            id, user_id, card_id, sense_id, deck_id, deck_version_id, mode, outcome, source, practiced_at, duration_ms, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(id) DO NOTHING
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: event.id)
        try bind(statement, index: 2, uuid: userID)
        try bind(statement, index: 3, uuid: event.cardID)
        try bind(statement, index: 4, uuid: event.senseID)
        try bind(statement, index: 5, uuid: event.deckID)
        try bind(statement, index: 6, uuid: deckVersionID)
        try bind(statement, index: 7, text: event.mode.rawValue)
        try bind(statement, index: 8, text: event.outcome.databaseValue)
        try bind(statement, index: 9, text: event.source.rawValue)
        guard sqlite3_bind_double(statement, 10, event.practicedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 11, int: event.durationMS)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func reviewedSenseIDs(
        day: Date = .now,
        deckID: UUID? = nil,
        source: StudyReviewSource? = nil,
        calendar: Calendar = .current
    ) throws -> [UUID] {
        let start = StudyDay.start(for: day, calendar: calendar)
        let end = StudyDay.end(for: day, calendar: calendar)
        var sql = """
        SELECT sense_id, MAX(reviewed_at) AS last_reviewed_at
        FROM study_reviews
        WHERE user_id = ? AND reviewed_at >= ? AND reviewed_at < ?
        """
        var nextIndex: Int32 = 4
        if deckID != nil {
            sql += " AND deck_id = ?"
            nextIndex += 1
        }
        if source != nil {
            sql += " AND source = ?"
        }
        sql += """

        GROUP BY sense_id
        ORDER BY last_reviewed_at DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_double(statement, 2, start.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, end.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        if let deckID {
            try bind(statement, index: 4, uuid: deckID)
        }
        if let source {
            try bind(statement, index: nextIndex, text: source.rawValue)
        }

        var senseIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let senseID = uuidColumn(statement, index: 0) else { continue }
            senseIDs.append(senseID)
        }
        return senseIDs
    }

    func studyActivity(since startDate: Date) throws -> [StudyActivityDay] {
        let sql = """
        SELECT
            strftime('%Y-%m-%d', reviewed_at, 'unixepoch', 'localtime', '-4 hours') AS day_key,
            COUNT(*),
            SUM(CASE WHEN outcome IN ('remembered', 'correct') THEN 1 ELSE 0 END)
        FROM study_reviews
        WHERE user_id = ? AND reviewed_at >= ?
        GROUP BY day_key
        ORDER BY day_key
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }

        var days: [StudyActivityDay] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let dayKey = textColumn(statement, index: 0) else { continue }
            days.append(
                StudyActivityDay(
                    dayKey: dayKey,
                    reviewedCount: Int(sqlite3_column_int(statement, 1)),
                    passedCount: Int(sqlite3_column_int(statement, 2))
                )
            )
        }
        return days
    }

    func studyReviewCount(since startDate: Date) throws -> StudyReviewCount {
        let sql = """
        SELECT
            COUNT(*),
            SUM(CASE WHEN outcome IN ('remembered', 'correct') THEN 1 ELSE 0 END)
        FROM study_reviews
        WHERE user_id = ? AND reviewed_at >= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return .zero }
        return StudyReviewCount(
            total: Int(sqlite3_column_int(statement, 0)),
            passed: Int(sqlite3_column_int(statement, 1))
        )
    }

    func uniqueStudyCardCount(since startDate: Date) throws -> Int {
        let sql = """
        SELECT COUNT(DISTINCT card_id)
        FROM study_reviews
        WHERE user_id = ? AND reviewed_at >= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func matchingAttemptCount(since startDate: Date) throws -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM matching_attempts
        WHERE user_id = ?
          AND completed_at >= ?
          AND mode IN (?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 3, text: StudyMode.matching.rawValue)
        try bind(statement, index: 4, text: StudyMode.matchingAudio.rawValue)
        try bind(statement, index: 5, text: "matching_audio")
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func randomCardCount() throws -> Int {
        let sql = """
        SELECT random_card_count
        FROM user_settings
        WHERE user_id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return UserStudySettingsDefaults.randomCardCount
        }
        return max(
            UserStudySettingsDefaults.minimumRandomCardCount,
            Int(sqlite3_column_int(statement, 0))
        )
    }

    func studyTimeBreakdown(since startDate: Date) throws -> StudyTimeBreakdown {
        let sql = """
        WITH timed_events AS (
            SELECT mode, COALESCE(duration_ms, 0) AS duration_ms
            FROM study_reviews
            WHERE user_id = ? AND reviewed_at >= ?
            UNION ALL
            SELECT mode, COALESCE(duration_ms, 0) AS duration_ms
            FROM practice_reviews
            WHERE user_id = ? AND practiced_at >= ?
            UNION ALL
            SELECT mode, COALESCE(duration_ms, 0) AS duration_ms
            FROM matching_attempts
            WHERE user_id = ? AND completed_at >= ?
        )
        SELECT
            COALESCE(SUM(CASE WHEN mode = ? THEN duration_ms ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN mode IN (?, ?) THEN duration_ms ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN mode = ? THEN duration_ms ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN mode IN (?, ?) THEN duration_ms ELSE 0 END), 0)
        FROM timed_events
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 3, uuid: userID)
        guard sqlite3_bind_double(statement, 4, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 5, uuid: userID)
        guard sqlite3_bind_double(statement, 6, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 7, text: StudyMode.flashcards.rawValue)
        try bind(statement, index: 8, text: StudyMode.clozeMultipleChoice.rawValue)
        try bind(statement, index: 9, text: StudyMode.clozeTyping.rawValue)
        try bind(statement, index: 10, text: StudyMode.matching.rawValue)
        try bind(statement, index: 11, text: StudyMode.matchingAudio.rawValue)
        try bind(statement, index: 12, text: "matching_audio")

        guard sqlite3_step(statement) == SQLITE_ROW else { return .zero }
        return StudyTimeBreakdown(
            flashcardsMilliseconds: Int(sqlite3_column_int64(statement, 0)),
            sentenceMilliseconds: Int(sqlite3_column_int64(statement, 1)),
            matchingMilliseconds: Int(sqlite3_column_int64(statement, 2)),
            matchingAudioMilliseconds: Int(sqlite3_column_int64(statement, 3))
        )
    }

    func weakCards(limit: Int = 30, deckID: UUID? = nil) throws -> [WeakCardStat] {
        guard limit > 0 else { return [] }

        let deckFilter = deckID == nil ? "" : "AND cards.deck_id = ?"
        let sql = """
        SELECT
            cards.id,
            study_reviews.sense_id,
            cards.deck_id,
            COALESCE(reviewed_sense.display_pattern, cards.display_word) AS display_word,
            reviewed_sense.translation,
            SUM(CASE WHEN study_reviews.outcome IN ('forgot', 'incorrect') THEN 1 ELSE 0 END) AS failed_count,
            COUNT(study_reviews.id) AS reviewed_count,
            MAX(CASE WHEN study_reviews.outcome IN ('forgot', 'incorrect') THEN study_reviews.reviewed_at ELSE NULL END) AS last_failed_at,
            sense_progress.fsrs_data
        FROM study_reviews
        JOIN cards ON cards.id = study_reviews.card_id
        JOIN decks ON decks.id = study_reviews.deck_id
        JOIN user_deck_assignments ON user_deck_assignments.user_id = study_reviews.user_id
            AND user_deck_assignments.deck_id = study_reviews.deck_id
            AND user_deck_assignments.status = 'active'
        JOIN card_senses AS reviewed_sense
            ON reviewed_sense.id = study_reviews.sense_id
            AND reviewed_sense.card_id = cards.id
            AND reviewed_sense.status = 'active'
        LEFT JOIN sense_progress ON sense_progress.user_id = study_reviews.user_id
            AND sense_progress.sense_id = study_reviews.sense_id
            AND sense_progress.card_id = cards.id
            AND sense_progress.deck_id = cards.deck_id
        LEFT JOIN user_deck_preferences ON user_deck_preferences.user_id = study_reviews.user_id
            AND user_deck_preferences.deck_id = study_reviews.deck_id
        WHERE study_reviews.user_id = ? AND cards.status = 'active' AND decks.status = 'active'
          AND COALESCE(user_deck_preferences.is_enabled, 1) = 1
          \(deckFilter)
        GROUP BY cards.id, study_reviews.sense_id, cards.deck_id, display_word, reviewed_sense.translation
        HAVING failed_count > 0
        ORDER BY failed_count DESC, CAST(failed_count AS REAL) / reviewed_count DESC, last_failed_at DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        if let deckID {
            try bind(statement, index: 2, uuid: deckID)
        }

        var cards: [WeakCardStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let failedCount = Int(sqlite3_column_int(statement, 5))
            let reviewedCount = Int(sqlite3_column_int(statement, 6))
            guard try isCurrentWeakCard(
                statement,
                fsrsDataIndex: 8,
                failedCount: failedCount,
                reviewedCount: reviewedCount
            ) else { continue }
            guard let cardID = uuidColumn(statement, index: 0),
                  let senseID = uuidColumn(statement, index: 1),
                  let deckID = uuidColumn(statement, index: 2),
                  let word = textColumn(statement, index: 3),
                  let translation = textColumn(statement, index: 4) else { continue }
            let lastFailedAt: Date?
            if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                lastFailedAt = nil
            } else {
                lastFailedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            }
            cards.append(
                WeakCardStat(
                    cardID: cardID,
                    senseID: senseID,
                    deckID: deckID,
                    word: word,
                    translation: translation,
                    failedCount: failedCount,
                    reviewedCount: reviewedCount,
                    lastFailedAt: lastFailedAt
                )
            )
            if cards.count >= limit { break }
        }
        return cards
    }

    func matchingRecord(deckID: UUID) throws -> DeckMatchingRecord? {
        let sql = """
        SELECT deck_version_id, best_duration_seconds, pair_count, achieved_at
        FROM deck_matching_records
        WHERE user_id = ? AND deck_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return DeckMatchingRecord(
            deckID: deckID,
            deckVersionID: uuidColumn(statement, index: 0),
            bestDuration: sqlite3_column_double(statement, 1),
            pairCount: Int(sqlite3_column_int(statement, 2)),
            achievedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    func saveMatchingRecord(_ record: DeckMatchingRecord) throws {
        let deckVersionID = try record.deckVersionID ?? contentVersionID(deckID: record.deckID)
        let sql = """
        INSERT INTO deck_matching_records (user_id, deck_id, deck_version_id, best_duration_seconds, pair_count, achieved_at, synced_at)
        VALUES (?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(user_id, deck_id) DO UPDATE SET
            deck_version_id = excluded.deck_version_id,
            best_duration_seconds = excluded.best_duration_seconds,
            pair_count = excluded.pair_count,
            achieved_at = excluded.achieved_at,
            synced_at = NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: record.deckID)
        try bind(statement, index: 3, uuid: deckVersionID)
        guard sqlite3_bind_double(statement, 4, record.bestDuration) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_bind_int(statement, 5, Int32(record.pairCount)) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_bind_double(statement, 6, record.achievedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func saveMatchingAttempt(_ event: MatchingAttemptEvent) throws {
        let deckVersionID: UUID?
        if let explicit = event.deckVersionID {
            deckVersionID = explicit
        } else if let deckID = event.deckID {
            deckVersionID = try contentVersionID(deckID: deckID)
        } else {
            deckVersionID = nil
        }
        let sql = """
        INSERT INTO matching_attempts (
            id, user_id, deck_id, deck_version_id, mode, source, completed_at, duration_ms, pair_count, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(id) DO NOTHING
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: event.id)
        try bind(statement, index: 2, uuid: userID)
        try bind(statement, index: 3, uuid: event.deckID)
        try bind(statement, index: 4, uuid: deckVersionID)
        try bind(statement, index: 5, text: event.mode.rawValue)
        try bind(statement, index: 6, text: event.source.rawValue)
        guard sqlite3_bind_double(statement, 7, event.completedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(statement, 8, Int32(max(0, Int((event.duration * 1000).rounded())))) == SQLITE_OK,
              sqlite3_bind_int(statement, 9, Int32(event.pairCount)) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func pendingServerSyncBatch(limit: Int = 100) throws -> PendingServerSyncBatch {
        let reviews = try pendingReviewEvents(limit: limit)
        let practiceReviews = try pendingPracticeReviews(limit: limit)
        let progress = try pendingProgressItems(limit: limit)
        let matchingRecords = try pendingMatchingRecords(limit: limit)
        let matchingAttempts = try pendingMatchingAttempts(limit: limit)
        let deckPreferences = try pendingDeckPreferences(limit: limit)
        return PendingServerSyncBatch(
            payload: ServerSyncEventsPayload(
                reviews: reviews.payload,
                practiceReviews: practiceReviews.payload,
                progress: progress.payload,
                matchingRecords: matchingRecords.payload,
                matchingAttempts: matchingAttempts.payload,
                deckPreferences: deckPreferences.payload
            ),
            reviewIDs: reviews.ids,
            practiceReviewIDs: practiceReviews.snapshots.map(\.id),
            progressSenseIDs: progress.snapshots.map(\.senseID),
            matchingDeckIDs: matchingRecords.snapshots.map(\.deckID),
            matchingAttemptIDs: matchingAttempts.snapshots.map(\.id),
            deckPreferenceDeckIDs: deckPreferences.snapshots.map(\.deckID),
            practiceReviewSnapshots: practiceReviews.snapshots,
            progressSnapshots: progress.snapshots,
            matchingSnapshots: matchingRecords.snapshots,
            matchingAttemptSnapshots: matchingAttempts.snapshots,
            deckPreferenceSnapshots: deckPreferences.snapshots
        )
    }

    func markServerSyncBatchUploaded(
        _ batch: PendingServerSyncBatch,
        response: ServerSyncEventsResponse? = nil,
        syncedAt: Date = .now
    ) throws {
        try beginTransaction()
        do {
            let timestamp = syncedAt.timeIntervalSince1970
            if let response, !batch.progressSnapshots.isEmpty,
               response.progressSenseIds.isEmpty, response.rejectedProgressSenseIds.isEmpty {
                Self.logger.info(
                    "outbox mark acking submitted progress after 200 OK even though server returned empty progressSenseIds count=\(batch.progressSnapshots.count, privacy: .public)"
                )
            }

            var markedReviews = 0
            for reviewID in batch.reviewIDs {
                markedReviews += try markReviewSynced(reviewID: reviewID, syncedAt: timestamp)
            }

            var markedPracticeReviews = 0
            for snapshot in batch.practiceReviewSnapshots {
                markedPracticeReviews += try markPracticeReviewSynced(snapshot: snapshot, syncedAt: timestamp)
            }

            var markedProgress = 0
            var zeroRowProgress = 0
            for snapshot in batch.progressSnapshots {
                let changes = try markProgressSynced(snapshot: snapshot, syncedAt: timestamp)
                if changes == 0 {
                    zeroRowProgress += 1
                    Self.logger.warning(
                        "outbox mark updated 0 rows progress senseID=\(snapshot.senseID.uuidString, privacy: .public) updatedAtMs=\(Int(snapshot.updatedAt.timeIntervalSince1970 * 1000), privacy: .public) reason=updated_at_mismatch_or_already_synced"
                    )
                } else {
                    markedProgress += changes
                }
            }

            var markedMatchingRecords = 0
            var zeroRowMatchingRecords = 0
            for snapshot in batch.matchingSnapshots {
                let changes = try markMatchingRecordSynced(snapshot: snapshot, syncedAt: timestamp)
                if changes == 0 {
                    zeroRowMatchingRecords += 1
                    Self.logger.warning(
                        "outbox mark updated 0 rows matching deckID=\(snapshot.deckID.uuidString, privacy: .public) achievedAtMs=\(Int(snapshot.achievedAt.timeIntervalSince1970 * 1000), privacy: .public) reason=achieved_at_mismatch_or_already_synced"
                    )
                } else {
                    markedMatchingRecords += changes
                }
            }

            var markedMatchingAttempts = 0
            for snapshot in batch.matchingAttemptSnapshots {
                markedMatchingAttempts += try markMatchingAttemptSynced(snapshot: snapshot, syncedAt: timestamp)
            }

            var markedDeckPreferences = 0
            var zeroRowDeckPreferences = 0
            for snapshot in batch.deckPreferenceSnapshots {
                let changes = try markDeckPreferenceSynced(snapshot: snapshot, syncedAt: timestamp)
                if changes == 0 {
                    zeroRowDeckPreferences += 1
                    Self.logger.warning(
                        "outbox mark updated 0 rows deckPreference deckID=\(snapshot.deckID.uuidString, privacy: .public) updatedAtMs=\(Int(snapshot.updatedAt.timeIntervalSince1970 * 1000), privacy: .public) reason=updated_at_mismatch_or_already_synced"
                    )
                } else {
                    markedDeckPreferences += changes
                }
            }

            if let serverRevision = response?.serverRevision {
                try setServerRevision(serverRevision)
            }
            try commitTransaction()

            Self.logger.info(
                "outbox mark finished \(batch.diagnosticSummary, privacy: .public) markedRows reviews=\(markedReviews, privacy: .public) practice=\(markedPracticeReviews, privacy: .public) progress=\(markedProgress, privacy: .public) matching=\(markedMatchingRecords, privacy: .public) attempts=\(markedMatchingAttempts, privacy: .public) prefs=\(markedDeckPreferences, privacy: .public) zeroRow progress=\(zeroRowProgress, privacy: .public) matching=\(zeroRowMatchingRecords, privacy: .public) prefs=\(zeroRowDeckPreferences, privacy: .public)"
            )
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    private func pendingReviewEvents(limit: Int) throws -> (payload: [ServerReviewEventPayload], ids: [UUID]) {
        let sql = """
        SELECT study_reviews.id, study_reviews.deck_id, study_reviews.deck_version_id,
               study_reviews.card_id, study_reviews.sense_id, study_reviews.mode,
               study_reviews.outcome, study_reviews.source, study_reviews.reviewed_at, study_reviews.duration_ms,
               study_reviews.was_new, study_reviews.previous_state, study_reviews.new_state
        FROM study_reviews
        WHERE study_reviews.user_id = ?
          AND study_reviews.synced_at IS NULL
        ORDER BY study_reviews.reviewed_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerReviewEventPayload] = []
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let deckID = uuidColumn(statement, index: 1),
                  let cardID = uuidColumn(statement, index: 3),
                  let senseID = uuidColumn(statement, index: 4),
                  let mode = textColumn(statement, index: 5),
                  let outcome = textColumn(statement, index: 6) else { continue }
            let source = textColumn(statement, index: 7) ?? StudyReviewSource.deckSession.rawValue
            let durationMS: Int?
            if sqlite3_column_type(statement, 9) == SQLITE_NULL {
                durationMS = nil
            } else {
                durationMS = Int(sqlite3_column_int(statement, 9))
            }
            ids.append(id)
            payload.append(
                ServerReviewEventPayload(
                    clientEventId: id,
                    deckId: deckID,
                    deckVersionId: uuidColumn(statement, index: 2),
                    cardId: cardID,
                    senseId: senseID,
                    mode: mode,
                    outcome: outcome,
                    source: source,
                    reviewedAt: isoString(Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))),
                    durationMs: durationMS,
                    wasNew: sqlite3_column_int(statement, 10) != 0,
                    previousState: textColumn(statement, index: 11),
                    newState: textColumn(statement, index: 12)
                )
            )
        }
        return (payload, ids)
    }

    private func pendingPracticeReviews(limit: Int) throws -> (
        payload: [ServerPracticeReviewPayload],
        snapshots: [PendingPracticeReviewSnapshot]
    ) {
        let sql = """
        SELECT practice_reviews.id, practice_reviews.deck_id, practice_reviews.deck_version_id,
               practice_reviews.card_id, practice_reviews.sense_id,
               practice_reviews.mode, practice_reviews.outcome, practice_reviews.source,
               practice_reviews.practiced_at, practice_reviews.duration_ms
        FROM practice_reviews
        WHERE practice_reviews.user_id = ?
          AND practice_reviews.synced_at IS NULL
        ORDER BY practice_reviews.practiced_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerPracticeReviewPayload] = []
        var snapshots: [PendingPracticeReviewSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let deckID = uuidColumn(statement, index: 1),
                  let cardID = uuidColumn(statement, index: 3),
                  let senseID = uuidColumn(statement, index: 4),
                  let mode = textColumn(statement, index: 5),
                  let outcome = textColumn(statement, index: 6),
                  let source = textColumn(statement, index: 7) else { continue }
            let durationMS: Int?
            if sqlite3_column_type(statement, 9) == SQLITE_NULL {
                durationMS = nil
            } else {
                durationMS = Int(sqlite3_column_int(statement, 9))
            }
            snapshots.append(PendingPracticeReviewSnapshot(id: id))
            payload.append(
                ServerPracticeReviewPayload(
                    clientEventId: id,
                    deckId: deckID,
                    deckVersionId: uuidColumn(statement, index: 2),
                    cardId: cardID,
                    senseId: senseID,
                    mode: mode,
                    outcome: outcome,
                    source: source,
                    practicedAt: isoString(Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))),
                    durationMs: durationMS
                )
            )
        }
        return (payload, snapshots)
    }

    private func pendingProgressItems(limit: Int) throws -> (payload: [ServerProgressPayload], snapshots: [PendingProgressSnapshot]) {
        let sql = """
        SELECT sense_progress.sense_id, sense_progress.card_id, sense_progress.deck_id,
               sense_progress.fsrs_data, sense_progress.updated_at
        FROM sense_progress
        WHERE sense_progress.user_id = ?
          AND sense_progress.synced_at IS NULL
        ORDER BY sense_progress.updated_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerProgressPayload] = []
        var snapshots: [PendingProgressSnapshot] = []
        var repairs: [(deckID: UUID, progress: CardProgress)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let senseID = uuidColumn(statement, index: 0),
                  let cardID = uuidColumn(statement, index: 1),
                  let deckID = uuidColumn(statement, index: 2),
                  let blob = sqlite3_column_blob(statement, 3) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 3))
            let data = Data(bytes: blob, count: length)
            let fsrsCard: Card
            do {
                fsrsCard = try JSONDecoder().decode(Card.self, from: data)
            } catch {
                repairs.append((deckID, CardProgress.newSense(senseID: senseID, now: .now)))
                continue
            }
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            guard let fsrsJSON = JSONValue(jsonObject: jsonObject) else {
                throw ContentDatabaseError.queryFailed
            }
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            snapshots.append(PendingProgressSnapshot(senseID: senseID, updatedAt: updatedAt))
            payload.append(
                ServerProgressPayload(
                    senseId: senseID,
                    cardId: cardID,
                    deckId: deckID,
                    fsrsData: fsrsJSON,
                    dueAt: isoString(fsrsCard.due),
                    state: String(describing: fsrsCard.state),
                    updatedAt: isoString(updatedAt)
                )
            )
        }
        sqlite3_finalize(statement)
        for repair in repairs {
            try saveProgress(deckID: repair.deckID, progress: repair.progress)
        }
        return (payload, snapshots)
    }

    private func pendingMatchingRecords(limit: Int) throws -> (payload: [ServerMatchingRecordPayload], snapshots: [PendingMatchingRecordSnapshot]) {
        let sql = """
        SELECT deck_matching_records.deck_id, deck_matching_records.deck_version_id,
               deck_matching_records.best_duration_seconds,
               deck_matching_records.pair_count, deck_matching_records.achieved_at
        FROM deck_matching_records
        WHERE deck_matching_records.user_id = ?
          AND deck_matching_records.synced_at IS NULL
        ORDER BY deck_matching_records.achieved_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerMatchingRecordPayload] = []
        var snapshots: [PendingMatchingRecordSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let deckID = uuidColumn(statement, index: 0) else { continue }
            let achievedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            snapshots.append(PendingMatchingRecordSnapshot(deckID: deckID, achievedAt: achievedAt))
            payload.append(
                ServerMatchingRecordPayload(
                    deckId: deckID,
                    deckVersionId: uuidColumn(statement, index: 1),
                    bestDurationSeconds: sqlite3_column_double(statement, 2),
                    pairCount: Int(sqlite3_column_int(statement, 3)),
                    achievedAt: isoString(achievedAt)
                )
            )
        }
        return (payload, snapshots)
    }

    private func pendingMatchingAttempts(limit: Int) throws -> (
        payload: [ServerMatchingAttemptPayload],
        snapshots: [PendingMatchingAttemptSnapshot]
    ) {
        let sql = """
        SELECT matching_attempts.id, matching_attempts.deck_id, matching_attempts.deck_version_id,
               matching_attempts.mode,
               matching_attempts.source, matching_attempts.completed_at,
               matching_attempts.duration_ms, matching_attempts.pair_count
        FROM matching_attempts
        WHERE matching_attempts.user_id = ?
          AND matching_attempts.synced_at IS NULL
        ORDER BY matching_attempts.completed_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerMatchingAttemptPayload] = []
        var snapshots: [PendingMatchingAttemptSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let mode = textColumn(statement, index: 3),
                  let source = textColumn(statement, index: 4) else { continue }
            snapshots.append(PendingMatchingAttemptSnapshot(id: id))
            payload.append(
                ServerMatchingAttemptPayload(
                    clientEventId: id,
                    deckId: uuidColumn(statement, index: 1),
                    deckVersionId: uuidColumn(statement, index: 2),
                    mode: mode,
                    source: source,
                    completedAt: isoString(Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))),
                    durationMs: Int(sqlite3_column_int(statement, 6)),
                    pairCount: Int(sqlite3_column_int(statement, 7))
                )
            )
        }
        return (payload, snapshots)
    }

    private func pendingDeckPreferences(limit: Int) throws -> (payload: [ServerDeckPreferencePayload], snapshots: [PendingDeckPreferenceSnapshot]) {
        let sql = """
        SELECT user_deck_preferences.deck_id,
               user_deck_preferences.is_enabled,
               user_deck_preferences.updated_at
        FROM user_deck_preferences
        JOIN user_deck_assignments ON user_deck_assignments.user_id = user_deck_preferences.user_id
            AND user_deck_assignments.deck_id = user_deck_preferences.deck_id
        WHERE user_deck_preferences.user_id = ?
          AND user_deck_preferences.synced_at IS NULL
        ORDER BY user_deck_preferences.updated_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerDeckPreferencePayload] = []
        var snapshots: [PendingDeckPreferenceSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let deckID = uuidColumn(statement, index: 0) else { continue }
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            snapshots.append(PendingDeckPreferenceSnapshot(deckID: deckID, updatedAt: updatedAt))
            payload.append(
                ServerDeckPreferencePayload(
                    deckId: deckID,
                    isEnabled: sqlite3_column_int(statement, 1) != 0,
                    updatedAt: isoString(updatedAt)
                )
            )
        }
        return (payload, snapshots)
    }

    @discardableResult
    private func markReviewSynced(reviewID: UUID, syncedAt: Double) throws -> Int {
        try markSynced(
            sql: "UPDATE study_reviews SET synced_at = ? WHERE user_id = ? AND id = ?",
            id: reviewID,
            syncedAt: syncedAt
        )
    }

    @discardableResult
    private func markPracticeReviewSynced(snapshot: PendingPracticeReviewSnapshot, syncedAt: Double) throws -> Int {
        try markSynced(
            sql: "UPDATE practice_reviews SET synced_at = ? WHERE user_id = ? AND id = ?",
            id: snapshot.id,
            syncedAt: syncedAt
        )
    }

    @discardableResult
    private func markProgressSynced(snapshot: PendingProgressSnapshot, syncedAt: Double) throws -> Int {
        try markSynced(
            sql: "UPDATE sense_progress SET synced_at = ? WHERE user_id = ? AND sense_id = ? AND updated_at = ?",
            id: snapshot.senseID,
            syncedAt: syncedAt,
            unchangedAt: snapshot.updatedAt.timeIntervalSince1970
        )
    }

    @discardableResult
    private func markMatchingRecordSynced(snapshot: PendingMatchingRecordSnapshot, syncedAt: Double) throws -> Int {
        try markSynced(
            sql: "UPDATE deck_matching_records SET synced_at = ? WHERE user_id = ? AND deck_id = ? AND achieved_at = ?",
            id: snapshot.deckID,
            syncedAt: syncedAt,
            unchangedAt: snapshot.achievedAt.timeIntervalSince1970
        )
    }

    @discardableResult
    private func markMatchingAttemptSynced(snapshot: PendingMatchingAttemptSnapshot, syncedAt: Double) throws -> Int {
        try markSynced(
            sql: "UPDATE matching_attempts SET synced_at = ? WHERE user_id = ? AND id = ?",
            id: snapshot.id,
            syncedAt: syncedAt
        )
    }

    @discardableResult
    private func markDeckPreferenceSynced(snapshot: PendingDeckPreferenceSnapshot, syncedAt: Double) throws -> Int {
        try markSynced(
            sql: "UPDATE user_deck_preferences SET synced_at = ? WHERE user_id = ? AND deck_id = ? AND updated_at = ?",
            id: snapshot.deckID,
            syncedAt: syncedAt,
            unchangedAt: snapshot.updatedAt.timeIntervalSince1970
        )
    }

    @discardableResult
    private func markSynced(sql: String, id: UUID, syncedAt: Double, unchangedAt: Double? = nil) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, syncedAt) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 2, uuid: userID)
        try bind(statement, index: 3, uuid: id)
        if let unchangedAt {
            guard sqlite3_bind_double(statement, 4, unchangedAt) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Server content import

    private func replaceAssignments(_ assignments: [ServerDeckAssignment], selectedUserID: UUID) throws {
        try exec("DELETE FROM user_deck_assignments WHERE user_id = ?", uuid: selectedUserID)
        try upsertAssignments(assignments, selectedUserID: selectedUserID)
    }

    private func upsertAssignments(_ assignments: [ServerDeckAssignment], selectedUserID: UUID) throws {
        for assignment in assignments where assignment.userId == selectedUserID {
            let sql = """
            INSERT INTO user_deck_assignments (
                user_id, deck_id, status, deck_group_id, deck_group_title,
                deck_group_sort_order, deck_sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, deck_id) DO UPDATE SET
                status = excluded.status,
                deck_group_id = excluded.deck_group_id,
                deck_group_title = excluded.deck_group_title,
                deck_group_sort_order = excluded.deck_group_sort_order,
                deck_sort_order = excluded.deck_sort_order
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: selectedUserID)
            try bind(statement, index: 2, uuid: assignment.deckId)
            try bind(statement, index: 3, text: assignmentStatusValue(assignment.assignmentStatus))
            try bind(statement, index: 4, uuid: assignment.deckGroupId)
            try bind(statement, index: 5, text: assignment.deckGroupTitle)
            try bind(statement, index: 6, int: assignment.deckGroupSortOrder)
            try bind(statement, index: 7, int: assignment.deckSortOrder ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertServerDeckPreferences(_ assignments: [ServerDeckAssignment], selectedUserID: UUID) throws {
        let syncedAt = Date().timeIntervalSince1970
        for assignment in assignments where assignment.userId == selectedUserID {
            let updatedAt = parseServerDate(assignment.preferenceUpdatedAt)?.timeIntervalSince1970 ?? 0
            let sql = """
            INSERT INTO user_deck_preferences (user_id, deck_id, is_enabled, updated_at, synced_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(user_id, deck_id) DO UPDATE SET
                is_enabled = excluded.is_enabled,
                updated_at = excluded.updated_at,
                synced_at = excluded.synced_at
            WHERE user_deck_preferences.synced_at IS NOT NULL
               OR excluded.updated_at >= user_deck_preferences.updated_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: selectedUserID)
            try bind(statement, index: 2, uuid: assignment.deckId)
            guard sqlite3_bind_int(statement, 3, (assignment.userEnabled ?? true) ? 1 : 0) == SQLITE_OK,
                  sqlite3_bind_double(statement, 4, updatedAt) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertServerUserSettings(_ settings: [ServerUserSettingsPayload], selectedUserID: UUID) throws {
        for setting in settings where setting.userId == selectedUserID {
            let updatedAt = parseServerDate(setting.updatedAt)?.timeIntervalSince1970 ?? 0
            let serverRevision = Int64(setting.serverRevision ?? "0") ?? 0
            let randomCardCount = max(
                UserStudySettingsDefaults.minimumRandomCardCount,
                setting.randomCardCount
            )
            let sql = """
            INSERT INTO user_settings (user_id, random_card_count, updated_at, server_revision)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                random_card_count = excluded.random_card_count,
                updated_at = excluded.updated_at,
                server_revision = excluded.server_revision
            WHERE excluded.server_revision >= user_settings.server_revision
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: selectedUserID)
            guard sqlite3_bind_int(statement, 2, Int32(randomCardCount)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 3, updatedAt) == SQLITE_OK,
                  sqlite3_bind_int64(statement, 4, serverRevision) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertMediaObjects(_ mediaObjects: [ServerMediaObject]) throws {
        for media in mediaObjects {
            let sql = """
            INSERT INTO media_objects (id, storage_key, sha256, mime_type, byte_size, width, height)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                storage_key = excluded.storage_key,
                sha256 = excluded.sha256,
                mime_type = excluded.mime_type,
                byte_size = excluded.byte_size,
                width = excluded.width,
                height = excluded.height
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: media.id)
            try bind(statement, index: 2, text: media.storageKey)
            try bind(statement, index: 3, text: media.sha256)
            try bind(statement, index: 4, text: media.mimeType)
            try bind(statement, index: 5, int: media.byteSize)
            try bind(statement, index: 6, int: media.width)
            try bind(statement, index: 7, int: media.height)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertDecks(_ assignments: [ServerDeckAssignment]) throws {
        for assignment in assignments {
            let manifest = assignment.manifest
            let sql = """
            INSERT INTO decks (
                id, status, title, avatar_system_name, avatar_media_id, language_code,
                new_cards_per_day, review_cards_per_day
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                title = excluded.title,
                avatar_system_name = excluded.avatar_system_name,
                avatar_media_id = excluded.avatar_media_id,
                language_code = excluded.language_code,
                new_cards_per_day = excluded.new_cards_per_day,
                review_cards_per_day = excluded.review_cards_per_day
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: assignment.deckId)
            try bind(statement, index: 2, text: localStatus(assignment.assignmentStatus).rawValue)
            try bind(statement, index: 3, text: assignment.title)
            try bind(statement, index: 4, text: assignment.avatarSystemName)
            try bind(statement, index: 5, uuid: assignment.avatarMediaId)
            try bind(statement, index: 6, text: assignment.languageCode)
            try bind(statement, index: 7, int: manifest?.newCardsPerDay ?? 12)
            try bind(statement, index: 8, int: manifest?.reviewCardsPerDay ?? 80)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func deleteDeckContent(deckID: UUID) throws {
        let deckID = deckID.databaseString
        let statements = [
            """
            DELETE FROM question_distractors
            WHERE sense_id IN (
                SELECT sentence_questions.sense_id
                FROM sentence_questions
                JOIN cards ON cards.id = sentence_questions.card_id
                WHERE cards.deck_id = '\(deckID)'
            )
            """,
            """
            DELETE FROM word_forms
            WHERE card_id IN (SELECT id FROM cards WHERE deck_id = '\(deckID)')
            """,
            """
            DELETE FROM card_examples
            WHERE card_id IN (SELECT id FROM cards WHERE deck_id = '\(deckID)')
            """,
            """
            DELETE FROM sentence_questions
            WHERE card_id IN (SELECT id FROM cards WHERE deck_id = '\(deckID)')
            """,
            """
            DELETE FROM card_senses
            WHERE card_id IN (SELECT id FROM cards WHERE deck_id = '\(deckID)')
            """,
            "UPDATE cards SET status = 'inactive' WHERE deck_id = '\(deckID)'",
        ]
        try executeMigrationStatements(statements)
    }

    private func fetchDeckIDsWithoutAssignments() throws -> [UUID] {
        let sql = """
        SELECT decks.id
        FROM decks
        WHERE NOT EXISTS (
            SELECT 1
            FROM user_deck_assignments
            WHERE user_deck_assignments.deck_id = decks.id
        )
        ORDER BY decks.id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var deckIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let deckID = uuidColumn(statement, index: 0) {
                deckIDs.append(deckID)
            }
        }
        return deckIDs
    }

    private func deleteRowsForDecksWithoutAssignments() throws {
        let orphanDecks = """
        SELECT decks.id
        FROM decks
        WHERE NOT EXISTS (
            SELECT 1
            FROM user_deck_assignments
            WHERE user_deck_assignments.deck_id = decks.id
        )
        """
        let orphanCards = "SELECT cards.id FROM cards WHERE cards.deck_id IN (\(orphanDecks))"
        let orphanSenses = "SELECT card_senses.id FROM card_senses WHERE card_senses.card_id IN (\(orphanCards))"
        let statements = [
            "DELETE FROM question_distractors WHERE sense_id IN (\(orphanSenses))",
            "DELETE FROM question_distractors WHERE source_card_id IN (\(orphanCards))",
            "DELETE FROM word_forms WHERE card_id IN (\(orphanCards))",
            "DELETE FROM card_examples WHERE card_id IN (\(orphanCards))",
            "DELETE FROM sentence_questions WHERE card_id IN (\(orphanCards))",
            "DELETE FROM card_senses WHERE card_id IN (\(orphanCards))",
            "DELETE FROM sense_progress WHERE deck_id IN (\(orphanDecks))",
            "DELETE FROM deck_daily_usage WHERE deck_id IN (\(orphanDecks))",
            "DELETE FROM deck_matching_records WHERE deck_id IN (\(orphanDecks))",
            "DELETE FROM user_deck_preferences WHERE deck_id IN (\(orphanDecks))",
            "DELETE FROM cards WHERE deck_id IN (\(orphanDecks))",
            "DELETE FROM decks WHERE id IN (\(orphanDecks))",
        ]
        try executeMigrationStatements(statements)
    }

    private func deleteUnreferencedMediaObjects() throws {
        let sql = """
        DELETE FROM media_objects
        WHERE id NOT IN (
            SELECT avatar_media_id FROM decks WHERE avatar_media_id IS NOT NULL
            UNION
            SELECT audio_word_media_id FROM cards WHERE audio_word_media_id IS NOT NULL
            UNION
            SELECT image_media_id FROM card_senses WHERE image_media_id IS NOT NULL
            UNION
            SELECT audio_answer_media_id FROM sentence_questions WHERE audio_answer_media_id IS NOT NULL
        )
        """
        try exec(sql)
    }

    private func upsertCards(_ cards: [ServerCardContent], versionDeckIDs: [UUID: UUID]) throws {
        for card in cards {
            guard let deckID = versionDeckIDs[card.deckVersionId] else { continue }
            let sql = """
            INSERT INTO cards (
                id, deck_id, status, lemma, display_word, part_of_speech, etymology,
                notes, primary_sense_id, audio_word_media_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                deck_id = excluded.deck_id,
                status = excluded.status,
                lemma = excluded.lemma,
                display_word = excluded.display_word,
                part_of_speech = excluded.part_of_speech,
                etymology = excluded.etymology,
                notes = excluded.notes,
                primary_sense_id = excluded.primary_sense_id,
                audio_word_media_id = excluded.audio_word_media_id
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: card.cardId)
            try bind(statement, index: 2, uuid: deckID)
            try bind(statement, index: 3, text: localStatus(card.status).rawValue)
            try bind(statement, index: 4, text: card.lemma)
            try bind(statement, index: 5, text: card.displayWord)
            try bind(statement, index: 6, text: card.partOfSpeech)
            try bind(statement, index: 7, text: card.etymology)
            try bind(statement, index: 8, text: card.notes)
            try bind(statement, index: 9, uuid: card.primarySenseId)
            try bind(statement, index: 10, uuid: card.audioWordMediaId)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertSenses(_ senses: [ServerSenseContent]) throws {
        for sense in senses {
            let sql = """
            INSERT INTO card_senses (
                id, card_id, status, display_pattern, translation, note, image_media_id, sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                card_id = excluded.card_id,
                status = excluded.status,
                display_pattern = excluded.display_pattern,
                translation = excluded.translation,
                note = excluded.note,
                image_media_id = excluded.image_media_id,
                sort_order = excluded.sort_order
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: sense.senseId)
            try bind(statement, index: 2, uuid: sense.cardId)
            try bind(statement, index: 3, text: localStatus(sense.status).rawValue)
            try bind(statement, index: 4, text: sense.displayPattern)
            try bind(statement, index: 5, text: sense.translation)
            try bind(statement, index: 6, text: sense.note)
            try bind(statement, index: 7, uuid: sense.imageMediaId)
            try bind(statement, index: 8, int: sense.sortOrder ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertExamples(_ examples: [ServerExampleContent]) throws {
        for example in examples {
            let sql = """
            INSERT INTO card_examples (
                sense_id, card_id, text, translation, note,
                sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(sense_id) DO UPDATE SET
                card_id = excluded.card_id,
                text = excluded.text,
                translation = excluded.translation,
                note = excluded.note,
                sort_order = excluded.sort_order
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: example.senseId)
            try bind(statement, index: 2, uuid: example.cardId)
            try bind(statement, index: 3, text: example.text)
            try bind(statement, index: 4, text: example.translation)
            try bind(statement, index: 5, text: example.note)
            try bind(statement, index: 6, int: example.sortOrder ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertSentenceQuestions(_ questions: [ServerSentenceQuestionContent]) throws {
        for question in questions {
            let sql = """
            INSERT INTO sentence_questions (sense_id, card_id, template, answer, translation, answer_form_key, audio_answer_media_id, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sense_id) DO UPDATE SET
                card_id = excluded.card_id,
                template = excluded.template,
                answer = excluded.answer,
                translation = excluded.translation,
                answer_form_key = excluded.answer_form_key,
                audio_answer_media_id = excluded.audio_answer_media_id,
                sort_order = excluded.sort_order
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: question.senseId)
            try bind(statement, index: 2, uuid: question.cardId)
            try bind(statement, index: 3, text: question.template)
            try bind(statement, index: 4, text: question.answer)
            try bind(statement, index: 5, text: question.translation)
            try bind(statement, index: 6, text: question.answerFormKey)
            try bind(statement, index: 7, uuid: question.audioAnswerMediaId)
            try bind(statement, index: 8, int: question.sortOrder ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertForms(_ forms: [ServerWordFormContent]) throws {
        for form in forms {
            let sql = """
            INSERT INTO word_forms (card_id, form_key, text, sort_order)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(card_id, form_key, text) DO UPDATE SET
                sort_order = excluded.sort_order
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: form.cardId)
            try bind(statement, index: 2, text: form.formKey)
            try bind(statement, index: 3, text: form.text)
            try bind(statement, index: 4, int: form.sortOrder ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertDistractors(_ distractors: [ServerDistractorContent]) throws {
        for distractor in distractors {
            let sql = """
            INSERT INTO question_distractors (id, sense_id, text, source_card_id, priority)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                sense_id = excluded.sense_id,
                text = excluded.text,
                source_card_id = excluded.source_card_id,
                priority = excluded.priority
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: distractor.id)
            try bind(statement, index: 2, uuid: distractor.senseId)
            try bind(statement, index: 3, text: distractor.text)
            try bind(statement, index: 4, uuid: distractor.sourceCardId)
            try bind(statement, index: 5, int: distractor.priority ?? 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func markContentVersionsImported(_ versionIDs: Set<UUID>, versionDeckIDs: [UUID: UUID]) throws {
        for versionID in versionIDs {
            guard let deckID = versionDeckIDs[versionID] else { continue }
            let sql = "UPDATE decks SET content_version_id = ? WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: versionID)
            try bind(statement, index: 2, uuid: deckID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertServerProgress(_ progressItems: [ServerProgressPayload]) throws {
        let syncedAt = Date().timeIntervalSince1970
        for progress in progressItems {
            let data = try JSONEncoder().encode(progress.fsrsData)
            let updatedAt = parseServerDate(progress.updatedAt)?.timeIntervalSince1970 ?? syncedAt
            let sql = """
            INSERT INTO sense_progress (user_id, sense_id, card_id, deck_id, fsrs_data, updated_at, synced_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, sense_id) DO UPDATE SET
                card_id = excluded.card_id,
                deck_id = excluded.deck_id,
                fsrs_data = excluded.fsrs_data,
                updated_at = excluded.updated_at,
                synced_at = excluded.synced_at
            WHERE sense_progress.synced_at IS NOT NULL
               OR excluded.updated_at >= sense_progress.updated_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: userID)
            try bind(statement, index: 2, uuid: progress.senseId)
            try bind(statement, index: 3, uuid: progress.cardId)
            try bind(statement, index: 4, uuid: progress.deckId)
            try data.withUnsafeBytes { raw in
                guard sqlite3_bind_blob(statement, 5, raw.baseAddress, Int32(data.count), sqliteTransient) == SQLITE_OK else {
                    throw ContentDatabaseError.queryFailed
                }
            }
            guard sqlite3_bind_double(statement, 6, updatedAt) == SQLITE_OK,
                  sqlite3_bind_double(statement, 7, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func deleteSyncedProgressMissingFromServerSnapshot(_ progressItems: [ServerProgressPayload]) throws {
        let senseIDs = Array(Set(progressItems.map(\.senseId))).sorted { $0.uuidString < $1.uuidString }
        let placeholders = senseIDs.map { _ in "?" }.joined(separator: ", ")
        let sql: String
        if senseIDs.isEmpty {
            sql = "DELETE FROM sense_progress WHERE user_id = ? AND synced_at IS NOT NULL"
        } else {
            sql = """
            DELETE FROM sense_progress
            WHERE user_id = ?
              AND synced_at IS NOT NULL
              AND sense_id NOT IN (\(placeholders))
            """
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        for (offset, senseID) in senseIDs.enumerated() {
            try bind(statement, index: Int32(offset + 2), uuid: senseID)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func applyStudyDataResets(_ resets: [ServerStudyDataResetPayload], selectedUserID: UUID) throws {
        for reset in resets where reset.userId == selectedUserID {
            try deleteSyncedStudyData(deckID: reset.deckId)
        }
    }

    private func deleteSyncedStudyData(deckID: UUID?) throws {
        try deleteSyncedRows(table: "study_reviews", deckID: deckID)
        try deleteSyncedRows(table: "practice_reviews", deckID: deckID)
        try deleteSyncedRows(table: "sense_progress", deckID: deckID)
        try deleteSyncedRows(table: "deck_matching_records", deckID: deckID)
        try deleteSyncedRows(table: "matching_attempts", deckID: deckID)
    }

    private func deleteSyncedRows(table: String, deckID: UUID?) throws {
        let sql: String
        if deckID == nil {
            sql = "DELETE FROM \(table) WHERE user_id = ? AND synced_at IS NOT NULL"
        } else {
            sql = "DELETE FROM \(table) WHERE user_id = ? AND deck_id = ? AND synced_at IS NOT NULL"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        if let deckID {
            try bind(statement, index: 2, uuid: deckID)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func upsertServerReviews(_ reviews: [ServerReviewEventPayload], selectedUserID: UUID) throws {
        let syncedAt = Date().timeIntervalSince1970
        for review in reviews {
            guard let reviewedAt = parseServerDate(review.reviewedAt) else {
                throw ContentDatabaseError.queryFailed
            }
            let sql = """
            INSERT INTO study_reviews (
                id, user_id, card_id, sense_id, deck_id, deck_version_id, mode, outcome, source, reviewed_at,
                duration_ms, was_new, previous_state, new_state, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                card_id = excluded.card_id,
                sense_id = excluded.sense_id,
                deck_id = excluded.deck_id,
                deck_version_id = excluded.deck_version_id,
                mode = excluded.mode,
                outcome = excluded.outcome,
                source = excluded.source,
                reviewed_at = excluded.reviewed_at,
                duration_ms = excluded.duration_ms,
                was_new = excluded.was_new,
                previous_state = excluded.previous_state,
                new_state = excluded.new_state,
                synced_at = excluded.synced_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: review.clientEventId)
            try bind(statement, index: 2, uuid: selectedUserID)
            try bind(statement, index: 3, uuid: review.cardId)
            try bind(statement, index: 4, uuid: review.senseId)
            try bind(statement, index: 5, uuid: review.deckId)
            try bind(statement, index: 6, uuid: review.deckVersionId)
            try bind(statement, index: 7, text: review.mode)
            try bind(statement, index: 8, text: review.outcome)
            try bind(statement, index: 9, text: review.source ?? StudyReviewSource.deckSession.rawValue)
            guard sqlite3_bind_double(statement, 10, reviewedAt.timeIntervalSince1970) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            try bind(statement, index: 11, int: review.durationMs)
            guard sqlite3_bind_int(statement, 12, review.wasNew ? 1 : 0) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            try bind(statement, index: 13, text: review.previousState)
            try bind(statement, index: 14, text: review.newState)
            guard sqlite3_bind_double(statement, 15, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertServerPracticeReviews(
        _ reviews: [ServerPracticeReviewPayload],
        selectedUserID: UUID
    ) throws {
        let syncedAt = Date().timeIntervalSince1970
        for review in reviews {
            guard let practicedAt = parseServerDate(review.practicedAt) else {
                throw ContentDatabaseError.queryFailed
            }
            let sql = """
            INSERT INTO practice_reviews (
                id, user_id, card_id, sense_id, deck_id, deck_version_id, mode, outcome, source, practiced_at, duration_ms, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                card_id = excluded.card_id,
                sense_id = excluded.sense_id,
                deck_id = excluded.deck_id,
                deck_version_id = excluded.deck_version_id,
                mode = excluded.mode,
                outcome = excluded.outcome,
                source = excluded.source,
                practiced_at = excluded.practiced_at,
                duration_ms = excluded.duration_ms,
                synced_at = excluded.synced_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: review.clientEventId)
            try bind(statement, index: 2, uuid: selectedUserID)
            try bind(statement, index: 3, uuid: review.cardId)
            try bind(statement, index: 4, uuid: review.senseId)
            try bind(statement, index: 5, uuid: review.deckId)
            try bind(statement, index: 6, uuid: review.deckVersionId)
            try bind(statement, index: 7, text: localStudyModeRawValue(review.mode))
            try bind(statement, index: 8, text: review.outcome)
            try bind(statement, index: 9, text: review.source)
            guard sqlite3_bind_double(statement, 10, practicedAt.timeIntervalSince1970) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            try bind(statement, index: 11, int: review.durationMs)
            guard sqlite3_bind_double(statement, 12, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertServerMatchingRecords(
        _ records: [ServerMatchingRecordPayload],
        selectedUserID: UUID
    ) throws {
        let syncedAt = Date().timeIntervalSince1970
        for record in records {
            guard let achievedAt = parseServerDate(record.achievedAt) else {
                throw ContentDatabaseError.queryFailed
            }
            let sql = """
            INSERT INTO deck_matching_records (user_id, deck_id, deck_version_id, best_duration_seconds, pair_count, achieved_at, synced_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, deck_id) DO UPDATE SET
                deck_version_id = excluded.deck_version_id,
                best_duration_seconds = excluded.best_duration_seconds,
                pair_count = excluded.pair_count,
                achieved_at = excluded.achieved_at,
                synced_at = excluded.synced_at
            WHERE deck_matching_records.synced_at IS NOT NULL
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: selectedUserID)
            try bind(statement, index: 2, uuid: record.deckId)
            try bind(statement, index: 3, uuid: record.deckVersionId)
            guard sqlite3_bind_double(statement, 4, record.bestDurationSeconds) == SQLITE_OK,
                  sqlite3_bind_int(statement, 5, Int32(record.pairCount)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 6, achievedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 7, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertServerMatchingAttempts(
        _ attempts: [ServerMatchingAttemptPayload],
        selectedUserID: UUID
    ) throws {
        let syncedAt = Date().timeIntervalSince1970
        for attempt in attempts {
            guard let completedAt = parseServerDate(attempt.completedAt) else {
                throw ContentDatabaseError.queryFailed
            }
            let sql = """
            INSERT INTO matching_attempts (
                id, user_id, deck_id, deck_version_id, mode, source, completed_at, duration_ms, pair_count, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                deck_id = excluded.deck_id,
                deck_version_id = excluded.deck_version_id,
                mode = excluded.mode,
                source = excluded.source,
                completed_at = excluded.completed_at,
                duration_ms = excluded.duration_ms,
                pair_count = excluded.pair_count,
                synced_at = excluded.synced_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: attempt.clientEventId)
            try bind(statement, index: 2, uuid: selectedUserID)
            try bind(statement, index: 3, uuid: attempt.deckId)
            try bind(statement, index: 4, uuid: attempt.deckVersionId)
            try bind(statement, index: 5, text: localStudyModeRawValue(attempt.mode))
            try bind(statement, index: 6, text: attempt.source)
            guard sqlite3_bind_double(statement, 7, completedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_int(statement, 8, Int32(attempt.durationMs)) == SQLITE_OK,
                  sqlite3_bind_int(statement, 9, Int32(attempt.pairCount)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 10, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func localStatus(_ value: String) -> ContentStatus {
        value == "active" ? .active : .inactive
    }

    private func assignmentStatusValue(_ value: String) -> String {
        switch value {
        case "active", "inactive", "archived":
            value
        default:
            "inactive"
        }
    }

    private func localStudyModeRawValue(_ value: String) -> String {
        switch value {
        case "cloze_multiple_choice":
            StudyMode.clozeMultipleChoice.rawValue
        case "cloze_typing":
            StudyMode.clozeTyping.rawValue
        case "matching_audio":
            StudyMode.matchingAudio.rawValue
        default:
            value
        }
    }

    private func parseServerDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func rebuildDerivedStats(selectedUserID: UUID) throws {
        try exec("DELETE FROM deck_daily_usage WHERE user_id = ?", uuid: selectedUserID)

        let sql = """
        INSERT INTO deck_daily_usage (user_id, deck_id, day_key, new_cards_studied)
        SELECT
            user_id,
            deck_id,
            strftime('%Y-%m-%d', reviewed_at, 'unixepoch', 'localtime', '-4 hours') AS day_key,
            COUNT(DISTINCT CASE WHEN was_new = 1 AND outcome IN ('remembered', 'correct') THEN card_id END) AS new_cards_studied
        FROM study_reviews
        WHERE user_id = ?
        GROUP BY user_id, deck_id, day_key
        HAVING new_cards_studied > 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: selectedUserID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func refreshDailyUsage(deckID: UUID, dayKey: String) throws {
        let sql = """
        SELECT COUNT(DISTINCT card_id)
        FROM study_reviews
        WHERE user_id = ?
          AND deck_id = ?
          AND was_new = 1
          AND outcome IN ('remembered', 'correct')
          AND strftime('%Y-%m-%d', reviewed_at, 'unixepoch', 'localtime', '-4 hours') = ?
        """
        let count: Int = try {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: userID)
            try bind(statement, index: 2, uuid: deckID)
            try bind(statement, index: 3, text: dayKey)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ContentDatabaseError.queryFailed
            }
            return Int(sqlite3_column_int(statement, 0))
        }()

        if count > 0 {
            try saveDailyUsage(deckID: deckID, usage: DeckDailyUsage(dayKey: dayKey, newCardsStudied: count))
        } else {
            try deleteDailyUsage(deckID: deckID, dayKey: dayKey)
        }
    }

    private func deleteDailyUsage(deckID: UUID, dayKey: String) throws {
        let sql = "DELETE FROM deck_daily_usage WHERE user_id = ? AND deck_id = ? AND day_key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)
        try bind(statement, index: 3, text: dayKey)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func setSyncMetadata(_ key: String, value: String, selectedUserID: UUID) throws {
        let sql = """
        INSERT INTO sync_metadata (user_id, key, value)
        VALUES (?, ?, ?)
        ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: selectedUserID)
        try bind(statement, index: 2, text: key)
        try bind(statement, index: 3, text: value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func syncMetadataValue(_ key: String) throws -> String? {
        let sql = """
        SELECT value
        FROM sync_metadata
        WHERE user_id = ? AND key = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, text: key)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, index: 0)
    }

    // MARK: - Schema

    private func executeMigrations() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
            title TEXT NOT NULL,
            avatar_system_name TEXT,
            avatar_media_id TEXT,
            content_version_id TEXT,
            language_code TEXT NOT NULL,
            new_cards_per_day INTEGER NOT NULL,
            review_cards_per_day INTEGER NOT NULL,
            FOREIGN KEY (avatar_media_id) REFERENCES media_objects(id)
        );
        CREATE TABLE IF NOT EXISTS user_deck_assignments (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'archived')),
            deck_group_id TEXT,
            deck_group_title TEXT,
            deck_group_sort_order INTEGER,
            deck_sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (user_id, deck_id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_user_deck_assignments_user_id ON user_deck_assignments(user_id);
        CREATE TABLE IF NOT EXISTS user_deck_preferences (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            updated_at REAL NOT NULL,
            synced_at REAL,
            PRIMARY KEY (user_id, deck_id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_user_deck_preferences_user_id ON user_deck_preferences(user_id);
        CREATE TABLE IF NOT EXISTS user_settings (
            user_id TEXT PRIMARY KEY NOT NULL,
            random_card_count INTEGER NOT NULL DEFAULT 30,
            updated_at REAL NOT NULL DEFAULT 0,
            server_revision INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS media_objects (
            id TEXT PRIMARY KEY NOT NULL,
            storage_key TEXT,
            local_path TEXT,
            sha256 TEXT,
            mime_type TEXT,
            byte_size INTEGER,
            width INTEGER,
            height INTEGER
        );
        CREATE TABLE IF NOT EXISTS cards (
            id TEXT PRIMARY KEY NOT NULL,
            deck_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
            lemma TEXT NOT NULL,
            display_word TEXT NOT NULL,
            part_of_speech TEXT,
            etymology TEXT,
            notes TEXT,
            primary_sense_id TEXT,
            audio_word_media_id TEXT,
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_cards_deck_id ON cards(deck_id);
        CREATE TABLE IF NOT EXISTS card_senses (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
            display_pattern TEXT,
            translation TEXT NOT NULL,
            note TEXT,
            image_media_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
        CREATE INDEX IF NOT EXISTS idx_card_senses_card_id ON card_senses(card_id);
        CREATE TABLE IF NOT EXISTS card_examples (
            sense_id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            text TEXT NOT NULL,
            translation TEXT,
            note TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (card_id) REFERENCES cards(id),
            FOREIGN KEY (sense_id) REFERENCES card_senses(id)
        );
        CREATE INDEX IF NOT EXISTS idx_card_examples_card_id ON card_examples(card_id);
        CREATE TABLE IF NOT EXISTS sentence_questions (
            sense_id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            template TEXT NOT NULL,
            answer TEXT NOT NULL,
            translation TEXT,
            answer_form_key TEXT,
            audio_answer_media_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (card_id) REFERENCES cards(id),
            FOREIGN KEY (sense_id) REFERENCES card_senses(id)
        );
        CREATE INDEX IF NOT EXISTS idx_sentence_questions_card_id ON sentence_questions(card_id);
        CREATE TABLE IF NOT EXISTS word_forms (
            card_id TEXT NOT NULL,
            form_key TEXT NOT NULL,
            text TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (card_id, form_key, text),
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
        CREATE INDEX IF NOT EXISTS idx_word_forms_form_key ON word_forms(form_key);
        CREATE TABLE IF NOT EXISTS question_distractors (
            id TEXT PRIMARY KEY NOT NULL,
            sense_id TEXT NOT NULL,
            text TEXT NOT NULL,
            source_card_id TEXT,
            priority INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (sense_id) REFERENCES sentence_questions(sense_id),
            FOREIGN KEY (source_card_id) REFERENCES cards(id)
        );
        CREATE INDEX IF NOT EXISTS idx_question_distractors_sense_id ON question_distractors(sense_id);
        CREATE TABLE IF NOT EXISTS sense_progress (
            user_id TEXT NOT NULL,
            sense_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            fsrs_data BLOB NOT NULL,
            updated_at REAL NOT NULL,
            synced_at REAL,
            PRIMARY KEY (user_id, sense_id),
            FOREIGN KEY (sense_id) REFERENCES card_senses(id),
            FOREIGN KEY (card_id) REFERENCES cards(id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_sense_progress_deck_id ON sense_progress(deck_id);
        CREATE TABLE IF NOT EXISTS deck_daily_usage (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            day_key TEXT NOT NULL,
            new_cards_studied INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (user_id, deck_id, day_key),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE TABLE IF NOT EXISTS sync_metadata (
            user_id TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (user_id, key)
        );
        CREATE TABLE IF NOT EXISTS deck_matching_records (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            deck_version_id TEXT,
            best_duration_seconds REAL NOT NULL,
            pair_count INTEGER NOT NULL,
            achieved_at REAL NOT NULL,
            synced_at REAL,
            PRIMARY KEY (user_id, deck_id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE TABLE IF NOT EXISTS matching_attempts (
            id TEXT PRIMARY KEY NOT NULL,
            user_id TEXT NOT NULL,
            deck_id TEXT,
            deck_version_id TEXT,
            mode TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'deck_session',
            completed_at REAL NOT NULL,
            duration_ms INTEGER NOT NULL,
            pair_count INTEGER NOT NULL,
            synced_at REAL,
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_matching_attempts_user_completed
            ON matching_attempts(user_id, completed_at);
        CREATE INDEX IF NOT EXISTS idx_matching_attempts_deck_completed
            ON matching_attempts(deck_id, completed_at);
        CREATE TABLE IF NOT EXISTS study_reviews (
            id TEXT PRIMARY KEY NOT NULL,
            user_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            sense_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            deck_version_id TEXT,
            mode TEXT NOT NULL,
            outcome TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'deck_session',
            reviewed_at REAL NOT NULL,
            duration_ms INTEGER,
            was_new INTEGER NOT NULL,
            previous_state TEXT,
            new_state TEXT,
            synced_at REAL,
            FOREIGN KEY (card_id) REFERENCES cards(id),
            FOREIGN KEY (sense_id) REFERENCES card_senses(id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_study_reviews_card_id ON study_reviews(card_id);
        CREATE INDEX IF NOT EXISTS idx_study_reviews_sense_id ON study_reviews(sense_id);
        CREATE INDEX IF NOT EXISTS idx_study_reviews_reviewed_at ON study_reviews(reviewed_at);
        CREATE INDEX IF NOT EXISTS idx_study_reviews_deck_reviewed ON study_reviews(deck_id, reviewed_at);
        CREATE TABLE IF NOT EXISTS practice_reviews (
            id TEXT PRIMARY KEY NOT NULL,
            user_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            sense_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            deck_version_id TEXT,
            mode TEXT NOT NULL,
            outcome TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'today_practice',
            practiced_at REAL NOT NULL,
            duration_ms INTEGER,
            synced_at REAL,
            FOREIGN KEY (card_id) REFERENCES cards(id),
            FOREIGN KEY (sense_id) REFERENCES card_senses(id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_practice_reviews_card_id ON practice_reviews(card_id);
        CREATE INDEX IF NOT EXISTS idx_practice_reviews_sense_id ON practice_reviews(sense_id);
        CREATE INDEX IF NOT EXISTS idx_practice_reviews_practiced_at ON practice_reviews(practiced_at);
        CREATE INDEX IF NOT EXISTS idx_practice_reviews_deck_practiced ON practice_reviews(deck_id, practiced_at);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.migrationFailed
        }
        try addColumnIfMissing(table: "decks", column: "avatar_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "decks", column: "content_version_id", definition: "TEXT")
        try addColumnIfMissing(table: "user_deck_assignments", column: "deck_group_id", definition: "TEXT")
        try addColumnIfMissing(table: "user_deck_assignments", column: "deck_group_title", definition: "TEXT")
        try addColumnIfMissing(table: "user_deck_assignments", column: "deck_group_sort_order", definition: "INTEGER")
        try addColumnIfMissing(table: "user_deck_assignments", column: "deck_sort_order", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "cards", column: "audio_word_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "card_senses", column: "image_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "sentence_questions", column: "translation", definition: "TEXT")
        try addColumnIfMissing(table: "sentence_questions", column: "audio_answer_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "sense_progress", column: "synced_at", definition: "REAL")
        try addColumnIfMissing(table: "deck_matching_records", column: "synced_at", definition: "REAL")
        try addColumnIfMissing(table: "deck_matching_records", column: "deck_version_id", definition: "TEXT")
        try addColumnIfMissing(table: "matching_attempts", column: "deck_version_id", definition: "TEXT")
        try addColumnIfMissing(table: "study_reviews", column: "synced_at", definition: "REAL")
        try addColumnIfMissing(table: "study_reviews", column: "source", definition: "TEXT NOT NULL DEFAULT 'deck_session'")
        try addColumnIfMissing(table: "study_reviews", column: "deck_version_id", definition: "TEXT")
        try addColumnIfMissing(table: "practice_reviews", column: "deck_version_id", definition: "TEXT")
        try executeMigrationStatements([
            "CREATE INDEX IF NOT EXISTS idx_study_reviews_user_reviewed ON study_reviews(user_id, reviewed_at)",
        ])
        try migrateUserDeckAssignmentsForArchivedStatus()
    }

    private func migrateUserDeckAssignmentsForArchivedStatus() throws {
        guard let ddl = try tableDDL("user_deck_assignments"),
              !ddl.localizedCaseInsensitiveContains("'archived'") else {
            return
        }
        try executeMigrationStatements([
            """
            CREATE TABLE user_deck_assignments__v2 (
                user_id TEXT NOT NULL,
                deck_id TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'archived')),
                deck_group_id TEXT,
                deck_group_title TEXT,
                deck_group_sort_order INTEGER,
                deck_sort_order INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (user_id, deck_id),
                FOREIGN KEY (deck_id) REFERENCES decks(id)
            );
            """,
            """
            INSERT INTO user_deck_assignments__v2 (
                user_id, deck_id, status, deck_group_id, deck_group_title,
                deck_group_sort_order, deck_sort_order
            )
            SELECT user_id, deck_id, status, deck_group_id, deck_group_title,
                   deck_group_sort_order, deck_sort_order
            FROM user_deck_assignments;
            """,
            "DROP TABLE user_deck_assignments;",
            "ALTER TABLE user_deck_assignments__v2 RENAME TO user_deck_assignments;",
            "CREATE INDEX IF NOT EXISTS idx_user_deck_assignments_user_id ON user_deck_assignments(user_id);",
        ])
    }

    private func tableDDL(_ table: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, text: table)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, index: 0)
    }

    private func executeMigrationStatements(_ statements: [String]) throws {
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw ContentDatabaseError.migrationFailed
            }
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard try !hasColumn(column, inTable: table) else { return }
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.migrationFailed
        }
    }

    private func hasColumn(_ column: String, inTable table: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if textColumn(statement, index: 1) == column {
                return true
            }
        }
        return false
    }

    private func normalizeUUIDColumns() throws {
        let statements = [
            "UPDATE decks SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE decks SET avatar_media_id = lower(avatar_media_id) WHERE avatar_media_id GLOB '*[A-Z]*'",
            "UPDATE media_objects SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE cards SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE cards SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE cards SET audio_word_media_id = lower(audio_word_media_id) WHERE audio_word_media_id GLOB '*[A-Z]*'",
            "UPDATE card_senses SET image_media_id = lower(image_media_id) WHERE image_media_id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET sense_id = lower(sense_id) WHERE sense_id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE sentence_questions SET sense_id = lower(sense_id) WHERE sense_id GLOB '*[A-Z]*'",
            "UPDATE sentence_questions SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE sentence_questions SET audio_answer_media_id = lower(audio_answer_media_id) WHERE audio_answer_media_id GLOB '*[A-Z]*'",
            "UPDATE word_forms SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE question_distractors SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE question_distractors SET sense_id = lower(sense_id) WHERE sense_id GLOB '*[A-Z]*'",
            "UPDATE question_distractors SET source_card_id = lower(source_card_id) WHERE source_card_id GLOB '*[A-Z]*'",
            "UPDATE sense_progress SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE sense_progress SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE sense_progress SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_daily_usage SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE deck_daily_usage SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE user_deck_preferences SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE user_deck_preferences SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE user_settings SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE sync_metadata SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE deck_matching_records SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE deck_matching_records SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE matching_attempts SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE matching_attempts SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE matching_attempts SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE practice_reviews SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE practice_reviews SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE practice_reviews SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE practice_reviews SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
        ]
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw ContentDatabaseError.migrationFailed
            }
        }
    }

    // MARK: - Decks & cards

    private struct DeckRow {
        let id: UUID
        let contentVersionID: UUID?
        let status: ContentStatus
        let title: String
        let avatarSystemName: String?
        let avatarMediaID: UUID?
        let languageCode: String
        let newCardsPerDay: Int
        let reviewCardsPerDay: Int
        let deckGroupID: UUID?
        let deckGroupTitle: String?
        let deckGroupSortOrder: Int?
        let deckSortOrder: Int
    }

    private func fetchDeckRows() throws -> [DeckRow] {
        let sql = """
        SELECT decks.id,
               CASE
                   WHEN user_deck_assignments.status = 'active'
                    AND COALESCE(user_deck_preferences.is_enabled, 1) = 1
                   THEN 'active'
                   ELSE 'inactive'
               END AS effective_status,
               decks.title, decks.avatar_system_name, decks.content_version_id,
               decks.avatar_media_id, decks.language_code, decks.new_cards_per_day, decks.review_cards_per_day,
               user_deck_assignments.deck_group_id, user_deck_assignments.deck_group_title,
               user_deck_assignments.deck_group_sort_order, user_deck_assignments.deck_sort_order
        FROM decks
        JOIN user_deck_assignments ON user_deck_assignments.deck_id = decks.id
        LEFT JOIN user_deck_preferences ON user_deck_preferences.user_id = user_deck_assignments.user_id
            AND user_deck_preferences.deck_id = user_deck_assignments.deck_id
        WHERE user_deck_assignments.user_id = ?
          AND user_deck_assignments.status != 'archived'
        ORDER BY user_deck_assignments.deck_group_sort_order IS NULL,
                 user_deck_assignments.deck_group_sort_order,
                 user_deck_assignments.deck_group_title,
                 title COLLATE NOCASE,
                 decks.id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)

        var rows: [DeckRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let title = textColumn(statement, index: 2),
                  let languageCode = textColumn(statement, index: 6) else { continue }
            rows.append(
                DeckRow(
                    id: id,
                    contentVersionID: uuidColumn(statement, index: 4),
                    status: statusColumn(statement, index: 1),
                    title: title,
                    avatarSystemName: textColumn(statement, index: 3),
                    avatarMediaID: uuidColumn(statement, index: 5),
                    languageCode: languageCode,
                    newCardsPerDay: Int(sqlite3_column_int(statement, 7)),
                    reviewCardsPerDay: Int(sqlite3_column_int(statement, 8)),
                    deckGroupID: uuidColumn(statement, index: 9),
                    deckGroupTitle: textColumn(statement, index: 10),
                    deckGroupSortOrder: intColumn(statement, index: 11),
                    deckSortOrder: Int(sqlite3_column_int(statement, 12))
                )
            )
        }
        return rows
    }

    private func fetchCards(deckID: UUID) throws -> [WordCardContent] {
        let rows = try fetchCardRows(deckID: deckID)
        let cardIDs = rows.map(\.id)
        let sensesByCardID = try fetchSenses(cardIDs: cardIDs)
        let senseIDs = sensesByCardID.values.flatMap { $0.map(\.id) }
        let examplesBySenseID = try fetchExamples(senseIDs: senseIDs)
        let questionsBySenseID = try fetchSentenceQuestions(senseIDs: senseIDs)
        let formsByCardID = try fetchForms(cardIDs: cardIDs)
        let distractorsBySenseID = try fetchDistractors(senseIDs: senseIDs)
        let mediaIDs = Set(
            rows.map(\.audioWordMediaID)
                + sensesByCardID.values.flatMap { $0.map(\.imageMediaID) }
                + questionsBySenseID.values.map(\.audioAnswerMediaID)
        ).compactMap { $0 }
        let mediaURLs = try fetchMediaURLMap(deckID: deckID, mediaIDs: mediaIDs)
        func mediaURL(_ id: UUID?) -> URL? {
            guard let id else { return nil }
            return mediaURLs[id]
        }

        return rows.compactMap { row in
            let forms = formsByCardID[row.id] ?? []
            let senses = (sensesByCardID[row.id] ?? []).compactMap { senseRow -> WordSenseContent? in
                guard let example = examplesBySenseID[senseRow.id] else { return nil }
                guard let question = questionsBySenseID[senseRow.id] else { return nil }
                return WordSenseContent(
                    id: senseRow.id,
                    cardID: row.id,
                    status: senseRow.status,
                    displayPattern: senseRow.displayPattern,
                    translation: senseRow.translation,
                    note: senseRow.note,
                    imageURL: mediaURL(senseRow.imageMediaID),
                    example: SenseExampleContent(
                        text: example.text,
                        translation: example.translation,
                        note: nil
                    ),
                    sentenceQuestion: SentenceQuestionContent(
                        template: question.template,
                        answer: question.answer,
                        translation: question.translation,
                        answerFormKey: question.answerFormKey,
                        audioAnswerURL: mediaURL(question.audioAnswerMediaID)
                    ),
                    distractors: distractorsBySenseID[senseRow.id] ?? []
                )
            }
            guard !senses.isEmpty else { return nil }
            return WordCardContent(
                id: row.id,
                status: row.status,
                word: row.displayWord,
                lemma: row.lemma,
                partOfSpeech: row.partOfSpeech,
                etymology: row.etymology,
                explanation: row.notes,
                audioWordURL: mediaURL(row.audioWordMediaID),
                forms: forms,
                primarySenseID: row.primarySenseID,
                senses: senses
            )
        }
    }

    private struct CardRow {
        let id: UUID
        let status: ContentStatus
        let lemma: String
        let displayWord: String
        let partOfSpeech: String?
        let etymology: String?
        let notes: String?
        let primarySenseID: UUID?
        let audioWordMediaID: UUID?
    }

    private func fetchCardRows(deckID: UUID) throws -> [CardRow] {
        let sql = """
        SELECT id, status, lemma, display_word, part_of_speech, etymology,
               notes, primary_sense_id, audio_word_media_id
        FROM cards
        WHERE deck_id = ?
        ORDER BY display_word
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: deckID)

        var rows: [CardRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let lemma = textColumn(statement, index: 2),
                  let displayWord = textColumn(statement, index: 3) else { continue }
            rows.append(
                CardRow(
                    id: id,
                    status: statusColumn(statement, index: 1),
                    lemma: lemma,
                    displayWord: displayWord,
                    partOfSpeech: textColumn(statement, index: 4),
                    etymology: textColumn(statement, index: 5),
                    notes: textColumn(statement, index: 6),
                    primarySenseID: uuidColumn(statement, index: 7),
                    audioWordMediaID: uuidColumn(statement, index: 8)
                )
            )
        }
        return rows
    }

    private struct SenseRow {
        let id: UUID
        let cardID: UUID
        let status: ContentStatus
        let displayPattern: String?
        let translation: String
        let note: String?
        let imageMediaID: UUID?
    }

    private func fetchSenses(cardIDs: [UUID]) throws -> [UUID: [SenseRow]] {
        guard !cardIDs.isEmpty else { return [:] }
        let sql = """
        SELECT card_id, id, status, display_pattern, translation, note, image_media_id
        FROM card_senses
        WHERE card_id IN (\(placeholders(count: cardIDs.count)))
        ORDER BY card_id, sort_order, id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bindUUIDs(cardIDs, to: statement)

        var rows: [UUID: [SenseRow]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cardID = uuidColumn(statement, index: 0),
                  let id = uuidColumn(statement, index: 1),
                  let translation = textColumn(statement, index: 4) else { continue }
            rows[cardID, default: []].append(
                SenseRow(
                    id: id,
                    cardID: cardID,
                    status: statusColumn(statement, index: 2),
                    displayPattern: textColumn(statement, index: 3),
                    translation: translation,
                    note: textColumn(statement, index: 5),
                    imageMediaID: uuidColumn(statement, index: 6)
                )
            )
        }
        return rows
    }

    private struct ExampleRow {
        let text: String
        let translation: String?
    }

    private func fetchExamples(senseIDs: [UUID]) throws -> [UUID: ExampleRow] {
        guard !senseIDs.isEmpty else { return [:] }
        let sql = """
        SELECT sense_id, text, translation
        FROM card_examples
        WHERE sense_id IN (\(placeholders(count: senseIDs.count)))
        ORDER BY sense_id, sort_order
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bindUUIDs(senseIDs, to: statement)

        var rows: [UUID: ExampleRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let senseID = uuidColumn(statement, index: 0),
                  rows[senseID] == nil,
                  let text = textColumn(statement, index: 1)
            else { continue }
            rows[senseID] = ExampleRow(
                text: text,
                translation: textColumn(statement, index: 2)
            )
        }
        return rows
    }

    private struct SentenceQuestionRow {
        let template: String
        let answer: String
        let translation: String?
        let answerFormKey: String?
        let audioAnswerMediaID: UUID?
    }

    private func fetchSentenceQuestions(senseIDs: [UUID]) throws -> [UUID: SentenceQuestionRow] {
        guard !senseIDs.isEmpty else { return [:] }
        let sql = """
        SELECT sense_id, template, answer, translation, answer_form_key, audio_answer_media_id
        FROM sentence_questions
        WHERE sense_id IN (\(placeholders(count: senseIDs.count)))
        ORDER BY sense_id, sort_order
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bindUUIDs(senseIDs, to: statement)

        var rows: [UUID: SentenceQuestionRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let senseID = uuidColumn(statement, index: 0),
                  rows[senseID] == nil,
                  let template = textColumn(statement, index: 1),
                  let answer = textColumn(statement, index: 2)
            else { continue }
            rows[senseID] = SentenceQuestionRow(
                template: template,
                answer: answer,
                translation: textColumn(statement, index: 3),
                answerFormKey: textColumn(statement, index: 4),
                audioAnswerMediaID: uuidColumn(statement, index: 5)
            )
        }
        return rows
    }

    private func fetchForms(cardIDs: [UUID]) throws -> [UUID: [WordForm]] {
        guard !cardIDs.isEmpty else { return [:] }
        let sql = """
        SELECT card_id, form_key, text
        FROM word_forms
        WHERE card_id IN (\(placeholders(count: cardIDs.count)))
        ORDER BY card_id, sort_order, form_key, text
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bindUUIDs(cardIDs, to: statement)

        var forms: [UUID: [WordForm]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cardID = uuidColumn(statement, index: 0),
                  let formKey = textColumn(statement, index: 1),
                  let text = textColumn(statement, index: 2) else { continue }
            forms[cardID, default: []].append(WordForm(formKey: formKey, text: text))
        }
        return forms
    }

    private func fetchDistractors(senseIDs: [UUID]) throws -> [UUID: [String]] {
        guard !senseIDs.isEmpty else { return [:] }
        let sql = """
        SELECT sense_id, text
        FROM question_distractors
        WHERE sense_id IN (\(placeholders(count: senseIDs.count)))
        ORDER BY sense_id, priority, text
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bindUUIDs(senseIDs, to: statement)

        var distractors: [UUID: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let senseID = uuidColumn(statement, index: 0),
                  let text = textColumn(statement, index: 1) else { continue }
            distractors[senseID, default: []].append(text)
        }
        return distractors
    }

    private func fetchMediaURLMap(deckID: UUID, mediaIDs: [UUID]) throws -> [UUID: URL] {
        guard !mediaIDs.isEmpty else { return [:] }
        let sql = """
        SELECT id, local_path, storage_key
        FROM media_objects
        WHERE id IN (\(placeholders(count: mediaIDs.count)))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bindUUIDs(mediaIDs, to: statement)

        var urls: [UUID: URL] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0) else { continue }
            if let localPath = textColumn(statement, index: 1),
               let url = resolveMediaReference(localPath, deckID: deckID) {
                urls[id] = url
            } else if let storageKey = textColumn(statement, index: 2),
                      let url = resolveMediaReference(storageKey, deckID: deckID) {
                urls[id] = url
            }
        }
        return urls
    }

    private func resolveMediaURL(deckID: UUID, mediaID: UUID?) -> URL? {
        guard let mediaID else { return nil }
        let sql = """
        SELECT local_path, storage_key
        FROM media_objects
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        try? bind(statement, index: 1, uuid: mediaID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        if let localPath = textColumn(statement, index: 0) {
            return resolveMediaReference(localPath, deckID: deckID)
        }
        if let storageKey = textColumn(statement, index: 1) {
            return resolveMediaReference(storageKey, deckID: deckID)
        }
        return nil
    }

    private func resolveMediaReference(_ reference: String, deckID: UUID) -> URL? {
        if let remoteURL = URL(string: reference), remoteURL.scheme == "http" || remoteURL.scheme == "https" {
            return remoteURL
        }
        return try? AppDataPaths.mediaFileURL(deckID: deckID, relativePath: reference)
    }

    // MARK: - SQLite helpers

    private func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func bindUUIDs(_ ids: [UUID], to statement: OpaquePointer?) throws {
        for (offset, id) in ids.enumerated() {
            try bind(statement, index: Int32(offset + 1), uuid: id)
        }
    }

    private func isCurrentWeakCard(
        _ statement: OpaquePointer?,
        fsrsDataIndex: Int32,
        failedCount: Int,
        reviewedCount: Int
    ) throws -> Bool {
        guard sqlite3_column_type(statement, fsrsDataIndex) != SQLITE_NULL,
              let blob = sqlite3_column_blob(statement, fsrsDataIndex) else {
            return true
        }
        let length = Int(sqlite3_column_bytes(statement, fsrsDataIndex))
        let data = Data(bytes: blob, count: length)
        let fsrsCard: Card
        do {
            fsrsCard = try JSONDecoder().decode(Card.self, from: data)
        } catch {
            return true
        }
        if fsrsCard.state != .review {
            return true
        }
        guard reviewedCount > 0 else { return false }
        let failureRate = Double(failedCount) / Double(reviewedCount)
        return failureRate >= WeakCardFilter.minimumFailureRate
    }

    private func exec(
        _ sql: String,
        uuid: UUID? = nil,
        uuid2: UUID? = nil,
        text: String? = nil,
        blob: Data? = nil,
        double: Double? = nil,
        int: Int? = nil
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        if let uuid {
            try bind(statement, index: index, uuid: uuid)
            index += 1
        }
        if let uuid2 {
            try bind(statement, index: index, uuid: uuid2)
            index += 1
        }
        if let blob {
            try blob.withUnsafeBytes { raw in
                guard sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(blob.count), sqliteTransient) == SQLITE_OK else {
                    throw ContentDatabaseError.queryFailed
                }
            }
            index += 1
        }
        if let double {
            guard sqlite3_bind_double(statement, index, double) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            index += 1
        }
        if let text {
            try bind(statement, index: index, text: text)
            index += 1
        }
        if let int {
            guard sqlite3_bind_int(statement, index, Int32(int)) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func beginTransaction() throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func commitTransaction() throws {
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func rollbackTransaction() throws {
        guard sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, uuid: UUID) throws {
        try bind(statement, index: index, text: uuid.databaseString)
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, uuid: UUID?) throws {
        guard let uuid else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            return
        }
        try bind(statement, index: index, uuid: uuid)
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, text: String) throws {
        try text.withCString { cString in
            guard sqlite3_bind_text(statement, index, cString, -1, sqliteTransient) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, text: String?) throws {
        guard let text else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            return
        }
        try bind(statement, index: index, text: text)
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, int: Int?) throws {
        guard let int else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            return
        }
        guard sqlite3_bind_int(statement, index, Int32(int)) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
    }

    private func textColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func uuidColumn(_ statement: OpaquePointer?, index: Int32) -> UUID? {
        guard let text = textColumn(statement, index: index) else { return nil }
        return UUID(databaseString: text)
    }

    private func intColumn(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func statusColumn(_ statement: OpaquePointer?, index: Int32) -> ContentStatus {
        guard let text = textColumn(statement, index: index),
              let status = ContentStatus(rawValue: text) else {
            return .active
        }
        return status
    }
}

enum ContentDatabaseError: Error {
    case openFailed
    case queryFailed
    case migrationFailed
}
