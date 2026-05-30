import Foundation

/// Card content from server or local seed (no SRS state).
struct WordCardContent: Codable, Identifiable, Hashable {
    let id: UUID
    let word: String
    let translation: String
    let clozePrompt: String
    /// Override when the gap uses a different form than `word` (e.g. went vs go).
    let clozeAnswer: String?
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
        clozeAnswer: String? = nil,
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

    /// Answer accepted in cloze exercises when `clozeAnswer` is nil.
    var effectiveClozeAnswer: String {
        if let clozeAnswer, !clozeAnswer.isEmpty {
            return clozeAnswer
        }
        return Self.headword(from: word)
    }

    /// Semicolon-separated senses in `translation` (trimmed, non-empty).
    static func translationSenses(_ translation: String) -> [String] {
        translation.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func headword(from word: String) -> String {
        var plain = word.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        plain = plain.split(separator: "(", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? plain
        let lower = plain.lowercased()
        if lower.hasPrefix("an ") {
            plain = String(plain.dropFirst(3))
        } else if lower.hasPrefix("a ") {
            plain = String(plain.dropFirst(2))
        } else if lower.hasPrefix("the ") {
            plain = String(plain.dropFirst(4))
        }
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
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
