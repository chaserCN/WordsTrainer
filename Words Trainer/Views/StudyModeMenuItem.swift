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
        case .clozeMultipleChoice:
            subtitle = "Выбери слово для примера с пропуском"
            systemImage = "text.quote"
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
        case .recall:
            subtitle = "Покажи слово и реши: оставить прогресс или начать заново"
            systemImage = "eye.fill"
            accent = .purple
        case .clozeTyping:
            return nil
        }
    }

    @MainActor
    static var exercises: [StudyModeMenuItem] {
        StudyMode.exerciseModes.compactMap(StudyModeMenuItem.init)
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
