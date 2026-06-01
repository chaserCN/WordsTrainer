import SwiftUI

struct DeckListView: View {
    @State private var decks: [DeckContent] = []
    @State private var store: DeckStore?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if let loadError {
                    DataPlaceholderView(
                        title: "Ошибка",
                        systemImage: "exclamationmark.triangle",
                        message: loadError
                    )
                } else if decks.isEmpty, store != nil {
                    DataPlaceholderView(
                        title: "Нет колод",
                        systemImage: "books.vertical",
                        message: emptyDecksMessage
                    )
                } else if let store {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            DeckListHeader(deckCount: activeDecks.count)

                            LazyVStack(spacing: 16) {
                                ForEach(activeDeckBindings) { $deck in
                                    NavigationLink {
                                        DeckDetailView(deck: $deck, store: store)
                                    } label: {
                                        LovableDeckCard(deck: deck, store: store)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !inactiveDecks.isEmpty {
                                NavigationLink {
                                    InactiveDecksView(decks: $decks, store: store)
                                } label: {
                                    HStack {
                                        Label("Отключенные колоды", systemImage: "pause.circle")
                                        Spacer()
                                        Text("\(inactiveDecks.count)")
                                            .font(.subheadline.bold())
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.bold())
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(16)
                                    .lovablePanel(cornerRadius: 20)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background { LovableBackground(variant: .decks) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await bootstrap()
        }
    }

    private var activeDecks: [DeckContent] {
        decks.filter(\.isActive)
    }

    private var inactiveDecks: [DeckContent] {
        decks.filter { !$0.isActive }
    }

    private var activeDeckBindings: [Binding<DeckContent>] {
        $decks.filter(\.wrappedValue.isActive)
    }

    private var emptyDecksMessage: String {
        if DeckStore.databaseExists {
            "В базе нет колод."
        } else {
            "Скопируйте test_data/Data в Documents/Data/ (см. test_data/README.md)."
        }
    }

    private func bootstrap() async {
        do {
            let deckStore = try DeckStore()
            store = deckStore
            decks = try deckStore.allDecks()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct InactiveDecksView: View {
    @Binding var decks: [DeckContent]
    let store: DeckStore

    @State private var statusError: String?

    private var inactiveDecks: [Binding<DeckContent>] {
        $decks.filter { !$0.wrappedValue.isActive }
    }

    var body: some View {
        ZStack {
            if inactiveDecks.isEmpty {
                DataPlaceholderView(
                    title: "Нет отключенных колод",
                    systemImage: "checkmark.circle",
                    message: "Все колоды сейчас участвуют в обучении."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(inactiveDecks) { $deck in
                            InactiveDeckRow(deck: deck) {
                                enable(deckID: deck.id)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background { LovableBackground(variant: .decks) }
        .navigationTitle("Отключенные")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
        .alert("Не удалось включить колоду", isPresented: statusErrorBinding) {
            Button("ОК", role: .cancel) {
                statusError = nil
            }
        } message: {
            Text(statusError ?? "")
        }
    }

    private var statusErrorBinding: Binding<Bool> {
        Binding(
            get: { statusError != nil },
            set: { isPresented in
                if !isPresented { statusError = nil }
            }
        )
    }

    private func enable(deckID: UUID) {
        do {
            try store.setDeckStatus(.active, for: deckID)
            guard let index = decks.firstIndex(where: { $0.id == deckID }) else { return }
            decks[index].status = .active
        } catch {
            statusError = error.localizedDescription
        }
    }
}

private struct InactiveDeckRow: View {
    let deck: DeckContent
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            DeckIcon(symbolName: deck.avatarSystemName, size: 48)
                .opacity(0.65)

            VStack(alignment: .leading, spacing: 4) {
                Text(deck.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(deck.activeCards.count) карточек")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Button("Включить", action: action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MatchPalette.successText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .padding(16)
        .lovablePanel(cornerRadius: 22)
    }
}

struct DataPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(LovableSurface.muted)

            Text(title)
                .font(.title2.bold())
                .foregroundStyle(LovableSurface.foreground)

            Text(message)
                .font(.body)
                .foregroundStyle(LovableSurface.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeckListHeader: View {
    let deckCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Колоды")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(LovableSurface.foreground)

            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MatchPalette.primary)
                Text("\(deckCount) \(decksLabel(deckCount))")
                    .font(.system(size: 13, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(LovableSurface.muted)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func decksLabel(_ count: Int) -> String {
    let mod10 = count % 10
    let mod100 = count % 100
    if mod100 >= 11 && mod100 <= 14 { return "колод" }
    if mod10 == 1 { return "колода" }
    if mod10 >= 2 && mod10 <= 4 { return "колоды" }
    return "колод"
}

private extension DeckStats {
    var dueTotal: Int { learningDue + reviewDue }
}

/// Карточка колоды в списке — дизайн Lovable (тёмная панель, градиентный аватар).
struct LovableDeckCard: View {
    let deck: DeckContent
    let store: DeckStore
    var showsChevron: Bool = true

    @State private var stats: DeckStats = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [oklch(0.8, 0.12, 280), oklch(0.75, 0.15, 310), oklch(0.7, 0.2, 340)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .overlay {
                        if let symbol = deck.avatarSystemName {
                            Image(systemName: symbol)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: oklch(0.5, 0.2, 320, 0.45), radius: 9, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(deck.activeCards.count) \(cardsGenitive(deck.activeCards.count)) · \(deck.languageCode.uppercased())")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 8)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            HStack(spacing: 10) {
                LovableDeckStat(count: stats.newAvailable, label: "Новые", color: oklch(0.75, 0.16, 240))
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1, height: 12)
                LovableDeckStat(count: stats.dueTotal, label: "Повторить", color: oklch(0.78, 0.15, 65))
            }
        }
        .padding(16)
        .lovablePanel(cornerRadius: 24)
        .task(id: "\(deck.id.databaseString)-\(deck.status.rawValue)") {
            stats = (try? store.stats(for: deck)) ?? .zero
        }
    }
}

private struct LovableDeckStat: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private func cardsGenitive(_ count: Int) -> String {
    let mod10 = count % 10
    let mod100 = count % 100
    if mod100 >= 11 && mod100 <= 14 { return "карточек" }
    if mod10 == 1 { return "карточка" }
    if mod10 >= 2 && mod10 <= 4 { return "карточки" }
    return "карточек"
}

struct DeckCardView: View {
    let deck: DeckContent
    let store: DeckStore
    var showsChevron: Bool = true

    @State private var stats: DeckStats = .zero
    private var activeCardCount: Int { deck.activeCards.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                DeckIcon(symbolName: deck.avatarSystemName)

                VStack(alignment: .leading, spacing: 6) {
                    Text(deck.title)
                        .font(.title3.bold())
                        .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.13))

                    HStack(spacing: 8) {
                        Text("\(activeCardCount) карточек · \(deck.languageCode.uppercased())")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0.45, green: 0.46, blue: 0.55))

                        if !deck.isActive {
                            DeckStatusBadge()
                        }
                    }
                }

                Spacer()

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.24))
                        .padding(.top, 6)
                }
            }

            HStack(spacing: 10) {
                DeckMetricPill(title: "Новые", value: stats.newAvailable, systemImage: "sparkles", tint: .blue)
                DeckMetricPill(title: "Повторить", value: stats.dueTotal, systemImage: "arrow.clockwise", tint: .orange)
            }
        }
        .padding(18)
        .background(LightCardBackground(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.75), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 26, x: 0, y: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task(id: statsTaskID) {
            stats = (try? store.stats(for: deck)) ?? .zero
        }
    }

    private var statsTaskID: String {
        "\(deck.id.databaseString)-\(deck.status.rawValue)"
    }

    private var accessibilityLabel: String {
        let statusText = deck.isActive ? "включена" : "отключена"
        return "\(deck.title), \(statusText), новых \(stats.newAvailable), повторить \(stats.dueTotal), всего \(activeCardCount)"
    }
}

struct DeckDetailView: View {
    @Binding var deck: DeckContent
    let store: DeckStore

    @State private var stats: DeckStats = .zero
    @State private var session: StudySession?
    @State private var showStudy = false
    @State private var statusError: String?
    private var studyCards: [WordCardContent] { deck.isActive ? deck.activeCards : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LovableDeckCard(deck: deck, store: store, showsChevron: false)
                DeckStatusControl(deck: deck) {
                    toggleDeckStatus()
                }

                    StudySection(title: "Упражнения", remaining: remainingSummary) {
                        StudyActionButton(
                            title: "Карточки",
                            subtitle: "Слово, перевод и заметки — переворот по тапу",
                            systemImage: "rectangle.on.rectangle.angled",
                            accent: .orange,
                            isEnabled: !studyCards.isEmpty
                        ) {
                            start(.flashcards)
                        }

                        StudyActionButton(
                            title: "Предложения",
                            subtitle: "Выбери слово для примера с пропуском",
                            systemImage: "text.quote",
                            accent: .blue,
                            isEnabled: !studyCards.isEmpty
                        ) {
                            start(.clozeMultipleChoice)
                        }

                        StudyActionButton(
                            title: "Колонки",
                            subtitle: "Соедини слово и перевод",
                            systemImage: "rectangle.split.2x1.fill",
                            accent: .green,
                            isEnabled: !studyCards.isEmpty
                        ) {
                            start(.matching)
                        }
                    }

                    StudySection(title: "Помню / Забыл", remaining: recallRemainingLabel) {
                        StudyActionButton(
                            title: "Быстрый проход",
                            subtitle: "Покажи слово и отметь: помню или забыл",
                            systemImage: "eye.fill",
                            accent: .purple,
                            isEnabled: !studyCards.isEmpty
                        ) {
                            start(.recall)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .background { LovableBackground(variant: .decks) }
        .navigationTitle(deck.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: deck.title)
            }
        }
        .task(id: statsTaskID) {
            stats = (try? store.stats(for: deck)) ?? .zero
        }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            stats = (try? store.stats(for: deck)) ?? .zero
        }
        .alert("Не удалось обновить колоду", isPresented: statusErrorBinding) {
            Button("ОК", role: .cancel) {
                statusError = nil
            }
        } message: {
            Text(statusError ?? "")
        }
    }

    private var recallRemainingLabel: String? {
        guard !studyCards.isEmpty else { return nil }
        return remainingCardsLabel(studyCards.count)
    }

    private var matchingPairCount: Int {
        studyCards.reduce(0) { total, card in
            let senses = WordCardContent.translationSenses(card.translation)
            return total + (senses.isEmpty ? 1 : senses.count)
        }
    }

    private var remainingSummary: String? {
        let clozeCount = stats.studyTotal > 0 ? stats.studyTotal : studyCards.count
        let parts = [
            matchingPairCount > 0 ? remainingPairsLabel(matchingPairCount) : nil,
            !studyCards.isEmpty ? remainingCardsLabel(clozeCount) : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func remainingPairsLabel(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod100 >= 11 && mod100 <= 14 {
            word = "пар"
        } else if mod10 == 1 {
            word = "пара"
        } else if mod10 >= 2 && mod10 <= 4 {
            word = "пары"
        } else {
            word = "пар"
        }
        return "\(count) \(word) осталось"
    }

    private func remainingCardsLabel(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod100 >= 11 && mod100 <= 14 {
            word = "карточек"
        } else if mod10 == 1 {
            word = "карточка"
        } else if mod10 >= 2 && mod10 <= 4 {
            word = "карточки"
        } else {
            word = "карточек"
        }
        return "\(count) \(word) в очереди"
    }

    private func start(_ mode: StudyMode) {
        guard deck.isActive else { return }
        session = try? store.startAllCardsSession(deck: deck, mode: mode)
        showStudy = session != nil
    }

    private var statsTaskID: String {
        "\(deck.id.databaseString)-\(deck.status.rawValue)"
    }

    private var statusErrorBinding: Binding<Bool> {
        Binding(
            get: { statusError != nil },
            set: { isPresented in
                if !isPresented { statusError = nil }
            }
        )
    }

    private func toggleDeckStatus() {
        let newStatus: ContentStatus = deck.isActive ? .inactive : .active
        do {
            try store.setDeckStatus(newStatus, for: deck.id)
            deck.status = newStatus
            stats = (try? store.stats(for: deck)) ?? .zero
        } catch {
            statusError = error.localizedDescription
        }
    }
}

private struct DeckStatusControl: View {
    let deck: DeckContent
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deck.isActive ? "checkmark" : "pause.fill")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    deck.isActive ? oklch(0.72, 0.18, 150) : MatchPalette.accent,
                    in: Circle()
                )
                .shadow(color: (deck.isActive ? oklch(0.55, 0.18, 150, 0.5) : MatchPalette.accent.opacity(0.5)), radius: 7, x: 0, y: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(deck.isActive ? "Колода включена" : "Колода отключена")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(deck.isActive ? "Карточки участвуют в повторениях." : "Карточки не попадают в учебные очереди.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 8)

            Button(deck.isActive ? "Отключить" : "Включить", action: action)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(deck.isActive ? oklch(0.78, 0.16, 55) : MatchPalette.successText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule().stroke((deck.isActive ? oklch(0.78, 0.16, 55) : MatchPalette.successText).opacity(0.35), lineWidth: 0.5)
                }
                .accessibilityLabel(deck.isActive ? "Отключить колоду" : "Включить колоду")
        }
        .padding(16)
        .lovablePanel(cornerRadius: 24)
    }
}

private struct DeckStatusBadge: View {
    var body: some View {
        Text("Отключена")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.14), in: Capsule())
    }
}

private struct StudySection<Content: View>: View {
    let title: String
    var remaining: String?
    let content: Content

    init(title: String, remaining: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.remaining = remaining
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                if let remaining {
                    Text(remaining)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(LovableSurface.muted)
                }
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                content
            }
        }
    }
}

private struct StudyActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var isEnabled: Bool = true
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(isEnabled ? 1 : 0.4), in: Circle())
                    .shadow(color: accent.opacity(isEnabled ? 0.5 : 0), radius: 9, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold))
                        if let badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .lovablePanel(cornerRadius: 20)
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct DeckIcon: View {
    let symbolName: String?
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.95), .purple.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbolName ?? "books.vertical.fill")
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .blue.opacity(0.25), radius: 12, x: 0, y: 6)
    }

}

private struct DeckMetricPill: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.headline.bold())
                .foregroundStyle(Color(red: 0.06, green: 0.07, blue: 0.12))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.19, blue: 0.27))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.2), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct DeckQueueSummary: View {
    let stats: DeckStats

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(summaryColor)
                .frame(width: 8, height: 8)
            Text(summaryText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(red: 0.28, green: 0.29, blue: 0.38))
            Spacer()
        }
        .padding(.horizontal, 2)
        .accessibilityLabel(summaryText)
    }

    private var summaryText: String {
        if stats.studyTotal == 0 {
            return "На сегодня всё готово"
        }
        return "\(stats.studyTotal) карточки в очереди"
    }

    private var summaryColor: Color {
        if stats.learningDue > 0 { return .orange }
        if stats.reviewDue > 0 { return .green }
        if stats.newAvailable > 0 { return .blue }
        return .gray
    }
}

private struct DeckProgressBar: View {
    let stats: DeckStats

    private var total: Int { max(stats.studyTotal, 1) }

    var body: some View {
        HStack(spacing: 3) {
            Capsule()
                .fill(.blue)
                .frame(maxWidth: proportionalWidth(stats.newAvailable))
            Capsule()
                .fill(.orange)
                .frame(maxWidth: proportionalWidth(stats.dueTotal))
        }
        .frame(height: 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.08), in: Capsule())
        .accessibilityHidden(true)
    }

    private func proportionalWidth(_ value: Int) -> CGFloat {
        value == 0 ? 0 : CGFloat(value) / CGFloat(total) * 180
    }
}

#Preview {
    DeckListView()
        .environment(AppSettings.shared)
}
