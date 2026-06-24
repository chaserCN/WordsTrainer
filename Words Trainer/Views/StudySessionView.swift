import SwiftUI

struct StudySessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppUserStore.self) private var userStore
    @Environment(AppSettings.self) private var settings

    @Bindable var session: StudySession
    let store: DeckStore
    let deckTitle: String

    @State private var matchingCompletion = MatchingSessionCompletionController()
    @State private var isFlashcardSubmitEnabled = true
    @State private var didRequestCompletionSync = false
    @State private var sessionError: String?

    private static let flashcardSubmitCooldown: TimeInterval = 1

    var body: some View {
        ZStack {
            studyBackground
            sessionContent
        }
        .overlay {
            if session.mode.showsMatchingRecordCelebration {
                ConfettiView(trigger: matchingCompletion.confettiBurst)
            }
        }
        .navigationTitle(session.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(usesLightStudyTheme ? .light : .dark, for: .navigationBar)
        .tint(usesLightStudyTheme ? LovableSurface.foreground : .white)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarSettingsButton
                    .tint(navbarButtonTint)
            }
        }
        .alert(
            L10n.text("Не удалось сохранить прогресс"),
            isPresented: sessionErrorBinding
        ) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(sessionError ?? "")
        }
        .task {
            if session.mode.isMatching, session.isFinished {
                finishMatchingSessionIfNeeded(playCompletionEffects: false)
            }
            requestCompletionSyncIfNeeded()
        }
        .onChange(of: session.isFinished) { _, isFinished in
            guard isFinished else { return }
            if session.mode.isMatching {
                finishMatchingSessionIfNeeded(playCompletionEffects: true)
            }
            requestCompletionSyncIfNeeded()
        }
        .onChange(of: userStore.selectedUserID) { _, selectedUserID in
            guard selectedUserID != store.currentUserID else { return }
            dismiss()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session.resumeTiming()
            case .inactive, .background:
                session.pauseTiming()
            @unknown default:
                break
            }
        }
        .onAppear {
            FrameHitchMonitor.shared.mark("study \(session.mode) appeared (pool=\(session.sessionChoicePool.count))")
        }
        .onDisappear {
            FrameHitchMonitor.shared.mark("returned from study \(session.mode)")
        }
    }

    @ViewBuilder
    private var studyBackground: some View {
        if usesLightStudyTheme {
            MatchingBackground()
        } else {
            AppBackground()
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        StudySessionContentRouter(
            session: session,
            store: store,
            flashcardDisplayMode: settings.flashcardDisplayMode,
            isFlashcardSubmitEnabled: isFlashcardSubmitEnabled,
            isMatchingFinished: matchingCompletion.isFinished,
            onSubmit: submit,
            onMatchingFinished: {
                finishMatchingSessionIfNeeded(playCompletionEffects: true)
            },
            onCloseUnsupportedMode: {
                dismiss()
            }
        ) {
            finishedView
        }
    }

    @ViewBuilder
    private var toolbarSettingsButton: some View {
        switch session.mode.toolbarSettingsKind {
        case .matching:
            MatchingSettingsMenu()
        case .flashcards:
            FlashcardSettingsMenu()
        case .none:
            EmptyView()
        }
    }

    private var sessionErrorBinding: Binding<Bool> {
        Binding(
            get: { sessionError != nil },
            set: { isPresented in
                if !isPresented {
                    sessionError = nil
                }
            }
        )
    }

    private var finishedView: some View {
        let isNewRecord = session.mode.recordsMatchingBestDuration && matchingCompletion.beatRecord
        return ContentUnavailableView {
            Label(
                L10n.text(isNewRecord ? newRecordTitle : "Готово"),
                systemImage: isNewRecord ? "trophy.fill" : "checkmark.circle"
            )
            .foregroundStyle(finishedTint)
        } description: {
            if isNewRecord, let finishedDuration = matchingCompletion.finishedDuration {
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
            return matchingCompletion.beatRecord ? MatchPalette.accent : MatchPalette.foreground
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

    private var usesLightStudyTheme: Bool {
        session.mode.usesLightStudyTheme
    }

    private func submit(_ outcome: ReviewOutcome, additionalFailureSenseID: UUID? = nil) {
        if session.mode.usesSubmitCooldown {
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
                additionalFailureSenseID: additionalFailureSenseID,
                reviewsActiveCardSenses: session.mode.reviewsActiveCardSenses(
                    flashcardDisplayMode: settings.flashcardDisplayMode
                ),
                store: store
            )
            requestCompletionSyncIfNeeded()
        } catch {
            sessionError = error.localizedDescription
            isFlashcardSubmitEnabled = true
        }
    }

    private func finishMatchingSessionIfNeeded(playCompletionEffects: Bool) {
        guard session.mode.isMatching else { return }
        do {
            try validateCurrentUser()
            try matchingCompletion.finishIfNeeded(
                session: session,
                store: store,
                playCompletionEffects: playCompletionEffects
            )
            requestCompletionSyncIfNeeded()
        } catch {
            sessionError = error.localizedDescription
        }
    }

    private func validateCurrentUser() throws {
        guard userStore.selectedUserID == store.currentUserID else {
            throw StudySessionViewError.userChanged
        }
    }

    private func requestCompletionSyncIfNeeded() {
        guard !didRequestCompletionSync,
              session.isFinished || matchingCompletion.isFinished,
              userStore.selectedUserID == store.currentUserID else {
            return
        }

        didRequestCompletionSync = true
        AppBackgroundSync.run {
            await userStore.syncPendingEventsToServer()
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
