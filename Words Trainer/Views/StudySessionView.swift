import SwiftUI

struct StudySessionView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var session: StudySession
    let store: DeckStore
    let deckTitle: String

    /// Для matching завершаем не по scheduler (он пустеет раньше времени из-за резерва замены),
    /// а когда доска реально опустела после анимации последнего гашения.
    @State private var matchingFinished = false
    /// Поставлен ли на этом раунде новый рекорд — чтобы сыграть джингл в конце раунда.
    @State private var beatRecord = false
    /// Счётчик залпов конфетти: ++ запускает залп на постоянно смонтированной ConfettiView.
    @State private var confettiBurst = 0
    /// Время прохождения раунда — для сообщения о рекорде.
    @State private var finishedDuration: TimeInterval?
    @State private var isFlashcardSubmitEnabled = true
    @State private var didSaveMatchingAttempt = false

    private static let flashcardSubmitCooldown: TimeInterval = 1

    var body: some View {
        ZStack {
            if usesLightStudyTheme {
                MatchingBackground()
            } else {
                AppBackground()
            }
            Group {
                if session.mode.isMatching {
                    if matchingFinished {
                        finishedView
                    } else {
                        MatchingColumnsStudyView(
                            session: session,
                            store: store,
                            onFinished: {
                                matchingFinished = true
                                // Поздравление только при новом рекорде.
                                if session.mode == .matching, beatRecord {
                                    confettiBurst += 1
                                    WordAudioPlayer.shared.playEffect(named: "new_record")
                                }
                            }
                        )
                    }
                } else if session.isFinished {
                    finishedView
                } else if let item = session.current {
                    switch session.mode {
                    case .recall:
                        RecallStudyView(
                            card: item.card,
                            totalCount: session.sessionChoicePool.count,
                            remainingCount: session.remainingCount
                        ) { outcome in
                            submit(outcome)
                        }
                    case .flashcards:
                        FlashcardStudyView(
                            card: item.card,
                            totalCount: session.sessionChoicePool.count,
                            remainingCount: session.remainingCount,
                            isAnswerEnabled: isFlashcardSubmitEnabled
                        ) { outcome in
                            submit(outcome)
                        }
                    case .clozeMultipleChoice:
                        ClozeMCQStudyView(
                            card: item.card,
                            sessionChoicePool: session.sessionChoicePool,
                            deckChoicePool: session.deckChoicePool,
                            totalCount: session.sessionChoicePool.count,
                            remainingCount: session.remainingCount
                        ) { outcome in
                            submit(outcome)
                        }
                    case .matching, .matchingAudio, .clozeTyping:
                        EmptyView()
                    }
                }
            }
        }
        .overlay {
            if session.mode == .matching {
                ConfettiView(trigger: confettiBurst)
            }
        }
        .navigationTitle(session.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(usesLightStudyTheme ? .light : .dark, for: .navigationBar)
        .tint(usesLightStudyTheme ? LovableSurface.foreground : .white)
        .toolbar {
            if session.mode == .matching {
                ToolbarItem(placement: .topBarTrailing) {
                    MatchingSettingsMenu()
                        .tint(navbarButtonTint)
                }
            } else if session.mode == .matchingAudio || session.mode == .flashcards || session.mode == .clozeMultipleChoice {
                ToolbarItem(placement: .topBarTrailing) {
                    SoundToggleButton()
                        .tint(navbarButtonTint)
                }
            }
        }
        .onChange(of: session.isFinished) { _, isFinished in
            guard isFinished, session.mode.isMatching, !didSaveMatchingAttempt else { return }
            didSaveMatchingAttempt = true
            let duration = session.matchingElapsed
            finishedDuration = duration
            try? store.saveMatchingAttempt(
                MatchingAttemptEvent(
                    deckID: matchingAttemptDeckID,
                    mode: session.mode,
                    source: session.reviewSource,
                    duration: duration,
                    pairCount: session.matchingTotalPairCount
                )
            )
            if session.mode == .matching {
                beatRecord = (try? store.saveMatchingRecordIfBest(
                    scope: session.matchingRecordScope,
                    duration: duration,
                    pairCount: session.matchingTotalPairCount
                )) ?? false
            }
        }
    }

    private var finishedView: some View {
        let isNewRecord = session.mode == .matching && beatRecord
        return ContentUnavailableView {
            Label(
                isNewRecord ? newRecordTitle : "Готово",
                systemImage: isNewRecord ? "trophy.fill" : "checkmark.circle"
            )
            .foregroundStyle(finishedTint)
        } description: {
            if isNewRecord, let finishedDuration {
                Text("Лучшее время: \(StudyDurationFormat.string(finishedDuration))")
                    .foregroundStyle(finishedTint)
            } else {
                Text("Сессия по колоде «\(deckTitle)» завершена.")
                    .foregroundStyle(finishedTint)
            }
        } actions: {
            Button("Закрыть") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(finishedActionTint)
        }
    }

    private var newRecordTitle: String {
        switch session.matchingRecordScope {
        case .deck:
            return "Новый рекорд для колоды"
        case .none:
            return "Новый рекорд"
        }
    }

    private var finishedTint: Color {
        if usesLightStudyTheme {
            return beatRecord ? MatchPalette.accent : MatchPalette.foreground
        }
        return .white
    }

    private var finishedActionTint: Color {
        usesLightStudyTheme ? LovableSurface.primary : .white
    }

    /// Кнопки навбара — единообразно тёмные на светлой теме (как договаривались).
    private var navbarButtonTint: Color {
        usesLightStudyTheme ? LovableSurface.foreground : .white
    }

    private var matchingAttemptDeckID: UUID? {
        switch session.matchingRecordScope {
        case .deck(let deckID):
            return deckID
        case .none:
            guard session.deckID != TodayStudySessionBuilder.deckID,
                  session.deckID != WeakCardsPractice.deckID else {
                return nil
            }
            return session.deckID
        }
    }

    private var usesLightStudyTheme: Bool {
        session.mode.isMatching
            || session.mode == .clozeMultipleChoice
            || session.mode == .recall
            || session.mode == .flashcards
    }

    private func submit(_ outcome: ReviewOutcome) {
        if session.mode == .flashcards {
            guard isFlashcardSubmitEnabled else { return }
            isFlashcardSubmitEnabled = false

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashcardSubmitCooldown) {
                isFlashcardSubmitEnabled = true
            }
        }

        do {
            try session.advanceAfterReview(outcome: outcome, store: store)
        } catch {
            // MVP: ignore scheduling errors in UI
        }
    }
}
