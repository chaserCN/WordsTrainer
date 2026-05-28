import Foundation
import FSRS
import SwiftData

@Model
final class DeckRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var avatarSystemName: String?
    var languageCode: String
    var newCardsPerDay: Int
    var reviewCardsPerDay: Int
    @Relationship(deleteRule: .cascade, inverse: \CardRecord.deck)
    var cards: [CardRecord]

    init(
        id: UUID,
        title: String,
        avatarSystemName: String? = nil,
        languageCode: String,
        newCardsPerDay: Int,
        reviewCardsPerDay: Int,
        cards: [CardRecord] = []
    ) {
        self.id = id
        self.title = title
        self.avatarSystemName = avatarSystemName
        self.languageCode = languageCode
        self.newCardsPerDay = newCardsPerDay
        self.reviewCardsPerDay = reviewCardsPerDay
        self.cards = cards
    }

    func toContent() -> DeckContent {
        DeckContent(
            id: id,
            title: title,
            avatarSystemName: avatarSystemName,
            languageCode: languageCode,
            newCardsPerDay: newCardsPerDay,
            reviewCardsPerDay: reviewCardsPerDay,
            cards: cards.map { $0.toContent() }.sorted { $0.word < $1.word }
        )
    }
}

@Model
final class CardRecord {
    @Attribute(.unique) var id: UUID
    var word: String
    var translation: String
    var clozePrompt: String
    var clozeAnswer: String
    var explanation: String?
    var imageURLString: String?
    var audioWordURLString: String?
    var audioExampleURLString: String?
    var distractorsJSON: String
    var deck: DeckRecord?

    init(from content: WordCardContent, deck: DeckRecord? = nil) {
        id = content.id
        word = content.word
        translation = content.translation
        clozePrompt = content.clozePrompt
        clozeAnswer = content.clozeAnswer
        explanation = content.explanation
        imageURLString = content.imageURL?.absoluteString
        audioWordURLString = content.audioWordURL?.absoluteString
        audioExampleURLString = content.audioExampleURL?.absoluteString
        distractorsJSON = (try? String(data: JSONEncoder().encode(content.distractors), encoding: .utf8)) ?? "[]"
        self.deck = deck
    }

    func toContent() -> WordCardContent {
        let distractors: [String] = {
            guard let data = distractorsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }()
        return WordCardContent(
            id: id,
            word: word,
            translation: translation,
            clozePrompt: clozePrompt,
            clozeAnswer: clozeAnswer,
            explanation: explanation,
            imageURL: imageURLString.flatMap(URL.init(string:)),
            audioWordURL: audioWordURLString.flatMap(URL.init(string:)),
            audioExampleURL: audioExampleURLString.flatMap(URL.init(string:)),
            distractors: distractors
        )
    }
}

@Model
final class CardProgressRecord {
    @Attribute(.unique) var cardID: UUID
    var deckID: UUID
    var fsrsData: Data
    var updatedAt: Date

    init(cardID: UUID, deckID: UUID, fsrsData: Data, updatedAt: Date) {
        self.cardID = cardID
        self.deckID = deckID
        self.fsrsData = fsrsData
        self.updatedAt = updatedAt
    }

    func toProgress() throws -> CardProgress {
        let card = try JSONDecoder().decode(Card.self, from: fsrsData)
        return CardProgress(cardID: cardID, fsrsCard: card, updatedAt: updatedAt)
    }

    static func encode(_ progress: CardProgress, deckID: UUID) throws -> CardProgressRecord {
        let data = try JSONEncoder().encode(progress.fsrsCard)
        return CardProgressRecord(
            cardID: progress.cardID,
            deckID: deckID,
            fsrsData: data,
            updatedAt: progress.updatedAt
        )
    }
}

@Model
final class DeckDailyUsageRecord {
    var deckID: UUID
    var dayKey: String
    var newCardsStudied: Int

    init(deckID: UUID, dayKey: String, newCardsStudied: Int) {
        self.deckID = deckID
        self.dayKey = dayKey
        self.newCardsStudied = newCardsStudied
    }

    func toUsage() -> DeckDailyUsage {
        DeckDailyUsage(dayKey: dayKey, newCardsStudied: newCardsStudied)
    }
}
