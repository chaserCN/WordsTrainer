import Foundation

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case recall
    case flashcards
    case clozeMultipleChoice
    case clozeTyping
    case matching
    case matchingAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: "Оставить / Сбросить"
        case .flashcards: "Карточки"
        case .clozeMultipleChoice: "Предложения"
        case .clozeTyping: "Пропуск — ввод"
        case .matching: "Колонки"
        case .matchingAudio: "Колонки аудио"
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

    var updatesSRS: Bool {
        switch self {
        case .matching, .matchingAudio: false
        default: true
        }
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

enum ReviewOutcome: Sendable, Hashable {
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
