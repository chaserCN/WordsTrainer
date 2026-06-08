import SwiftUI

struct StudySessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppUserStore.self) private var userStore
    @Environment(AppSettings.self) private var settings

    @Bindable var session: StudySession
    let store: DeckStore
    let deckTitle: String

    /// Matching завершаем сразу по scheduler, а не после анимации очистки доски.
    @State private var matchingFinished = false
    /// Поставлен ли на этом раунде новый рекорд — чтобы сыграть джингл в конце раунда.
    @State private var beatRecord = false
    /// Счётчик залпов конфетти: ++ запускает залп на постоянно смонтированной ConfettiView.
    @State private var confettiBurst = 0
    /// Время прохождения раунда — для сообщения о рекорде.
    @State private var finishedDuration: TimeInterval?
    @State private var isFlashcardSubmitEnabled = true
    @State private var didSaveMatchingAttempt = false
    @State private var didPlayMatchingCompletionEffects = false
    @State private var sessionError: String?

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
                                finishMatchingSessionIfNeeded(playCompletionEffects: true)
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
                            displayMode: settings.flashcardDisplayMode,
                            totalCount: session.displayTotalCount(flashcardDisplayMode: settings.flashcardDisplayMode),
                            remainingCount: session.displayRemainingCount(flashcardDisplayMode: settings.flashcardDisplayMode),
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
                        ) { outcome, additionalFailureCardID in
                            submit(outcome, additionalFailureCardID: additionalFailureCardID)
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
                    SoundToggleButton(showsFlashcardMode: session.mode == .flashcards)
                        .tint(navbarButtonTint)
                }
            }
        }
        .alert(
            L10n.text("Не удалось сохранить прогресс"),
            isPresented: Binding(
                get: { sessionError != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionError = nil
                    }
                }
            )
        ) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(sessionError ?? "")
        }
        .task {
            if session.mode.isMatching, session.isFinished {
                finishMatchingSessionIfNeeded(playCompletionEffects: false)
            }
        }
        .onChange(of: session.isFinished) { _, isFinished in
            guard isFinished, session.mode.isMatching else { return }
            finishMatchingSessionIfNeeded(playCompletionEffects: true)
        }
        .onChange(of: userStore.selectedUserID) { _, selectedUserID in
            guard selectedUserID != store.currentUserID else { return }
            dismiss()
        }
    }

    private var finishedView: some View {
        let isNewRecord = session.mode == .matching && beatRecord
        return ContentUnavailableView {
            Label(
                L10n.text(isNewRecord ? newRecordTitle : "Готово"),
                systemImage: isNewRecord ? "trophy.fill" : "checkmark.circle"
            )
            .foregroundStyle(finishedTint)
        } description: {
            if isNewRecord, let finishedDuration {
                Text(L10n.format("Лучшее время: %@", StudyDurationFormat.string(finishedDuration)))
                    .foregroundStyle(finishedTint)
            } else {
                Text(L10n.format("Сессия по колоде «%@» завершена.", deckTitle))
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
            return L10n.text("Новый рекорд для колоды")
        case .none:
            return L10n.text("Новый рекорд")
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
                  session.deckID != RandomStudySessionBuilder.deckID,
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

    private func submit(_ outcome: ReviewOutcome, additionalFailureCardID: UUID? = nil) {
        if session.mode == .flashcards {
            guard isFlashcardSubmitEnabled else { return }
            isFlashcardSubmitEnabled = false

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashcardSubmitCooldown) {
                isFlashcardSubmitEnabled = true
            }
        }

        do {
            try validateCurrentUser()
            try session.advanceAfterReview(
                outcome: outcome,
                additionalFailureCardID: additionalFailureCardID,
                reviewsActiveCardSenses: session.mode == .flashcards && settings.flashcardDisplayMode == .wholeCard,
                store: store
            )
        } catch {
            sessionError = error.localizedDescription
            isFlashcardSubmitEnabled = true
        }
    }

    private func finishMatchingSessionIfNeeded(playCompletionEffects: Bool) {
        guard session.mode.isMatching else { return }
        do {
            try validateCurrentUser()
            if !didSaveMatchingAttempt {
                let duration = session.matchingElapsed
                finishedDuration = duration
                try store.saveMatchingAttempt(
                    MatchingAttemptEvent(
                        deckID: matchingAttemptDeckID,
                        mode: session.mode,
                        source: session.reviewSource,
                        duration: duration,
                        pairCount: session.matchingTotalPairCount
                    )
                )
                didSaveMatchingAttempt = true
                if session.mode == .matching {
                    beatRecord = try store.saveMatchingRecordIfBest(
                        scope: session.matchingRecordScope,
                        duration: duration,
                        pairCount: session.matchingTotalPairCount
                    )
                }
            }
            matchingFinished = true
            if playCompletionEffects, session.mode == .matching, beatRecord, !didPlayMatchingCompletionEffects {
                didPlayMatchingCompletionEffects = true
                confettiBurst += 1
                WordAudioPlayer.shared.playEffect(named: "new_record")
            }
        } catch {
            sessionError = error.localizedDescription
        }
    }

    private func validateCurrentUser() throws {
        guard userStore.selectedUserID == store.currentUserID else {
            throw StudySessionViewError.userChanged
        }
    }
}

private enum StudySessionViewError: LocalizedError {
    case userChanged

    var errorDescription: String? {
        switch self {
        case .userChanged:
            return L10n.text("Пользователь изменился. Откройте упражнение заново.")
        }
    }
}
