import Foundation
import FSRS

struct StudyQueueItem: Identifiable, Sendable {
    let id: UUID
    let card: WordCardContent
    let progress: CardProgress

    init(card: WordCardContent, progress: CardProgress) {
        self.id = card.id
        self.card = card
        self.progress = progress
    }
}

enum StudyQueueBuilder {
    static func build(
        deck: DeckContent,
        progressByCardID: [UUID: CardProgress],
        dailyUsage: DeckDailyUsage?,
        now: Date = .now
    ) -> [StudyQueueItem] {
        var learning: [StudyQueueItem] = []
        var review: [StudyQueueItem] = []
        var newCards: [StudyQueueItem] = []

        let studiedToday = dailyUsage?.newCardsStudied ?? 0
        let newSlotsLeft = max(0, deck.newCardsPerDay - studiedToday)

        for content in deck.cards {
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
                if fsrs.due <= now, review.count < deck.reviewCardsPerDay {
                    review.append(item)
                }
            }
        }

        learning.sort { $0.progress.fsrsCard.due < $1.progress.fsrsCard.due }
        review.sort { $0.progress.fsrsCard.due < $1.progress.fsrsCard.due }

        let takenNew = Array(newCards.prefix(min(newCards.count, newSlotsLeft)))
        return learning + review + takenNew
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
