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
            if session.mode == .matching {
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
                        ClozeMCQStudyView(card: item.card) { outcome in
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
        .toolbarColorScheme(session.mode == .matching ? .light : .dark, for: .navigationBar)
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
        if session.mode == .matching {
            return beatRecord ? MatchPalette.accent : MatchPalette.foreground
        }
        return .white
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
    let card: WordCardContent
    let onAnswer: (ReviewOutcome) -> Void

    @State private var selected: String?
    @State private var answered = false
    @State private var choices: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HTMLText(html: card.clozePrompt)
                .font(.title2)
                .foregroundStyle(.white)
                .padding(.top, 24)

            ForEach(choices, id: \.self) { option in
                Button {
                    guard !answered else { return }
                    selected = option
                    answered = true
                    onAnswer(option == card.effectiveClozeAnswer ? .correct : .incorrect)
                } label: {
                    HStack {
                        Text(option)
                            .foregroundStyle(.white)
                        Spacer()
                        if answered, option == selected {
                            Image(systemName: option == card.effectiveClozeAnswer ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(option == card.effectiveClozeAnswer ? .green : .red)
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(answered && option != selected)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .onAppear {
            if choices.isEmpty {
                choices = (card.distractors + [card.effectiveClozeAnswer]).shuffled()
            }
        }
    }
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
        .allowsHitTesting(wordSlotOpacity[slot.id] == nil)
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
        .allowsHitTesting(translationSlotOpacity[slot.id] == nil)
    }

    private func scale(for opacity: Double?) -> Double {
        guard let opacity else { return 1 }
        return 0.9 + (0.1 * opacity)
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
        guard wrongWordSlot == nil, wordSlotOpacity[slot.id] == nil else { return }
        if selectedWordSlot == slot.id {
            selectedWordSlot = nil
            return
        }
        selectedWordSlot = slot.id
        if let pair = pairCache[slot.pairID] {
            WordAudioPlayer.shared.playWord(from: pair.card)
        }
        checkPairIfReady()
    }

    private func selectTranslation(_ slot: Slot) {
        guard wrongWordSlot == nil, translationSlotOpacity[slot.id] == nil else { return }
        if selectedTranslationSlot == slot.id {
            selectedTranslationSlot = nil
            return
        }
        selectedTranslationSlot = slot.id
        checkPairIfReady()
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

    /// Исчезновение одной пары: подтверждение (зелёным) → гашение. Новую пару сразу резервируем
    /// из пула в общий пул подстановки. Появление — в тех же ячейках, по таймеру этого матча.
    private func beginMatchTransition(
        matchedID: String,
        wordSlotID: UUID,
        translationSlotID: UUID,
        shuffle: Bool
    ) {
        // 1. Блокируем ячейки и подтверждаем правильный выбор зелёным.
        wordSlotOpacity[wordSlotID] = 1
        translationSlotOpacity[translationSlotID] = 1
        correctWordSlots.insert(wordSlotID)
        correctTranslationSlots.insert(translationSlotID)

        // 2. Резервируем замену из пула — чтобы её можно было подмешать к соседним матчам.
        reserveReplacement(for: matchedID)

        // 3. После паузы подтверждения — плавное гашение.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmHighlightDuration) {
            withAnimation(.easeInOut(duration: Self.fadeOutDuration)) {
                wordSlotOpacity[wordSlotID] = 0
                translationSlotOpacity[translationSlotID] = 0
            }
        }

        // 4. После полного исчезновения — подстановка (или перетасовка) в тех же ячейках.
        let disappearDuration = Self.confirmHighlightDuration + Self.fadeOutDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + disappearDuration) {
            correctWordSlots.remove(wordSlotID)
            correctTranslationSlots.remove(translationSlotID)
            if shuffle {
                applyReshuffle()
            } else {
                commitMatch(wordSlotID: wordSlotID, translationSlotID: translationSlotID)
            }
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

        withAnimation(.easeInOut(duration: Self.fadeInDuration)) {
            wordSlotOpacity[wordSlotID] = 1
            translationSlotOpacity[translationSlotID] = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDuration) {
            wordSlotOpacity.removeValue(forKey: wordSlotID)
            translationSlotOpacity.removeValue(forKey: translationSlotID)
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
