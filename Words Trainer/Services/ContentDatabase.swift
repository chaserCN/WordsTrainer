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
                status: row.status,
                title: row.title,
                avatarSystemName: row.avatarSystemName,
                languageCode: row.languageCode,
                newCardsPerDay: row.newCardsPerDay,
                reviewCardsPerDay: row.reviewCardsPerDay,
                cards: try fetchCards(deckID: row.id)
            )
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

    func saveStudyReview(_ event: StudyReviewEvent) throws {
        let sql = """
        INSERT INTO study_reviews (
            id, card_id, deck_id, mode, outcome, reviewed_at,
            duration_ms, was_new, previous_state, new_state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, uuid: event.id)
        try bind(statement, index: 2, uuid: event.cardID)
        try bind(statement, index: 3, uuid: event.deckID)
        try bind(statement, index: 4, text: event.mode.rawValue)
        try bind(statement, index: 5, text: event.outcome.databaseValue)
        guard sqlite3_bind_double(statement, 6, event.reviewedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        if let durationMS = event.durationMS {
            guard sqlite3_bind_int(statement, 7, Int32(durationMS)) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        } else {
            guard sqlite3_bind_null(statement, 7) == SQLITE_OK else {
                throw ContentDatabaseError.queryFailed
            }
        }
        guard sqlite3_bind_int(statement, 8, event.wasNew ? 1 : 0) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        try bind(statement, index: 9, text: event.previousState)
        try bind(statement, index: 10, text: event.newState)
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
        WHERE reviewed_at >= ?
        GROUP BY day_key
        ORDER BY day_key
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970) == SQLITE_OK else {
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
        WHERE reviewed_at >= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970) == SQLITE_OK else {
            throw ContentDatabaseError.queryFailed
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return .zero }
        return StudyReviewCount(
            total: Int(sqlite3_column_int(statement, 0)),
            passed: Int(sqlite3_column_int(statement, 1))
        )
    }

    func weakCards(limit: Int = 10) throws -> [WeakCardStat] {
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
        WHERE cards.status = 'active' AND decks.status = 'active'
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
        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
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
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
            title TEXT NOT NULL,
            avatar_system_name TEXT,
            language_code TEXT NOT NULL,
            new_cards_per_day INTEGER NOT NULL,
            review_cards_per_day INTEGER NOT NULL
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
            image_url TEXT,
            audio_word_path TEXT,
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
            audio_example_path TEXT,
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
        CREATE TABLE IF NOT EXISTS study_reviews (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL,
            deck_id TEXT NOT NULL,
            mode TEXT NOT NULL,
            outcome TEXT NOT NULL,
            reviewed_at REAL NOT NULL,
            duration_ms INTEGER,
            was_new INTEGER NOT NULL,
            previous_state TEXT,
            new_state TEXT,
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
    }

    private func normalizeUUIDColumns() throws {
        let statements = [
            "UPDATE decks SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE cards SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE cards SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE card_examples SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE word_forms SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE example_distractors SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
            "UPDATE example_distractors SET example_id = lower(example_id) WHERE example_id GLOB '*[A-Z]*'",
            "UPDATE example_distractors SET source_card_id = lower(source_card_id) WHERE source_card_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET card_id = lower(card_id) WHERE card_id GLOB '*[A-Z]*'",
            "UPDATE card_progress SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_daily_usage SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE deck_matching_records SET deck_id = lower(deck_id) WHERE deck_id GLOB '*[A-Z]*'",
            "UPDATE study_reviews SET id = lower(id) WHERE id GLOB '*[A-Z]*'",
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
        let languageCode: String
        let newCardsPerDay: Int
        let reviewCardsPerDay: Int
    }

    private func fetchDeckRows() throws -> [DeckRow] {
        let sql = """
        SELECT id, status, title, avatar_system_name, language_code,
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
                  let title = textColumn(statement, index: 2),
                  let languageCode = textColumn(statement, index: 4) else { continue }
            rows.append(
                DeckRow(
                    id: id,
                    status: statusColumn(statement, index: 1),
                    title: title,
                    avatarSystemName: textColumn(statement, index: 3),
                    languageCode: languageCode,
                    newCardsPerDay: Int(sqlite3_column_int(statement, 5)),
                    reviewCardsPerDay: Int(sqlite3_column_int(statement, 6))
                )
            )
        }
        return rows
    }

    private func fetchCards(deckID: UUID) throws -> [WordCardContent] {
        let sql = """
        SELECT id, status, lemma, display_word, part_of_speech, translation,
               short_definition, memory_hint, etymology, usage_note, synonym_note,
               grammar_note, notes, image_url, audio_word_path
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
                    answerFormKey: example.answerFormKey,
                    shortDefinition: textColumn(statement, index: 6),
                    memoryHint: textColumn(statement, index: 7),
                    etymology: textColumn(statement, index: 8),
                    usageNote: textColumn(statement, index: 9),
                    synonymNote: textColumn(statement, index: 10),
                    grammarNote: textColumn(statement, index: 11),
                    explanation: textColumn(statement, index: 12),
                    imageURL: textColumn(statement, index: 13).flatMap(URL.init(string:)),
                    audioWordURL: resolveMediaURL(
                        deckID: deckID,
                        relativePath: textColumn(statement, index: 14)
                    ),
                    audioExampleURL: resolveMediaURL(
                        deckID: deckID,
                        relativePath: example.audioExamplePath
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
        let audioExamplePath: String?
    }

    private func fetchPrimaryExample(cardID: UUID) throws -> ExampleRow? {
        let sql = """
        SELECT id, template, answer, answer_form_key, translation, audio_example_path
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
            audioExamplePath: textColumn(statement, index: 5)
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
