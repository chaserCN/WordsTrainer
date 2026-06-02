import SwiftUI
import OSLog

struct AppRootView: View {
    @Environment(AppUserStore.self) private var userStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Сегодня", systemImage: "calendar") {
                TodayView()
            }
            Tab("Колоды", systemImage: "books.vertical") {
                DeckListView()
            }
            Tab("Статистика", systemImage: "chart.bar.xaxis") {
                StatisticsView()
            }
        }
        .tint(.cyan)
        .task {
            await userStore.refreshFromServer()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            AppBackgroundSync.run {
                await userStore.syncPendingEventsToServer()
            }
        }
    }
}

struct TodayView: View {
    private static let syncLogger = Logger(subsystem: "com.uniweb.wordtrainer.Words-Trainer", category: "TodaySync")

    @Environment(AppUserStore.self) private var userStore
    @State private var store: DeckStore?
    @State private var storeUserID: UUID?
    @State private var decks: [DeckContent] = []
    @State private var statsByDeckID: [UUID: DeckStats] = [:]
    @State private var streakDays = 0
    @State private var session: StudySession?
    @State private var sessionDeckTitle = ""
    @State private var showUserSwitcher = false
    @State private var showTodayModes = false
    @State private var showStudy = false
    @State private var isSyncing = false
    @State private var syncTask: Task<Void, Never>?
    @State private var toast: TodayToast?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var loadError: String?

    private var activeDecks: [DeckContent] {
        decks.filter(\.isActive)
    }

    private var activeDecksWithStudyToday: [DeckContent] {
        activeDecks.filter { deck in
            (statsByDeckID[deck.id] ?? .zero).studyTotal > 0
        }
    }

    private var totalStats: DeckStats {
        statsByDeckID.values.reduce(.zero) { partial, stats in
            DeckStats(
                newAvailable: partial.newAvailable + stats.newAvailable,
                learningDue: partial.learningDue + stats.learningDue,
                reviewDue: partial.reviewDue + stats.reviewDue
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selectedUser = userStore.selectedUser {
                        TodayHeader(
                            user: selectedUser,
                            streakDays: streakDays,
                            showUserSwitcher: { showUserSwitcher = true }
                        )
                    } else if showsNoUserConnectionCard {
                        TodayServerConnectionCard(
                            title: noUserTitle,
                            systemImage: noUserSystemImage,
                            message: noUserMessage
                        )
                    }

                    if let contentStatus {
                        TodaySyncStatusCard(status: contentStatus)
                    }

                    StudyTodayCard(
                        stats: totalStats,
                        isEnabled: totalStats.studyTotal > 0,
                        action: {
                            showTodayModes = true
                        }
                    )

                    if let store, !activeDecksWithStudyToday.isEmpty {
                        TodayDeckSummary(decks: activeDecksWithStudyToday, statsByDeckID: statsByDeckID, store: store)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .refreshable {
                await syncNow()
            }
            .background { LovableBackground(variant: .today) }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showTodayModes) {
                if store != nil {
                    TodayStudyModesView(
                        queueCount: totalStats.studyTotal,
                        newCount: totalStats.newAvailable,
                        dueCount: totalStats.learningDue + totalStats.reviewDue,
                        start: startToday(mode:)
                    )
                }
            }
            .navigationDestination(isPresented: $showStudy) {
                if let session, let store {
                    StudySessionView(session: session, store: store, deckTitle: sessionDeckTitle)
                }
            }
            .sheet(isPresented: $showUserSwitcher) {
                UserSwitcherSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .overlay {
                if let loadError {
                    DataPlaceholderView(
                        title: "Ошибка",
                        systemImage: "exclamationmark.triangle",
                        message: loadError
                    )
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    TodayToastView(toast: toast)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: toast)
        }
        .task {
            await reload()
        }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            Task { await reload() }
        }
        .onChange(of: userStore.selectedUserID) {
            store = nil
            storeUserID = nil
            clearToast()
            Task { await reload() }
        }
        .onChange(of: userStore.bootstrapState) { _, state in
            presentToast(forBootstrapState: state)
        }
    }

    private var showsNoUserConnectionCard: Bool {
        userStore.bootstrapState == .emptyServer
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
            userStore.bootstrapState.message ?? "Нажмите синхронизацию, чтобы загрузить пользователя с сервера."
        }
    }

    private var contentStatus: TodaySyncStatus? {
        guard userStore.selectedUser != nil,
              store != nil else { return nil }
        if decks.isEmpty {
            return TodaySyncStatus(
                title: "Нет колод",
                message: "Для выбранного пользователя пока нет назначенных колод.",
                systemImage: "books.vertical",
                tint: oklch(0.64, 0.19, 35)
            )
        }
        if activeDecks.isEmpty {
            return TodaySyncStatus(
                title: "Колоды неактивны",
                message: "У пользователя есть колоды, но сейчас нет активных назначений для занятий.",
                systemImage: "pause.circle.fill",
                tint: oklch(0.64, 0.19, 35)
            )
        }
        return nil
    }

    private func reload() async {
        do {
            guard let selectedUserID = userStore.selectedUserID else {
                decks = []
                statsByDeckID = [:]
                streakDays = 0
                loadError = nil
                return
            }
            let deckStore: DeckStore
            if let store, storeUserID == selectedUserID {
                deckStore = store
            } else {
                deckStore = try DeckStore(userID: selectedUserID)
                store = deckStore
                storeUserID = selectedUserID
            }
            decks = try deckStore.allDecks()
            var nextStats: [UUID: DeckStats] = [:]
            for deck in decks where deck.isActive {
                nextStats[deck.id] = try deckStore.stats(for: deck)
            }
            statsByDeckID = nextStats
            streakDays = currentStreakDays(from: try deckStore.studyActivity(days: 90))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func startToday(mode: StudyMode) {
        guard let store else { return }
        do {
            guard let next = try store.firstDeckWithStudyToday(mode: mode) else { return }
            sessionDeckTitle = next.0.title
            session = next.1
            showStudy = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func syncNow() async {
        Self.syncLogger.info("syncNow invoked isSyncing=\(self.isSyncing, privacy: .public)")
        let task = startSyncTask()
        await task.value
    }

    @MainActor
    private func startSyncTask() -> Task<Void, Never> {
        if let syncTask {
            Self.syncLogger.info("syncNow joined existing sync task")
            return syncTask
        }
        let task = Task { @MainActor in
            isSyncing = true
            defer {
                isSyncing = false
                syncTask = nil
            }
            presentToast(
                status: TodaySyncStatus(
                    title: "Синхронизация",
                    message: "Проверяем сервер и загружаем данные.",
                    systemImage: "arrow.clockwise",
                    tint: LovableSurface.primary
                ),
                autoDismiss: false
            )
            let result = await userStore.refreshFromServer()
            Self.syncLogger.info("syncNow refresh finished")
            await reload()
            presentToast(for: result)
        }
        syncTask = task
        return task
    }

    private func presentToast(for result: AppUserRefreshResult) {
        guard let message = result.message else {
            clearToast()
            return
        }
        presentToast(status: TodaySyncStatus(result: result, message: message), autoDismiss: true)
    }

    private func presentToast(forBootstrapState state: AppUserBootstrapState) {
        guard !isSyncing else { return }
        switch state {
        case .missingConfiguration:
            presentToast(
                status: TodaySyncStatus(
                    title: "Сервер не настроен",
                    message: state.message ?? "Нужно подключить устройство к серверу.",
                    systemImage: "link.badge.plus",
                    tint: oklch(0.64, 0.19, 35)
                ),
                autoDismiss: true
            )
        case .failed(let message):
            presentToast(
                status: TodaySyncStatus(
                    title: "Синхронизация не удалась",
                    message: message,
                    systemImage: "wifi.exclamationmark",
                    tint: oklch(0.64, 0.19, 35)
                ),
                autoDismiss: true
            )
        default:
            break
        }
    }

    private func presentToast(status: TodaySyncStatus, autoDismiss: Bool) {
        toastDismissTask?.cancel()
        let nextToast = TodayToast(status: status)
        withAnimation(.snappy(duration: 0.22)) {
            toast = nextToast
        }
        guard autoDismiss else { return }
        toastDismissTask = Task { [id = nextToast.id] in
            try? await Task.sleep(for: .seconds(5.0))
            await MainActor.run {
                guard toast?.id == id else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    toast = nil
                }
            }
        }
    }

    private func clearToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        withAnimation(.snappy(duration: 0.22)) {
            toast = nil
        }
    }
}

struct StatisticsView: View {
    @Environment(AppUserStore.self) private var userStore
    @State private var store: DeckStore?
    @State private var storeUserID: UUID?
    @State private var todayCount: StudyReviewCount = .zero
    @State private var weekCount: StudyReviewCount = .zero
    @State private var monthCount: StudyReviewCount = .zero
    @State private var activity: [StudyActivityDay] = []
    @State private var scheduledDays: [ScheduledReviewDay] = []
    @State private var weakCardsPool: [WeakCardStat] = []
    @State private var weakGameSession: StudySession?
    @State private var showWeakGame = false
    @State private var loadError: String?

    private var studyDaysCount: Int {
        activity.suffix(30).filter { $0.reviewedCount > 0 }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StatisticsHeader()

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        DashboardMetric(title: "Сегодня", value: "\(todayCount.total)", subtitle: cardsLabel(todayCount.total))
                        DashboardMetric(title: "7 дней", value: "\(weekCount.total)", subtitle: cardsLabel(weekCount.total))
                        DashboardMetric(title: "30 дней", value: "\(monthCount.total)", subtitle: cardsLabel(monthCount.total))
                        DashboardMetric(title: "Дни занятий", value: "\(studyDaysCount)", subtitle: "за 30 дней")
                    }

                    ActivityHeatmap(days: activity)
                    ForecastSection(days: scheduledDays)
                    WeakCardsSection(
                        cards: Array(weakCardsPool.prefix(WeakCardsPractice.displayLimit)),
                        onPractice: startWeakGame
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .background { LovableBackground(variant: .stats) }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showWeakGame) {
                if let weakGameSession, let store {
                    StudySessionView(session: weakGameSession, store: store, deckTitle: "Забытые слова")
                }
            }
            .overlay {
                if let loadError {
                    DataPlaceholderView(
                        title: "Ошибка",
                        systemImage: "exclamationmark.triangle",
                        message: loadError
                    )
                }
            }
        }
        .task {
            await reload()
        }
        .onChange(of: userStore.selectedUserID) {
            store = nil
            storeUserID = nil
            Task { await reload() }
        }
    }

    private func reload() async {
        do {
            guard let selectedUserID = userStore.selectedUserID else {
                todayCount = .zero
                weekCount = .zero
                monthCount = .zero
                activity = []
                scheduledDays = []
                weakCardsPool = []
                loadError = nil
                return
            }
            let deckStore: DeckStore
            if let store, storeUserID == selectedUserID {
                deckStore = store
            } else {
                deckStore = try DeckStore(userID: selectedUserID)
                store = deckStore
                storeUserID = selectedUserID
            }
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: .now)
            let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            let monthStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
            todayCount = try deckStore.studyReviewCount(since: todayStart)
            weekCount = try deckStore.studyReviewCount(since: weekStart)
            monthCount = try deckStore.studyReviewCount(since: monthStart)
            activity = try deckStore.studyActivity(days: 120)
            scheduledDays = try deckStore.scheduledReviewDays(days: 7)
            weakCardsPool = try deckStore.weakCards(limit: WeakCardsPractice.fetchLimit)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func startWeakGame() {
        guard let store else { return }
        guard let session = try? store.weakCardsMatchingSession(from: weakCardsPool) else { return }
        weakGameSession = session
        showWeakGame = true
    }
}

private struct TodayHeader: View {
    let user: AppUser
    let streakDays: Int
    let showUserSwitcher: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Сегодня")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(LovableSurface.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 12)

            UserAvatarButton(user: user, streakDays: streakDays, action: showUserSwitcher)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatisticsHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Статистика")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(LovableSurface.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodayServerConnectionCard: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LovableSurface.primary)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Text(message ?? "Загружаем профиль с сервера.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LovableSurface.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct TodaySyncStatus: Equatable {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    init(title: String, message: String, systemImage: String, tint: Color) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
    }

    init(result: AppUserRefreshResult, message: String) {
        switch result {
        case .loaded:
            self.init(
                title: "Готово",
                message: message,
                systemImage: "checkmark.circle.fill",
                tint: oklch(0.58, 0.14, 155)
            )
        case .missingConfiguration:
            self.init(
                title: "Сервер не настроен",
                message: message,
                systemImage: "link.badge.plus",
                tint: oklch(0.64, 0.19, 35)
            )
        case .emptyServer:
            self.init(
                title: "Сервер пуст",
                message: message,
                systemImage: "person.2.slash",
                tint: oklch(0.64, 0.19, 35)
            )
        case .cancelled:
            self.init(
                title: "Синхронизация отменена",
                message: message,
                systemImage: "xmark.circle.fill",
                tint: LovableSurface.muted
            )
        case .failed:
            self.init(
                title: "Синхронизация не удалась",
                message: message,
                systemImage: "wifi.exclamationmark",
                tint: oklch(0.64, 0.19, 35)
            )
        }
    }

    static func == (lhs: TodaySyncStatus, rhs: TodaySyncStatus) -> Bool {
        lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.systemImage == rhs.systemImage
    }
}

private struct TodayToast: Identifiable, Equatable {
    let id = UUID()
    let status: TodaySyncStatus

    static func == (lhs: TodayToast, rhs: TodayToast) -> Bool {
        lhs.id == rhs.id
    }
}

private struct TodayToastView: View {
    let toast: TodayToast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.status.systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(toast.status.tint, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.status.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Text(toast.status.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LovableSurface.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }
}

private struct TodaySyncStatusCard: View {
    let status: TodaySyncStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(status.tint, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Text(status.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LovableSurface.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 0.5)
        }
    }
}

private struct UserAvatarButton: View {
    let user: AppUser
    let streakDays: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            UserAvatar(user: user, size: 56)
                .overlay(alignment: .bottomTrailing) {
                    if streakDays > 3 {
                        StreakBadge(days: streakDays)
                            .offset(x: 7, y: 7)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Выбрать пользователя")
        .accessibilityValue(user.displayName)
    }
}

private struct UserAvatar: View {
    let user: AppUser
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            oklch(0.84, 0.14, user.accentHue),
                            oklch(0.72, 0.18, user.accentHue + 35),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url = user.avatarImageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Text(user.initials)
                            .font(.system(size: size * 0.34, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Text(user.initials)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(.white.opacity(0.92), lineWidth: 2)
        }
        .shadow(color: oklch(0.18, 0.05, 260, 0.16), radius: 12, x: 0, y: 7)
    }
}

private struct StreakBadge: View {
    let days: Int

    private var colors: [Color] {
        if days > 7 {
            [oklch(0.66, 0.24, 25), oklch(0.56, 0.24, 15)]
        } else {
            [oklch(0.74, 0.18, 42), oklch(0.64, 0.22, 25)]
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 11, weight: .black))
            Text("\(days)")
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(.white, lineWidth: 2)
        }
        .shadow(color: colors.last?.opacity(0.35) ?? .clear, radius: 8, x: 0, y: 4)
        .accessibilityLabel("Серия \(days) дней")
    }
}

private struct UserSwitcherSheet: View {
    @Environment(AppUserStore.self) private var userStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if userStore.users.isEmpty {
                    ContentUnavailableView(
                        "Пользователи не загружены",
                        systemImage: "person.2.slash",
                        description: Text(userStore.bootstrapState.message ?? "Выполните синхронизацию с сервером.")
                    )
                } else {
                    Section {
                        ForEach(userStore.users) { user in
                            Button {
                                userStore.select(user)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    UserAvatar(user: user, size: 44)
                                    Text(user.displayName)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if user.id == userStore.selectedUserID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(LovableSurface.primary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Пользователь")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct StudyTodayCard: View {
    let stats: DeckStats
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Учить сегодня")
                        .font(.system(size: 24, weight: .bold))
                    Text(isEnabled ? "\(stats.studyTotal) карточек в очереди" : "На сегодня всё готово")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.22), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .background(
                LinearGradient(
                    colors: [
                        LovableSurface.primary.opacity(isEnabled ? 1 : 0.42),
                        LovableSurface.primaryDeep.opacity(isEnabled ? 1 : 0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .shadow(color: oklch(0.4, 0.22, 260, isEnabled ? 0.35 : 0), radius: 18, x: 0, y: 14)
    }
}

private struct TodayStudyModesView: View {
    let queueCount: Int
    var newCount: Int = 0
    var dueCount: Int = 0
    var deck: DeckContent? = nil
    let start: (StudyMode) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                QueueSummaryCard(queueCount: queueCount, newCount: newCount, dueCount: dueCount, deck: deck)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Упражнения")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(LovableSurface.foreground)
                        .padding(.top, 28)

                    TodayModeButton(
                        title: "Карточки",
                        subtitle: "Слово, перевод и заметки — переворот по тапу",
                        systemImage: "rectangle.on.rectangle.angled",
                        accent: .orange,
                        isEnabled: queueCount > 0
                    ) {
                        start(.flashcards)
                    }

                    TodayModeButton(
                        title: "Предложения",
                        subtitle: "Выбери слово для примера с пропуском",
                        systemImage: "text.quote",
                        accent: .blue,
                        isEnabled: queueCount > 0
                    ) {
                        start(.clozeMultipleChoice)
                    }

                    TodayModeButton(
                        title: "Колонки",
                        subtitle: "Соедини слово и перевод",
                        systemImage: "rectangle.split.2x1.fill",
                        accent: .green,
                        isEnabled: queueCount > 0
                    ) {
                        start(.matching)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background { LovableBackground(variant: .today) }
        .navigationTitle(deck?.title ?? "Сегодня")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
        .tint(LovableSurface.foreground)
    }
}

/// Экран режимов для конкретной колоды на вкладке «Сегодня».
/// Учим только сегодняшнюю очередь этой колоды.
private struct TodayDeckModesView: View {
    let deck: DeckContent
    let store: DeckStore

    @State private var stats: DeckStats = .zero
    @State private var session: StudySession?
    @State private var showStudy = false

    var body: some View {
        TodayStudyModesView(
            queueCount: stats.studyTotal,
            newCount: stats.newAvailable,
            dueCount: stats.learningDue + stats.reviewDue,
            deck: deck,
            start: start
        )
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: deck.title)
            }
        }
        .task { await reload() }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            Task { await reload() }
        }
    }

    private func reload() async {
        stats = (try? store.stats(for: deck)) ?? .zero
    }

    private func start(_ mode: StudyMode) {
        session = try? store.startTodaySession(deck: deck, mode: mode)
        showStudy = session != nil
    }
}

private struct QueueSummaryCard: View {
    let queueCount: Int
    let newCount: Int
    let dueCount: Int
    var deck: DeckContent? = nil

    private var todayDayNumber: String {
        "\(Calendar.current.component(.day, from: .now))"
    }

    private var todayMonthShort: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("LLL")
        return formatter.string(from: .now)
    }

    @ViewBuilder private var deckOrDateAvatar: some View {
        if let deck {
            DeckAvatarView(deck: deck, size: 56)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [LovableSurface.primary, LovableSurface.primaryDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay {
                    VStack(spacing: 0) {
                        Text(todayMonthShort)
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(todayDayNumber)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: oklch(0.4, 0.22, 260, 0.28), radius: 12, x: 0, y: 8)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                deckOrDateAvatar

                VStack(alignment: .leading, spacing: 3) {
                    Text(deck?.title ?? "Дневная очередь")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(queueCount) \(cardsLabel(queueCount)) · сегодня")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                LovableStat(count: newCount, label: "Новые", color: LovableSurface.blueText)
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1, height: 12)
                LovableStat(count: dueCount, label: "Повторить", color: LovableSurface.amberText)
            }
        }
        .padding(16)
        .lovablePanel(cornerRadius: 24)
    }
}

private struct TodayModeButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.42))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(accent.opacity(isEnabled ? 0.95 : 0.25)))
                    .shadow(color: accent.opacity(isEnabled ? 0.35 : 0), radius: 12, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(18)
            .foregroundStyle(.white)
            .lovablePanel(cornerRadius: 20)
            .opacity(isEnabled ? 1 : 0.58)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(oklch(0.82, 0.03, 250, 0.7))
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(oklch(0.99, 0.01, 240))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(oklch(0.82, 0.03, 250, 0.65))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lovablePanel(cornerRadius: 20)
    }
}

private struct ActivityHeatmap: View {
    let days: [StudyActivityDay]

    private var maxCount: Int { max(days.map(\.reviewedCount).max() ?? 0, 1) }
    private var months: [ActivityMonth] {
        ActivityCalendarBuilder.months(from: days)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Активность")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(months.count) мес.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(months) { month in
                            ActivityMonthView(month: month, maxCount: maxCount)
                        }
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("activity-latest")
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo("activity-latest", anchor: .trailing)
                }
                .onChange(of: days) {
                    proxy.scrollTo("activity-latest", anchor: .trailing)
                }
            }
        }
        .padding(18)
        .lovablePanel(cornerRadius: 24)
    }

}

private struct ActivityMonthView: View {
    let month: ActivityMonth
    let maxCount: Int

    private let columns = Array(repeating: GridItem(.fixed(18), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(month.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(Array(month.weekdays.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(width: 18, height: 10)
                }

                ForEach(month.cells) { cell in
                    if let day = cell.day {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(day.isToday ? oklch(0.78, 0.2, 235) : color(for: day.reviewedCount))
                            .frame(width: 15, height: 15)
                            .frame(width: 18, height: 18)
                            .overlay {
                                if day.isToday {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(.white.opacity(0.9), lineWidth: 1.5)
                                        .frame(width: 15, height: 15)
                                        .shadow(color: oklch(0.7, 0.18, 235, 0.6), radius: 5)
                                }
                            }
                            .accessibilityLabel("\(day.dayKey): \(day.reviewedCount) карточек")
                    } else {
                        Color.clear
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(width: 162, alignment: .leading)
    }

    private func color(for count: Int) -> Color {
        guard count > 0 else { return oklch(0.32, 0.02, 265, 0.5) }
        let ratio = Double(count) / Double(maxCount)
        switch ratio {
        case ..<0.25: return oklch(0.55, 0.1, 235, 0.55)
        case ..<0.5: return oklch(0.65, 0.15, 235, 0.75)
        case ..<0.75: return oklch(0.72, 0.18, 235, 0.9)
        default: return oklch(0.8, 0.2, 235)
        }
    }
}

private struct ActivityMonth: Identifiable, Hashable {
    let id: String
    let title: String
    let weekdays: [String]
    let cells: [ActivityCalendarCell]
}

private struct ActivityCalendarCell: Identifiable, Hashable {
    let id: String
    let day: ActivityCalendarDay?
}

private struct ActivityCalendarDay: Hashable {
    let dayKey: String
    let reviewedCount: Int
    let isToday: Bool
}

private enum ActivityCalendarBuilder {
    static func months(from days: [StudyActivityDay]) -> [ActivityMonth] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let todayKey = DeckDailyUsage.dayKey(for: today, calendar: calendar)
        let byKey = Dictionary(uniqueKeysWithValues: days.map { ($0.dayKey, $0.reviewedCount) })
        let startDate = days.first.flatMap { dateFromDayKey($0.dayKey) } ?? today
        let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start ?? startDate
        let currentMonthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        var months: [ActivityMonth] = []
        var date = monthStart

        while date <= currentMonthStart {
            months.append(month(for: date, todayKey: todayKey, countsByKey: byKey, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: date) else { break }
            date = next
        }

        return months
    }

    private static func month(
        for monthStart: Date,
        todayKey: String,
        countsByKey: [String: Int],
        calendar: Calendar
    ) -> ActivityMonth {
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<1
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingSlots = (firstWeekday - calendar.firstWeekday + 7) % 7
        let monthKey = DeckDailyUsage.dayKey(for: monthStart, calendar: calendar)
        var cells = (0..<leadingSlots).map { ActivityCalendarCell(id: "\(monthKey)-blank-\($0)", day: nil) }

        for dayNumber in dayRange {
            guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: monthStart) else { continue }
            let key = DeckDailyUsage.dayKey(for: date, calendar: calendar)
            let day = ActivityCalendarDay(
                dayKey: key,
                reviewedCount: countsByKey[key, default: 0],
                isToday: key == todayKey
            )
            cells.append(ActivityCalendarCell(id: key, day: day))
        }

        return ActivityMonth(
            id: monthKey,
            title: title(for: monthStart),
            weekdays: weekdaySymbols(calendar: calendar),
            cells: cells
        )
    }

    private static let ruLocale = Locale(identifier: "ru_RU")

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = ruLocale
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["В", "П", "В", "С", "Ч", "П", "С"]
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = ruLocale
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter.string(from: date)
    }

    private static func dateFromDayKey(_ dayKey: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayKey)
    }
}

private struct TodayDeckSummary: View {
    let decks: [DeckContent]
    let statsByDeckID: [UUID: DeckStats]
    let store: DeckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("По колодам")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LovableSurface.foreground)
                .padding(.horizontal, 4)

            if decks.isEmpty {
                Text("Нет включенных колод.")
                    .font(.subheadline)
                    .foregroundStyle(LovableSurface.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(decks) { deck in
                        NavigationLink {
                            TodayDeckModesView(deck: deck, store: store)
                        } label: {
                            TodayDeckCard(deck: deck, stats: statsByDeckID[deck.id] ?? .zero)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Карточка колоды на вкладке «Сегодня»: сегодняшняя очередь + разбивка Новые/Повторить.
private struct TodayDeckCard: View {
    let deck: DeckContent
    let stats: DeckStats

    private var dueTotal: Int { stats.learningDue + stats.reviewDue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DeckAvatarView(deck: deck, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(stats.studyTotal) на сегодня")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }

            HStack(spacing: 10) {
                LovableStat(count: stats.newAvailable, label: "Новые", color: LovableSurface.blueText)
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1, height: 12)
                LovableStat(count: dueTotal, label: "Повторить", color: LovableSurface.amberText)
            }
        }
        .padding(16)
        .lovablePanel(cornerRadius: 24)
    }
}

private struct DeckAvatarView: View {
    let deck: DeckContent
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [oklch(0.8, 0.12, 280), oklch(0.75, 0.15, 310), oklch(0.7, 0.2, 340)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url = deck.avatarImageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: deckSymbol(deck.avatarSystemName))
                            .font(.system(size: size * 0.38, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Image(systemName: deckSymbol(deck.avatarSystemName))
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .shadow(color: oklch(0.5, 0.2, 320, 0.45), radius: 9, x: 0, y: 8)
    }
}

private struct LovableStat: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 4, x: 0, y: 0)
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

private struct ForecastSection: View {
    let days: [ScheduledReviewDay]
    private var maxCount: Int { max(days.map(\.dueCount).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("План на неделю")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(LovableSurface.foreground)

            VStack(spacing: 10) {
                ForEach(days) { day in
                    HStack(spacing: 12) {
                        Text(shortDay(day.dayKey))
                            .font(.system(size: 13, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(oklch(0.82, 0.03, 250, 0.7))
                            .frame(width: 48, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(.white.opacity(0.08))
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [oklch(0.78, 0.14, 235), oklch(0.7, 0.18, 245)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(day.dueCount > 0 ? 6 : 2, proxy.size.width * CGFloat(day.dueCount) / CGFloat(maxCount)))
                                    .shadow(color: day.dueCount > 0 ? oklch(0.7, 0.18, 245, 0.55) : .clear, radius: 6)
                            }
                        }
                        .frame(height: 8)
                        Text("\(day.dueCount)")
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(oklch(0.97, 0.01, 240))
                            .frame(width: 18, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .lovablePanel(cornerRadius: 24)
        }
    }
}

private struct WeakCardsSection: View {
    let cards: [WeakCardStat]
    var onPractice: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Часто забываемые")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Spacer(minLength: 8)
                if cards.count >= 2, let onPractice {
                    Button(action: onPractice) {
                        Text("Играть")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [LovableSurface.primary, LovableSurface.primaryDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .shadow(color: oklch(0.4, 0.22, 260, 0.3), radius: 8, x: 0, y: 5)
                    }
                    .buttonStyle(.plain)
                }
            }

            if cards.isEmpty {
                Text("Пока нет слов для дополнительного повтора.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lovablePanel(cornerRadius: 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(cards) { card in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.word)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(oklch(0.99, 0.01, 240))
                                    .lineLimit(1)
                                Text(card.translation)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(oklch(0.82, 0.03, 250, 0.65))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .lovablePanel(cornerRadius: 20)
                    }
                }
            }
        }
    }
}

private func shortDay(_ dayKey: String) -> String {
    String(dayKey.suffix(5))
}

private func currentStreakDays(from activity: [StudyActivityDay]) -> Int {
    let activeDayKeys = Set(activity.filter { $0.reviewedCount > 0 }.map(\.dayKey))
    guard !activeDayKeys.isEmpty else { return 0 }

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let todayKey = DeckDailyUsage.dayKey(for: today, calendar: calendar)
    let startDate: Date
    if activeDayKeys.contains(todayKey) {
        startDate = today
    } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              activeDayKeys.contains(DeckDailyUsage.dayKey(for: yesterday, calendar: calendar)) {
        startDate = yesterday
    } else {
        return 0
    }

    var streak = 0
    var date = startDate
    while activeDayKeys.contains(DeckDailyUsage.dayKey(for: date, calendar: calendar)) {
        streak += 1
        guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
        date = previous
    }
    return streak
}

private func cardsLabel(_ count: Int) -> String {
    let mod10 = count % 10
    let mod100 = count % 100
    if mod100 >= 11 && mod100 <= 14 {
        return "карточек"
    }
    if mod10 == 1 {
        return "карточка"
    }
    if mod10 >= 2 && mod10 <= 4 {
        return "карточки"
    }
    return "карточек"
}
