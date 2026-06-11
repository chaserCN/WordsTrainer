import Foundation

/// App-wide warm cache of full study cards (examples, questions, media URLs).
///
/// The dashboard paints from lightweight decks (fetchCardsLite: empty examples,
/// audioWordURL == nil) for a fast first frame. Study, however, needs full cards
/// or the flashcard plays TTS instead of the recording. Rather than load one
/// deck synchronously at session start, we warm every active deck in the
/// background shortly after launch and after each sync, so entering study is
/// instant and always has audio.
///
/// Correctness rule: the cache MUST be cleared whenever content changes, or it
/// would serve a stale card set after a sync (e.g. a newly added card without
/// its audio). Invalidation is driven by AppUserStore on sync completion and by
/// DeckStore.localDataDidChange; the cache is also scoped to a userID and drops
/// everything when the selected user changes.
@MainActor
final class StudyCardCache {
    static let shared = StudyCardCache()

    private var userID: UUID?
    private var cardsByDeckID: [UUID: [WordCardContent]] = [:]
    private var warmTask: Task<Void, Never>?

    private init() {}

    /// Full cards for a deck if warmed for this user, else nil (caller loads from DB).
    func cards(deckID: UUID, userID: UUID) -> [WordCardContent]? {
        guard self.userID == userID else { return nil }
        return cardsByDeckID[deckID]
    }

    /// Drop everything. Call on content change (sync), local edits, or user switch.
    func invalidate() {
        warmTask?.cancel()
        warmTask = nil
        cardsByDeckID = [:]
        userID = nil
    }

    /// Reload full cards for every active deck of `userID` off the main actor,
    /// then publish them on the main actor. Cheap to call repeatedly: a new warm
    /// supersedes any in-flight one. A failed load just leaves the cache empty,
    /// and the DB fallback in DeckStore still serves correct cards.
    func warm(userID: UUID) {
        warmTask?.cancel()
        let started = Date()
        Log.log("Cache", "warm START user=\(userID.uuidString)")
        warmTask = Task { [weak self] in
            let loaded: [UUID: [WordCardContent]]
            do {
                loaded = try await Task.detached(priority: .utility) {
                    let database = try ContentDatabase(userID: userID, mode: .readOnly)
                    return try database.readTransaction {
                        var result: [UUID: [WordCardContent]] = [:]
                        for deck in try database.loadDecks() where deck.isActive {
                            result[deck.id] = deck.cards
                        }
                        return result
                    }
                }.value
            } catch is CancellationError {
                Log.log("Cache", "warm CANCELLED user=\(userID.uuidString)")
                return
            } catch {
                Log.log("Cache", "warm FAILED: \(error.localizedDescription)")
                return
            }
            guard !Task.isCancelled else { return }
            self?.cardsByDeckID = loaded
            self?.userID = userID
            let cards = loaded.values.reduce(0) { $0 + $1.count }
            Log.log("Cache", "warm DONE decks=\(loaded.count) cards=\(cards) ms=\(Int(Date().timeIntervalSince(started) * 1000)) user=\(userID.uuidString)")
        }
    }

    /// Convenience for the common "content changed, refill for the active user".
    func invalidateAndWarm(userID: UUID?) {
        invalidate()
        if let userID {
            warm(userID: userID)
        }
    }
}
