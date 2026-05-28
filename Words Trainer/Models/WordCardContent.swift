import Foundation

/// Card content from server or local seed (no SRS state).
struct WordCardContent: Codable, Identifiable, Hashable {
    let id: UUID
    let word: String
    let translation: String
    let clozePrompt: String
    let clozeAnswer: String
    let explanation: String?
    let imageURL: URL?
    let audioWordURL: URL?
    let audioExampleURL: URL?
    let distractors: [String]

    init(
        id: UUID = UUID(),
        word: String,
        translation: String,
        clozePrompt: String,
        clozeAnswer: String,
        explanation: String? = nil,
        imageURL: URL? = nil,
        audioWordURL: URL? = nil,
        audioExampleURL: URL? = nil,
        distractors: [String] = []
    ) {
        self.id = id
        self.word = word
        self.translation = translation
        self.clozePrompt = clozePrompt
        self.clozeAnswer = clozeAnswer
        self.explanation = explanation
        self.imageURL = imageURL
        self.audioWordURL = audioWordURL
        self.audioExampleURL = audioExampleURL
        self.distractors = distractors
    }
}

struct DeckContent: Identifiable, Hashable {
    let id: UUID
    var title: String
    var avatarSystemName: String?
    var languageCode: String
    var newCardsPerDay: Int
    var reviewCardsPerDay: Int
    var cards: [WordCardContent]
}
