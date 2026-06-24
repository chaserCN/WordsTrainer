import Foundation

enum StudyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case recall
    case flashcards
    case flashcardsReverse
    case clozeMultipleChoice
    case clozeMultipleChoiceReverse
    case clozeTyping
    case translationTyping
    case matching
    case matchingAudio
    case pictureChoice

    var id: String { rawValue }

    static let exerciseModes: [StudyMode] = [
        .flashcards,
        .flashcardsReverse,
        .clozeMultipleChoice,
        .clozeMultipleChoiceReverse,
        .clozeTyping,
        .translationTyping,
        .matching,
        .matchingAudio,
        .pictureChoice,
    ]

    var title: String {
        switch self {
        case .recall: L10n.text("Оставить / Сбросить")
        case .flashcards: L10n.text("Карточки")
        case .flashcardsReverse: L10n.text("Карточки наоборот")
        case .clozeMultipleChoice: L10n.text("Предложения")
        case .clozeMultipleChoiceReverse: L10n.text("Предложения наоборот")
        case .clozeTyping: L10n.text("Письмо: пропуск")
        case .translationTyping: L10n.text("Письмо: перевод")
        case .matching: L10n.text("Колонки")
        case .matchingAudio: L10n.text("Колонки аудио")
        case .pictureChoice: L10n.text("Картинки")
        }
    }

    var isMatching: Bool {
        switch self {
        case .matching, .matchingAudio: true
        default: false
        }
    }

    var isAudioMatching: Bool {
        self == .matchingAudio
    }

    var recordsStudyReview: Bool {
        switch self {
        case .flashcards, .flashcardsReverse, .clozeMultipleChoice, .clozeMultipleChoiceReverse, .clozeTyping, .translationTyping, .pictureChoice:
            true
        case .recall, .matching, .matchingAudio:
            false
        }
    }

    func usesWholeCardCounters(flashcardDisplayMode: FlashcardDisplayMode) -> Bool {
        isFlashcard && flashcardDisplayMode == .wholeCard
    }

    var isFlashcard: Bool {
        self == .flashcards || self == .flashcardsReverse
    }

    var isReversePrompt: Bool {
        self == .flashcardsReverse || self == .clozeMultipleChoiceReverse
    }

    func skipsProgressSave(outcome: ReviewOutcome) -> Bool {
        self == .recall && outcome == .remembered
    }

    func resetsProgress(outcome: ReviewOutcome) -> Bool {
        self == .recall && outcome == .forgot
    }
}

nonisolated enum ReviewOutcome: Sendable, Hashable {
    case remembered
    case forgot
    case correct
    case incorrect

    var passed: Bool {
        switch self {
        case .remembered, .correct: true
        case .forgot, .incorrect: false
        }
    }

    var databaseValue: String {
        switch self {
        case .remembered: "remembered"
        case .forgot: "forgot"
        case .correct: "correct"
        case .incorrect: "incorrect"
        }
    }
}
