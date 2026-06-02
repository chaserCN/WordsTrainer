import Foundation
import FSRS

struct StudyQueueItem: Identifiable, Sendable {
    let id: UUID
    let deckID: UUID?
    let card: WordCardContent
    let progress: CardProgress

    init(card: WordCardContent, progress: CardProgress, deckID: UUID? = nil) {
        self.id = card.id
        self.deckID = deckID
        self.card = card
        self.progress = progress
    }

    func withDeckID(_ deckID: UUID) -> StudyQueueItem {
        StudyQueueItem(card: card, progress: progress, deckID: deckID)
    }
}

/// One word sense paired with one translation line in matching columns.
struct MatchingPair: Identifiable, Sendable, Hashable {
    let cardID: UUID
    let card: WordCardContent
    let senseIndex: Int
    let translation: String

    var id: String { "\(cardID.uuidString)-\(senseIndex)" }

    static func pairs(from item: StudyQueueItem) -> [MatchingPair] {
        let senses = WordCardContent.translationSenses(item.card.translation)
        if senses.isEmpty {
            return [
                MatchingPair(
                    cardID: item.card.id,
                    card: item.card,
                    senseIndex: 0,
                    translation: item.card.translation
                ),
            ]
        }
        return senses.enumerated().map { index, sense in
            MatchingPair(
                cardID: item.card.id,
                card: item.card,
                senseIndex: index,
                translation: sense
            )
        }
    }
}

enum StudyQueueBuilder {
    static func build(
        deck: DeckContent,
        progressByCardID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now
    ) -> [StudyQueueItem] {
        var rng = SystemRandomNumberGenerator()
        return build(
            deck: deck,
            progressByCardID: progressByCardID,
            dailyUsage: dailyUsage,
            now: now,
            using: &rng
        )
    }

    static func build<RNG: RandomNumberGenerator>(
        deck: DeckContent,
        progressByCardID: [UUID: CardProgress],
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
            let progress = progressByCardID[content.id]
                ?? CardProgress.newCard(cardID: content.id, now: now)
            let fsrs = progress.fsrsCard
            let item = StudyQueueItem(card: content, progress: progress)

            switch fsrs.state {
            case .new:
                if newSlotsLeft > 0 {
                    newCards.append(item)
                }
            case .learning, .relearning:
                if fsrs.due <= now {
                    learning.append(item)
                }
            case .review:
                if fsrs.due <= now {
                    review.append(item)
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

    init(parameters: FSRSParameters = FSRSParameters()) {
        self.scheduler = FSRS(parameters: parameters)
    }

    func applyReview(
        progress: CardProgress,
        outcome: ReviewOutcome,
        now: Date = .now
    ) throws -> CardProgress {
        let updated = try BinaryFSRS.review(
            scheduler: scheduler,
            card: progress.fsrsCard,
            passed: outcome.passed,
            now: now
        )
        return CardProgress(cardID: progress.cardID, fsrsCard: updated, updatedAt: now)
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
