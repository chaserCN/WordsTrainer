import SwiftUI

struct StudySessionView: View {
    @Bindable var session: StudySession
    let store: DeckStore
    let deckTitle: String

    var body: some View {
        Group {
            if session.isFinished {
                ContentUnavailableView(
                    "Готово",
                    systemImage: "checkmark.circle",
                    description: Text("Сессия по колоде «\(deckTitle)» завершена.")
                )
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
        .navigationTitle(session.mode.title)
        .navigationBarTitleDisplayMode(.inline)
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
            .padding(.bottom, 32)
        }
        .padding()
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
                        Spacer()
                        if answered, option == selected {
                            Image(systemName: option == card.effectiveClozeAnswer ? "checkmark.circle.fill" : "xmark.circle.fill")
                        }
                    }
                    .padding()
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(answered && option != selected)
            }
            Spacer()
        }
        .padding()
        .onAppear {
            if choices.isEmpty {
                choices = (card.distractors + [card.effectiveClozeAnswer]).shuffled()
            }
        }
    }
}

struct MatchingColumnsStudyView: View {
    @Bindable var session: StudySession

    @State private var selectedWordID: UUID?
    @State private var selectedTranslationID: UUID?
    @State private var wrongWordID: UUID?
    @State private var wrongTranslationID: UUID?
    @State private var translationItems: [StudyQueueItem] = []

    private var wordItems: [StudyQueueItem] {
        session.matchingVisibleItems
    }

    private var matchingRows: [(word: StudyQueueItem, translation: StudyQueueItem)] {
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
                Text("Выбери слово слева и перевод справа. Правильная пара исчезнет.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                        item: row.word,
                        label: row.word.card.word,
                        isSelected: selectedWordID == row.word.id,
                        isWrong: wrongWordID == row.word.id,
                        action: { selectWord(row.word) }
                    )

                    MatchingCell(
                        item: row.translation,
                        label: translationLabel(for: row.translation),
                        isSelected: selectedTranslationID == row.translation.id,
                        isWrong: wrongTranslationID == row.translation.id,
                        action: { selectTranslation(row.translation) }
                    )
                }
            }

            Spacer()

            Text("\(session.remainingCount) осталось")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .padding()
        .onChange(of: wordItems.map(\.id), initial: true) { _, ids in
            syncTranslations(withWordIDs: ids)
        }
    }

    private func syncTranslations(withWordIDs ids: [UUID]) {
        guard !ids.isEmpty else {
            translationItems = []
            return
        }
        let idSet = Set(ids)
        if translationItems.count == ids.count,
           Set(translationItems.map(\.id)) == idSet {
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: (translationItems + wordItems).map { ($0.id, $0) })
        var next = ids.compactMap { byID[$0] }
        if next.count != ids.count {
            next = wordItems.shuffled()
        } else if translationItems.isEmpty {
            next.shuffle()
        }
        translationItems = next
    }

    private func selectWord(_ item: StudyQueueItem) {
        guard wrongWordID == nil else { return }
        if selectedWordID == item.id {
            selectedWordID = nil
            return
        }
        selectedWordID = item.id
        checkPairIfReady()
    }

    private func selectTranslation(_ item: StudyQueueItem) {
        guard wrongWordID == nil else { return }
        if selectedTranslationID == item.id {
            selectedTranslationID = nil
            return
        }
        selectedTranslationID = item.id
        checkPairIfReady()
    }

    private func refillTranslationColumn(
        removedID: UUID,
        newCard: StudyQueueItem?,
        wordSlotIndex: Int
    ) {
        translationItems.removeAll { $0.id == removedID }
        guard let newCard else { return }

        let slotCount = wordItems.count
        guard slotCount > 0 else { return }

        var insertIndex = wordSlotIndex
        if slotCount > 1 {
            let alternatives = (0..<slotCount).filter { $0 != wordSlotIndex }
            insertIndex = alternatives.randomElement() ?? wordSlotIndex
        }
        insertIndex = min(insertIndex, translationItems.count)
        translationItems.insert(newCard, at: insertIndex)
    }

    private func translationLabel(for item: StudyQueueItem) -> String {
        if wrongWordID != nil {
            return ""
        }
        return item.card.matchingTranslationDisplay()
    }

    private func checkPairIfReady() {
        guard let selectedWordID, let selectedTranslationID else { return }
        if selectedWordID == selectedTranslationID {
            let matchedID = selectedWordID
            withAnimation(.snappy) {
                if let refill = session.removeMatchedCard(id: matchedID) {
                    refillTranslationColumn(
                        removedID: matchedID,
                        newCard: refill.newCard,
                        wordSlotIndex: refill.slotIndex
                    )
                }
            }
            self.selectedWordID = nil
            self.selectedTranslationID = nil
        } else {
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
            .foregroundStyle(.secondary)
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
    let item: StudyQueueItem
    let label: String
    let isSelected: Bool
    let isWrong: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(borderColor, lineWidth: isSelected || isWrong ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .transition(.scale.combined(with: .opacity))
    }

    private var backgroundColor: Color {
        if isWrong { return .red.opacity(0.16) }
        if isSelected { return .blue.opacity(0.18) }
        return Color(.secondarySystemGroupedBackground)
    }

    private var borderColor: Color {
        if isWrong { return .red.opacity(0.65) }
        if isSelected { return .blue }
        return .black.opacity(0.08)
    }
}
