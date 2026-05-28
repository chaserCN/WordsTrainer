import Foundation

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case recall
    case clozeMultipleChoice
    case clozeTyping
    case matching

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: "Помню / Забыл"
        case .clozeMultipleChoice: "Предложения"
        case .clozeTyping: "Пропуск — ввод"
        case .matching: "Колонки"
        }
    }

    var updatesSRS: Bool {
        switch self {
        case .matching: false
        default: true
        }
    }
}

enum ReviewOutcome: Sendable {
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
}
