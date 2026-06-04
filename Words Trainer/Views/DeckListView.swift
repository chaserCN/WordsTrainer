import SwiftUI

struct DeckListView: View {
    @Environment(AppUserStore.self) private var userStore
    @State private var decks: [DeckContent] = []
    @State private var store: DeckStore?
    @State private var storeUserID: UUID?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { LovableBackground(variant: .decks) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await bootstrap()
        }
        .onChange(of: userStore.selectedUserID) {
            store = nil
            storeUserID = nil
            Task { await bootstrap() }
        }
        .onChange(of: userStore.bootstrapState) { _, state in
            guard state == .loaded else { return }
            Task { await bootstrap() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DeckStore.localDataDidChangeNotification)) { _ in
            Task { await bootstrap() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            DataPlaceholderView(
                title: "Ошибка",
                systemImage: "exclamationmark.triangle",
                message: loadError
            )
        } else if userStore.selectedUserID == nil {
            DataPlaceholderView(
                title: noUserTitle,
                systemImage: noUserSystemImage,
                message: noUserMessage
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

                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sortedDeckBindings) { $deck in
                            NavigationLink {
                                DeckDetailView(deck: $deck, store: store)
                            } label: {
                                LovableDeckCard(deck: deck)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .opacity(deck.isActive ? 1 : 0.45)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
        }
    }

    private var activeDecks: [DeckContent] {
        decks.filter(\.isActive)
    }

    /// Активные колоды выше, отключённые ниже; внутри каждой группы — порядок из БД (по названию).
    private var sortedDeckBindings: [Binding<DeckContent>] {
        $decks.filter(\.wrappedValue.isActive) + $decks.filter { !$0.wrappedValue.isActive }
    }

    private var emptyDecksMessage: String {
        "Для выбранного пользователя пока нет колод в локальной базе. Проверьте назначения на сервере и выполните синхронизацию."
    }

    private var noUserTitle: String {
        switch userStore.bootstrapState {
        case .loading:
            "Синхронизация"
        case .emptyServer:
            "Сервер пуст"
        case .failed:
            "Синхронизация не удалась"
        case .missingConfiguration:
            "Сервер не настроен"
        default:
            "Нет пользователя"
        }
    }

    private var noUserSystemImage: String {
        switch userStore.bootstrapState {
        case .loading:
            "arrow.clockwise"
        case .emptyServer:
            "person.2.slash"
        case .failed:
            "wifi.exclamationmark"
        case .missingConfiguration:
            "link.badge.plus"
        default:
            "person.crop.circle.badge.exclamationmark"
        }
    }

    private var noUserMessage: String {
        switch userStore.bootstrapState {
        case .loading:
            "Подключаемся к серверу и загружаем пользователей."
        default:
            userStore.bootstrapState.message ?? "Сначала синхронизируйте пользователей с сервером."
        }
    }

    private func bootstrap() async {
        do {
            guard let selectedUserID = userStore.selectedUserID else {
                decks = []
                store = nil
                storeUserID = nil
                loadError = nil
                return
            }
            let deckStore = try DeckStore(userID: selectedUserID)
            storeUserID = selectedUserID
            store = deckStore
            decks = try deckStore.allDecks()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
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

/// Карточка колоды — дизайн Lovable (тёмная панель, градиентный аватар).
/// `footnote` — опциональная подпись внизу (например «Учим все карты в колоде»).
struct LovableDeckCard: View {
    let deck: DeckContent
    var showsChevron: Bool = true
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DeckAvatarPalette(seed: deck.id.uuidString).gradient)
                    .frame(width: 56, height: 56)
                    .overlay {
                        DeckAvatarContent(
                            symbolName: deck.avatarSystemName,
                            imageURL: deck.avatarImageURL,
                            size: 56,
                            cornerRadius: 16
                        )
                    }
                    .shadow(color: DeckAvatarPalette(seed: deck.id.uuidString).shadowColor, radius: 9, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(deck.activeCards.count) \(cardsGenitive(deck.activeCards.count)) · \(deck.languageCode.uppercased())")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let footnote {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(oklch(0.75, 0.16, 240))
                    Text(footnote)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(16)
        .padding(.trailing, showsChevron ? 24 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.trailing, 16)
            }
        }
        .lovablePanel(cornerRadius: 24)
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

struct DeckAvatarPalette {
    let seed: String

    var gradient: LinearGradient {
        LinearGradient(
            colors: [
                oklch(0.89, 0.095, hue - 10),
                oklch(0.82, 0.115, hue + 12),
                oklch(0.76, 0.13, hue + 28)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var shadowColor: Color {
        oklch(0.50, 0.09, hue + 12, 0.30)
    }

    private var hue: Double {
        Self.pastelHue(for: Self.mixedHash(Self.stableHash(seed.normalizedAvatarSeed)))
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func pastelHue(for hash: UInt64) -> Double {
        let ranges: [(lower: Double, upper: Double)] = [
            (326, 342), // rose
            (270, 300), // violet
            (205, 235), // blue
            (154, 180), // mint
        ]
        let range = ranges[Int((hash >> 8) % UInt64(ranges.count))]
        let width = UInt64(range.upper - range.lower)
        return range.lower + Double((hash >> 16) % width)
    }

    private static func mixedHash(_ value: UInt64) -> UInt64 {
        var hash = value
        hash = (hash ^ (hash >> 30)) &* 0xbf58_476d_1ce4_e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d0_49bb_1331_11eb
        return hash ^ (hash >> 31)
    }
}

private extension String {
    var normalizedAvatarSeed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
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
                DeckIcon(symbolName: deck.avatarSystemName, imageURL: deck.avatarImageURL)

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
    @State private var exerciseScope: DeckExerciseScope = .all
    @State private var weakCardIDs: Set<UUID> = []
    @State private var matchingRecord: DeckMatchingRecord?
    private var studyCards: [WordCardContent] { deck.isActive ? deck.activeCards : [] }
    private var scopedStudyCards: [WordCardContent] {
        switch exerciseScope {
        case .all:
            return studyCards
        case .weak:
            return studyCards.filter { weakCardIDs.contains($0.id) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink {
                    WordListView(
                        title: "Слова",
                        cards: deck.activeCards,
                        emptyMessage: "В этой колоде пока нет активных карточек.",
                        backgroundVariant: .decks
                    )
                } label: {
                    LovableDeckCard(deck: deck, showsChevron: true, footnote: deckFootnote)
                }
                .buttonStyle(.plain)

                StudySection(
                    title: "Упражнения",
                    trailing: AnyView(DeckExerciseScopePicker(selection: $exerciseScope))
                ) {
                    StudyActionButton(
                        title: "Карточки",
                        subtitle: "Слово, перевод и заметки — переворот по тапу",
                        systemImage: "rectangle.on.rectangle.angled",
                        accent: .orange,
                        isEnabled: !scopedStudyCards.isEmpty
                    ) {
                        start(.flashcards)
                    }

                    StudyActionButton(
                        title: "Предложения",
                        subtitle: "Выбери слово для примера с пропуском",
                        systemImage: "text.quote",
                        accent: .blue,
                        isEnabled: !scopedStudyCards.isEmpty
                    ) {
                        start(.clozeMultipleChoice)
                    }

                    StudyActionButton(
                        title: "Колонки",
                        subtitle: matchingSubtitle,
                        systemImage: "rectangle.split.2x1.fill",
                        accent: .green,
                        isEnabled: !scopedStudyCards.isEmpty
                    ) {
                        start(.matching)
                    }

                    StudyActionButton(
                        title: "Колонки аудио",
                        subtitle: "Слушай слово и выбирай перевод",
                        systemImage: "speaker.wave.2.fill",
                        accent: .cyan,
                        isEnabled: !scopedStudyCards.isEmpty
                    ) {
                        start(.matchingAudio)
                    }
                }

                StudySection(title: "Сбросить") {
                    StudyActionButton(
                        title: "Оставить / Сбросить",
                        subtitle: "Покажи слово и реши: оставить прогресс или начать заново",
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
        .tint(LovableSurface.foreground)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section(deck.isActive ? "Колода включена" : "Колода отключена") {
                        Button(role: deck.isActive ? .destructive : nil) {
                            toggleDeckStatus()
                        } label: {
                            Label(
                                deck.isActive ? "Отключить колоду" : "Включить колоду",
                                systemImage: deck.isActive ? "pause.circle" : "play.circle"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(LovableSurface.foreground)
            }
        }
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: deck.title)
            }
        }
        .task(id: statsTaskID) {
            reloadDeckState()
        }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            reloadDeckState()
        }
        .alert("Не удалось обновить колоду", isPresented: statusErrorBinding) {
            Button("ОК", role: .cancel) {
                statusError = nil
            }
        } message: {
            Text(statusError ?? "")
        }
    }

    private func start(_ mode: StudyMode) {
        guard deck.isActive else { return }
        switch exerciseScope {
        case .all:
            session = try? store.startAllCardsSession(deck: deck, mode: mode)
        case .weak:
            session = try? store.startWeakCardsSession(deck: deck, mode: mode)
        }
        showStudy = session != nil
    }

    private var deckFootnote: String {
        switch exerciseScope {
        case .all:
            return "Учим все карты в колоде"
        case .weak:
            return "\(weakCardIDs.count) \(cardsGenitive(weakCardIDs.count)) в сложных"
        }
    }

    private var matchingSubtitle: String {
        guard exerciseScope == .all,
              let matchingRecord,
              matchingRecord.pairCount == fullDeckMatchingPairCount else {
            return "Соедини слово и перевод"
        }
        return "Рекорд: \(StudyDurationFormat.string(matchingRecord.bestDuration))"
    }

    private var fullDeckMatchingPairCount: Int {
        studyCards.reduce(0) { count, card in
            count + MatchingPair.pairs(from: StudyQueueItem(card: card, progress: CardProgress.newCard(cardID: card.id))).count
        }
    }

    private func reloadDeckState() {
        stats = (try? store.stats(for: deck)) ?? .zero
        matchingRecord = try? store.matchingRecord(deckID: deck.id)
        reloadWeakCards()
    }

    private func reloadWeakCards() {
        let weakCards = (try? store.weakCards(deckID: deck.id, limit: deck.activeCards.count)) ?? []
        weakCardIDs = Set(weakCards.map(\.cardID))
        if exerciseScope == .weak, weakCardIDs.isEmpty {
            exerciseScope = .all
        }
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
            reloadDeckState()
        } catch {
            statusError = error.localizedDescription
        }
    }
}

struct WordListView: View {
    let title: String
    let emptyMessage: String
    let backgroundVariant: LovableBackgroundVariant
    private let sortedCards: [WordCardContent]

    init(
        title: String,
        cards: [WordCardContent],
        emptyMessage: String,
        backgroundVariant: LovableBackgroundVariant
    ) {
        self.title = title
        self.emptyMessage = emptyMessage
        self.backgroundVariant = backgroundVariant
        self.sortedCards = cards.sorted { lhs, rhs in
            let lemmaOrder = lhs.lemma.localizedCaseInsensitiveCompare(rhs.lemma)
            if lemmaOrder != .orderedSame {
                return lemmaOrder == .orderedAscending
            }

            let wordOrder = lhs.word.localizedCaseInsensitiveCompare(rhs.word)
            if wordOrder != .orderedSame {
                return wordOrder == .orderedAscending
            }

            return lhs.translation.localizedCaseInsensitiveCompare(rhs.translation) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if sortedCards.isEmpty {
                    DataPlaceholderView(
                        title: "Нет слов",
                        systemImage: "text.book.closed",
                        message: emptyMessage
                    )
                    .frame(minHeight: 360)
                } else {
                    ForEach(Array(sortedCards.enumerated()), id: \.element.id) { index, card in
                        DeckWordRow(
                            card: card,
                            position: rowPosition(index: index, count: sortedCards.count)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background { LovableBackground(variant: backgroundVariant) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
        .tint(LovableSurface.foreground)
    }

    private func rowPosition(index: Int, count: Int) -> DeckWordRow.Position {
        if count == 1 { return .single }
        if index == 0 { return .top }
        if index == count - 1 { return .bottom }
        return .middle
    }
}

private struct DeckWordRow: View {
    enum Position: Equatable {
        case single
        case top
        case middle
        case bottom

        var hasSeparator: Bool {
            self == .top || self == .middle
        }

        var cornerRadii: RectangleCornerRadii {
            let radius: CGFloat = 18
            switch self {
            case .single:
                return RectangleCornerRadii(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: radius
                )
            case .top:
                return RectangleCornerRadii(topLeading: radius, topTrailing: radius)
            case .middle:
                return RectangleCornerRadii()
            case .bottom:
                return RectangleCornerRadii(bottomLeading: radius, bottomTrailing: radius)
            }
        }
    }

    let card: WordCardContent
    let position: Position

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.word)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(card.translation)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    oklch(0.25, 0.04, 265),
                    oklch(0.18, 0.04, 270)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: UnevenRoundedRectangle(cornerRadii: position.cornerRadii, style: .continuous)
        )
        .overlay {
            UnevenRoundedRectangle(cornerRadii: position.cornerRadii, style: .continuous)
                .stroke(.white.opacity(0.05), lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if position.hasSeparator {
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
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

private enum DeckExerciseScope: String, CaseIterable, Identifiable {
    case all
    case weak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Все"
        case .weak:
            return "Сложные"
        }
    }
}

private struct DeckExerciseScopePicker: View {
    @Binding var selection: DeckExerciseScope

    var body: some View {
        Picker("Карточки", selection: $selection) {
            ForEach(DeckExerciseScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        .accessibilityLabel("Фильтр упражнений")
    }
}

private struct StudySection<Content: View>: View {
    let title: String
    var remaining: String?
    var trailing: AnyView?
    let content: Content

    init(
        title: String,
        remaining: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.remaining = remaining
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
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
                .frame(maxWidth: .infinity, alignment: .leading)

                if let trailing {
                    trailing
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
    let imageURL: URL?
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
            DeckAvatarContent(
                symbolName: symbolName,
                imageURL: imageURL,
                size: size,
                cornerRadius: size * 0.32
            )
        }
        .frame(width: size, height: size)
        .shadow(color: .blue.opacity(0.25), radius: 12, x: 0, y: 6)
    }

}

private struct DeckAvatarContent: View {
    let symbolName: String?
    let imageURL: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        symbol
                    }
                }
            } else {
                symbol
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var symbol: some View {
        Image(systemName: deckSymbol(symbolName))
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
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
