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
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(typingPromptText)
                        .multilineTextAlignment(.leading)

                    HTMLText(
                        html: card.clozePromptWithGap,
                        foregroundColor: typingPromptText.opacity(0.86),
                        font: .body.weight(.medium)
                    )
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
        Text(answer.displayText(for: input))
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .foregroundStyle(slotColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .background(typingInputShape.fill(inputFill))
            .overlay(typingInputShape.strokeBorder(inputRingColor, lineWidth: inputRingWidth))
            .compositingGroup()
            .shadow(color: MatchPalette.shadow.opacity(0.12), radius: 8, x: 0, y: 5)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !answered else { return }
                isInputFocused = true
            }
            .modifier(ShakeEffect(animatableData: shakeCount))
            .animation(.linear(duration: 0.4), value: shakeCount)
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
        withAnimation(.easeInOut(duration: 0.22)) {
            answered = true
        }
        isInputFocused = false
        if isCorrect {
            WordAudioPlayer.shared.playClozeAnswer(from: card)
        } else {
            shakeCount += 1
        }
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

    func displayText(for value: String) -> String {
        let typed = Array(sanitizedInput(value))
        var typedIndex = 0
        var pieces: [String] = []

        if !prefilledPrefix.isEmpty {
            pieces.append(prefilledPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        for character in fillableText {
            if Self.isFillable(character) {
                if typed.indices.contains(typedIndex) {
                    pieces.append(String(typed[typedIndex]))
                } else {
                    pieces.append("_")
                }
                typedIndex += 1
            } else if character.isWhitespace {
                pieces.append("  ")
            } else {
                pieces.append(String(character))
            }
        }

        return pieces.joined(separator: " ")
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

private let typingPromptGradient = LinearGradient(
    gradient: Gradient(stops: [
        .init(color: oklch(0.25, 0.04, 265), location: 0),
        .init(color: oklch(0.19, 0.04, 265), location: 0.6),
        .init(color: oklch(0.15, 0.05, 270), location: 1),
    ]),
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)
