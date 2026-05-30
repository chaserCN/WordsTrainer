import Foundation
import FSRS
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read/write access to `Documents/Data/flashgame.db` (content + study progress).
final class ContentDatabase {
    private var db: OpaquePointer?

    init() throws {
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
                title: row.title,
                avatarSystemName: row.avatarSystemName,
                languageCode: row.languageCode,
                newCardsPerDay: row.newCardsPerDay,
                reviewCardsPerDay: row.reviewCardsPerDay,
                cards: try fetchCards(deckID: row.id)
            )
        }
    }

    func progressMap(deckID: UUID) throws -> [UUID: CardProgress] {
        let sql = """
        SELECT card_id, fsrs_data, updated_at
        FROM card_progress
        WHERE deck_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: deckID)

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
        WHERE deck_id = ? AND day_key = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: deckID)
        try bind(statement, index: 2, text: dayKey)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_int(statement, 0))
        return DeckDailyUsage(dayKey: dayKey, newCardsStudied: count)
    }

    func saveProgress(deckID: UUID, progress: CardProgress) throws {
        let fsrsData = try JSONEncoder().encode(progress.fsrsCard)
        let sql = """
        INSERT INTO card_progress (card_id, deck_id, fsrs_data, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(card_id) DO UPDATE SET
            deck_id = excluded.deck_id,
            fsrs_data = excluded.fsrs_data,
            updated_at = excluded.updated_at
        """
        try exec(
            sql,
            uuid: progress.cardID,
            uuid2: deckID,
            blob: fsrsData,
            double: progress.updatedAt.timeIntervalSince1970
        )
    }

    func saveDailyUsage(deckID: UUID, usage: DeckDailyUsage) throws {
        let sql = """
        INSERT INTO deck_daily_usage (deck_id, day_key, new_cards_studied)
        VALUES (?, ?, ?)
        ON CONFLICT(deck_id, day_key) DO UPDATE SET
            new_cards_studied = excluded.new_cards_studied
        """
        try exec(sql, uuid: deckID, text: usage.dayKey, int: usage.newCardsStudied)
    }

    func matchingRecord(deckID: UUID) throws -> DeckMatchingRecord? {
        let sql = """
        SELECT best_duration_seconds, pair_count, achieved_at
        FROM deck_matching_records
        WHERE deck_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: deckID)

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
        INSERT INTO deck_matching_records (deck_id, best_duration_seconds, pair_count, achieved_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(deck_id) DO UPDATE SET
            best_duration_seconds = excluded.best_duration_seconds,
            pair_count = excluded.pair_count,
            achieved_at = excluded.achieved_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: record.deckID)
        guard sqlite3_bind_double(statement, 2, record.bestDuration) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_bind_int(statement, 3, Int32(record.pairCount)) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_bind_double(statement, 4, record.achievedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContentDatabaseError.queryFailed
        }
    }

    // MARK: - Schema

    private func executeMigrations() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS decks (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            avatar_system_name TEXT,
            language_code TEXT NOT NULL,
            new_cards_per_day INTEGER NOT NULL,
            review_cards_per_day INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cards (
            id TEXT PRIMARY KEY NOT NULL,
            deck_id TEXT NOT NULL,
            word TEXT NOT NULL,
            translation TEXT NOT NULL,
            cloze_prompt TEXT NOT NULL,
            cloze_answer TEXT,
            explanation TEXT,
            image_url TEXT,
            audio_word_path TEXT,
            audio_example_path TEXT,
            distractors_json TEXT NOT NULL DEFAULT '[]',
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_cards_deck_id ON cards(deck_id);
        CREATE TABLE IF NOT EXISTS card_progress (
            card_id TEXT PRIMARY KEY NOT NULL,
            deck_id TEXT NOT NULL,
            fsrs_data BLOB NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE INDEX IF NOT EXISTS idx_card_progress_deck_id ON card_progress(deck_id);
        CREATE TABLE IF NOT EXISTS deck_daily_usage (
            deck_id TEXT NOT NULL,
            day_key TEXT NOT NULL,
            new_cards_studied INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (deck_id, day_key),
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        CREATE TABLE IF NOT EXISTS deck_matching_records (
            deck_id TEXT PRIMARY KEY NOT NULL,
            best_duration_seconds REAL NOT NULL,
            pair_count INTEGER NOT NULL,
            achieved_at REAL NOT NULL,
            FOREIGN KEY (deck_id) REFERENCES decks(id)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ContentDatabaseError.migrationFailed
        }
    }

    private func normalizeUUIDColumns() throws {
        let statements = [
            "UPDATE decks SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE cards SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE cards SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_daily_usage SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_matching_records SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
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
        let title: String
        let avatarSystemName: String?
        let languageCode: String
        let newCardsPerDay: Int
        let reviewCardsPerDay: Int
    }

    private func fetchDeckRows() throws -> [DeckRow] {
        let sql = """
        SELECT id, title, avatar_system_name, language_code,
               new_cards_per_day, review_cards_per_day
        FROM decks
        ORDER BY title
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var rows: [DeckRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let title = textColumn(statement, index: 1),
                  let languageCode = textColumn(statement, index: 3) else { continue }
            rows.append(
                DeckRow(
                    id: id,
                    title: title,
                    avatarSystemName: textColumn(statement, index: 2),
                    languageCode: languageCode,
                    newCardsPerDay: Int(sqlite3_column_int(statement, 4)),
                    reviewCardsPerDay: Int(sqlite3_column_int(statement, 5))
                )
            )
        }
        return rows
    }

    private func fetchCards(deckID: UUID) throws -> [WordCardContent] {
        let sql = """
        SELECT id, word, translation, cloze_prompt, cloze_answer, explanation,
               image_url, audio_word_path, audio_example_path, distractors_json
        FROM cards
        WHERE deck_id = ?
        ORDER BY word
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
                  let word = textColumn(statement, index: 1),
                  let translation = textColumn(statement, index: 2),
                  let clozePrompt = textColumn(statement, index: 3) else { continue }

            let distractorsJSON = textColumn(statement, index: 9) ?? "[]"
            let distractors = (try? JSONDecoder().decode([String].self, from: Data(distractorsJSON.utf8))) ?? []

            cards.append(
                WordCardContent(
                    id: id,
                    word: word,
                    translation: translation,
                    clozePrompt: clozePrompt,
                    clozeAnswer: textColumn(statement, index: 4),
                    explanation: textColumn(statement, index: 5),
                    imageURL: textColumn(statement, index: 6).flatMap(URL.init(string:)),
                    audioWordURL: resolveMediaURL(
                        deckID: deckID,
                        relativePath: textColumn(statement, index: 7)
                    ),
                    audioExampleURL: resolveMediaURL(
                        deckID: deckID,
                        relativePath: textColumn(statement, index: 8)
                    ),
                    distractors: distractors
                )
            )
        }
        return cards
    }

    private func resolveMediaURL(deckID: UUID, relativePath: String?) -> URL? {
        guard let relativePath else { return nil }
        return try? AppDataPaths.mediaFileURL(deckID: deckID, relativePath: relativePath)
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

    private func bind(_ statement: OpaquePointer?, index: Int32, uuid: UUID) throws {
        try bind(statement, index: index, text: uuid.databaseString)
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, text: String) throws {
        try text.withCString { cString in
            guard sqlite3_bind_text(statement, index, cString, -1, sqliteTransient) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
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
}

enum ContentDatabaseError: Error {
    case openFailed
    case queryFailed
    case migrationFailed
}
