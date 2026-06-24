import SwiftUI

struct StudyModeMenuItem: Identifiable {
    let mode: StudyMode
    let subtitle: String
    let systemImage: String
    let accent: Color

    var id: StudyMode { mode }

    /// Title is owned by `StudyMode.title` so the menu button and the in-session
    /// navigation bar never drift apart; only UI chrome lives here.
    var title: String { mode.title }

    init?(_ mode: StudyMode) {
        self.mode = mode
        switch mode {
        case .flashcards:
            subtitle = "Слово, перевод и заметки — переворот по тапу"
            systemImage = "rectangle.on.rectangle.angled"
            accent = .orange
        case .flashcardsReverse:
            subtitle = "Перевод и пример — вспомни английское слово"
            systemImage = "arrow.left.arrow.right.square"
            accent = .orange
        case .clozeMultipleChoice:
            subtitle = "Выбери слово для примера с пропуском"
            systemImage = "text.quote"
            accent = .blue
        case .clozeMultipleChoiceReverse:
            subtitle = "Русский перевод предложения — выбери английское слово"
            systemImage = "quote.bubble"
            accent = .blue
        case .matching:
            subtitle = "Соедини слово и перевод"
            systemImage = "rectangle.split.2x1.fill"
            accent = .green
        case .matchingAudio:
            subtitle = "Слушай слово и выбирай перевод"
            systemImage = "speaker.wave.2.fill"
            accent = .cyan
        case .pictureChoice:
            subtitle = "Смотри картинку — выбери слово"
            systemImage = "photo"
            accent = .pink
        case .clozeTyping:
            subtitle = "Впиши слово в пропуск по буквам"
            systemImage = "keyboard"
            accent = .indigo
        case .translationTyping:
            subtitle = "Смотри перевод и пример — напиши английское слово"
            systemImage = "pencil"
            accent = .indigo
        case .recall:
            subtitle = "Покажи слово и реши: оставить прогресс или начать заново"
            systemImage = "eye.fill"
            accent = .purple
        }
    }

    @MainActor
    static var exercises: [StudyModeMenuItem] {
        StudyMode.exerciseModes.compactMap(StudyModeMenuItem.init)
    }

    @MainActor
    static var sections: [StudyModeMenuSection] {
        [
            StudyModeMenuSection(title: L10n.text("Флешкарты"), modes: [.flashcards, .flashcardsReverse]),
            StudyModeMenuSection(title: L10n.text("Предложения"), modes: [.clozeMultipleChoice, .clozeMultipleChoiceReverse]),
            StudyModeMenuSection(title: L10n.text("Письмо"), modes: [.clozeTyping, .translationTyping]),
            StudyModeMenuSection(title: L10n.text("Колонки"), modes: [.matching, .matchingAudio]),
            StudyModeMenuSection(title: L10n.text("Картинки"), modes: [.pictureChoice]),
        ]
    }

    @MainActor
    static var reset: StudyModeMenuItem {
        StudyModeMenuItem(.recall)!
    }

    func isEnabled(canStart: Bool, hasImagedCards: Bool) -> Bool {
        canStart && (!mode.requiresImagedSenseQueue || hasImagedCards)
    }

    func subtitle(matchingRecordSubtitle: String?) -> String {
        switch mode {
        case .matching:
            matchingRecordSubtitle ?? subtitle
        default:
            subtitle
        }
    }
}

struct StudyModeMenuSection: Identifiable {
    let title: String
    let items: [StudyModeMenuItem]

    var id: String { title }

    @MainActor
    init(title: String, modes: [StudyMode]) {
        self.title = title
        items = modes.compactMap(StudyModeMenuItem.init)
    }
}
