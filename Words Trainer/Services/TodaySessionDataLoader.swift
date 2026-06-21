import Foundation

@MainActor
final class TodaySessionDataLoader {
    private let userID: UUID
    private let database: ContentDatabase

    init(userID: UUID, database: ContentDatabase) {
        self.userID = userID
        self.database = database
    }

    /// Active decks with full card content (examples, questions, audio), favoring
    /// the warm cache. The deck shells and sense rows come from the cheap lite
    /// load; each deck's cards are replaced with the cached full cards when warmed.
    func activeDecksWithFullCardsFavoringCache() throws -> [DeckContent] {
        let started = Date()
        var hits = 0
        var dbLoads = 0
        let decks = try database.loadDecksLite().filter(\.isActive).map { deck -> DeckContent in
            if let cached = StudyCardCache.shared.cards(deckID: deck.id, userID: userID) {
                hits += 1
                var full = deck
                full.cards = cached
                return full
            }
            dbLoads += 1
            let fullCards = try database.deckCards(deckID: deck.id)
            guard !fullCards.isEmpty else { return deck }
            var full = deck
            full.cards = fullCards
            return full
        }
        if dbLoads == 0 {
            Log.log("Cache", "all \(decks.count) decks' cards served from warm cache (no DB) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        } else {
            Log.log("Cache", "\(hits) deck(s) from cache, \(dbLoads) loaded from DB (cache cold) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        return decks
    }

    /// Return the deck with full card content (examples, questions, media URLs).
    ///
    /// Views may hand us a lightweight deck painted before full content loaded.
    /// Reload just this deck's cards from cache/DB so study starts with audio and
    /// examples intact.
    func deckWithFullCards(_ deck: DeckContent) throws -> DeckContent {
        let looksLite = deck.cards.contains { card in
            card.activeSenses.contains { $0.example.text.isEmpty }
        }
        guard looksLite else {
            Log.log("Cache", "study deck '\(deck.title)': already full (came in with content, e.g. from Колоди) — no load")
            return deck
        }

        let fullCards: [WordCardContent]
        if let cached = StudyCardCache.shared.cards(deckID: deck.id, userID: userID) {
            Log.log("Cache", "study deck '\(deck.title)': \(cached.count) cards from warm cache (no DB)")
            fullCards = cached
        } else {
            let started = Date()
            fullCards = try database.deckCards(deckID: deck.id)
            Log.log("Cache", "study deck '\(deck.title)': cache cold, loaded \(fullCards.count) cards from DB in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        guard !fullCards.isEmpty else { return deck }
        var full = deck
        full.cards = fullCards
        return full
    }

    func todaySnapshots() throws -> [TodayStudyDeckSnapshot] {
        let started = Date()
        // Card content comes from the warm cache (fast); each snapshot still reads
        // fresh progress from the DB, so today's queue reflects cards just studied.
        let decks = try activeDecksWithFullCardsFavoringCache()
        let snapshots = try decks.map { try todaySnapshot(deck: $0) }
        Log.log("Today", "built today's queue for all \(snapshots.count) decks (content from cache, progress fresh from DB) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return snapshots
    }

    func todaySnapshots(deckIDs: Set<UUID>) throws -> [TodayStudyDeckSnapshot] {
        guard !deckIDs.isEmpty else { return [] }
        let started = Date()
        let decks = try activeDecksWithFullCardsFavoringCache().filter { deckIDs.contains($0.id) }
        let snapshots = try decks.map { try todaySnapshot(deck: $0) }
        Log.log("Today", "built today's queue for \(snapshots.count) selected deck(s) (content from cache, progress fresh from DB) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return snapshots
    }

    func todaySnapshot(deck: DeckContent) throws -> TodayStudyDeckSnapshot {
        try TodaySnapshotBuilder.deckSnapshot(database: database, deck: deck)
    }
}
