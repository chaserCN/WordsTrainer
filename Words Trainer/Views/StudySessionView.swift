import SwiftUI

struct StudySessionView: View {
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

    private static let flashcardSubmitCooldown: TimeInterval = 1

    var body: some View {
        ZStack {
            if usesLightStudyTheme {
                MatchingBackground()
            } else {
                AppBackground()
            }
            Group {
                if session.mode == .matching {
                    if matchingFinished {
                        finishedView
                    } else {
                        MatchingColumnsStudyView(
                            session: session,
                            store: store,
                            onFinished: {
                                matchingFinished = true
                                // Поздравление только при новом рекорде.
                                if beatRecord {
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
                    case .matching, .clozeTyping:
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
                }
            } else if session.mode == .flashcards {
                ToolbarItem(placement: .topBarTrailing) {
                    SoundToggleButton()
                }
            }
        }
        .onChange(of: session.isFinished) { _, isFinished in
            guard isFinished, session.mode == .matching, session.savesProgress else { return }
            let duration = session.matchingElapsed
            finishedDuration = duration
            beatRecord = (try? store.saveMatchingRecordIfBest(
                deckID: session.deckID,
                duration: duration,
                pairCount: session.matchingTotalPairCount
            )) ?? false
        }
    }

    private var finishedView: some View {
        let isNewRecord = session.mode == .matching && beatRecord
        return ContentUnavailableView {
            Label(
                isNewRecord ? "Новый рекорд!" : "Готово",
                systemImage: isNewRecord ? "trophy.fill" : "checkmark.circle"
            )
        } description: {
            if isNewRecord, let finishedDuration {
                Text("Лучшее время: \(StudyDurationFormat.string(finishedDuration))")
            } else {
                Text("Сессия по колоде «\(deckTitle)» завершена.")
            }
        }
        .foregroundStyle(finishedTint)
    }

    private var finishedTint: Color {
        if usesLightStudyTheme {
            return beatRecord ? MatchPalette.accent : MatchPalette.foreground
        }
        return .white
    }

    private var usesLightStudyTheme: Bool {
        session.mode == .matching
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
