import SwiftUI

struct DeckListView: View {
    @Environment(AppUserStore.self) private var userStore
    @State private var decks: [DeckContent] = []
    @State private var store: DeckStore?
    @State private var storeUserID: UUID?
    @State private var loadError: String?
    @State private var startError: String?
    @State private var isSearching = false
    @State private var searchSourceRevision = 0
    @State private var searchIndex: DeckWordSearchIndex?
    @State private var searchIndexTask: Task<Void, Never>?
    @State private var showRandomModes = false
    @State private var randomStudyCards: [WordCardContent] = []
    @State private var randomStudyTitle = RandomStudySessionBuilder.title
    @State private var randomStudyDeckIDs: Set<UUID>?
    @State private var isVisible = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var reloadGeneration = 0
    @State private var needsReloadWhenVisible = false
    @State private var collapsedDeckGroupIDs: Set<String> = []

    static let searchTransitionDuration: TimeInterval = 0.32
    static let searchTransition: Animation = .snappy(duration: searchTransitionDuration, extraBounce: 0)

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { LovableBackground(variant: .decks) }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showRandomModes) {
                if let store {
                    RandomAllDecksModesView(
                        store: store,
                        initialCards: randomStudyCards,
                        title: randomStudyTitle,
                        deckIDs: randomStudyDeckIDs
                    )
                }
            }
        }
        .alert("Не удалось начать упражнение", isPresented: startErrorBinding) {
            Button("ОК", role: .cancel) {
                startError = nil
            }
        } message: {
            Text(startError ?? "")
        }
        .task {
            loadCollapsedDeckGroups()
            await bootstrap()
        }
        .onAppear {
            isVisible = true
            if needsReloadWhenVisible {
                needsReloadWhenVisible = false
                scheduleLocalDataReload()
            }
        }
        .onDisappear {
            isVisible = false
            cancelScheduledReload()
        }
        .onChange(of: userStore.selectedUserID) {
            isSearching = false
            invalidateSearchIndex()
            loadCollapsedDeckGroups()
            store = nil
            storeUserID = nil
            reloadImmediately()
        }
        .onChange(of: userStore.bootstrapState) { _, state in
            guard state == .loaded else { return }
            reloadImmediately()
        }
        .onReceive(NotificationCenter.default.publisher(for: DeckStore.localDataDidChangeNotification)) { _ in
            scheduleLocalDataReload()
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
            ZStack {
                deckList(store: store)
                    .opacity(isSearching ? 0 : 1)
                    .allowsHitTesting(!isSearching)
                    .accessibilityHidden(isSearching)

                if isSearching {
                    WordSearchPane(
                        index: searchIndex,
                        sourceRevision: searchSourceRevision
                    ) {
                        withAnimation(Self.searchTransition) { isSearching = false }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private func deckList(store: DeckStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeckListHeader(
                    deckCount: activeDecks.count,
                    cardCount: activeCardCount,
                    isRandomEnabled: hasSearchItems,
                    isSearchEnabled: hasSearchItems,
                    random: {
                        startRandom()
                    },
                    search: {
                        openSearch()
                    }
                )

                deckRows(store: store)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func deckRows(store: DeckStore) -> some View {
        if showsGroupedDecks {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(groupedDeckSections) { section in
                    DeckGroupSectionView(
                        section: section,
                        store: store,
                        isCollapsed: collapsedDeckGroupIDs.contains(section.id),
                        random: {
                            startRandom(deckIDs: section.activeDeckIDs, title: section.title)
                        },
                        toggle: {
                            toggleDeckGroup(section.id)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
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
    }

    private var activeDecks: [DeckContent] {
        decks.filter(\.isActive)
    }

    private var activeCardCount: Int {
        activeDecks.reduce(0) { count, deck in
            count + deck.activeCards.count
        }
    }

    private var hasSearchItems: Bool {
        activeDecks.contains { !$0.activeCards.isEmpty }
    }

    /// Активные колоды выше, отключённые ниже; внутри каждой группы — по названию.
    private var sortedDeckBindings: [Binding<DeckContent>] {
        let activeDecks = $decks
            .filter(\.wrappedValue.isActive)
            .sorted(by: compareDeckBindingsByTitle)
        let inactiveDecks = $decks
            .filter { !$0.wrappedValue.isActive }
            .sorted(by: compareDeckBindingsByTitle)
        return activeDecks + inactiveDecks
    }

    private var showsGroupedDecks: Bool {
        decks.contains(where: \.hasDeckGroup)
    }

    private var groupedDeckSections: [DeckGroupSection] {
        let grouped = Dictionary(grouping: sortedDeckBindings) { binding in
            DeckGroupKey(deck: binding.wrappedValue)
        }
        return grouped.map { key, decks in
            DeckGroupSection(
                key: key,
                title: key.title,
                sortOrder: key.sortOrder,
                decks: decks.sorted(by: compareDeckBindingsByActivityThenTitle)
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.key.isOther, rhs.key.isOther) {
            case (true, false):
                return false
            case (false, true):
                return true
            default:
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func compareDeckBindingsByTitle(_ lhs: Binding<DeckContent>, _ rhs: Binding<DeckContent>) -> Bool {
        let left = lhs.wrappedValue
        let right = rhs.wrappedValue
        let titleComparison = left.title.localizedStandardCompare(right.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return left.id.uuidString < right.id.uuidString
    }

    private func compareDeckBindingsByActivityThenTitle(
        _ lhs: Binding<DeckContent>,
        _ rhs: Binding<DeckContent>
    ) -> Bool {
        let left = lhs.wrappedValue
        let right = rhs.wrappedValue
        if left.isActive != right.isActive {
            return left.isActive
        }
        return compareDeckBindingsByTitle(lhs, rhs)
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

    private var startErrorBinding: Binding<Bool> {
        Binding(
            get: { startError != nil },
            set: { isPresented in
                if !isPresented { startError = nil }
            }
        )
    }

    private func reloadImmediately() {
        cancelScheduledReload()
        Task { await bootstrap() }
    }

    private func scheduleLocalDataReload() {
        guard isVisible else {
            needsReloadWhenVisible = true
            return
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, reloadGeneration == generation else { return }
            await bootstrap()
            guard reloadGeneration == generation else { return }
            reloadTask = nil
        }
    }

    private func cancelScheduledReload() {
        reloadGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
        needsReloadWhenVisible = false
    }

    private func startRandom() {
        guard let store else { return }
        do {
            randomStudyCards = try store.randomStudyCards()
            randomStudyTitle = RandomStudySessionBuilder.title
            randomStudyDeckIDs = nil
            guard !randomStudyCards.isEmpty else {
                startError = "Нет карточек для этого упражнения."
                return
            }
            showRandomModes = true
        } catch {
            startError = error.localizedDescription
        }
    }

    private func startRandom(deckIDs: Set<UUID>, title: String) {
        guard let store else { return }
        do {
            randomStudyCards = try store.randomStudyCards(deckIDs: deckIDs)
            randomStudyTitle = title
            randomStudyDeckIDs = deckIDs
            guard !randomStudyCards.isEmpty else {
                startError = "Нет карточек для этого упражнения."
                return
            }
            showRandomModes = true
        } catch {
            startError = error.localizedDescription
        }
    }

    private func openSearch() {
        withAnimation(Self.searchTransition) { isSearching = true }
    }

    private func loadCollapsedDeckGroups() {
        collapsedDeckGroupIDs = DeckGroupExpansionStorage.load(userID: userStore.selectedUserID)
    }

    private func toggleDeckGroup(_ groupID: String) {
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            if collapsedDeckGroupIDs.contains(groupID) {
                collapsedDeckGroupIDs.remove(groupID)
            } else {
                collapsedDeckGroupIDs.insert(groupID)
            }
        }
        DeckGroupExpansionStorage.save(collapsedDeckGroupIDs, userID: userStore.selectedUserID)
    }

    /// Сбрасывает построенный индекс поиска, пока новые данные не загружены.
    private func invalidateSearchIndex() {
        searchIndexTask?.cancel()
        searchIndexTask = nil
        searchIndex = nil
        searchSourceRevision += 1
    }

    /// Строит индекс поиска в фоне заранее, чтобы форма поиска появлялась уже заполненной
    /// и анимация открытия не дёргалась из-за тяжёлой работы на главном потоке.
    private func rebuildSearchIndex() {
        searchIndexTask?.cancel()
        let snapshot = decks
        guard !snapshot.isEmpty else {
            searchIndex = nil
            searchSourceRevision += 1
            return
        }
        searchIndexTask = Task { @MainActor in
            let built = await Task.detached(priority: .utility) {
                DeckWordSearchIndex(decks: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            searchIndex = built
            searchSourceRevision += 1
        }
    }

    private func bootstrap() async {
        do {
            guard let selectedUserID = userStore.selectedUserID else {
                decks = []
                invalidateSearchIndex()
                store = nil
                storeUserID = nil
                loadError = nil
                return
            }
            let deckStore = try DeckStore(userID: selectedUserID)
            storeUserID = selectedUserID
            store = deckStore
            let loadedDecks = try deckStore.allDecks()
            decks = loadedDecks
            rebuildSearchIndex()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct DeckGroupKey: Hashable {
    let id: String
    let title: String
    let sortOrder: Int
    let isOther: Bool

    init(deck: DeckContent) {
        if let title = deck.normalizedDeckGroupTitle {
            id = deck.deckGroupID?.uuidString.lowercased() ?? "title:\(title)"
            self.title = title
            sortOrder = deck.deckGroupSortOrder ?? 0
            isOther = false
        } else {
            id = "other"
            title = L10n.text("Другие")
            sortOrder = Int.max
            isOther = true
        }
    }
}

private extension DeckContent {
    var hasDeckGroup: Bool {
        normalizedDeckGroupTitle != nil
    }

    var normalizedDeckGroupTitle: String? {
        guard let deckGroupTitle else { return nil }
        let trimmed = deckGroupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct DeckGroupSection: Identifiable {
    let key: DeckGroupKey
    let title: String
    let sortOrder: Int
    let decks: [Binding<DeckContent>]

    var id: String { key.id }

    var activeDeckCount: Int {
        decks.map(\.wrappedValue).filter(\.isActive).count
    }

    var activeCardCount: Int {
        decks.map(\.wrappedValue).filter(\.isActive).reduce(0) { total, deck in
            total + deck.activeCards.count
        }
    }

    var activeDeckIDs: Set<UUID> {
        Set(decks.map(\.wrappedValue).filter(\.isActive).map(\.id))
    }
}

private struct DeckGroupSectionView: View {
    let section: DeckGroupSection
    let store: DeckStore
    let isCollapsed: Bool
    let random: () -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeckGroupHeader(section: section, isCollapsed: isCollapsed, random: random, toggle: toggle)

            if !isCollapsed {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(section.decks) { $deck in
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
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DeckGroupHeader: View {
    let section: DeckGroupSection
    let isCollapsed: Bool
    let random: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LovableSurface.muted)
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))

                    Text(section.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(LovableSurface.foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text("\(section.activeDeckCount) · \(section.activeCardCount)")
                        .font(.system(size: 14, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(LovableSurface.muted)

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                L10n.format(
                    "%@, %@, %@",
                    section.title,
                    LocalizedCounts.deckPhrase(section.activeDeckCount),
                    LocalizedCounts.cardPhrase(section.activeCardCount)
                )
            )
            .accessibilityValue(isCollapsed ? L10n.text("Закрыта") : L10n.text("Открыта"))

            GroupStudyButton(
                title: L10n.text("Учить"),
                accessibilityLabel: L10n.format(L10n.text("Случайные карточки из %@"), section.title),
                isEnabled: section.activeCardCount > 0,
                action: random
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupStudyButton: View {
    let title: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .bold))
                    .symbolRenderingMode(.monochrome)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(oklch(0.35, 0.04, 260))
            .frame(height: 32)
            .padding(.horizontal, 12)
            .background(oklch(1, 0, 0, 0.45), in: Capsule())
            .overlay(alignment: .top) {
                Capsule()
                    .stroke(oklch(1, 0, 0, 0.7), lineWidth: 0.5)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }
            .overlay {
                Capsule()
                    .stroke(oklch(0.18, 0.02, 260, 0.06), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(GroupStudyButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct GroupStudyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum DeckGroupExpansionStorage {
    private static let keyPrefix = "deckList.collapsedDeckGroupIDs"

    static func load(userID: UUID?, defaults: UserDefaults = .standard) -> Set<String> {
        guard let key = key(for: userID) else { return [] }
        return Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func save(_ groupIDs: Set<String>, userID: UUID?, defaults: UserDefaults = .standard) {
        guard let key = key(for: userID) else { return }
        if groupIDs.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(groupIDs.sorted(), forKey: key)
        }
    }

    private static func key(for userID: UUID?) -> String? {
        guard let userID else { return nil }
        return "\(keyPrefix).\(userID.uuidString.lowercased())"
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

            Text(L10n.text(title))
                .font(.title2.bold())
                .foregroundStyle(LovableSurface.foreground)

            Text(L10n.text(message))
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
    let cardCount: Int
    let isRandomEnabled: Bool
    let isSearchEnabled: Bool
    let random: () -> Void
    let search: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Колоды")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)

                HStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MatchPalette.primary)
                    Text(LocalizedCounts.deckPhrase(deckCount))
                        .font(.system(size: 13, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(LovableSurface.muted)
                    Text("·")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(LovableSurface.muted.opacity(0.7))
                    Text(LocalizedCounts.cardPhrase(cardCount))
                        .font(.system(size: 13, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(LovableSurface.muted)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                HeaderIconButton(
                    systemImage: "shuffle",
                    accessibilityLabel: L10n.text("Случайные"),
                    isEnabled: isRandomEnabled,
                    action: random
                )

                HeaderIconButton(
                    systemImage: "magnifyingglass",
                    accessibilityLabel: L10n.text("Поиск"),
                    isEnabled: isSearchEnabled,
                    action: search
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HeaderIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LovableSurface.foreground)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.58), lineWidth: 0.8)
                }
                .shadow(color: oklch(0.18, 0.05, 260, 0.12), radius: 12, x: 0, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(L10n.text(accessibilityLabel))
    }
}

private struct DeckWordSearchItem: Identifiable, Hashable, Sendable {
    let card: WordCardContent
    let deckID: UUID
    let deckTitle: String

    var id: String { "\(deckID.databaseString)-\(card.id.databaseString)" }
}

private struct WordSearchPane: View {
    private let index: DeckWordSearchIndex?
    private let sourceRevision: Int
    private let onCancel: () -> Void

    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var visibleItems: [DeckWordSearchItem] = []
    @FocusState private var isSearchFieldFocused: Bool

    private static let searchDebounceNanoseconds: UInt64 = 180_000_000

    init(
        index: DeckWordSearchIndex?,
        sourceRevision: Int,
        onCancel: @escaping () -> Void
    ) {
        self.index = index
        self.sourceRevision = sourceRevision
        self.onCancel = onCancel
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 22) {
            searchHeader

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Поднимаем клавиатуру только после того, как форма доехала до места:
            // если фокусироваться посреди перехода, первое появление клавиатуры
            // подвешивает анимацию ровно на середине.
            try? await Task.sleep(for: .seconds(DeckListView.searchTransitionDuration + 0.05))
            guard !Task.isCancelled else { return }
            isSearchFieldFocused = true
        }
        .task(id: sourceRevision) {
            applyCurrentIndex()
        }
        .task(id: query) {
            await updateResults(for: query)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let index, index.sortedItems.isEmpty {
            DataPlaceholderView(
                title: "Нет слов",
                systemImage: "text.book.closed",
                message: "В колодах пока нет активных карточек."
            )
            .frame(minHeight: 360)
        } else if index == nil {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(LovableSurface.primary)

                Text(L10n.text("Загружаем данные"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LovableSurface.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 360)
        } else if trimmedQuery.isEmpty {
            wordRows(visibleItems)
        } else if visibleItems.isEmpty {
            DataPlaceholderView(
                title: "Нет совпадений",
                systemImage: "magnifyingglass",
                message: "Попробуйте другое написание."
            )
            .frame(minHeight: 360)
        } else {
            wordRows(visibleItems)
        }
    }

    /// Применяет уже готовый индекс (построенный заранее в DeckListView) к текущему запросу.
    private func applyCurrentIndex() {
        guard let index else {
            visibleItems = []
            return
        }
        debouncedQuery = query
        visibleItems = index.results(for: query)
    }

    private func updateResults(for query: String) async {
        guard let currentIndex = index else { return }
        let nextQuery = query
        if nextQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debouncedQuery = nextQuery
            visibleItems = currentIndex.sortedItems
            return
        }

        try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
        guard !Task.isCancelled, let currentIndex = index else { return }
        debouncedQuery = nextQuery
        visibleItems = currentIndex.results(for: nextQuery)
    }

    @ViewBuilder
    private func wordRows(_ list: [DeckWordSearchItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { position, item in
                DeckSearchWordRow(
                    item: item,
                    position: rowPosition(index: position, count: list.count)
                )
            }
        }
    }

    private func rowPosition(index: Int, count: Int) -> DeckSearchWordRow.Position {
        if count == 1 { return .single }
        if index == 0 { return .top }
        if index == count - 1 { return .bottom }
        return .middle
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(LovableSurface.muted)

                TextField(L10n.text("Поиск по колодам и словам"), text: $query)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(LovableSurface.foreground)
                    .tint(LovableSurface.primary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFieldFocused)
                    .submitLabel(.search)

                if !query.isEmpty {
                    Button {
                        query = ""
                        isSearchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(LovableSurface.muted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .accessibilityLabel(L10n.text("Очистить"))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.58), lineWidth: 0.8)
            }
            .shadow(color: oklch(0.18, 0.05, 260, 0.12), radius: 16, x: 0, y: 8)

            Button(action: onCancel) {
                Text(L10n.text("Отмена"))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LovableSurface.foreground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
    }
}

private nonisolated struct DeckWordSearchIndex: Sendable {
    private struct Entry: Sendable {
        let item: DeckWordSearchItem
        let sortOrder: Int
        let candidates: [Candidate]
    }

    private struct Candidate: Sendable {
        let original: String
        let normalized: String
        let normalizedCharacters: [Character]
    }

    let sortedItems: [DeckWordSearchItem]
    private let entries: [Entry]

    init(decks: [DeckContent]) {
        self.init(items: Self.items(from: decks))
    }

    init(items: [DeckWordSearchItem]) {
        let sortedItems = items.sorted(by: Self.sortItems)
        self.sortedItems = sortedItems
        self.entries = sortedItems.enumerated().map { sortOrder, item in
            Entry(
                item: item,
                sortOrder: sortOrder,
                candidates: Self.candidates(for: item)
            )
        }
    }

    private static func items(from decks: [DeckContent]) -> [DeckWordSearchItem] {
        decks.flatMap { deck in
            deck.activeCards.map { card in
                DeckWordSearchItem(card: card, deckID: deck.id, deckTitle: deck.title)
            }
        }
    }

    func results(for query: String) -> [DeckWordSearchItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.normalizedForWordSearch
        guard !normalizedQuery.isEmpty else { return sortedItems }
        guard normalizedQuery.count >= 2 else { return [] }
        let normalizedQueryCharacters = Array(normalizedQuery)

        return entries
            .compactMap { entry -> (entry: Entry, score: Int)? in
                guard let score = Self.searchScore(
                    query: trimmedQuery,
                    normalizedQuery: normalizedQuery,
                    normalizedQueryCharacters: normalizedQueryCharacters,
                    entry: entry
                ) else { return nil }
                return (entry, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.entry.sortOrder < rhs.entry.sortOrder
            }
            .map(\.entry.item)
    }

    nonisolated private static func sortItems(_ lhs: DeckWordSearchItem, _ rhs: DeckWordSearchItem) -> Bool {
        let lemmaOrder = lhs.card.lemma.localizedCaseInsensitiveCompare(rhs.card.lemma)
        if lemmaOrder != .orderedSame {
            return lemmaOrder == .orderedAscending
        }

        let wordOrder = lhs.card.word.localizedCaseInsensitiveCompare(rhs.card.word)
        if wordOrder != .orderedSame {
            return wordOrder == .orderedAscending
        }

        let deckOrder = lhs.deckTitle.localizedCaseInsensitiveCompare(rhs.deckTitle)
        if deckOrder != .orderedSame {
            return deckOrder == .orderedAscending
        }

        return lhs.card.translation.localizedCaseInsensitiveCompare(rhs.card.translation) == .orderedAscending
    }

    private static func candidates(for item: DeckWordSearchItem) -> [Candidate] {
        [item.card.word, item.card.lemma]
            .flatMap { text in [text] + text.split(separator: " ").map(String.init) }
            .map { text in
                let normalized = text.normalizedForWordSearch
                return Candidate(
                    original: text,
                    normalized: normalized,
                    normalizedCharacters: Array(normalized)
                )
            }
            .filter { !$0.normalized.isEmpty }
    }

    private static func searchScore(
        query: String,
        normalizedQuery: String,
        normalizedQueryCharacters: [Character],
        entry: Entry
    ) -> Int? {
        var bestScore: Int?
        for candidate in entry.candidates {
            let score: Int?
            if candidate.normalized == normalizedQuery {
                score = 0
            } else if candidate.normalized.hasPrefix(normalizedQuery) {
                score = 1
            } else if candidate.normalized.contains(normalizedQuery) || candidate.original.localizedStandardRange(of: query) != nil {
                score = 2
            } else {
                score = fuzzyScore(query: normalizedQueryCharacters, candidate: candidate)
            }

            if let score, bestScore == nil || score < bestScore! {
                bestScore = score
            }
        }
        return bestScore
    }

    private static func fuzzyScore(query: [Character], candidate: Candidate) -> Int? {
        guard query.count >= 3 else { return nil }
        let maxDistance = allowedTypoDistance(for: query.count)
        guard abs(candidate.normalizedCharacters.count - query.count) <= maxDistance + 1 else { return nil }

        let distance = levenshteinDistance(
            query,
            candidate.normalizedCharacters,
            maximumDistance: maxDistance
        )
        guard distance <= maxDistance else { return nil }
        return 10 + distance
    }

    private static func allowedTypoDistance(for length: Int) -> Int {
        if length <= 4 { return 1 }
        if length <= 8 { return 2 }
        return 3
    }

    private static func levenshteinDistance(
        _ lhsCharacters: [Character],
        _ rhsCharacters: [Character],
        maximumDistance: Int
    ) -> Int {
        guard !lhsCharacters.isEmpty else { return rhsCharacters.count }
        guard !rhsCharacters.isEmpty else { return lhsCharacters.count }

        var previous = Array(0...rhsCharacters.count)
        var current = Array(repeating: 0, count: rhsCharacters.count + 1)

        for lhsIndex in 1...lhsCharacters.count {
            current[0] = lhsIndex
            var rowMinimum = current[0]

            for rhsIndex in 1...rhsCharacters.count {
                let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rhsIndex])
            }

            if rowMinimum > maximumDistance {
                return maximumDistance + 1
            }

            swap(&previous, &current)
        }

        return previous[rhsCharacters.count]
    }
}

private struct DeckSearchWordRow: View {
    enum Position: Equatable {
        case single
        case top
        case middle
        case bottom

        var hasSeparator: Bool {
            self == .top || self == .middle
        }

        var cornerRadii: RectangleCornerRadii {
            let radius: CGFloat = 20
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

    let item: DeckWordSearchItem
    let position: Position

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.card.word)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(oklch(0.99, 0.01, 240))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(item.deckTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(oklch(0.78, 0.13, 250))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text(item.card.translation)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(oklch(0.82, 0.03, 250, 0.65))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var normalizedForWordSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
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
                    Text("\(LocalizedCounts.cardPhrase(deck.activeCards.count)) · \(deck.languageCode.uppercased())")
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
                    Text(L10n.text(footnote))
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
                        Text("\(LocalizedCounts.cardPhrase(activeCardCount)) · \(deck.languageCode.uppercased())")
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
        let statusText = L10n.text(deck.isActive ? "включена" : "отключена")
        return L10n.format(
            "%@, %@, новых %d, повторить %d, всего %d",
            deck.title,
            statusText,
            stats.newAvailable,
            stats.dueTotal,
            activeCardCount
        )
    }
}

struct DeckDetailView: View {
    @Binding var deck: DeckContent
    let store: DeckStore

    @State private var stats: DeckStats = .zero
    @State private var session: StudySession?
    @State private var showStudy = false
    @State private var statusError: String?
    @State private var startError: String?
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
            await reloadDeckState()
        }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            Task {
                await reloadDeckState()
            }
        }
        .alert("Не удалось обновить колоду", isPresented: statusErrorBinding) {
            Button("ОК", role: .cancel) {
                statusError = nil
            }
        } message: {
            Text(statusError ?? "")
        }
        .alert("Не удалось начать упражнение", isPresented: startErrorBinding) {
            Button("ОК", role: .cancel) {
                startError = nil
            }
        } message: {
            Text(startError ?? "")
        }
    }

    private func start(_ mode: StudyMode) {
        guard deck.isActive else { return }
        do {
            switch exerciseScope {
            case .all:
                session = try store.startAllCardsSession(deck: deck, mode: mode)
            case .weak:
                session = try store.startWeakCardsSession(deck: deck, mode: mode)
            }
            guard session != nil else {
                startError = "Нет карточек для этого упражнения."
                return
            }
            showStudy = true
        } catch {
            startError = error.localizedDescription
        }
    }

    private var deckFootnote: String {
        switch exerciseScope {
        case .all:
            return "Учим все карты в колоде"
        case .weak:
            return LocalizedCounts.cardsInWeak(weakCardIDs.count)
        }
    }

    private var matchingSubtitle: String {
        guard exerciseScope == .all,
              let matchingRecord,
              matchingRecord.pairCount == fullDeckMatchingPairCount else {
            return "Соедини слово и перевод"
        }
        return L10n.format("Рекорд: %@", StudyDurationFormat.string(matchingRecord.bestDuration))
    }

    private var fullDeckMatchingPairCount: Int {
        studyCards.reduce(0) { count, card in
            count + card.activeSenses.count
        }
    }

    @MainActor
    private func reloadDeckState() async {
        let userID = store.currentUserID
        let currentDeck = deck
        do {
            let snapshot = try await DeckStore.deckDetailSnapshot(userID: userID, deck: currentDeck)
            guard !Task.isCancelled else { return }
            stats = snapshot.stats
            matchingRecord = snapshot.matchingRecord
            weakCardIDs = snapshot.weakCardIDs
        } catch {
            guard !Task.isCancelled else { return }
            stats = .zero
            matchingRecord = nil
            weakCardIDs = []
        }
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

    private var startErrorBinding: Binding<Bool> {
        Binding(
            get: { startError != nil },
            set: { isPresented in
                if !isPresented { startError = nil }
            }
        )
    }

    private func toggleDeckStatus() {
        let newStatus: ContentStatus = deck.isActive ? .inactive : .active
        do {
            try store.setDeckStatus(newStatus, for: deck.id)
            deck.status = newStatus
            Task {
                await reloadDeckState()
            }
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
        .navigationTitle(L10n.text(title))
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
                Text(L10n.text(scope.title)).tag(scope)
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
                    Text(L10n.text(title))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(LovableSurface.foreground)
                    if let remaining {
                        Text(L10n.text(remaining))
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
                        Text(L10n.text(title))
                            .font(.system(size: 16, weight: .bold))
                        if let badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(L10n.text(subtitle))
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
            Text(L10n.text(title))
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
            return L10n.text("На сегодня всё готово")
        }
        return LocalizedCounts.cardsInQueue(stats.studyTotal)
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
