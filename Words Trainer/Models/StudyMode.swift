import Foundation

enum StudyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case recall
    case flashcards
    case clozeMultipleChoice
    case clozeTyping
    case matching
    case matchingAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: L10n.text("Оставить / Сбросить")
        case .flashcards: L10n.text("Карточки")
        case .clozeMultipleChoice: L10n.text("Предложения")
        case .clozeTyping: L10n.text("Пропуск — ввод")
        case .matching: L10n.text("Колонки")
        case .matchingAudio: L10n.text("Колонки аудио")
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
        case .flashcards, .clozeMultipleChoice, .clozeTyping:
            true
        case .recall, .matching, .matchingAudio:
            false
        }
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
