import Foundation

@Observable
@MainActor
final class MatchingSessionCompletionController {
    /// Matching завершаем сразу по scheduler, а не после анимации очистки доски.
    private(set) var isFinished = false
    /// Поставлен ли на этом раунде новый рекорд — чтобы сыграть джингл в конце раунда.
    private(set) var beatRecord = false
    /// Счётчик залпов конфетти: ++ запускает залп на постоянно смонтированной ConfettiView.
    private(set) var confettiBurst = 0
    /// Время прохождения раунда — для сообщения о рекорде.
    private(set) var finishedDuration: TimeInterval?

    private var didSaveAttempt = false
    private var didPlayCompletionEffects = false

    func finishIfNeeded(
        session: StudySession,
        store: DeckStore,
        playCompletionEffects: Bool
    ) throws {
        guard session.mode.isMatching else { return }

        if !didSaveAttempt {
            let duration = session.matchingElapsed
            finishedDuration = duration
            try store.saveMatchingAttempt(
                MatchingAttemptEvent(
                    deckID: attemptDeckID(for: session),
                    mode: session.mode,
                    source: session.reviewSource,
                    duration: duration,
                    pairCount: session.matchingTotalPairCount
                )
            )
            didSaveAttempt = true
            if session.mode.recordsMatchingBestDuration {
                beatRecord = try store.saveMatchingRecordIfBest(
                    scope: session.matchingRecordScope,
                    duration: duration,
                    pairCount: session.matchingTotalPairCount
                )
            }
        }

        isFinished = true
        playEffectsIfNeeded(for: session, playCompletionEffects: playCompletionEffects)
    }

    private func playEffectsIfNeeded(for session: StudySession, playCompletionEffects: Bool) {
        guard playCompletionEffects,
              session.mode.playsMatchingRecordEffects,
              beatRecord,
              !didPlayCompletionEffects else {
            return
        }

        didPlayCompletionEffects = true
        confettiBurst += 1
        WordAudioPlayer.shared.playEffect(named: "new_record")
    }

    private func attemptDeckID(for session: StudySession) -> UUID? {
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
}
