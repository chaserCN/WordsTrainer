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
                        RecallStudyView(card: item.card) { outcome in
                            submit(outcome)
                        }
                    case .clozeMultipleChoice:
                        ClozeMCQStudyView(
                            card: item.card,
                            answerPool: session.queue.map(\.card)
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
        .toolbar {
            if session.mode == .matching {
                ToolbarItem(placement: .topBarTrailing) {
                    MatchingSettingsMenu()
                }
            }
        }
        .onChange(of: session.isFinished) { _, isFinished in
            guard isFinished, session.mode == .matching else { return }
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
        session.mode == .matching || session.mode == .clozeMultipleChoice
    }

    private func submit(_ outcome: ReviewOutcome) {
        do {
            try session.advanceAfterReview(outcome: outcome, store: store)
        } catch {
            // MVP: ignore scheduling errors in UI
        }
    }
}

struct RecallStudyView: View {
    let card: WordCardContent
    let onAnswer: (ReviewOutcome) -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text(card.word)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Spacer()
            HStack(spacing: 16) {
                Button("Забыл") {
                    onAnswer(.forgot)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button("Помню") {
                    onAnswer(.remembered)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }
}

struct ClozeMCQStudyView: View {
    private static let answerAdvanceDelay: TimeInterval = 0.65

    let card: WordCardContent
    let answerPool: [WordCardContent]
    let onAnswer: (ReviewOutcome) -> Void

    @State private var displayedCardID: UUID?
    @State private var selected: String?
    @State private var answered = false
    @State private var choices: [String] = []
    @State private var advanceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Выбери слово")
                .font(.largeTitle.bold())
                .foregroundStyle(MatchPalette.foreground)
                .padding(.top, 12)

            HTMLText(html: card.clozePromptWithGap, foregroundColor: MatchPalette.cardForeground)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
                .background(matchingCardShape.fill(.white.opacity(0.88)))
                .overlay(matchingCardShape.strokeBorder(MatchPalette.shadow.opacity(0.08), lineWidth: 0.5))
                .shadow(color: MatchPalette.shadow.opacity(0.10), radius: 10, x: 0, y: 6)

            VStack(spacing: 14) {
                ForEach(choices, id: \.self) { option in
                    ClozeChoiceButton(
                        option: option,
                        isSelected: selected == option,
                        isCorrect: answered && option == card.effectiveClozeAnswer,
                        isWrong: answered && selected == option && option != card.effectiveClozeAnswer,
                        isDimmed: answered && selected != option && option != card.effectiveClozeAnswer
                    ) {
                        select(option)
                    }
                    .disabled(answered)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .onAppear {
            resetRoundIfNeeded()
        }
        .onChange(of: card.id) { _, _ in
            resetRound()
        }
    }

    private func select(_ option: String) {
        guard !answered else { return }
        let outcome: ReviewOutcome = option == card.effectiveClozeAnswer ? .correct : .incorrect
        selected = option
        answered = true
        advanceTask?.cancel()
        advanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.answerAdvanceDelay))
            guard !Task.isCancelled else { return }
            onAnswer(outcome)
        }
    }

    private func resetRoundIfNeeded() {
        guard displayedCardID != card.id else { return }
        resetRound()
    }

    private func resetRound() {
        advanceTask?.cancel()
        advanceTask = nil
        displayedCardID = card.id
        selected = nil
        answered = false
        choices = card.clozeChoices(answerPool: answerPool).shuffled()
    }
}

private struct ClozeChoiceButton: View {
    let option: String
    let isSelected: Bool
    let isCorrect: Bool
    let isWrong: Bool
    let isDimmed: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Text(option)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MatchPalette.cardForeground)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isCorrect ? MatchPalette.success : MatchPalette.destructive)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(matchingCardShape.fill(cardFill))
            .overlay(matchingCardShape.strokeBorder(ringColor, lineWidth: ringWidth))
            .shadow(color: primaryShadow.color, radius: primaryShadow.radius, x: 0, y: primaryShadow.y)
            .shadow(color: MatchPalette.shadow.opacity(0.08), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.62 : 1)
        .modifier(ShakeEffect(animatableData: isWrong ? 1 : 0))
        .animation(.linear(duration: 0.4), value: isWrong)
    }

    private var cardFill: LinearGradient {
        if isCorrect {
            return LinearGradient(
                colors: [oklch(0.95, 0.04, 160, 0.95), oklch(0.88, 0.08, 160, 0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [.white, oklch(0.995, 0.003, 250)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var ringColor: Color {
        if isWrong { return MatchPalette.destructive }
        if isCorrect { return MatchPalette.success }
        if isSelected { return MatchPalette.primary }
        return MatchPalette.shadow.opacity(0.10)
    }

    private var ringWidth: CGFloat {
        if isCorrect { return 2.5 }
        if isWrong || isSelected { return 2 }
        return 0.5
    }

    private var primaryShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if isSelected { return (MatchPalette.primary.opacity(0.35), 12, 8) }
        if isCorrect { return (MatchPalette.success.opacity(0.40), 16, 6) }
        if isWrong { return (MatchPalette.destructive.opacity(0.35), 11, 8) }
        return (MatchPalette.shadow.opacity(0.18), 10, 6)
    }
}

private var matchingCardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
}

struct MatchingColumnsStudyView: View {
    /// Исчезновение = подтверждение правильного выбора (зелёным) + плавное гашение.
    private static let confirmHighlightDuration: TimeInterval = 1.0
    private static let fadeOutDuration: TimeInterval = 1.5
    /// Появление новой лексики.
    private static let fadeInDuration: TimeInterval = 0.7

    @Bindable var session: StudySession
    let store: DeckStore
    /// Доска опустела после анимации последнего гашения — пора показать «Готово».
    let onFinished: () -> Void

    /// Одна ячейка колонки: стабильная позиция на экране (`id`) + лексика в ней (`pairID`).
    /// `id` — это «пара ячеек» из модели: не двигается, на ней играет анимация.
    /// `pairID` — содержимое: его и перемешиваем при подстановке.
    private struct Slot: Identifiable, Equatable {
        let id = UUID()
        var pairID: String
    }

    @State private var wordColumn: [Slot] = []
    @State private var translationColumn: [Slot] = []

    @State private var selectedWordSlot: UUID?
    @State private var selectedTranslationSlot: UUID?
    @State private var wrongWordSlot: UUID?
    @State private var wrongTranslationSlot: UUID?

    /// Прозрачность анимирующихся ячеек, по id слота. Наличие ключа = ячейка занята анимацией (блок тапов).
    @State private var wordSlotOpacity: [UUID: Double] = [:]
    @State private var translationSlotOpacity: [UUID: Double] = [:]

    /// Ячейки в фазе подтверждения правильного выбора (зелёная подсветка).
    @State private var correctWordSlots: Set<UUID> = []
    @State private var correctTranslationSlots: Set<UUID> = []

    /// Ячейки в фазе проявления: контент уже валиден — по ним можно тапать и их можно ускорить.
    @State private var appearingWordSlots: Set<UUID> = []
    @State private var appearingTranslationSlots: Set<UUID> = []

    /// Идущие переходы матча (подтверждение → гашение → подстановка) — чтобы ускорять их при выборе.
    @State private var pendingTransitions: [UUID: MatchTransition] = [:]
    @State private var transitionTasks: [UUID: Task<Void, Never>] = [:]

    /// Общий пул содержимого на подстановку: id пар, чьё слово / перевод ещё ждут пустой ячейки.
    /// Левая ячейка тянет случайное слово, правая — случайный перевод (колонки независимо).
    @State private var pendingWords: [String] = []
    @State private var pendingTranslations: [String] = []

    /// Лейблы всех виденных пар — чтобы текст не пропадал, пока матченная пара гаснет.
    @State private var pairCache: [String: MatchingPair] = [:]
    @State private var matchingRecord: DeckMatchingRecord?

    // Перемешивание поля, если три раза подряд матч в одни и те же ячейки.
    @State private var lastMatchedWordSlot: UUID?
    @State private var lastMatchedTranslationSlot: UUID?
    @State private var consecutiveMatchesAtSamePositions = 0

    private var rows: [(word: Slot, translation: Slot)] {
        guard wordColumn.count == translationColumn.count else { return [] }
        return Array(zip(wordColumn, translationColumn))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Соедини пары")
                .font(.largeTitle.bold())
                .foregroundStyle(MatchPalette.foreground)
                .padding(.top, 12)

            if let startedAt = session.matchingStartedAt {
                MatchingStatusBar(
                    remainingCount: session.remainingCount,
                    startedAt: startedAt,
                    record: matchingRecord,
                    pairCount: session.matchingTotalPairCount
                )
            }

            VStack(spacing: 14) {
                ForEach(rows, id: \.word.id) { row in
                    HStack(alignment: .center, spacing: 14) {
                        wordCell(row.word)
                        translationCell(row.translation)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .task(id: session.deckID) {
            matchingRecord = try? store.matchingRecord(deckID: session.deckID)
        }
        .onChange(of: session.matchingVisibleItems.map(\.id), initial: true) { _, _ in
            seedColumnsIfNeeded()
        }
    }

    @ViewBuilder
    private func wordCell(_ slot: Slot) -> some View {
        MatchingCell(
            label: pairCache[slot.pairID]?.card.word ?? "",
            isSelected: selectedWordSlot == slot.id,
            isWrong: wrongWordSlot == slot.id,
            isCorrect: correctWordSlots.contains(slot.id),
            action: { selectWord(slot) }
        )
        .opacity(wordSlotOpacity[slot.id] ?? 1)
        .scaleEffect(scale(for: wordSlotOpacity[slot.id]))
        .allowsHitTesting(isWordTappable(slot.id))
    }

    @ViewBuilder
    private func translationCell(_ slot: Slot) -> some View {
        MatchingCell(
            label: pairCache[slot.pairID]?.translation ?? "",
            isSelected: selectedTranslationSlot == slot.id,
            isWrong: wrongTranslationSlot == slot.id,
            isCorrect: correctTranslationSlots.contains(slot.id),
            action: { selectTranslation(slot) }
        )
        .opacity(translationSlotOpacity[slot.id] ?? 1)
        .scaleEffect(scale(for: translationSlotOpacity[slot.id]))
        .allowsHitTesting(isTranslationTappable(slot.id))
    }

    private func scale(for opacity: Double?) -> Double {
        guard let opacity else { return 1 }
        return 0.9 + (0.1 * opacity)
    }

    // Тапать можно по свободным ячейкам и по тем, что уже проявляются (контент валиден).
    private func isWordTappable(_ id: UUID) -> Bool {
        wordSlotOpacity[id] == nil || appearingWordSlots.contains(id)
    }

    private func isTranslationTappable(_ id: UUID) -> Bool {
        translationSlotOpacity[id] == nil || appearingTranslationSlots.contains(id)
    }

    /// Первичная раздача: лексика по ячейкам, колонки мешаем независимо.
    private func seedColumnsIfNeeded() {
        guard wordColumn.isEmpty, translationColumn.isEmpty else { return }
        let pairs = session.matchingVisibleItems
        guard !pairs.isEmpty else { return }
        for pair in pairs { pairCache[pair.id] = pair }
        wordColumn = pairs.shuffled().map { Slot(pairID: $0.id) }
        translationColumn = pairs.shuffled().map { Slot(pairID: $0.id) }
    }

    // MARK: - Selection

    private func selectWord(_ slot: Slot) {
        guard wrongWordSlot == nil, isWordTappable(slot.id) else { return }
        if selectedWordSlot == slot.id {
            selectedWordSlot = nil
            return
        }
        selectedWordSlot = slot.id
        accelerateIfPartnerMissing(pairID: slot.pairID, selectedWord: true)
        if let pair = pairCache[slot.pairID] {
            WordAudioPlayer.shared.playWord(from: pair.card)
        }
        checkPairIfReady()
    }

    private func selectTranslation(_ slot: Slot) {
        guard wrongWordSlot == nil, isTranslationTappable(slot.id) else { return }
        if selectedTranslationSlot == slot.id {
            selectedTranslationSlot = nil
            return
        }
        selectedTranslationSlot = slot.id
        accelerateIfPartnerMissing(pairID: slot.pairID, selectedWord: false)
        checkPairIfReady()
    }

    /// Если пары выбранной ячейки сейчас нет на экране (ещё в пуле или ещё проявляется) —
    /// ускоряем все зависшие подстановки, чтобы поле досело и пара появилась. Иначе не трогаем.
    private func accelerateIfPartnerMissing(pairID: String, selectedWord: Bool) {
        guard !isPartnerReady(pairID: pairID, selectedWord: selectedWord) else { return }
        fastForwardTransitions()
        revealPartner(pairID: pairID, selectedWord: selectedWord)
    }

    /// Пара «готова», если она уже на доске и не в анимации (видима и нажимаема).
    private func isPartnerReady(pairID: String, selectedWord: Bool) -> Bool {
        if selectedWord {
            guard let partner = translationColumn.first(where: { $0.pairID == pairID }) else { return false }
            return translationSlotOpacity[partner.id] == nil
        } else {
            guard let partner = wordColumn.first(where: { $0.pairID == pairID }) else { return false }
            return wordSlotOpacity[partner.id] == nil
        }
    }

    private func checkPairIfReady() {
        guard let wordSlotID = selectedWordSlot, let translationSlotID = selectedTranslationSlot else { return }
        guard let wordSlot = wordColumn.first(where: { $0.id == wordSlotID }),
              let translationSlot = translationColumn.first(where: { $0.id == translationSlotID }) else {
            selectedWordSlot = nil
            selectedTranslationSlot = nil
            return
        }

        if wordSlot.pairID == translationSlot.pairID {
            let matchedID = wordSlot.pairID
            let shuffle = shouldShuffleAfterMatch(wordSlot: wordSlotID, translationSlot: translationSlotID)
            selectedWordSlot = nil
            selectedTranslationSlot = nil
            beginMatchTransition(
                matchedID: matchedID,
                wordSlotID: wordSlotID,
                translationSlotID: translationSlotID,
                shuffle: shuffle
            )
        } else {
            if let pair = pairCache[wordSlot.pairID] {
                WordAudioPlayer.shared.playWord(from: pair.card, style: .wrong)
            }
            wrongWordSlot = wordSlotID
            wrongTranslationSlot = translationSlotID
            selectedWordSlot = nil
            selectedTranslationSlot = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeOut(duration: 0.2)) {
                    wrongWordSlot = nil
                    wrongTranslationSlot = nil
                }
            }
        }
    }

    /// Перемешиваем всё поле, если три раза подряд тапнули одни и те же ячейки.
    private func shouldShuffleAfterMatch(wordSlot: UUID, translationSlot: UUID) -> Bool {
        if lastMatchedWordSlot == wordSlot, lastMatchedTranslationSlot == translationSlot {
            consecutiveMatchesAtSamePositions += 1
        } else {
            lastMatchedWordSlot = wordSlot
            lastMatchedTranslationSlot = translationSlot
            consecutiveMatchesAtSamePositions = 1
        }

        guard consecutiveMatchesAtSamePositions >= 3 else { return false }
        consecutiveMatchesAtSamePositions = 0
        lastMatchedWordSlot = nil
        lastMatchedTranslationSlot = nil
        return true
    }

    // MARK: - Match transition

    private struct MatchTransition {
        let matchedID: String
        let wordSlotID: UUID
        let translationSlotID: UUID
        let shuffle: Bool
    }

    /// Исчезновение одной пары: подтверждение (зелёным) → гашение. Новую пару сразу резервируем
    /// из пула в общий пул подстановки. Появление — в тех же ячейках, по таймеру этого матча.
    /// Переход живёт в отменяемой Task, чтобы его можно было ускорить при следующем выборе.
    private func beginMatchTransition(
        matchedID: String,
        wordSlotID: UUID,
        translationSlotID: UUID,
        shuffle: Bool
    ) {
        // 1. Блокируем ячейки и подтверждаем правильный выбор зелёным.
        //    Если ячейка ещё проявлялась — перехватываем её (снимаем флаг проявления).
        appearingWordSlots.remove(wordSlotID)
        appearingTranslationSlots.remove(translationSlotID)
        wordSlotOpacity[wordSlotID] = 1
        translationSlotOpacity[translationSlotID] = 1
        correctWordSlots.insert(wordSlotID)
        correctTranslationSlots.insert(translationSlotID)

        // 2. Резервируем замену из пула — чтобы её можно было подмешать к соседним матчам.
        reserveReplacement(for: matchedID)

        // 3. Подтверждение → гашение → подстановка, в отменяемой задаче.
        let id = UUID()
        pendingTransitions[id] = MatchTransition(
            matchedID: matchedID,
            wordSlotID: wordSlotID,
            translationSlotID: translationSlotID,
            shuffle: shuffle
        )
        transitionTasks[id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.confirmHighlightDuration))
            guard !Task.isCancelled, pendingTransitions[id] != nil else { return }
            withAnimation(.easeInOut(duration: Self.fadeOutDuration)) {
                wordSlotOpacity[wordSlotID] = 0
                translationSlotOpacity[translationSlotID] = 0
            }
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration))
            guard !Task.isCancelled else { return }
            finishTransition(id)
        }
    }

    /// Завершить переход: убрать подтверждение и подставить новую лексику. Идемпотентно.
    private func finishTransition(_ id: UUID) {
        guard let transition = pendingTransitions.removeValue(forKey: id) else { return }
        transitionTasks.removeValue(forKey: id)?.cancel()
        correctWordSlots.remove(transition.wordSlotID)
        correctTranslationSlots.remove(transition.translationSlotID)
        if transition.shuffle {
            applyReshuffle()
        } else {
            commitMatch(wordSlotID: transition.wordSlotID, translationSlotID: transition.translationSlotID)
        }
    }

    /// Ускорить все идущие переходы (при выборе ячейки): быстро гасим и сразу подставляем.
    private func fastForwardTransitions() {
        let ids = Array(pendingTransitions.keys)
        guard !ids.isEmpty else { return }
        for id in ids { transitionTasks.removeValue(forKey: id)?.cancel() }
        withAnimation(.easeOut(duration: 0.14)) {
            for id in ids {
                if let transition = pendingTransitions[id] {
                    wordSlotOpacity[transition.wordSlotID] = 0
                    translationSlotOpacity[transition.translationSlotID] = 0
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            for id in ids { finishTransition(id) }
        }
    }

    /// Убираем матченную пару из колоды и кладём её замену в общий пул подстановки.
    private func reserveReplacement(for matchedID: String) {
        let before = Set(session.matchingVisibleItems.map(\.id))
        session.removeMatchedPair(id: matchedID)
        let visible = session.matchingVisibleItems
        for pair in visible { pairCache[pair.id] = pair }
        for pair in visible where !before.contains(pair.id) {
            pendingWords.append(pair.id)
            pendingTranslations.append(pair.id)
        }
    }

    /// Подстановка в освободившиеся ячейки: левая берёт случайное слово из пула, правая — случайный
    /// перевод (колонки независимо). Поэтому в паре ячеек матча могут оказаться половинки разных пар.
    private func commitMatch(wordSlotID: UUID, translationSlotID: UUID) {
        guard let wordIndex = wordColumn.firstIndex(where: { $0.id == wordSlotID }),
              let translationIndex = translationColumn.firstIndex(where: { $0.id == translationSlotID }) else {
            return // ячейки уже нет (перетасовка) — ничего не делаем
        }

        // Конец колоды: подставлять нечего — схлопываем эту пару ячеек.
        guard !pendingWords.isEmpty, !pendingTranslations.isEmpty else {
            wordColumn.remove(at: wordIndex)
            translationColumn.remove(at: translationIndex)
            wordSlotOpacity.removeValue(forKey: wordSlotID)
            translationSlotOpacity.removeValue(forKey: translationSlotID)
            finishIfBoardEmpty()
            return
        }

        let wordPick = pendingWords.remove(at: Int.random(in: pendingWords.indices))
        let translationPick = pendingTranslations.remove(at: Int.random(in: pendingTranslations.indices))
        wordColumn[wordIndex].pairID = wordPick
        translationColumn[translationIndex].pairID = translationPick

        startAppearTransition(wordSlotID: wordSlotID, translationSlotID: translationSlotID)
    }

    /// Перетасовка всего поля: занятые ячейки тоже переезжают (исключение из «ячейки не двигаются»).
    /// Матченные пары уже убраны при гашении, раздаём заново всё видимое.
    private func applyReshuffle() {
        pendingWords.removeAll()
        pendingTranslations.removeAll()
        wordSlotOpacity.removeAll()
        translationSlotOpacity.removeAll()
        correctWordSlots.removeAll()
        correctTranslationSlots.removeAll()
        appearingWordSlots.removeAll()
        appearingTranslationSlots.removeAll()
        for (_, task) in transitionTasks { task.cancel() }
        transitionTasks.removeAll()
        pendingTransitions.removeAll()
        selectedWordSlot = nil
        selectedTranslationSlot = nil

        let pairs = session.matchingVisibleItems
        for pair in pairs { pairCache[pair.id] = pair }
        guard !pairs.isEmpty else {
            wordColumn = []
            translationColumn = []
            finishIfBoardEmpty()
            return
        }
        wordColumn = pairs.shuffled().map { Slot(pairID: $0.id) }
        translationColumn = pairs.shuffled().map { Slot(pairID: $0.id) }
    }

    private func finishIfBoardEmpty() {
        if wordColumn.isEmpty, translationColumn.isEmpty {
            onFinished()
        }
    }

    /// Проявляем новую лексику в тех же ячейках, где был матч.
    private func startAppearTransition(wordSlotID: UUID, translationSlotID: UUID) {
        wordSlotOpacity[wordSlotID] = 0
        translationSlotOpacity[translationSlotID] = 0
        appearingWordSlots.insert(wordSlotID)
        appearingTranslationSlots.insert(translationSlotID)

        withAnimation(.easeInOut(duration: Self.fadeInDuration)) {
            wordSlotOpacity[wordSlotID] = 1
            translationSlotOpacity[translationSlotID] = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDuration) {
            finishAppear(wordSlotID: wordSlotID, translationSlotID: translationSlotID)
        }
    }

    private func finishAppear(wordSlotID: UUID, translationSlotID: UUID) {
        // Чистим только если ячейка всё ещё проявляется — иначе её перехватил новый переход (матч).
        if appearingWordSlots.remove(wordSlotID) != nil {
            wordSlotOpacity.removeValue(forKey: wordSlotID)
        }
        if appearingTranslationSlots.remove(translationSlotID) != nil {
            translationSlotOpacity.removeValue(forKey: translationSlotID)
        }
    }

    /// При выборе ячейки мгновенно доявляем её пару (если она ещё проявляется), чтобы
    /// её можно было сразу найти и тапнуть, не дожидаясь конца анимации.
    private func revealPartner(pairID: String, selectedWord: Bool) {
        if selectedWord {
            guard let partner = translationColumn.first(where: { $0.pairID == pairID }),
                  appearingTranslationSlots.contains(partner.id) else { return }
            withAnimation(.easeOut(duration: 0.12)) { translationSlotOpacity[partner.id] = 1 }
        } else {
            guard let partner = wordColumn.first(where: { $0.pairID == pairID }),
                  appearingWordSlots.contains(partner.id) else { return }
            withAnimation(.easeOut(duration: 0.12)) { wordSlotOpacity[partner.id] = 1 }
        }
    }
}

private struct MatchingStatusBar: View {
    @Environment(AppSettings.self) private var settings
    let remainingCount: Int
    let startedAt: Date
    let record: DeckMatchingRecord?
    let pairCount: Int

    private var recordDuration: TimeInterval? {
        guard settings.isPaceBarEnabled, let record, record.pairCount == pairCount else { return nil }
        return record.bestDuration
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(remainingCount)")
                            .font(.title2.bold())
                            .foregroundStyle(MatchPalette.foreground)
                        Text("осталось")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MatchPalette.muted)
                    }
                    Spacer()
                    Text(StudyDurationFormat.string(elapsed))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(MatchPalette.foreground)
                }

                if let recordDuration {
                    paceBar(record: recordDuration, elapsed: elapsed)
                }
            }
        }
    }

    /// Линия-бюджет относительно рекорда: сжимается со временем, цвет — по темпу
    /// (зелёная — обгоняешь рекорд, коралловая — отстаёшь).
    @ViewBuilder
    private func paceBar(record: TimeInterval, elapsed: TimeInterval) -> some View {
        let budget = max(0, min(1, (record - elapsed) / record))
        let progress = pairCount > 0 ? Double(pairCount - remainingCount) / Double(pairCount) : 0
        let ahead = elapsed < record && elapsed / record <= progress
        let fill = LinearGradient(
            colors: ahead
                ? [MatchPalette.paceAheadStart, MatchPalette.paceAheadEnd]
                : [MatchPalette.progressStart, MatchPalette.progressEnd],
            startPoint: .leading,
            endPoint: .trailing
        )

        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(MatchPalette.accent)
                    .imageScale(.small)
                Text(StudyDurationFormat.string(record))
                    .foregroundStyle(MatchPalette.muted)
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MatchPalette.shadow.opacity(0.10))
                    Capsule()
                        .fill(fill)
                        .frame(width: geo.size.width * budget)
                        .animation(.linear(duration: 1), value: budget)
                }
            }
            .frame(height: 7)
        }
    }
}

private struct MatchingCell: View {
    let label: String
    let isSelected: Bool
    let isWrong: Bool
    let isCorrect: Bool
    let action: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .foregroundStyle(MatchPalette.cardForeground)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Self.shape.fill(cardFill))
                .overlay(Self.shape.strokeBorder(ringColor, lineWidth: ringWidth))
                .shadow(color: primaryShadow.color, radius: primaryShadow.radius, x: 0, y: primaryShadow.y)
                .shadow(color: secondaryShadow.color, radius: secondaryShadow.radius, x: 0, y: secondaryShadow.y)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .modifier(ShakeEffect(animatableData: isWrong ? 1 : 0))
        .animation(.linear(duration: 0.4), value: isWrong)
        .transition(.scale.combined(with: .opacity))
    }

    private var cardFill: LinearGradient {
        if isCorrect {
            return LinearGradient(
                colors: [oklch(0.95, 0.04, 160, 0.95), oklch(0.88, 0.08, 160, 0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Сплошная белая карточка (gradient-card непрозрачный).
        return LinearGradient(
            colors: [.white, oklch(0.995, 0.003, 250)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var ringColor: Color {
        if isWrong { return MatchPalette.destructive }
        if isCorrect { return MatchPalette.success }
        if isSelected { return MatchPalette.primary }
        return MatchPalette.shadow.opacity(0.10) // тонкая тёмная рамка
    }

    private var ringWidth: CGFloat {
        if isCorrect { return 2.5 }
        if isWrong || isSelected { return 2 }
        return 0.5
    }

    // Усиленная двухслойная тень — чтобы карточки не сливались со светлым фоном.
    private var primaryShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if isSelected { return (MatchPalette.primary.opacity(0.35), 12, 8) }
        if isCorrect { return (MatchPalette.success.opacity(0.40), 16, 6) }
        if isWrong { return (MatchPalette.destructive.opacity(0.35), 11, 8) }
        return (MatchPalette.shadow.opacity(0.18), 10, 6)
    }

    private var secondaryShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        (isSelected || isCorrect || isWrong)
            ? (MatchPalette.shadow.opacity(0.06), 4, 2)
            : (MatchPalette.shadow.opacity(0.08), 4, 2)
    }
}
