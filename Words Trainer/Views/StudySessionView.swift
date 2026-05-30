import SwiftUI

struct StudySessionView: View {
    @Bindable var session: StudySession
    let store: DeckStore
    let deckTitle: String

    var body: some View {
        StudyScreenChrome {
            Group {
                if session.isFinished {
                    ContentUnavailableView(
                        "Готово",
                        systemImage: "checkmark.circle",
                        description: Text("Сессия по колоде «\(deckTitle)» завершена.")
                    )
                    .foregroundStyle(.white)
                } else if session.mode == .matching {
                    MatchingColumnsStudyView(session: session)
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
        .navigationTitle(session.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SoundToggleToolbarButton()
            }
        }
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
    @Bindable var session: StudySession

    @State private var selectedWordID: String?
    @State private var selectedTranslationID: String?
    @State private var wrongWordID: String?
    @State private var wrongTranslationID: String?
    @State private var translationItems: [MatchingPair] = []

    private var wordItems: [MatchingPair] {
        session.matchingVisibleItems
    }

    private var matchingRows: [(word: MatchingPair, translation: MatchingPair)] {
        let words = wordItems
        guard !words.isEmpty,
              translationItems.count == words.count,
              Set(translationItems.map(\.id)) == Set(words.map(\.id)) else {
            return []
        }
        return Array(zip(words, translationItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Соедини пары")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Выбери слово слева и перевод справа. Правильная пара исчезнет.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.top, 12)

            HStack(alignment: .top, spacing: 12) {
                Text("Слово")
                    .matchingColumnHeader()
                Text("Перевод")
                    .matchingColumnHeader()
            }

            ForEach(Array(matchingRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: 12) {
                    MatchingCell(
                        pairID: row.word.id,
                        label: row.word.card.word,
                        isSelected: selectedWordID == row.word.id,
                        isWrong: wrongWordID == row.word.id,
                        action: { selectWord(row.word) }
                    )

                    MatchingCell(
                        pairID: row.translation.id,
                        label: row.translation.translation,
                        isSelected: selectedTranslationID == row.translation.id,
                        isWrong: wrongTranslationID == row.translation.id,
                        action: { selectTranslation(row.translation) }
                    )
                }
            }

            Spacer()

            Text("\(session.remainingCount) осталось")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .onChange(of: wordItems.map(\.id), initial: true) { _, ids in
            syncTranslations(withPairIDs: ids)
        }
    }

    private func syncTranslations(withPairIDs ids: [String]) {
        guard !ids.isEmpty else {
            translationItems = []
            return
        }
        let idSet = Set(ids)
        let previousIDs = Set(translationItems.map(\.id))
        if previousIDs == idSet, translationItems.count == ids.count {
            return
        }

        let byID = Dictionary(uniqueKeysWithValues: wordItems.map { ($0.id, $0) })
        var next = ids.compactMap { byID[$0] }
        guard next.count == ids.count else {
            translationItems = wordItems.shuffled()
            return
        }

        if previousIDs != idSet || translationItems.isEmpty {
            next.shuffle()
        }
        translationItems = next
    }

    private func selectWord(_ pair: MatchingPair) {
        guard wrongWordID == nil else { return }
        if selectedWordID == pair.id {
            selectedWordID = nil
            return
        }
        selectedWordID = pair.id
        WordAudioPlayer.shared.playWord(from: pair.card)
        checkPairIfReady()
    }

    private func selectTranslation(_ pair: MatchingPair) {
        guard wrongWordID == nil else { return }
        if selectedTranslationID == pair.id {
            selectedTranslationID = nil
            return
        }
        selectedTranslationID = pair.id
        checkPairIfReady()
    }

    private func checkPairIfReady() {
        guard let selectedWordID, let selectedTranslationID else { return }
        if selectedWordID == selectedTranslationID {
            withAnimation(.snappy) {
                session.removeMatchedPair(id: selectedWordID)
            }
            self.selectedWordID = nil
            self.selectedTranslationID = nil
        } else {
            if let wordPair = wordItems.first(where: { $0.id == selectedWordID }) {
                WordAudioPlayer.shared.playWord(from: wordPair.card, style: .wrong)
            }
            wrongWordID = selectedWordID
            wrongTranslationID = selectedTranslationID
            self.selectedWordID = nil
            self.selectedTranslationID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeOut(duration: 0.2)) {
                    wrongWordID = nil
                    wrongTranslationID = nil
                    self.selectedWordID = nil
                    self.selectedTranslationID = nil
                }
            }
        }
    }
}

private struct MatchingColumnHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

private extension View {
    func matchingColumnHeader() -> some View {
        modifier(MatchingColumnHeaderStyle())
    }
}

private struct MatchingCell: View {
    let pairID: String
    let label: String
    let isSelected: Bool
    let isWrong: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    Group {
                        if isWrong {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.red.opacity(0.82))
                        } else if isSelected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.blue.opacity(0.88))
                        } else {
                            LightCardBackground(cornerRadius: 18)
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(borderColor, lineWidth: isSelected || isWrong ? 2 : 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .transition(.scale.combined(with: .opacity))
    }

    private var textColor: Color {
        if isWrong || isSelected {
            return .white
        }
        return Color(red: 0.08, green: 0.08, blue: 0.13)
    }

    private var borderColor: Color {
        if isWrong { return .red.opacity(0.95) }
        if isSelected { return .blue.opacity(0.95) }
        return .white.opacity(0.75)
    }
}
