import SwiftUI

struct StudySessionContentRouter<FinishedContent: View>: View {
    @Bindable var session: StudySession
    let store: DeckStore
    let flashcardDisplayMode: FlashcardDisplayMode
    let isFlashcardSubmitEnabled: Bool
    let isMatchingFinished: Bool
    let onSubmit: (ReviewOutcome, UUID?) -> Void
    let onMatchingFinished: () -> Void
    let onCloseUnsupportedMode: () -> Void
    @ViewBuilder let finishedContent: () -> FinishedContent

    var body: some View {
        if session.mode.isMatching {
            matchingContent
        } else if session.isFinished {
            finishedContent()
        } else if let item = session.current {
            studyContent(for: item)
        }
    }

    @ViewBuilder
    private var matchingContent: some View {
        if isMatchingFinished {
            finishedContent()
        } else {
            MatchingColumnsStudyView(
                session: session,
                store: store,
                onFinished: onMatchingFinished
            )
        }
    }

    @ViewBuilder
    private func studyContent(for item: StudyQueueItem) -> some View {
        switch session.mode {
        case .recall:
            RecallStudyView(
                card: item.card,
                totalCount: session.sessionChoicePool.count,
                remainingCount: session.remainingCount
            ) { outcome in
                onSubmit(outcome, nil)
            }
        case .flashcards, .flashcardsReverse:
            flashcardContent(for: item)
        case .clozeMultipleChoice, .clozeMultipleChoiceReverse:
            ClozeMCQStudyView(
                card: item.card,
                promptMode: session.mode.isReversePrompt ? .translation : .cloze,
                sessionChoicePool: session.sessionChoicePool,
                deckChoicePool: session.deckChoicePool,
                totalCount: session.sessionChoicePool.count,
                remainingCount: session.remainingCount
            ) { outcome, additionalFailureSenseID in
                onSubmit(outcome, additionalFailureSenseID)
            }
        case .clozeTyping, .translationTyping:
            TypingStudyView(
                card: item.card,
                promptMode: session.mode == .translationTyping ? .translationExample : .clozeSentence,
                totalCount: session.sessionChoicePool.count,
                remainingCount: session.remainingCount
            ) { outcome in
                onSubmit(outcome, nil)
            }
        case .pictureChoice:
            PictureChoiceStudyView(
                card: item.card,
                sessionChoicePool: session.sessionChoicePool,
                deckChoicePool: session.deckChoicePool,
                totalCount: session.sessionChoicePool.count,
                remainingCount: session.remainingCount
            ) { outcome in
                onSubmit(outcome, nil)
            }
        case .matching, .matchingAudio:
            EmptyView()
        }
    }

    private func flashcardContent(for item: StudyQueueItem) -> some View {
        FlashcardStudyView(
            card: item.card,
            displayMode: flashcardDisplayMode,
            promptMode: session.mode.isReversePrompt ? .translation : .word,
            totalCount: session.displayTotalCount(flashcardDisplayMode: flashcardDisplayMode),
            remainingCount: session.displayRemainingCount(flashcardDisplayMode: flashcardDisplayMode),
            isAnswerEnabled: isFlashcardSubmitEnabled
        ) { outcome in
            onSubmit(outcome, nil)
        }
    }
}
