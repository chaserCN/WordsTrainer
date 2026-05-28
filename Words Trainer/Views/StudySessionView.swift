import SwiftUI

struct StudySessionView: View {
    @Bindable var session: StudySession
    let store: DeckStore
    let deckTitle: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if session.isFinished {
                ContentUnavailableView(
                    "Готово",
                    systemImage: "checkmark.circle",
                    description: Text("Сессия по колоде «\(deckTitle)» завершена.")
                )
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
                case .matching:
                    MatchingColumnsStudyView(session: session)
                case .clozeTyping:
                    EmptyView()
                }
            }
        }
        .navigationTitle(session.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Закрыть") { dismiss() }
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
            Text(card.clozePrompt)
                .font(.title2)
                .padding(.top, 24)

            ForEach(choices, id: \.self) { option in
                Button {
                    guard !answered else { return }
                    selected = option
                    answered = true
                    onAnswer(option == card.clozeAnswer ? .correct : .incorrect)
                } label: {
                    HStack {
                        Text(option)
                        Spacer()
                        if answered, option == selected {
                            Image(systemName: option == card.clozeAnswer ? "checkmark.circle.fill" : "xmark.circle.fill")
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
                choices = (card.distractors + [card.clozeAnswer]).shuffled()
            }
        }
    }
}

struct MatchingColumnsStudyView: View {
    @Bindable var session: StudySession

    @State private var selectedWordID: UUID?
    @State private var selectedTranslationID: UUID?
    @State private var wrongPairIDs: Set<UUID> = []
    @State private var translationItems: [StudyQueueItem] = []

    private var wordItems: [StudyQueueItem] {
        session.matchingVisibleItems
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
                MatchingColumn(
                    title: "Слово",
                    items: wordItems,
                    selectedID: selectedWordID,
                    wrongPairIDs: wrongPairIDs,
                    text: { $0.card.word },
                    action: selectWord
                )

                MatchingColumn(
                    title: "Перевод",
                    items: translationItems,
                    selectedID: selectedTranslationID,
                    wrongPairIDs: wrongPairIDs,
                    text: { $0.card.translation },
                    action: selectTranslation
                )
            }

            Spacer()

            Text("\(session.remainingCount) осталось")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .padding()
        .onAppear(perform: refreshTranslationsIfNeeded)
        .onChange(of: wordItems.map(\.id)) { _, _ in
            selectedWordID = nil
            selectedTranslationID = nil
            wrongPairIDs = []
            translationItems = wordItems.shuffled()
        }
    }

    private func refreshTranslationsIfNeeded() {
        guard translationItems.map(\.id) != wordItems.map(\.id) else { return }
        translationItems = wordItems.shuffled()
    }

    private func selectWord(_ item: StudyQueueItem) {
        selectedWordID = item.id
        checkPairIfReady()
    }

    private func selectTranslation(_ item: StudyQueueItem) {
        selectedTranslationID = item.id
        checkPairIfReady()
    }

    private func checkPairIfReady() {
        guard let selectedWordID, let selectedTranslationID else { return }
        if selectedWordID == selectedTranslationID {
            withAnimation(.snappy) {
                session.removeMatchedCard(id: selectedWordID)
            }
        } else {
            wrongPairIDs = [selectedWordID, selectedTranslationID]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeOut(duration: 0.2)) {
                    wrongPairIDs = []
                    self.selectedWordID = nil
                    self.selectedTranslationID = nil
                }
            }
        }
    }
}

private struct MatchingColumn: View {
    let title: String
    let items: [StudyQueueItem]
    let selectedID: UUID?
    let wrongPairIDs: Set<UUID>
    let text: (StudyQueueItem) -> String
    let action: (StudyQueueItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(items) { item in
                Button {
                    action(item)
                } label: {
                    Text(text(item))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .padding(.horizontal, 10)
                        .background(backgroundColor(for: item), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(borderColor(for: item), lineWidth: selectedID == item.id ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func backgroundColor(for item: StudyQueueItem) -> Color {
        if wrongPairIDs.contains(item.id) {
            return .red.opacity(0.16)
        }
        if selectedID == item.id {
            return .blue.opacity(0.18)
        }
        return Color(.secondarySystemGroupedBackground)
    }

    private func borderColor(for item: StudyQueueItem) -> Color {
        if wrongPairIDs.contains(item.id) {
            return .red.opacity(0.65)
        }
        if selectedID == item.id {
            return .blue
        }
        return .black.opacity(0.08)
    }
}
