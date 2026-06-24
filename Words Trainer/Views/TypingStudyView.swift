import SwiftUI

enum TypingPromptMode: Sendable {
    case clozeSentence
    case translationExample
}

struct TypingStudyView: View {
    let card: WordCardContent
    let promptMode: TypingPromptMode
    let totalCount: Int
    let remainingCount: Int
    let onAnswer: (ReviewOutcome) -> Void

    @State private var displayedRoundID: UUID?
    @State private var input = ""
    @State private var answered = false
    @State private var passed = false
    @State private var shakeCount: CGFloat = 0
    @State private var nextFeedbackTrigger = false
    @State private var previewPair: MatchingPair?
    @FocusState private var isInputFocused: Bool

    private var roundID: UUID {
        card.primarySenseID ?? card.id
    }

    private var answer: TypingAnswer {
        TypingAnswer(rawAnswer: card.effectiveClozeAnswer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudyProgressHeader(totalCount: totalCount, remainingCount: remainingCount)

            VStack(alignment: .leading, spacing: 18) {
                promptCard

                VStack(spacing: 14) {
                    answerSlots
                    hiddenInput
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 16) {
                    answerResult
                        .frame(maxWidth: .infinity)
                        .opacity(answered ? 1 : 0)

                    Button("Дальше") {
                        nextFeedbackTrigger.toggle()
                        advance()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MatchPalette.primary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .sensoryFeedback(.selection, trigger: nextFeedbackTrigger)
                    .opacity(answered ? 1 : 0)
                    .disabled(!answered)
                    .accessibilityHidden(!answered)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onAppear {
            resetRoundIfNeeded()
            isInputFocused = true
        }
        .onChange(of: roundID) { _, _ in
            resetRound()
        }
        .onChange(of: input) { _, newValue in
            sanitizeAndCheck(newValue)
        }
        .overlay {
            if let previewPair {
                MatchingFlashcardPreviewOverlay(pair: previewPair) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.previewPair = nil
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: previewPair?.id)
    }

    /// Карточка слова для overlay по долгому тапу (как в режиме «Предложения»).
    private var previewPairForCard: MatchingPair {
        MatchingPair(
            cardID: card.id,
            senseID: card.primarySenseID ?? card.id,
            card: card,
            translation: card.translation
        )
    }

    private var promptCard: some View {
        Group {
            switch promptMode {
            case .clozeSentence:
                HTMLText(
                    html: card.clozePromptWithGap,
                    foregroundColor: typingPromptText,
                    font: .title3.weight(.semibold)
                )
            case .translationExample:
                VStack(alignment: .leading, spacing: 14) {
                    Text(card.translation)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(typingPromptText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)

                    HTMLText(
                        html: card.clozePromptWithGap,
                        foregroundColor: typingPromptText.opacity(0.86),
                        font: .body.weight(.medium)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(
            typingPromptShape
                .fill(typingPromptGradient)
                .overlay {
                    Circle()
                        .fill(oklch(0.7, 0.18, 245, 0.25))
                        .frame(width: 180, height: 180)
                        .blur(radius: 50)
                        .offset(x: 80, y: -70)
                }
                .clipShape(typingPromptShape)
        )
        .overlay(typingPromptShape.strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: oklch(0.2, 0.12, 265, 0.4), radius: 18, x: 0, y: 12)
    }

    private var answerSlots: some View {
        let metrics = slotMetrics
        return Text(slotsAttributedString(fontSize: metrics.fontSize, lineCount: metrics.lineCount))
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.center)
            .lineLimit(slotMetrics.lineCount)
            // Страховка: если оценка ширины чуть промахнулась, буквы ужимаются,
            // а не обрезаются. Высота панели при этом фиксирована и не скачет.
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: slotMetrics.boxHeight)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(typingInputShape.fill(inputFill))
            .overlay(typingInputShape.strokeBorder(inputRingColor, lineWidth: inputRingWidth))
            .compositingGroup()
            .shadow(color: MatchPalette.shadow.opacity(0.12), radius: 8, x: 0, y: 5)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !answered else { return }
                isInputFocused = true
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard answered else { return }
                        isInputFocused = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            previewPair = previewPairForCard
                        }
                    }
            )
            .modifier(ShakeEffect(animatableData: shakeCount))
            .animation(.linear(duration: 0.4), value: shakeCount)
    }

    /// Кегль, число строк и фиксированная высота панели ответа — всё считается
    /// детерминированно из геометрии слотов (моноширинный шрифт → ширина =
    /// число глифов × advance) и постоянной доступной ширины. Не зависит от
    /// введённого текста, поэтому ни размер, ни высота не «прыгают» при наборе.
    private var slotMetrics: (fontSize: CGFloat, lineCount: Int, boxHeight: CGFloat) {
        let maxSize: CGFloat = 34
        let minSize: CGFloat = 18
        // Реальная ширина ячейки моноширинного SF semibold с учётом пробелов
        // между слотами; берём с запасом, чтобы строка точно влезала.
        let advance: CGFloat = 0.70

        // Доступная ширина текста: экран минус внешние (16+16) и внутренние
        // (16+16) горизонтальные отступы панели.
        let width = max(UIScreen.main.bounds.width - 64, 1)

        let totalGlyphs = CGFloat(max(answer.slots(for: "").count * 2 - 1, 1))
        let longestWordGlyphs = CGFloat(max(answer.longestWordSlotCount * 2 - 1, 1))

        // Сначала пробуем одну строку на максимальном кегле.
        let oneLineSize = min(maxSize, width / (totalGlyphs * advance))
        let fontSize: CGFloat
        let lineCount: Int
        if oneLineSize >= minSize {
            fontSize = oneLineSize.rounded(.down)
            lineCount = 1
        } else {
            // Не лезет в строку читаемым кеглем → две строки. Перенос по словам
            // делит фразу неравномерно, поэтому на длинную строку приходится
            // больше половины глифов — берём ~0.6 как запас. Плюс строка не
            // должна быть уже самого длинного слова.
            let glyphsPerLine = max(totalGlyphs * 0.6, longestWordGlyphs)
            fontSize = min(maxSize, max(minSize, width / (glyphsPerLine * advance))).rounded(.down)
            lineCount = 2
        }

        // Высота строки моноширинного SF ≈ 1.2 × кегль; высота панели
        // фиксирована под число строк, поэтому не меняется при наборе.
        // Нижняя граница держит панель «воздушной» для коротких слов.
        let lineHeight = fontSize * 1.2
        let boxHeight = max(lineHeight * CGFloat(lineCount), 44)
        return (fontSize, lineCount, boxHeight)
    }

    private var hiddenInput: some View {
        TextField("", text: $input)
            .keyboardType(.alphabet)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isInputFocused)
            .submitLabel(.done)
            .onSubmit {
                guard !answered else { return }
                checkAnswer(force: true)
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var answerResult: some View {
        if answered {
            Text(answer.rawAnswer)
                .font(.headline.weight(.semibold))
                .foregroundStyle(passed ? MatchPalette.successText : MatchPalette.destructive)
                .multilineTextAlignment(.center)
        } else {
            Text(" ")
                .font(.headline)
        }
    }

    private var slotColor: Color {
        if !answered { return MatchPalette.foreground }
        return passed ? MatchPalette.successText : MatchPalette.destructive
    }

    /// Цветная строка слотов: разделители — светло-серые, текущий слот —
    /// синий primary из палитры. После ответа всё красится цветом результата.
    ///
    /// Внутри слова слоты соединяются неразрывным пробелом, на границе слов —
    /// обычным, чтобы при переносе строка рвалась только между словами, а не
    /// посередине слова.
    /// Строка слотов с ЖЁСТКИМ переносом, посчитанным заранее.
    ///
    /// Раньше переносом управлял системный word-wrap: при каждом наборе буквы
    /// ширина строки чуть менялась, и движок выбирал то одну границу слов, то
    /// другую — раскладка прыгала. Здесь все пробелы делаем неразрывными, а
    /// перенос на 2-ю строку вставляем сами (`\n`) в детерминированной точке,
    /// не зависящей от введённого текста. Поэтому раскладка стабильна.
    private func slotsAttributedString(fontSize: CGFloat, lineCount: Int) -> AttributedString {
        // Зазор между прочерками — обычный пробел моноширинного шрифта, который во
        // весь кегль выглядит слишком широким. Поджимаем его отрицательным кернингом
        // примерно вдвое.
        let spacerKern = -fontSize * 0.3
        let slots = answer.slots(for: input)
        let words = TypingSlotLayout.wordRanges(isSeparator: slots.map(\.isSeparator))
        let breakAfterWord = lineCount >= 2
            ? TypingSlotLayout.balancedBreakIndex(wordSlotCounts: words.map(\.count))
            : nil

        var result = AttributedString()
        for (wordIndex, word) in words.enumerated() {
            if wordIndex > 0 {
                // Перенос строки строго после посчитанного слова; иначе —
                // неразрывный пробел, чтобы система не переносила сама.
                if breakAfterWord == wordIndex - 1 {
                    result.append(plainRun("\n"))
                } else {
                    result.append(spacerRun("\u{00A0}", kern: spacerKern))
                }
            }
            // Хвостовой разделитель слова, после которого идёт перенос, в конце
            // строки не рисуем — прочерк-пробел у самого края не нужен.
            let dropsTrailingSeparator = breakAfterWord == wordIndex && slots[word.upperBound - 1].isSeparator
            let visible = dropsTrailingSeparator ? word.dropLast() : word
            for (offset, slotIndex) in visible.enumerated() {
                if offset > 0 {
                    result.append(spacerRun("\u{00A0}", kern: spacerKern))
                }
                result.append(runForSlot(slots[slotIndex]))
            }
        }

        return result
    }

    private func runForSlot(_ slot: TypingAnswer.Slot) -> AttributedString {
        switch slot {
        case let .fixed(text), let .typed(text):
            return coloredRun(text, slotColor)
        case .current:
            // Подсвечиваем ближайший слот для ввода только до ответа.
            return coloredRun("_", answered ? slotColor : MatchPalette.primary)
        case .pending:
            return coloredRun("_", slotColor)
        case .separator:
            return coloredRun("_", typingSeparatorColor)
        }
    }


    private func coloredRun(_ string: String, _ color: Color) -> AttributedString {
        var run = AttributedString(string)
        run.foregroundColor = color
        return run
    }

    private func spacerRun(_ string: String, kern: CGFloat) -> AttributedString {
        var run = AttributedString(string)
        run.kern = kern
        return run
    }

    private func plainRun(_ string: String) -> AttributedString {
        AttributedString(string)
    }

    private var inputFill: LinearGradient {
        if answered && passed {
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

    private var inputRingColor: Color {
        if answered && !passed { return MatchPalette.destructive }
        if answered && passed { return MatchPalette.success }
        return MatchPalette.shadow.opacity(0.12)
    }

    private var inputRingWidth: CGFloat {
        answered ? 2 : 0.5
    }

    private func sanitizeAndCheck(_ value: String) {
        let sanitized = answer.sanitizedInput(value)
        if sanitized != value {
            input = sanitized
            return
        }
        guard !answered, answer.isComplete(input) else { return }
        checkAnswer(force: false)
    }

    private func checkAnswer(force: Bool) {
        guard !answered else { return }
        guard force || answer.isComplete(input) else { return }
        let isCorrect = answer.matches(input)
        passed = isCorrect

        // Правильный ответ ребёнок уже ввёл сам — подтверждать нечего, сразу
        // листаем дальше. Фокус НЕ снимаем, чтобы клавиатура не пряталась и не
        // появлялась снова на следующей карточке. На неверный показываем
        // результат и кнопку «Дальше».
        if isCorrect {
            WordAudioPlayer.shared.playClozeAnswer(from: card)
            advance()
            return
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            answered = true
        }
        isInputFocused = false
        shakeCount += 1
    }

    private func advance() {
        onAnswer(passed ? .correct : .incorrect)
    }

    private func resetRoundIfNeeded() {
        guard displayedRoundID != roundID else { return }
        resetRound()
    }

    private func resetRound() {
        displayedRoundID = roundID
        input = ""
        answered = false
        passed = false
        isInputFocused = true
    }
}

private struct TypingAnswer {
    let rawAnswer: String
    let prefilledPrefix: String
    let fillableText: String
    private let targetCharacters: [Character]

    init(rawAnswer: String) {
        let trimmed = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawAnswer = trimmed

        let prefix = Self.prefilledPrefix(in: trimmed)
        self.prefilledPrefix = prefix
        let body = String(trimmed.dropFirst(prefix.count))
        self.fillableText = body
        self.targetCharacters = body.filter(Self.isFillable)
    }

    func sanitizedInput(_ value: String) -> String {
        String(value.filter(Self.isFillable).prefix(targetCharacters.count))
    }

    func isComplete(_ value: String) -> Bool {
        sanitizedInput(value).count >= targetCharacters.count
    }

    func matches(_ value: String) -> Bool {
        Self.normalized(sanitizedInput(value)) == Self.normalized(String(targetCharacters))
    }

    /// Один отображаемый «слот» в строке ответа.
    enum Slot: Hashable {
        /// Заранее открытая часть (артикль/`to`) или буква, не требующая ввода.
        case fixed(String)
        /// Введённая пользователем буква.
        case typed(String)
        /// Ближайший незаполненный слот — его подсвечиваем.
        case current
        /// Ещё не заполненный слот.
        case pending
        /// Разделитель между словами (вместо пробела) — пропускается при вводе.
        case separator

        var isSeparator: Bool {
            if case .separator = self { return true }
            return false
        }
    }

    /// Полный набор слотов для текущего ввода. Длина и состав не зависят от
    /// того, сколько уже введено (меняются только typed/current/pending),
    /// поэтому раскладка не «прыгает» при наборе.
    func slots(for value: String) -> [Slot] {
        let typed = Array(sanitizedInput(value))
        var typedIndex = 0
        var slots: [Slot] = []

        let prefix = prefilledPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            slots.append(.fixed(prefix))
        }

        for character in fillableText {
            if Self.isFillable(character) {
                if typed.indices.contains(typedIndex) {
                    slots.append(.typed(String(typed[typedIndex])))
                } else if typedIndex == typed.count {
                    slots.append(.current)
                } else {
                    slots.append(.pending)
                }
                typedIndex += 1
            } else if character.isWhitespace {
                slots.append(.separator)
            } else {
                slots.append(.fixed(String(character)))
            }
        }

        return slots
    }

    /// Число слотов в самом длинном «слове» (между разделителями). По нему
    /// гарантируем, что при переносе по словам каждое слово влезает в строку
    /// целиком.
    var longestWordSlotCount: Int {
        var longest = 0
        var current = 0
        for slot in slots(for: "") {
            if slot.isSeparator {
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(longest, current, 1)
    }

    private static func prefilledPrefix(in answer: String) -> String {
        let lower = answer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for prefix in ["an ", "a ", "to "] where lower.hasPrefix(prefix) {
            return String(answer.prefix(prefix.count))
        }
        return ""
    }

    private static func isFillable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

private let typingPromptShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
private let typingInputShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
private let typingPromptText = Color.white.opacity(0.92)
/// Светло-серый прочерк-разделитель между словами в ответе.
private let typingSeparatorColor = oklch(0.80, 0.01, 260)

private let typingPromptGradient = LinearGradient(
    gradient: Gradient(stops: [
        .init(color: oklch(0.25, 0.04, 265), location: 0),
        .init(color: oklch(0.19, 0.04, 265), location: 0.6),
        .init(color: oklch(0.15, 0.05, 270), location: 1),
    ]),
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)
