import SwiftUI

struct MatchingColumnsStudyView: View {
    /// Исчезновение = подтверждение правильного выбора (зелёным) + плавное гашение.
    private static let confirmHighlightDuration: TimeInterval = 0.5
    private static let fadeOutDuration: TimeInterval = 1.0
    /// Появление новой лексики.
    private static let fadeInDuration: TimeInterval = 0.5
    private static let partnerNextStepProbability = 0.75

    @Bindable var session: StudySession
    let store: DeckStore
    /// Доска опустела после анимации последнего гашения — пора показать «Готово».
    let onFinished: () -> Void

    /// Одна ячейка колонки: стабильная позиция на экране (`id`) + лексика в ней (`pairID`).
    /// `id` — это «пара ячеек» из модели: не двигается, на ней играет анимация.
    /// `pairID` — содержимое: его и перемешиваем при подстановке.
    private struct Slot: Identifiable, Equatable {
        let id = UUID()
        var contentID = UUID()
        var pairID: String?
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
    @State private var pendingWordPartnerDelays: [String: Int] = [:]
    @State private var pendingTranslationPartnerDelays: [String: Int] = [:]

    /// Лейблы всех виденных пар — чтобы текст не пропадал, пока матченная пара гаснет.
    @State private var pairCache: [String: MatchingPair] = [:]
    @State private var matchingRecord: MatchingRecordSummary?
    @State private var previewPair: MatchingPair?
    @State private var suppressedWordTapSlot: UUID?

    // Перемешивание поля, если три раза подряд матч в одни и те же ячейки.
    @State private var lastMatchedWordSlot: UUID?
    @State private var lastMatchedTranslationSlot: UUID?
    @State private var consecutiveMatchesAtSamePositions = 0

    private var rows: [(word: Slot, translation: Slot)] {
        guard wordColumn.count == translationColumn.count else { return [] }
        return Array(zip(wordColumn, translationColumn))
    }

    private var usesAudioPrompts: Bool {
        session.mode.isAudioMatching
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(usesAudioPrompts ? "Послушай и соедини" : "Соедини пары"))
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
        .task(id: session.matchingRecordScope) {
            matchingRecord = try? store.matchingRecord(scope: session.matchingRecordScope)
        }
        .onChange(of: session.matchingVisibleItems.map(\.id), initial: true) { _, _ in
            seedColumnsIfNeeded()
        }
        .overlay {
            if let previewPair {
                MatchingFlashcardPreviewOverlay(pair: previewPair) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.previewPair = nil
                    }
                    suppressedWordTapSlot = nil
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: previewPair?.id)
        .onDisappear {
            cancelTransitionTasks()
        }
    }

    @ViewBuilder
    private func wordCell(_ slot: Slot) -> some View {
        let pair = slot.pairID.flatMap { pairCache[$0] }
        Group {
            if usesAudioPrompts {
                MatchingCell(
                    label: "",
                    systemImage: "speaker.wave.2.fill",
                    accessibilityLabel: "Проиграть слово",
                    isSelected: selectedWordSlot == slot.id,
                    isWrong: wrongWordSlot == slot.id,
                    isCorrect: correctWordSlots.contains(slot.id),
                    action: { selectWord(slot) }
                )
            } else {
                MatchingCell(
                    label: pair?.card.word ?? "",
                    isSelected: selectedWordSlot == slot.id,
                    isWrong: wrongWordSlot == slot.id,
                    isCorrect: correctWordSlots.contains(slot.id),
                    action: { selectWord(slot) }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            guard let pair else { return }
                            suppressedWordTapSlot = slot.id
                            withAnimation(.easeOut(duration: 0.18)) {
                                previewPair = pair
                            }
                        }
                )
            }
        }
        .id(slot.contentID)
        .opacity(wordSlotOpacity[slot.id] ?? 1)
        .opacity(slot.pairID == nil ? 0 : 1)
        .allowsHitTesting(slot.pairID != nil && isWordTappable(slot.id))
    }

    @ViewBuilder
    private func translationCell(_ slot: Slot) -> some View {
        MatchingCell(
            label: slot.pairID.flatMap { pairCache[$0]?.translation } ?? "",
            isSelected: selectedTranslationSlot == slot.id,
            isWrong: wrongTranslationSlot == slot.id,
            isCorrect: correctTranslationSlots.contains(slot.id),
            action: { selectTranslation(slot) }
        )
        .id(slot.contentID)
        .opacity(translationSlotOpacity[slot.id] ?? 1)
        .opacity(slot.pairID == nil ? 0 : 1)
        .allowsHitTesting(slot.pairID != nil && isTranslationTappable(slot.id))
    }

    // Тапать можно по свободным ячейкам и по тем, что уже проявляются (контент валиден).
    private func isWordTappable(_ id: UUID) -> Bool {
        wordSlotOpacity[id] == nil || appearingWordSlots.contains(id)
    }

    private func isTranslationTappable(_ id: UUID) -> Bool {
        let canTap = translationSlotOpacity[id] == nil || appearingTranslationSlots.contains(id)
        guard canTap else { return false }
        return !usesAudioPrompts || selectedWordSlot != nil
    }

    /// Первичная раздача: лексика по ячейкам, колонки мешаем независимо.
    private func seedColumnsIfNeeded() {
        guard wordColumn.isEmpty, translationColumn.isEmpty else { return }
        let pairs = session.matchingVisibleItems
        guard !pairs.isEmpty else { return }
        for pair in pairs { pairCache[pair.id] = pair }
        wordColumn = fixedSlots(from: pairs.shuffled().map(\.id))
        translationColumn = fixedSlots(from: pairs.shuffled().map(\.id))
    }

    private func fixedSlots(from pairIDs: [String]) -> [Slot] {
        (0..<MatchingPairScheduler.slotCount).map { index in
            Slot(pairID: index < pairIDs.count ? pairIDs[index] : nil)
        }
    }

    // MARK: - Selection

    private func selectWord(_ slot: Slot) {
        guard wrongWordSlot == nil, isWordTappable(slot.id) else { return }
        if suppressedWordTapSlot == slot.id {
            suppressedWordTapSlot = nil
            return
        }
        guard let pairID = slot.pairID else { return }
        if selectedWordSlot == slot.id {
            if usesAudioPrompts, let pair = pairCache[pairID] {
                WordAudioPlayer.shared.playWord(from: pair.card)
                return
            }
            selectedWordSlot = nil
            return
        }
        selectedWordSlot = slot.id
        accelerateIfPartnerMissing(pairID: pairID, selectedWord: true)
        if let pair = pairCache[pairID] {
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
        guard let pairID = slot.pairID else { return }
        accelerateIfPartnerMissing(pairID: pairID, selectedWord: false)
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
            clearSelection()
            return
        }

        guard let wordPairID = wordSlot.pairID, let translationPairID = translationSlot.pairID else {
            clearSelection()
            return
        }

        if wordPairID == translationPairID {
            let shuffle = shouldShuffleAfterMatch(wordSlot: wordSlotID, translationSlot: translationSlotID)
            clearSelection()
            beginMatchTransition(
                matchedID: wordPairID,
                wordSlotID: wordSlotID,
                translationSlotID: translationSlotID,
                shuffle: shuffle
            )
        } else {
            if let pair = pairCache[wordPairID] {
                WordAudioPlayer.shared.playWord(from: pair.card, style: .wrong)
            }
            wrongWordSlot = wordSlotID
            wrongTranslationSlot = translationSlotID
            clearSelection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeOut(duration: 0.2)) {
                    wrongWordSlot = nil
                    wrongTranslationSlot = nil
                }
            }
        }
    }

    private func clearSelection() {
        selectedWordSlot = nil
        selectedTranslationSlot = nil
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

        // 2. Резервируем замену из пула. Старые переходы не ускоряем: пусть гаснут своим темпом.
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

    private func cancelTransitionTasks() {
        for task in transitionTasks.values {
            task.cancel()
        }
        transitionTasks.removeAll()
        pendingTransitions.removeAll()
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
            return // ячейки уже нет — ничего не делаем
        }

        // Конец колоды: подставлять нечего — очищаем ячейки, но сохраняем их место.
        guard !pendingWords.isEmpty, !pendingTranslations.isEmpty else {
            wordColumn[wordIndex].pairID = nil
            translationColumn[translationIndex].pairID = nil
            pendingWordPartnerDelays.removeAll()
            pendingTranslationPartnerDelays.removeAll()
            wordSlotOpacity.removeValue(forKey: wordSlotID)
            translationSlotOpacity.removeValue(forKey: translationSlotID)
            finishIfBoardEmpty()
            return
        }

        let wordPick = removeScheduledWord()
        let translationPick = removeScheduledTranslation(excluding: wordPick)
        scheduleMissingPartners(wordPick: wordPick, translationPick: translationPick)
        resetSlotOpacityForReplacement(wordSlotID: wordSlotID, translationSlotID: translationSlotID)
        wordColumn[wordIndex].pairID = wordPick
        wordColumn[wordIndex].contentID = UUID()
        translationColumn[translationIndex].pairID = translationPick
        translationColumn[translationIndex].contentID = UUID()

        startAppearTransition(wordSlotID: wordSlotID, translationSlotID: translationSlotID)
    }

    private func resetSlotOpacityForReplacement(wordSlotID: UUID, translationSlotID: UUID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            wordSlotOpacity[wordSlotID] = 0
            translationSlotOpacity[translationSlotID] = 0
        }
    }

    private func removeScheduledWord() -> String {
        let index = scheduledPickIndex(in: pendingWords, delays: pendingWordPartnerDelays)
        let pick = pendingWords.remove(at: index)
        pendingWordPartnerDelays.removeValue(forKey: pick)
        advanceWordPartnerDelays()
        return pick
    }

    private func removeScheduledTranslation(excluding pairID: String) -> String {
        let index = scheduledTranslationPickIndex(excluding: pairID)
        let pick = pendingTranslations.remove(at: index)
        pendingTranslationPartnerDelays.removeValue(forKey: pick)
        advanceTranslationPartnerDelays()
        return pick
    }

    private func scheduledTranslationPickIndex(excluding pairID: String) -> Int {
        let due = pendingTranslations.indices.filter {
            pendingTranslations[$0] != pairID && pendingTranslationPartnerDelays[pendingTranslations[$0]] == 0
        }
        if let index = due.randomElement() {
            return index
        }

        let unscheduled = pendingTranslations.indices.filter {
            pendingTranslations[$0] != pairID && pendingTranslationPartnerDelays[pendingTranslations[$0]] == nil
        }
        if let index = unscheduled.randomElement() {
            return index
        }

        let delayed = pendingTranslations.indices.filter {
            pendingTranslations[$0] != pairID
        }
        if let index = delayed.randomElement() {
            return index
        }

        return scheduledPickIndex(in: pendingTranslations, delays: pendingTranslationPartnerDelays)
    }

    private func scheduledPickIndex(in pending: [String], delays: [String: Int]) -> Int {
        let due = pending.indices.filter { delays[pending[$0]] == 0 }
        if let index = due.randomElement() {
            return index
        }

        let unscheduled = pending.indices.filter { delays[pending[$0]] == nil }
        if let index = unscheduled.randomElement() {
            return index
        }

        return Int.random(in: pending.indices)
    }

    private func scheduleMissingPartners(wordPick: String, translationPick: String) {
        if wordPick != translationPick, pendingTranslations.contains(wordPick) {
            scheduleTranslationPartner(for: wordPick)
        }
        if translationPick != wordPick, pendingWords.contains(translationPick) {
            scheduleWordPartner(for: translationPick)
        }
    }

    private func scheduleWordPartner(for pairID: String) {
        guard pendingWordPartnerDelays[pairID] == nil else { return }
        pendingWordPartnerDelays[pairID] = partnerDelay()
    }

    private func scheduleTranslationPartner(for pairID: String) {
        guard pendingTranslationPartnerDelays[pairID] == nil else { return }
        pendingTranslationPartnerDelays[pairID] = partnerDelay()
    }

    private func partnerDelay() -> Int {
        Double.random(in: 0..<1) < Self.partnerNextStepProbability ? 0 : 1
    }

    private func advanceWordPartnerDelays() {
        let pending = Set(pendingWords)
        for (pairID, delay) in Array(pendingWordPartnerDelays) {
            if !pending.contains(pairID) {
                pendingWordPartnerDelays.removeValue(forKey: pairID)
            } else if delay > 0 {
                pendingWordPartnerDelays[pairID] = delay - 1
            }
        }
    }

    private func advanceTranslationPartnerDelays() {
        let pending = Set(pendingTranslations)
        for (pairID, delay) in Array(pendingTranslationPartnerDelays) {
            if !pending.contains(pairID) {
                pendingTranslationPartnerDelays.removeValue(forKey: pairID)
            } else if delay > 0 {
                pendingTranslationPartnerDelays[pairID] = delay - 1
            }
        }
    }

    /// Перетасовка всего поля: занятые ячейки тоже переезжают (исключение из «ячейки не двигаются»).
    /// Матченные пары уже убраны при гашении, раздаём заново всё видимое.
    private func applyReshuffle() {
        pendingWords.removeAll()
        pendingTranslations.removeAll()
        pendingWordPartnerDelays.removeAll()
        pendingTranslationPartnerDelays.removeAll()
        wordSlotOpacity.removeAll()
        translationSlotOpacity.removeAll()
        correctWordSlots.removeAll()
        correctTranslationSlots.removeAll()
        appearingWordSlots.removeAll()
        appearingTranslationSlots.removeAll()
        for (_, task) in transitionTasks { task.cancel() }
        transitionTasks.removeAll()
        pendingTransitions.removeAll()
        clearSelection()

        let pairs = session.matchingVisibleItems
        for pair in pairs { pairCache[pair.id] = pair }
        guard !pairs.isEmpty else {
            clearBoardSlots()
            finishIfBoardEmpty()
            return
        }
        wordColumn = fixedSlots(from: pairs.shuffled().map(\.id))
        translationColumn = fixedSlots(from: pairs.shuffled().map(\.id))
    }

    private func finishIfBoardEmpty() {
        if wordColumn.allSatisfy({ $0.pairID == nil }), translationColumn.allSatisfy({ $0.pairID == nil }) {
            onFinished()
        }
    }

    private func clearBoardSlots() {
        wordColumn = fixedSlots(from: [])
        translationColumn = fixedSlots(from: [])
    }

    /// Проявляем новую лексику в тех же ячейках, где был матч.
    private func startAppearTransition(wordSlotID: UUID, translationSlotID: UUID) {
        appearingWordSlots.insert(wordSlotID)
        appearingTranslationSlots.insert(translationSlotID)

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: Self.fadeInDuration)) {
                wordSlotOpacity[wordSlotID] = 1
                translationSlotOpacity[translationSlotID] = 1
            }
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
    let record: MatchingRecordSummary?
    let pairCount: Int

    private var recordDuration: TimeInterval? {
        guard settings.isPaceBarEnabled, let record, record.pairCount == pairCount else { return nil }
        return record.bestDuration
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(remainingCount)")
                            .font(.title2.bold())
                            .foregroundStyle(MatchPalette.foreground)
                        Text("осталось")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MatchPalette.muted)
                    }
                    StudySessionProgressBar(
                        completed: max(0, pairCount - remainingCount),
                        total: pairCount
                    )
                }

                HStack(spacing: 10) {
                    if let recordDuration {
                        paceBar(record: recordDuration, elapsed: max(0, elapsed))
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(StudyDurationFormat.string(max(0, elapsed)))
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(MatchPalette.foreground)
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

struct MatchingFlashcardPreviewOverlay: View {
    let pair: MatchingPair
    let onClose: () -> Void

    @State private var cardFrame: CGRect = .zero

    private var card: WordCardContent {
        pair.card
    }

    private var exampleTranslation: String? {
        trimmedNonEmpty(card.clozeExampleTranslation)
    }

    private var etymologyHTML: String? {
        trimmedNonEmpty(card.etymology)
    }

    private var senseNoteHTML: String? {
        trimmedNonEmpty(card.primarySense?.note)
    }

    private var cardNotesHTML: String? {
        trimmedNonEmpty(card.cardNotes)
    }

    private var hasDetails: Bool {
        etymologyHTML != nil || senseNoteHTML != nil || cardNotesHTML != nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 14) {
                        headerSection
                            .padding(.trailing, 44)

                        exampleSection

                        if hasDetails {
                            detailsSection
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .accessibilityLabel("Закрыть")
                }
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(oklch(0.32, 0.016, 260))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                .compositingGroup()
                .shadow(color: MatchPalette.shadow.opacity(0.22), radius: 18, x: 0, y: 10)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MatchingPreviewCardFrameKey.self,
                            value: proxy.frame(in: .named("matchingPreviewOverlay"))
                        )
                    }
                )
                .padding(.horizontal, 22)
                .padding(.top, 96)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named("matchingPreviewOverlay"))
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("matchingPreviewOverlay"))
                .onEnded { value in
                    let isTap = abs(value.translation.width) < 8 && abs(value.translation.height) < 8
                    guard isTap, !cardFrame.contains(value.location) else { return }
                    onClose()
                }
        )
        .onPreferenceChange(MatchingPreviewCardFrameKey.self) { frame in
            cardFrame = frame
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.word)
                .font(.title.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(pair.translation)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exampleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.clozeExamplePlainText)
                .font(.body)
                .foregroundStyle(oklch(0.92, 0.01, 260))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let exampleTranslation {
                HTMLText(
                    html: exampleTranslation,
                    foregroundColor: oklch(0.92, 0.01, 260),
                    font: .body
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .overlay(.white.opacity(0.12))
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 12) {
                if let etymologyHTML {
                    detailSection(title: "Этимология", html: etymologyHTML)
                }

                if let senseNoteHTML {
                    detailSection(title: "Значение", html: senseNoteHTML)
                }

                if let cardNotesHTML {
                    detailSection(title: "Заметка", html: cardNotesHTML)
                }
            }
        }
    }

    private func detailSection(title: String, html: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(oklch(0.82, 0.018, 260))

            HTMLText(
                html: html,
                foregroundColor: oklch(0.72, 0.015, 260),
                font: .footnote
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct MatchingPreviewCardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct MatchingCell: View {
    let label: String
    var systemImage: String?
    var accessibilityLabel: String?
    let isSelected: Bool
    let isWrong: Bool
    let isCorrect: Bool
    let action: () -> Void
    @State private var feedbackTrigger = false

    var body: some View {
        Button {
            feedbackTrigger.toggle()
            action()
        } label: {
            cellContent
            .foregroundStyle(MatchPalette.cardForeground)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(studyCardShape.fill(cardFill))
            .overlay(studyCardShape.strokeBorder(ringColor, lineWidth: ringWidth))
            .compositingGroup()
            .shadow(color: primaryShadow.color, radius: primaryShadow.radius, x: 0, y: primaryShadow.y)
            .shadow(color: secondaryShadow.color, radius: secondaryShadow.radius, x: 0, y: secondaryShadow.y)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel.map { L10n.text($0) } ?? label)
        .frame(maxWidth: .infinity)
        .modifier(ShakeEffect(animatableData: isWrong ? 1 : 0))
        .animation(.linear(duration: 0.4), value: isWrong)
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private var cellContent: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .imageScale(.medium)
        } else {
            Text(label)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
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
