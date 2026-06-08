import Foundation
import FSRS

nonisolated struct StudyQueueItem: Identifiable, Sendable {
    let id: UUID
    let deckID: UUID?
    let cardID: UUID
    let senseID: UUID
    let card: WordCardContent
    let sense: WordSenseContent
    let progress: CardProgress

    init(card: WordCardContent, sense: WordSenseContent, progress: CardProgress, deckID: UUID? = nil) {
        self.id = sense.id
        self.deckID = deckID
        self.cardID = sense.cardID
        self.senseID = sense.id
        self.sense = sense
        self.card = card.focused(on: sense)
        self.progress = progress
    }

    func withDeckID(_ deckID: UUID) -> StudyQueueItem {
        StudyQueueItem(card: card, sense: sense, progress: progress, deckID: deckID)
    }
}

/// One word sense paired with one translation line in matching columns.
struct MatchingPair: Identifiable, Sendable, Hashable {
    let cardID: UUID
    let senseID: UUID
    let deckID: UUID?
    let card: WordCardContent
    let translation: String
    var progress: CardProgress

    var id: String { senseID.uuidString }

    init(
        cardID: UUID,
        senseID: UUID,
        deckID: UUID? = nil,
        card: WordCardContent,
        translation: String,
        progress: CardProgress? = nil
    ) {
        self.cardID = cardID
        self.senseID = senseID
        self.deckID = deckID
        self.card = card
        self.translation = translation
        self.progress = progress ?? CardProgress.newSense(senseID: senseID)
    }

    static func pairs(from item: StudyQueueItem) -> [MatchingPair] {
        [
            MatchingPair(
                cardID: item.cardID,
                senseID: item.senseID,
                deckID: item.deckID,
                card: item.card,
                translation: item.sense.translation,
                progress: item.progress
            ),
        ]
    }
}

nonisolated enum StudyQueueBuilder {
    static func allItems(
        cards: [WordCardContent],
        progressBySenseID: [UUID: CardProgress],
        deckID: UUID? = nil,
        now: Date = .now
    ) -> [StudyQueueItem] {
        cards.flatMap { card in
            card.activeSenses.map { sense in
                StudyQueueItem(
                    card: card,
                    sense: sense,
                    progress: progressBySenseID[sense.id] ?? CardProgress.newSense(senseID: sense.id, now: now),
                    deckID: deckID
                )
            }
        }
    }

    static func build(
        deck: DeckContent,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now
    ) -> [StudyQueueItem] {
        var rng = SystemRandomNumberGenerator()
        return build(
            deck: deck,
            progressBySenseID: progressBySenseID,
            dailyUsage: dailyUsage,
            now: now,
            using: &rng
        )
    }

    static func build<RNG: RandomNumberGenerator>(
        deck: DeckContent,
        progressBySenseID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now,
        using rng: inout RNG
    ) -> [StudyQueueItem] {
        guard deck.isActive else { return [] }

        var learning: [StudyQueueItem] = []
        var review: [StudyQueueItem] = []
        var newCards: [StudyQueueItem] = []

        let studiedToday = dailyUsage?.newCardsStudied ?? 0
        let newSlotsLeft = max(0, deck.newCardsPerDay - studiedToday)

        for content in deck.activeCards {
            for sense in content.activeSenses {
                let progress = progressBySenseID[sense.id]
                    ?? CardProgress.newSense(senseID: sense.id, now: now)
                let fsrs = progress.fsrsCard
                let due = ReviewSchedule.availableDate(for: fsrs.due)
                let item = StudyQueueItem(card: content, sense: sense, progress: progress)

                switch fsrs.state {
                case .new:
                    if newSlotsLeft > 0 {
                        newCards.append(item)
                    }
                case .learning, .relearning:
                    if due <= now {
                        learning.append(item)
                    }
                case .review:
                    if due <= now {
                        review.append(item)
                    }
                }
            }
        }

        learning.shuffle(using: &rng)
        review.shuffle(using: &rng)
        newCards.shuffle(using: &rng)

        let takenReview = Array(review.prefix(min(review.count, deck.reviewCardsPerDay)))
        let takenNew = Array(newCards.prefix(min(newCards.count, newSlotsLeft)))
        return learning + takenReview + takenNew
    }
}

final class StudySessionEngine: @unchecked Sendable {
    let scheduler: FSRS

    init(parameters: FSRSParameters = FSRSParameters(enableShortTerm: false)) {
        self.scheduler = FSRS(parameters: parameters)
    }

    func applyReview(
        progress: CardProgress,
        outcome: ReviewOutcome,
        now: Date = .now
    ) throws -> CardProgress {
        var updated = try BinaryFSRS.review(
            scheduler: scheduler,
            card: progress.fsrsCard,
            passed: outcome.passed,
            now: now
        )
        updated.due = ReviewSchedule.availableDate(for: updated.due)
        return CardProgress(senseID: progress.senseID, fsrsCard: updated, updatedAt: now)
    }

    func recordNewCardStudied(previous: DeckDailyUsage?) -> DeckDailyUsage {
        let key = DeckDailyUsage.todayKey()
        var usage = previous ?? DeckDailyUsage(dayKey: key)
        if usage.dayKey != key {
            usage = DeckDailyUsage(dayKey: key)
        }
        usage.newCardsStudied += 1
        return usage
    }
}
