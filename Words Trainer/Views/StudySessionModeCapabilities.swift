import SwiftUI

enum StudyModeToolbarSettingsKind {
    case none
    case sound
    case flashcards
    case matching
}

extension StudyMode {
    var usesLightStudyTheme: Bool {
        switch self {
        case .recall, .flashcards, .clozeMultipleChoice, .matching, .matchingAudio, .pictureChoice:
            true
        case .clozeTyping:
            true
        }
    }

    var toolbarSettingsKind: StudyModeToolbarSettingsKind {
        switch self {
        case .matching:
            .matching
        case .flashcards:
            .flashcards
        case .matchingAudio, .clozeMultipleChoice:
            .sound
        case .recall, .pictureChoice, .clozeTyping:
            .none
        }
    }

    var recordsMatchingBestDuration: Bool {
        self == .matching
    }

    var playsMatchingRecordEffects: Bool {
        self == .matching
    }

    var showsMatchingRecordCelebration: Bool {
        self == .matching
    }

    var usesSubmitCooldown: Bool {
        self == .flashcards
    }

    func reviewsActiveCardSenses(flashcardDisplayMode: FlashcardDisplayMode) -> Bool {
        self == .flashcards && flashcardDisplayMode == .wholeCard
    }
}

struct UnsupportedStudyModeView: View {
    let mode: StudyMode
    let close: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(mode.title, systemImage: "wrench.and.screwdriver")
        } description: {
            Text(L10n.text("Этот режим ещё не подключён к учебной сессии."))
        } actions: {
            Button("Закрыть") {
                close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(LovableSurface.primary)
        }
        .foregroundStyle(MatchPalette.foreground)
    }
}
