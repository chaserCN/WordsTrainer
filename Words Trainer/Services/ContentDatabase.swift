import Foundation
import FSRS
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct PendingServerSyncBatch {
    let payload: ServerSyncEventsPayload
    let reviewIDs: [UUID]
    let progressCardIDs: [UUID]
    let matchingDeckIDs: [UUID]

    var isEmpty: Bool {
        payload.isEmpty && reviewIDs.isEmpty && progressCardIDs.isEmpty && matchingDeckIDs.isEmpty
    }
}

/// Read/write access to `Documents/Data/flashgame.db` (content + study progress).
final class ContentDatabase {
    private var db: OpaquePointer?
    private let userID: UUID

    init(userID: UUID = AppUser.defaultID) throws {
        self.userID = userID
        _ = try AppDataPaths.dataDirectoryURL()
        let path = try AppDataPaths.databaseURL().path
        guard sqlite3_open(path, &db) == SQLITE_OK, db != nil else {
            throw ContentDatabaseError.openFailed
        }
        try executeMigrations()
        try normalizeUUIDColumns()
        try AppDataPaths.normalizeDeckMediaFolders()
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
                status: row.status,
                title: row.title,
                avatarSystemName: row.avatarSystemName,
                avatarImageURL: resolveMediaURL(deckID: row.id, mediaID: row.avatarMediaID),
                languageCode: row.languageCode,
                newCardsPerDay: row.newCardsPerDay,
                reviewCardsPerDay: row.reviewCardsPerDay,
                cards: try fetchCards(deckID: row.id)
            )
        }
    }

    func importServerBootstrap(_ bootstrap: ServerBootstrap, selectedUserID: UUID) throws {
        let versionDeckIDs = Dictionary(
            uniqueKeysWithValues: bootstrap.assignments.compactMap { assignment -> (UUID, UUID)? in
                let versionID = assignment.deckVersionId ?? assignment.currentVersionId
                guard let versionID else { return nil }
                return (versionID, assignment.deckId)
            }
        )
        let assignedDeckIDs = bootstrap.assignments.map(\.deckId)

        try beginTransaction()
        do {
            try replaceAssignments(bootstrap.assignments, selectedUserID: selectedUserID)
            try upsertMediaObjects(bootstrap.media)
            for deckID in assignedDeckIDs {
                try deleteDeckContent(deckID: deckID)
            }
            try upsertDecks(bootstrap.assignments)
            try upsertCards(bootstrap.content.cards, versionDeckIDs: versionDeckIDs)
            try upsertExamples(bootstrap.content.examples)
            try upsertForms(bootstrap.content.forms)
            try upsertDistractors(bootstrap.content.distractors)
            try upsertServerProgress(bootstrap.progress)
            try upsertServerReviews(bootstrap.reviews, selectedUserID: selectedUserID)
            try upsertServerMatchingRecords(bootstrap.matchingRecords, selectedUserID: selectedUserID)
            try rebuildDerivedStats(selectedUserID: selectedUserID)
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
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
        let sql = """
        UPDATE decks
        SET status = ?
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, text: status.rawValue)
        try bind(statement, index: 2, uuid: deckID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func progressMap(deckID: UUID) throws -> [UUID: CardProgress] {
        let sql = """
        SELECT card_id, fsrs_data, updated_at
        FROM card_progress
        WHERE user_id = ? AND deck_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, uuid: deckID)

        var map: [UUID: CardProgress] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cardID = uuidColumn(statement, index: 0),
                  let blob = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: blob, count: length)
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let fsrsCard = try JSONDecoder().decode(Card.self, from: data)
            map[cardID] = CardProgress(cardID: cardID, fsrsCard: fsrsCard, updatedAt: updatedAt)
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

    func saveProgress(deckID: UUID, progress: CardProgress) throws {
        let fsrsData = try JSONEncoder().encode(progress.fsrsCard)
        let sql = """
        INSERT INTO card_progress (user_id, card_id, deck_id, fsrs_data, updated_at, synced_at)
        VALUES (?, ?, ?, ?, ?, NULL)
        ON CONFLICT(user_id, card_id) DO UPDATE SET
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
        try bind(statement, index: 2, uuid: progress.cardID)
        try bind(statement, index: 3, uuid: deckID)
        try fsrsData.withUnsafeBytes { raw in
            guard sqlite3_bind_blob(statement, 4, raw.baseAddress, Int32(fsrsData.count), sqliteTransient) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
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
        let sql = """
        INSERT INTO study_reviews (
            id, user_id, card_id, deck_id, mode, outcome, reviewed_at,
            duration_ms, was_new, previous_state, new_state, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: event.id)
        try bind(statement, index: 2, uuid: userID)
        try bind(statement, index: 3, uuid: event.cardID)
        try bind(statement, index: 4, uuid: event.deckID)
        try bind(statement, index: 5, text: event.mode.rawValue)
        try bind(statement, index: 6, text: event.outcome.databaseValue)
        guard sqlite3_bind_double(statement, 7, event.reviewedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        if let durationMS = event.durationMS {
            guard sqlite3_bind_int(statement, 8, Int32(durationMS)) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        } else {
            guard sqlite3_bind_null(statement, 8) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
        guard sqlite3_bind_int(statement, 9, event.wasNew ? 1 : 0) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 10, text: event.previousState)
        try bind(statement, index: 11, text: event.newState)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func studyActivity(since startDate: Date) throws -> [StudyActivityDay] {
        let sql = """
        SELECT
            strftime('%Y-%m-%d', reviewed_at, 'unixepoch', 'localtime') AS day_key,
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

    func weakCards(limit: Int = 30) throws -> [WeakCardStat] {
        let sql = """
        SELECT
            cards.id,
            cards.deck_id,
            cards.display_word,
            cards.translation,
            SUM(CASE WHEN study_reviews.outcome IN ('forgot', 'incorrect') THEN 1 ELSE 0 END) AS failed_count,
            COUNT(study_reviews.id) AS reviewed_count,
            MAX(CASE WHEN study_reviews.outcome IN ('forgot', 'incorrect') THEN study_reviews.reviewed_at ELSE NULL END) AS last_failed_at
        FROM study_reviews
        JOIN cards ON cards.id = study_reviews.card_id
        JOIN decks ON decks.id = study_reviews.deck_id
        WHERE study_reviews.user_id = ? AND cards.status = 'active' AND decks.status = 'active'
        GROUP BY cards.id, cards.deck_id, cards.display_word, cards.translation
        HAVING failed_count > 0
        ORDER BY failed_count DESC, CAST(failed_count AS REAL) / reviewed_count DESC, last_failed_at DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }

        var cards: [WeakCardStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cardID = uuidColumn(statement, index: 0),
                  let deckID = uuidColumn(statement, index: 1),
                  let word = textColumn(statement, index: 2),
                  let translation = textColumn(statement, index: 3) else { continue }
            let lastFailedAt: Date?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                lastFailedAt = nil
            } else {
                lastFailedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            }
            cards.append(
                WeakCardStat(
                    cardID: cardID,
                    deckID: deckID,
                    word: word,
                    translation: translation,
                    failedCount: Int(sqlite3_column_int(statement, 4)),
                    reviewedCount: Int(sqlite3_column_int(statement, 5)),
                    lastFailedAt: lastFailedAt
                )
            )
        }
        return cards
    }

    func matchingRecord(deckID: UUID) throws -> DeckMatchingRecord? {
        let sql = """
        SELECT best_duration_seconds, pair_count, achieved_at
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
            bestDuration: sqlite3_column_double(statement, 0),
            pairCount: Int(sqlite3_column_int(statement, 1)),
            achievedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        )
    }

    func saveMatchingRecord(_ record: DeckMatchingRecord) throws {
        let sql = """
        INSERT INTO deck_matching_records (user_id, deck_id, best_duration_seconds, pair_count, achieved_at, synced_at)
        VALUES (?, ?, ?, ?, ?, NULL)
        ON CONFLICT(user_id, deck_id) DO UPDATE SET
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
        guard sqlite3_bind_double(statement, 3, record.bestDuration) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_bind_int(statement, 4, Int32(record.pairCount)) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_bind_double(statement, 5, record.achievedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    func pendingServerSyncBatch(limit: Int = 100) throws -> PendingServerSyncBatch {
        let reviews = try pendingReviewEvents(limit: limit)
        let progress = try pendingProgressItems(limit: limit)
        let matchingRecords = try pendingMatchingRecords(limit: limit)
        return PendingServerSyncBatch(
            payload: ServerSyncEventsPayload(
                reviews: reviews.payload,
                progress: progress.payload,
                matchingRecords: matchingRecords.payload
            ),
            reviewIDs: reviews.ids,
            progressCardIDs: progress.cardIDs,
            matchingDeckIDs: matchingRecords.deckIDs
        )
    }

    func markServerSyncBatchUploaded(_ batch: PendingServerSyncBatch, syncedAt: Date = .now) throws {
        let timestamp = syncedAt.timeIntervalSince1970
        for reviewID in batch.reviewIDs {
            try markReviewSynced(reviewID: reviewID, syncedAt: timestamp)
        }
        for cardID in batch.progressCardIDs {
            try markProgressSynced(cardID: cardID, syncedAt: timestamp)
        }
        for deckID in batch.matchingDeckIDs {
            try markMatchingRecordSynced(deckID: deckID, syncedAt: timestamp)
        }
    }

    private func pendingReviewEvents(limit: Int) throws -> (payload: [ServerReviewEventPayload], ids: [UUID]) {
        let sql = """
        SELECT study_reviews.id, study_reviews.deck_id, study_reviews.card_id, study_reviews.mode,
               study_reviews.outcome, study_reviews.reviewed_at, study_reviews.duration_ms,
               study_reviews.was_new, study_reviews.previous_state, study_reviews.new_state
        FROM study_reviews
        JOIN cards ON cards.id = study_reviews.card_id AND cards.deck_id = study_reviews.deck_id
        JOIN user_deck_assignments ON user_deck_assignments.deck_id = study_reviews.deck_id
        WHERE study_reviews.user_id = ?
          AND user_deck_assignments.user_id = study_reviews.user_id
          AND user_deck_assignments.status = 'active'
          AND cards.status = 'active'
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
                  let cardID = uuidColumn(statement, index: 2),
                  let mode = textColumn(statement, index: 3),
                  let outcome = textColumn(statement, index: 4) else { continue }
            let durationMS: Int?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                durationMS = nil
            } else {
                durationMS = Int(sqlite3_column_int(statement, 6))
            }
            ids.append(id)
            payload.append(
                ServerReviewEventPayload(
                    clientEventId: id,
                    deckId: deckID,
                    deckVersionId: nil,
                    cardId: cardID,
                    mode: mode,
                    outcome: outcome,
                    reviewedAt: isoString(Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))),
                    durationMs: durationMS,
                    wasNew: sqlite3_column_int(statement, 7) != 0,
                    previousState: textColumn(statement, index: 8),
                    newState: textColumn(statement, index: 9)
                )
            )
        }
        return (payload, ids)
    }

    private func pendingProgressItems(limit: Int) throws -> (payload: [ServerProgressPayload], cardIDs: [UUID]) {
        let sql = """
        SELECT card_progress.card_id, card_progress.deck_id, card_progress.fsrs_data, card_progress.updated_at
        FROM card_progress
        JOIN cards ON cards.id = card_progress.card_id AND cards.deck_id = card_progress.deck_id
        JOIN user_deck_assignments ON user_deck_assignments.deck_id = card_progress.deck_id
        WHERE card_progress.user_id = ?
          AND user_deck_assignments.user_id = card_progress.user_id
          AND user_deck_assignments.status = 'active'
          AND cards.status = 'active'
          AND card_progress.synced_at IS NULL
        ORDER BY card_progress.updated_at
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: userID)
        try bind(statement, index: 2, int: limit)

        var payload: [ServerProgressPayload] = []
        var cardIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cardID = uuidColumn(statement, index: 0),
                  let deckID = uuidColumn(statement, index: 1),
                  let blob = sqlite3_column_blob(statement, 2) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 2))
            let data = Data(bytes: blob, count: length)
            let fsrsCard = try JSONDecoder().decode(Card.self, from: data)
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            guard let fsrsJSON = JSONValue(jsonObject: jsonObject) else {
                throw ContentDatabaseError.queryFailed
            }
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            cardIDs.append(cardID)
            payload.append(
                ServerProgressPayload(
                    cardId: cardID,
                    deckId: deckID,
                    fsrsData: fsrsJSON,
                    dueAt: isoString(fsrsCard.due),
                    state: String(describing: fsrsCard.state),
                    updatedAt: isoString(updatedAt)
                )
            )
        }
        return (payload, cardIDs)
    }

    private func pendingMatchingRecords(limit: Int) throws -> (payload: [ServerMatchingRecordPayload], deckIDs: [UUID]) {
        let sql = """
        SELECT deck_matching_records.deck_id, deck_matching_records.best_duration_seconds,
               deck_matching_records.pair_count, deck_matching_records.achieved_at
        FROM deck_matching_records
        JOIN user_deck_assignments ON user_deck_assignments.deck_id = deck_matching_records.deck_id
        WHERE deck_matching_records.user_id = ?
          AND user_deck_assignments.user_id = deck_matching_records.user_id
          AND user_deck_assignments.status = 'active'
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
        var deckIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let deckID = uuidColumn(statement, index: 0) else { continue }
            deckIDs.append(deckID)
            payload.append(
                ServerMatchingRecordPayload(
                    deckId: deckID,
                    deckVersionId: nil,
                    bestDurationSeconds: sqlite3_column_double(statement, 1),
                    pairCount: Int(sqlite3_column_int(statement, 2)),
                    achievedAt: isoString(Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)))
                )
            )
        }
        return (payload, deckIDs)
    }

    private func markReviewSynced(reviewID: UUID, syncedAt: Double) throws {
        try markSynced(
            sql: "UPDATE study_reviews SET synced_at = ? WHERE user_id = ? AND id = ?",
            id: reviewID,
            syncedAt: syncedAt
        )
    }

    private func markProgressSynced(cardID: UUID, syncedAt: Double) throws {
        try markSynced(
            sql: "UPDATE card_progress SET synced_at = ? WHERE user_id = ? AND card_id = ?",
            id: cardID,
            syncedAt: syncedAt
        )
    }

    private func markMatchingRecordSynced(deckID: UUID, syncedAt: Double) throws {
        try markSynced(
            sql: "UPDATE deck_matching_records SET synced_at = ? WHERE user_id = ? AND deck_id = ?",
            id: deckID,
            syncedAt: syncedAt
        )
    }

    private func markSynced(sql: String, id: UUID, syncedAt: Double) throws {
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
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    // MARK: - Server content import

    private func replaceAssignments(_ assignments: [ServerDeckAssignment], selectedUserID: UUID) throws {
        try exec("DELETE FROM user_deck_assignments WHERE user_id = ?", uuid: selectedUserID)
        for assignment in assignments where assignment.userId == selectedUserID {
            let sql = """
            INSERT INTO user_deck_assignments (user_id, deck_id, status)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id, deck_id) DO UPDATE SET
                status = excluded.status
            """
            try exec(
                sql,
                uuid: selectedUserID,
                uuid2: assignment.deckId,
                text: localStatus(assignment.assignmentStatus).rawValue
            )
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
            DELETE FROM example_distractors
            WHERE example_id IN (
                SELECT card_examples.id
                FROM card_examples
                JOIN cards ON cards.id = card_examples.card_id
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
            "UPDATE cards SET status = 'inactive' WHERE deck_id = '\(deckID)'",
        ]
        try executeMigrationStatements(statements)
    }

    private func upsertCards(_ cards: [ServerCardContent], versionDeckIDs: [UUID: UUID]) throws {
        for card in cards {
            guard let deckID = versionDeckIDs[card.deckVersionId] else { continue }
            let sql = """
            INSERT INTO cards (
                id, deck_id, status, lemma, display_word, part_of_speech, translation,
                short_definition, memory_hint, etymology, usage_note, synonym_note,
                grammar_note, notes, image_media_id, audio_word_media_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                deck_id = excluded.deck_id,
                status = excluded.status,
                lemma = excluded.lemma,
                display_word = excluded.display_word,
                part_of_speech = excluded.part_of_speech,
                translation = excluded.translation,
                short_definition = excluded.short_definition,
                memory_hint = excluded.memory_hint,
                etymology = excluded.etymology,
                usage_note = excluded.usage_note,
                synonym_note = excluded.synonym_note,
                grammar_note = excluded.grammar_note,
                notes = excluded.notes,
                image_media_id = excluded.image_media_id,
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
            try bind(statement, index: 7, text: card.translation)
            try bind(statement, index: 8, text: card.shortDefinition)
            try bind(statement, index: 9, text: card.memoryHint)
            try bind(statement, index: 10, text: card.etymology)
            try bind(statement, index: 11, text: card.usageNote)
            try bind(statement, index: 12, text: card.synonymNote)
            try bind(statement, index: 13, text: card.grammarNote)
            try bind(statement, index: 14, text: card.notes)
            try bind(statement, index: 15, uuid: card.imageMediaId)
            try bind(statement, index: 16, uuid: card.audioWordMediaId)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func upsertExamples(_ examples: [ServerExampleContent]) throws {
        for example in examples {
            let sql = """
            INSERT INTO card_examples (
                id, card_id, template, answer, answer_form_key, translation, note,
                image_media_id, audio_example_media_id, sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                card_id = excluded.card_id,
                template = excluded.template,
                answer = excluded.answer,
                answer_form_key = excluded.answer_form_key,
                translation = excluded.translation,
                note = excluded.note,
                image_media_id = excluded.image_media_id,
                audio_example_media_id = excluded.audio_example_media_id,
                sort_order = excluded.sort_order
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: example.exampleId)
            try bind(statement, index: 2, uuid: example.cardId)
            try bind(statement, index: 3, text: example.template)
            try bind(statement, index: 4, text: example.answer)
            try bind(statement, index: 5, text: example.answerFormKey)
            try bind(statement, index: 6, text: example.translation)
            try bind(statement, index: 7, text: example.note)
            try bind(statement, index: 8, uuid: example.imageMediaId)
            try bind(statement, index: 9, uuid: example.audioExampleMediaId)
            try bind(statement, index: 10, int: example.sortOrder ?? 0)
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
            INSERT INTO example_distractors (id, example_id, text, source_card_id, priority)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                example_id = excluded.example_id,
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
            try bind(statement, index: 2, uuid: distractor.exampleId)
            try bind(statement, index: 3, text: distractor.text)
            try bind(statement, index: 4, uuid: distractor.sourceCardId)
            try bind(statement, index: 5, int: distractor.priority ?? 0)
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
            INSERT INTO card_progress (user_id, card_id, deck_id, fsrs_data, updated_at, synced_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, card_id) DO UPDATE SET
                deck_id = excluded.deck_id,
                fsrs_data = excluded.fsrs_data,
                updated_at = excluded.updated_at,
                synced_at = excluded.synced_at
            WHERE card_progress.synced_at IS NOT NULL
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            defer { sqlite3_finalize(statement) }
            try bind(statement, index: 1, uuid: userID)
            try bind(statement, index: 2, uuid: progress.cardId)
            try bind(statement, index: 3, uuid: progress.deckId)
            try data.withUnsafeBytes { raw in
                guard sqlite3_bind_blob(statement, 4, raw.baseAddress, Int32(data.count), sqliteTransient) == SQLITE_OK else {
                    throw ContentDatabaseError.queryFailed
                }
            }
            guard sqlite3_bind_double(statement, 5, updatedAt) == SQLITE_OK,
                  sqlite3_bind_double(statement, 6, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
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
                id, user_id, card_id, deck_id, mode, outcome, reviewed_at,
                duration_ms, was_new, previous_state, new_state, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                card_id = excluded.card_id,
                deck_id = excluded.deck_id,
                mode = excluded.mode,
                outcome = excluded.outcome,
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
            try bind(statement, index: 4, uuid: review.deckId)
            try bind(statement, index: 5, text: review.mode)
            try bind(statement, index: 6, text: review.outcome)
            guard sqlite3_bind_double(statement, 7, reviewedAt.timeIntervalSince1970) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            try bind(statement, index: 8, int: review.durationMs)
            guard sqlite3_bind_int(statement, 9, review.wasNew ? 1 : 0) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
            try bind(statement, index: 10, text: review.previousState)
            try bind(statement, index: 11, text: review.newState)
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
            INSERT INTO deck_matching_records (user_id, deck_id, best_duration_seconds, pair_count, achieved_at, synced_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, deck_id) DO UPDATE SET
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
            guard sqlite3_bind_double(statement, 3, record.bestDurationSeconds) == SQLITE_OK,
                  sqlite3_bind_int(statement, 4, Int32(record.pairCount)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, achievedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 6, syncedAt) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ContentDatabaseError.queryFailed
            }
        }
    }

    private func localStatus(_ value: String) -> ContentStatus {
        value == "active" ? .active : .inactive
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
            strftime('%Y-%m-%d', reviewed_at, 'unixepoch', 'localtime') AS day_key,
            SUM(CASE WHEN was_new = 1 THEN 1 ELSE 0 END) AS new_cards_studied
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

    // MARK: - Schema

    private func executeMigrations() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
            title TEXT NOT NULL,
            avatar_system_name TEXT,
            avatar_media_id TEXT,
            language_code TEXT NOT NULL,
            new_cards_per_day INTEGER NOT NULL,
            review_cards_per_day INTEGER NOT NULL,
            FOREIGN KEY (avatar_media_id) REFERENCES media_objects(id)
        );
        CREATE TABLE IF NOT EXISTS user_deck_assignments (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
            PRIMARY KEY (user_id, deck_id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_user_deck_assignments_user_id ON user_deck_assignments(user_id);
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
            translation TEXT NOT NULL,
            short_definition TEXT,
            memory_hint TEXT,
            etymology TEXT,
            usage_note TEXT,
            synonym_note TEXT,
            grammar_note TEXT,
            notes TEXT,
            image_media_id TEXT,
            audio_word_media_id TEXT,
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_cards_deck_id ON cards(deck_id);
        CREATE TABLE IF NOT EXISTS card_examples (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            template TEXT NOT NULL,
            answer TEXT NOT NULL,
            answer_form_key TEXT,
            translation TEXT,
            note TEXT,
            image_media_id TEXT,
            audio_example_media_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
        CREATE INDEX IF NOT EXISTS idx_card_examples_card_id ON card_examples(card_id);
        CREATE TABLE IF NOT EXISTS word_forms (
            card_id TEXT NOT NULL,
            form_key TEXT NOT NULL,
            text TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (card_id, form_key, text),
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
        CREATE INDEX IF NOT EXISTS idx_word_forms_form_key ON word_forms(form_key);
        CREATE TABLE IF NOT EXISTS example_distractors (
            id TEXT PRIMARY KEY NOT NULL,
            example_id TEXT NOT NULL,
            text TEXT NOT NULL,
            source_card_id TEXT,
            priority INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (example_id) REFERENCES card_examples(id),
            FOREIGN KEY (source_card_id) REFERENCES cards(id)
        );
        CREATE INDEX IF NOT EXISTS idx_example_distractors_example_id ON example_distractors(example_id);
        CREATE TABLE IF NOT EXISTS card_progress (
            user_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            fsrs_data BLOB NOT NULL,
            updated_at REAL NOT NULL,
            synced_at REAL,
            PRIMARY KEY (user_id, card_id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_card_progress_deck_id ON card_progress(deck_id);
        CREATE TABLE IF NOT EXISTS deck_daily_usage (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            day_key TEXT NOT NULL,
            new_cards_studied INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (user_id, deck_id, day_key),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE TABLE IF NOT EXISTS deck_matching_records (
            user_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            best_duration_seconds REAL NOT NULL,
            pair_count INTEGER NOT NULL,
            achieved_at REAL NOT NULL,
            synced_at REAL,
            PRIMARY KEY (user_id, deck_id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE TABLE IF NOT EXISTS study_reviews (
            id TEXT PRIMARY KEY NOT NULL,
            user_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            mode TEXT NOT NULL,
            outcome TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            duration_ms INTEGER,
            was_new INTEGER NOT NULL,
            previous_state TEXT,
            new_state TEXT,
            synced_at REAL,
            FOREIGN KEY (card_id) REFERENCES cards(id),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_study_reviews_card_id ON study_reviews(card_id);
        CREATE INDEX IF NOT EXISTS idx_study_reviews_reviewed_at ON study_reviews(reviewed_at);
        CREATE INDEX IF NOT EXISTS idx_study_reviews_deck_reviewed ON study_reviews(deck_id, reviewed_at);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.migrationFailed
        }
        try addColumnIfMissing(table: "decks", column: "avatar_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "cards", column: "image_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "cards", column: "audio_word_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "card_examples", column: "image_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "card_examples", column: "audio_example_media_id", definition: "TEXT")
        try addColumnIfMissing(table: "card_progress", column: "synced_at", definition: "REAL")
        try addColumnIfMissing(table: "deck_matching_records", column: "synced_at", definition: "REAL")
        try addColumnIfMissing(table: "study_reviews", column: "synced_at", definition: "REAL")
        try migrateUserScopedTablesIfNeeded()
        try seedDefaultAssignmentsIfNeeded()
    }

    private func migrateUserScopedTablesIfNeeded() throws {
        let defaultUserID = AppUser.defaultID.databaseString
        if try !hasColumn("user_id", inTable: "card_progress") {
            try executeMigrationStatements([
                "ALTER TABLE card_progress RENAME TO card_progress_legacy",
                """
                CREATE TABLE card_progress (
                    user_id TEXT NOT NULL,
                    card_id TEXT NOT NULL,
                    deck_id TEXT NOT NULL,
                    fsrs_data BLOB NOT NULL,
                    updated_at REAL NOT NULL,
                    synced_at REAL,
                    PRIMARY KEY (user_id, card_id),
                    FOREIGN KEY (deck_id) REFERENCES decks(id)
                )
                """,
                """
                INSERT INTO card_progress (user_id, card_id, deck_id, fsrs_data, updated_at, synced_at)
                SELECT '\(defaultUserID)', card_id, deck_id, fsrs_data, updated_at, NULL
                FROM card_progress_legacy
                """,
                "DROP TABLE card_progress_legacy",
                "CREATE INDEX IF NOT EXISTS idx_card_progress_deck_id ON card_progress(deck_id)",
            ])
        }

        if try !hasColumn("user_id", inTable: "deck_daily_usage") {
            try executeMigrationStatements([
                "ALTER TABLE deck_daily_usage RENAME TO deck_daily_usage_legacy",
                """
                CREATE TABLE deck_daily_usage (
                    user_id TEXT NOT NULL,
                    deck_id TEXT NOT NULL,
                    day_key TEXT NOT NULL,
                    new_cards_studied INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, deck_id, day_key),
                    FOREIGN KEY (deck_id) REFERENCES decks(id)
                )
                """,
                """
                INSERT INTO deck_daily_usage (user_id, deck_id, day_key, new_cards_studied)
                SELECT '\(defaultUserID)', deck_id, day_key, new_cards_studied
                FROM deck_daily_usage_legacy
                """,
                "DROP TABLE deck_daily_usage_legacy",
            ])
        }

        if try !hasColumn("user_id", inTable: "deck_matching_records") {
            try executeMigrationStatements([
                "ALTER TABLE deck_matching_records RENAME TO deck_matching_records_legacy",
                """
                CREATE TABLE deck_matching_records (
                    user_id TEXT NOT NULL,
                    deck_id TEXT NOT NULL,
                    best_duration_seconds REAL NOT NULL,
                    pair_count INTEGER NOT NULL,
                    achieved_at REAL NOT NULL,
                    synced_at REAL,
                    PRIMARY KEY (user_id, deck_id),
                    FOREIGN KEY (deck_id) REFERENCES decks(id)
                )
                """,
                """
                INSERT INTO deck_matching_records (user_id, deck_id, best_duration_seconds, pair_count, achieved_at, synced_at)
                SELECT '\(defaultUserID)', deck_id, best_duration_seconds, pair_count, achieved_at, NULL
                FROM deck_matching_records_legacy
                """,
                "DROP TABLE deck_matching_records_legacy",
            ])
        }

        try addColumnIfMissing(
            table: "study_reviews",
            column: "user_id",
            definition: "TEXT NOT NULL DEFAULT '\(defaultUserID)'"
        )
        try executeMigrationStatements([
            "CREATE INDEX IF NOT EXISTS idx_study_reviews_user_reviewed ON study_reviews(user_id, reviewed_at)",
        ])
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

    private func seedDefaultAssignmentsIfNeeded() throws {
        let defaultUserID = AppUser.defaultID.databaseString
        let sql = """
        INSERT OR IGNORE INTO user_deck_assignments (user_id, deck_id, status)
        SELECT '\(defaultUserID)', id, status
        FROM decks
        WHERE NOT EXISTS (
            SELECT 1 FROM user_deck_assignments WHERE user_deck_assignments.deck_id = decks.id
        )
        """
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
            "UPDATE cards SET image_media_id = lower(image_media_id) WHERE image_media_id GLOB '*[A-Z]*'",
            "UPDATE cards SET audio_word_media_id = lower(audio_word_media_id) WHERE audio_word_media_id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET image_media_id = lower(image_media_id) WHERE image_media_id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET audio_example_media_id = lower(audio_example_media_id) WHERE audio_example_media_id GLOB '*[A-Z]*'",
            "UPDATE word_forms SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE example_distractors SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE example_distractors SET example_id = lower(example_id) WHERE example_id GLOB '*[A-Z]*'",
            "UPDATE example_distractors SET source_card_id = lower(source_card_id) WHERE source_card_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_daily_usage SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE deck_daily_usage SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_matching_records SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE deck_matching_records SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET user_id = lower(user_id) WHERE user_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
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
        let status: ContentStatus
        let title: String
        let avatarSystemName: String?
        let avatarMediaID: UUID?
        let languageCode: String
        let newCardsPerDay: Int
        let reviewCardsPerDay: Int
    }

    private func fetchDeckRows() throws -> [DeckRow] {
        let sql = """
        SELECT decks.id, user_deck_assignments.status, decks.title, decks.avatar_system_name,
               decks.avatar_media_id, decks.language_code, decks.new_cards_per_day, decks.review_cards_per_day
        FROM decks
        JOIN user_deck_assignments ON user_deck_assignments.deck_id = decks.id
        WHERE user_deck_assignments.user_id = ?
        ORDER BY title
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
                  let languageCode = textColumn(statement, index: 5) else { continue }
            rows.append(
                DeckRow(
                    id: id,
                    status: statusColumn(statement, index: 1),
                    title: title,
                    avatarSystemName: textColumn(statement, index: 3),
                    avatarMediaID: uuidColumn(statement, index: 4),
                    languageCode: languageCode,
                    newCardsPerDay: Int(sqlite3_column_int(statement, 6)),
                    reviewCardsPerDay: Int(sqlite3_column_int(statement, 7))
                )
            )
        }
        return rows
    }

    private func fetchCards(deckID: UUID) throws -> [WordCardContent] {
        let sql = """
        SELECT id, status, lemma, display_word, part_of_speech, translation,
               short_definition, memory_hint, etymology, usage_note, synonym_note,
               grammar_note, notes, image_media_id, audio_word_media_id
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

        var cards: [WordCardContent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let lemma = textColumn(statement, index: 2),
                  let displayWord = textColumn(statement, index: 3),
                  let translation = textColumn(statement, index: 5),
                  let example = try fetchPrimaryExample(cardID: id) else { continue }

            cards.append(
                WordCardContent(
                    id: id,
                    status: statusColumn(statement, index: 1),
                    word: displayWord,
                    lemma: lemma,
                    partOfSpeech: textColumn(statement, index: 4),
                    translation: translation,
                    clozePrompt: example.template,
                    clozeTemplate: example.template,
                    clozeAnswer: example.answer,
                    clozeExampleTranslation: example.translation,
                    clozeExampleImageURL: resolveMediaURL(
                        deckID: deckID,
                        mediaID: example.imageMediaID ?? uuidColumn(statement, index: 13)
                    ),
                    answerFormKey: example.answerFormKey,
                    shortDefinition: textColumn(statement, index: 6),
                    memoryHint: textColumn(statement, index: 7),
                    etymology: textColumn(statement, index: 8),
                    usageNote: textColumn(statement, index: 9),
                    synonymNote: textColumn(statement, index: 10),
                    grammarNote: textColumn(statement, index: 11),
                    explanation: textColumn(statement, index: 12),
                    imageURL: resolveMediaURL(
                        deckID: deckID,
                        mediaID: uuidColumn(statement, index: 13)
                    ),
                    audioWordURL: resolveMediaURL(
                        deckID: deckID,
                        mediaID: uuidColumn(statement, index: 14)
                    ),
                    audioExampleURL: resolveMediaURL(
                        deckID: deckID,
                        mediaID: example.audioExampleMediaID
                    ),
                    distractors: try fetchDistractors(exampleID: example.id),
                    forms: try fetchForms(cardID: id)
                )
            )
        }
        return cards
    }

    private struct ExampleRow {
        let id: UUID
        let template: String
        let answer: String
        let answerFormKey: String?
        let translation: String?
        let imageMediaID: UUID?
        let audioExampleMediaID: UUID?
    }

    private func fetchPrimaryExample(cardID: UUID) throws -> ExampleRow? {
        let sql = """
        SELECT id, template, answer, answer_form_key, translation, image_media_id, audio_example_media_id
        FROM card_examples
        WHERE card_id = ?
        ORDER BY sort_order, id
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: cardID)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = uuidColumn(statement, index: 0),
              let template = textColumn(statement, index: 1),
              let answer = textColumn(statement, index: 2)
        else {
            return nil
        }
        return ExampleRow(
            id: id,
            template: template,
            answer: answer,
            answerFormKey: textColumn(statement, index: 3),
            translation: textColumn(statement, index: 4),
            imageMediaID: uuidColumn(statement, index: 5),
            audioExampleMediaID: uuidColumn(statement, index: 6)
        )
    }

    private func fetchForms(cardID: UUID) throws -> [WordForm] {
        let sql = """
        SELECT form_key, text
        FROM word_forms
        WHERE card_id = ?
        ORDER BY sort_order, form_key, text
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: cardID)

        var forms: [WordForm] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let formKey = textColumn(statement, index: 0),
                  let text = textColumn(statement, index: 1) else { continue }
            forms.append(WordForm(formKey: formKey, text: text))
        }
        return forms
    }

    private func fetchDistractors(exampleID: UUID) throws -> [String] {
        let sql = """
        SELECT text
        FROM example_distractors
        WHERE example_id = ?
        ORDER BY priority, text
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: exampleID)

        var distractors: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = textColumn(statement, index: 0) else { continue }
            distractors.append(text)
        }
        return distractors
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
