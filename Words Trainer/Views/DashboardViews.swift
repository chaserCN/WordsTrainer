import SwiftUI
import OSLog
#if canImport(UIKit)
import UIKit
#endif

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
            // Заранее растеризуем фоны вкладок, чтобы первый переход в колоду/режимы
            // не платил за офскрин-рендер MeshGradient + blur во время анимации.
            LovableBackgroundImageCache.warm([.today, .decks, .stats])
            // И тёмный фон study — иначе первый вход в карточки платит за blur'ы.
            AppBackgroundImageCache.warm()
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
    @State private var todayPracticeCount = 0
    @State private var todayStudyCards: [WordCardContent] = []
    @State private var streakDays = 0
    @State private var showUserSwitcher = false
    @State private var showTodayModes = false
    @State private var toast: AppToast?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var isVisible = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var reloadGeneration = 0
    @State private var lastAppliedReloadGeneration = -1
    @State private var needsReloadWhenVisible = false

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
                reviewDue: partial.reviewDue + stats.reviewDue,
                dueLaterToday: partial.dueLaterToday + stats.dueLaterToday
            )
        }
    }

    var body: some View {
        NavigationStack {
            todayScrollContent
            .refreshable {
                await syncNow()
            }
            .tint(LovableSurface.foreground)
            .background { LovableBackground(variant: .today) }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showTodayModes) { todayModesDestination }
            .sheet(isPresented: $showUserSwitcher) {
                UserSwitcherSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .overlay { loadErrorOverlay }
            .overlay(alignment: .bottom) { toastOverlay }
            .animation(.snappy(duration: 0.22), value: toast)
        }
        .task {
            reloadImmediately()
        }
        .onAppear {
            FrameHitchMonitor.shared.mark("Today dashboard appeared")
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
            store = nil
            storeUserID = nil
            lastAppliedReloadGeneration = -1
            clearToast()
            reloadImmediately()
        }
        .onChange(of: userStore.bootstrapState) { _, state in
            presentToast(forBootstrapState: state)
            if state == .loaded {
                reloadImmediately()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DeckStore.localDataDidChangeNotification)) { _ in
            scheduleLocalDataReload()
        }
        .onChange(of: showTodayModes) { _, isShowing in
            // Returned from the study/modes subtree: apply any reload deferred
            // while it was on top, so the dashboard reflects what was studied.
            if !isShowing, needsReloadWhenVisible {
                needsReloadWhenVisible = false
                reloadImmediately()
            }
        }
    }

    private var todayScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                todayHeaderSection
                contentStatusSection
                studyTodaySection
                todayDecksSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var todayHeaderSection: some View {
        if let selectedUser = userStore.selectedUser {
            TodayHeader(
                user: selectedUser,
                streakDays: streakDays,
                syncStatus: userStore.syncStatus,
                showUserSwitcher: { showUserSwitcher = true },
                sync: { _ = Task { await syncNow() } }
            )
        } else if showsNoUserConnectionCard {
            TodayServerConnectionCard(
                title: noUserTitle,
                systemImage: noUserSystemImage,
                message: noUserMessage
            )
        }
    }

    @ViewBuilder
    private var contentStatusSection: some View {
        if let contentStatus {
            TodaySyncStatusCard(status: contentStatus)
        }
    }

    private var studyTodaySection: some View {
        let stats = totalStats
        return StudyTodayCard(
            stats: stats,
            practiceCount: todayPracticeCount,
            isEnabled: stats.studyTotal > 0 || todayPracticeCount > 0,
            isPrimary: stats.studyTotal > 0,
            action: { showTodayModes = true }
        )
    }

    @ViewBuilder
    private var todayDecksSection: some View {
        if let store, !activeDecksWithStudyToday.isEmpty {
            TodayDeckSummary(decks: activeDecksWithStudyToday, statsByDeckID: statsByDeckID, store: store)
        }
    }

    @ViewBuilder
    private var todayModesDestination: some View {
        if let store {
            let stats = totalStats
            TodayAllDecksModesView(
                store: store,
                queueCount: stats.studyTotal,
                newCount: stats.newAvailable,
                dueCount: stats.learningDue + stats.reviewDue,
                laterCount: stats.dueLaterToday,
                initialPracticeCount: todayPracticeCount,
                initialWordListCards: todayStudyCards
            )
        }
    }

    @ViewBuilder
    private var loadErrorOverlay: some View {
        if let loadError {
            DataPlaceholderView(
                title: "Ошибка",
                systemImage: "exclamationmark.triangle",
                message: loadError
            )
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            AppToastView(toast: toast)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func reload(generation: Int) async {
        do {
            guard let selectedUserID = userStore.selectedUserID else {
                guard reloadGeneration == generation else { return }
                decks = []
                statsByDeckID = [:]
                todayPracticeCount = 0
                todayStudyCards = []
                streakDays = 0
                loadError = nil
                return
            }
            let snapshot = try await DeckStore.todayDashboardSnapshot(userID: selectedUserID)
            // Apply if this result is at least as new as whatever is already
            // painted and the user hasn't changed. Using a monotonic watermark
            // (instead of strict generation equality) lets the initial reload
            // paint local data immediately, even when sync completion kicks off
            // a follow-up reload that bumps the generation — the follow-up then
            // harmlessly repaints the same data instead of leaving an empty gap.
            guard generation >= lastAppliedReloadGeneration,
                  userStore.selectedUserID == selectedUserID else {
                return
            }
            lastAppliedReloadGeneration = generation
            if store == nil || storeUserID != selectedUserID {
                store = try DeckStore(userID: selectedUserID)
                storeUserID = selectedUserID
            }
            decks = snapshot.decks
            statsByDeckID = snapshot.statsByDeckID
            todayPracticeCount = snapshot.todayPracticeCount
            todayStudyCards = snapshot.todayStudyCards
            streakDays = currentStreakDays(from: snapshot.activityDays)
            loadError = nil
        } catch {
            guard reloadGeneration == generation else { return }
            loadError = error.localizedDescription
        }
    }

    private func reloadImmediately() {
        cancelScheduledReload()
        let generation = reloadGeneration
        Task { await reload(generation: generation) }
    }

    private func scheduleLocalDataReload() {
        // Defer while not on screen, or while navigated into the study subtree:
        // a NavigationStack push does not fire .onDisappear on the root, so
        // isVisible stays true during study. Without this, every answer's
        // localDataDidChange would recompute the (hidden) dashboard stats.
        guard isVisible, !showTodayModes else {
            needsReloadWhenVisible = true
            return
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, reloadGeneration == generation else { return }
            await reload(generation: generation)
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

    @MainActor
    private func syncNow() async {
        guard !userStore.syncStatus.isSyncing else { return }
        cancelScheduledReload()
        Self.syncLogger.info("syncNow invoked isSyncing=\(self.userStore.syncStatus.isSyncing, privacy: .public)")
        let result = await userStore.refreshFromServer()
        Self.syncLogger.info("syncNow refresh finished")
        let generation = reloadGeneration
        await reload(generation: generation)
        presentToast(for: result)
    }

    private func presentToast(for result: AppUserRefreshResult) {
        guard let message = result.message else {
            clearToast()
            return
        }
        let duration: Duration = switch result {
        case .loaded:
            .seconds(3.0)
        default:
            .seconds(5.0)
        }
        presentToast(status: TodaySyncStatus(result: result, message: message), autoDismissAfter: duration)
    }

    private func presentToast(forBootstrapState state: AppUserBootstrapState) {
        guard !userStore.syncStatus.isSyncing else { return }
        switch state {
        case .missingConfiguration:
            presentToast(
                status: TodaySyncStatus(
                    title: "Сервер не настроен",
                    message: state.message ?? "Нужно подключить устройство к серверу.",
                    systemImage: "link.badge.plus",
                    tint: oklch(0.64, 0.19, 35)
                ),
                autoDismissAfter: .seconds(5.0)
            )
        case .failed(let message):
            presentToast(
                status: TodaySyncStatus(
                    title: "Синхронизация не удалась",
                    message: message,
                    systemImage: "wifi.exclamationmark",
                    tint: oklch(0.64, 0.19, 35)
                ),
                autoDismissAfter: .seconds(5.0)
            )
        default:
            break
        }
    }

    private func presentToast(status: TodaySyncStatus, autoDismissAfter duration: Duration?) {
        toastDismissTask?.cancel()
        let nextToast = AppToast(
            title: status.title,
            message: status.message,
            systemImage: status.systemImage,
            tint: status.tint
        )
        withAnimation(.snappy(duration: 0.22)) {
            toast = nextToast
        }
        guard let duration else { return }
        toastDismissTask = Task { [id = nextToast.id] in
            try? await Task.sleep(for: duration)
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
    @State private var todayUniqueCardCount = 0
    @State private var todayMatchingAttemptCount = 0
    @State private var weekUniqueCardCount = 0
    @State private var weekMatchingAttemptCount = 0
    @State private var monthUniqueCardCount = 0
    @State private var monthMatchingAttemptCount = 0
    @State private var todayStudyTimeBreakdown: StudyTimeBreakdown = .zero
    @State private var studyDaysCount = 0
    @State private var activityMonths: [ActivityMonth] = []
    @State private var scheduledDays: [ScheduledReviewDay] = []
    @State private var weakCardsPool: [WeakCardStat] = []
    @State private var weakGameSession: StudySession?
    @State private var showWeakGame = false
    @State private var loadError: String?
    @State private var isVisible = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var reloadGeneration = 0
    @State private var needsReloadWhenVisible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StatisticsHeader()

                    StatisticsMetricsGrid(
                        todayCount: todayUniqueCardCount,
                        todayMatchingAttemptCount: todayMatchingAttemptCount,
                        weekCount: weekUniqueCardCount,
                        weekMatchingAttemptCount: weekMatchingAttemptCount,
                        monthCount: monthUniqueCardCount,
                        monthMatchingAttemptCount: monthMatchingAttemptCount,
                        studyDaysCount: studyDaysCount
                    )

                    StudyTimeBreakdownPanel(breakdown: todayStudyTimeBreakdown)
                    ActivityHeatmap(months: activityMonths)
                    ForecastSection(days: scheduledDays)
                    WeakCardsSection(
                        cards: Array(weakCardsPool.prefix(WeakCardsPractice.displayLimit)),
                        onPractice: startWeakGame
                    )

                    AppVersionFooter()
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
            reloadImmediately()
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

    private func reload(generation: Int) async {
        do {
            guard let selectedUserID = userStore.selectedUserID else {
                guard reloadGeneration == generation else { return }
                todayUniqueCardCount = 0
                todayMatchingAttemptCount = 0
                weekUniqueCardCount = 0
                weekMatchingAttemptCount = 0
                monthUniqueCardCount = 0
                monthMatchingAttemptCount = 0
                todayStudyTimeBreakdown = .zero
                studyDaysCount = 0
                activityMonths = []
                scheduledDays = []
                weakCardsPool = []
                loadError = nil
                return
            }
            let snapshot = try await DeckStore.statisticsSnapshot(userID: selectedUserID)
            guard reloadGeneration == generation,
                  userStore.selectedUserID == selectedUserID else { return }
            if store == nil || storeUserID != selectedUserID {
                store = try DeckStore(userID: selectedUserID)
                storeUserID = selectedUserID
            }
            todayUniqueCardCount = snapshot.todayUniqueCardCount
            todayMatchingAttemptCount = snapshot.todayMatchingAttemptCount
            weekUniqueCardCount = snapshot.weekUniqueCardCount
            weekMatchingAttemptCount = snapshot.weekMatchingAttemptCount
            monthUniqueCardCount = snapshot.monthUniqueCardCount
            monthMatchingAttemptCount = snapshot.monthMatchingAttemptCount
            todayStudyTimeBreakdown = snapshot.todayStudyTimeBreakdown
            studyDaysCount = Self.studyDaysCount(from: snapshot.activityDays)
            let maxActivityCount = max(snapshot.activityDays.map(\.reviewedCount).max() ?? 0, 1)
            activityMonths = ActivityCalendarBuilder.months(from: snapshot.activityDays, maxCount: maxActivityCount)
            scheduledDays = snapshot.scheduledDays
            weakCardsPool = snapshot.weakCards
            loadError = nil
        } catch {
            guard reloadGeneration == generation else { return }
            loadError = error.localizedDescription
        }
    }

    private func reloadImmediately() {
        cancelScheduledReload()
        let generation = reloadGeneration
        Task { await reload(generation: generation) }
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
            await reload(generation: generation)
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

    private func startWeakGame() {
        guard let store else { return }
        do {
            guard let session = try store.weakCardsMatchingSession(from: weakCardsPool) else {
                loadError = "Нет забытых слов для упражнения."
                return
            }
            weakGameSession = session
            showWeakGame = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func studyDaysCount(from activity: [StudyActivityDay]) -> Int {
        activity.suffix(30).filter { $0.reviewedCount > 0 }.count
    }
}

private struct AppVersionFooter: View {
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "-"
        return L10n.format("Версия %@ (%@)", version, build)
    }

    var body: some View {
        Text(versionText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.72))
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(versionText)
    }
}

private struct StatisticsPanel: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            // Тень вешаем на фоновую фигуру, а не на весь content: иначе SwiftUI
            // считает размытую тень из всей растеризованной панели (вместе с текстом)
            // и пере-композитит её на каждом кадре скролла. Силуэт-фигура же
            // растеризуется один раз и просто сдвигается. Текст остаётся живым.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                oklch(0.25, 0.04, 265),
                                oklch(0.18, 0.04, 270)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: oklch(0.1, 0.04, 265, 0.14), radius: 8, x: 0, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.05), lineWidth: 0.5)
            }
    }
}

private extension View {
    func statisticsPanel(cornerRadius: CGFloat = 24) -> some View {
        modifier(StatisticsPanel(cornerRadius: cornerRadius))
    }
}

private struct TodayHeader: View {
    let user: AppUser
    let streakDays: Int
    let syncStatus: AppUserSyncStatus
    let showUserSwitcher: () -> Void
    let sync: () -> Void

    private var isSyncing: Bool {
        syncStatus.isSyncing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            UserAvatarButton(user: user, streakDays: streakDays, action: showUserSwitcher)

            Text(user.displayName)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(LovableSurface.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 12)

            Button(action: sync) {
                ZStack {
                    if isSyncing {
                        SyncProgressIndicator(progress: syncStatus.progress)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LovableSurface.foreground)
                    }
                }
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
            .disabled(isSyncing)
            .opacity(isSyncing ? 0.72 : 1)
            .accessibilityLabel(L10n.text(isSyncing ? "Синхронизация выполняется" : "Синхронизировать"))
            .accessibilityValue(syncStatus.progress?.title ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncProgressIndicator: View {
    let progress: AppUserSyncProgress?

    private var fractionCompleted: Double? {
        progress?.fractionCompleted
    }

    private var percentText: String {
        guard let fractionCompleted else { return "" }
        return "\(Int((fractionCompleted * 100).rounded()))"
    }

    var body: some View {
        ZStack {
            if let fractionCompleted {
                Circle()
                    .stroke(LovableSurface.foreground.opacity(0.22), lineWidth: 3)
                    .frame(width: 25, height: 25)

                Circle()
                    .trim(from: 0, to: fractionCompleted)
                    .stroke(
                        LovableSurface.foreground,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 25, height: 25)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.18), value: fractionCompleted)

                Text(percentText)
                    .font(.system(size: percentText.count >= 3 ? 7.5 : 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LovableSurface.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .frame(width: 23, height: 10)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(LovableSurface.foreground)
            }
        }
        .accessibilityHidden(true)
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

private struct StatisticsMetricsGrid: View {
    let todayCount: Int
    let todayMatchingAttemptCount: Int
    let weekCount: Int
    let weekMatchingAttemptCount: Int
    let monthCount: Int
    let monthMatchingAttemptCount: Int
    let studyDaysCount: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DashboardMetric(
                    title: "Сегодня",
                    value: "\(todayCount)",
                    subtitle: LocalizedCounts.wordWord(for: todayCount),
                    secondaryValue: "\(todayMatchingAttemptCount)",
                    secondarySubtitle: LocalizedCounts.gameWord(for: todayMatchingAttemptCount)
                )
                DashboardMetric(
                    title: "7 дней",
                    value: "\(weekCount)",
                    subtitle: LocalizedCounts.wordWord(for: weekCount),
                    secondaryValue: "\(weekMatchingAttemptCount)",
                    secondarySubtitle: LocalizedCounts.gameWord(for: weekMatchingAttemptCount)
                )
            }

            HStack(spacing: 12) {
                DashboardMetric(
                    title: "30 дней",
                    value: "\(monthCount)",
                    subtitle: LocalizedCounts.wordWord(for: monthCount),
                    secondaryValue: "\(monthMatchingAttemptCount)",
                    secondarySubtitle: LocalizedCounts.gameWord(for: monthMatchingAttemptCount)
                )
                DashboardMetric(title: "Дни занятий", value: "\(studyDaysCount)", subtitle: LocalizedCounts.daysPeriod(30))
            }
        }
    }
}

private struct StudyTimeBreakdownPanel: View {
    let breakdown: StudyTimeBreakdown

    private var rows: [StudyTimeBreakdownRow] {
        [
            StudyTimeBreakdownRow(
                title: "Карточки",
                milliseconds: breakdown.flashcardsMilliseconds,
                tint: oklch(0.71, 0.16, 145)
            ),
            StudyTimeBreakdownRow(
                title: "Предложения",
                milliseconds: breakdown.sentenceMilliseconds,
                tint: oklch(0.72, 0.16, 35)
            ),
            StudyTimeBreakdownRow(
                title: "Колонки",
                milliseconds: breakdown.matchingMilliseconds,
                tint: oklch(0.72, 0.17, 250)
            ),
            StudyTimeBreakdownRow(
                title: "Колонки аудио",
                milliseconds: breakdown.matchingAudioMilliseconds,
                tint: oklch(0.76, 0.14, 315)
            ),
        ]
    }

    private var maxMilliseconds: Int {
        max(rows.map(\.milliseconds).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Время занятий сегодня")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(oklch(0.99, 0.01, 240))

                Spacer(minLength: 10)

                Text(studyDurationLabel(milliseconds: breakdown.totalMilliseconds))
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(oklch(0.99, 0.01, 240))
            }

            VStack(spacing: 12) {
                ForEach(rows) { row in
                    StudyTimeRow(row: row, maxMilliseconds: maxMilliseconds)
                }
            }
        }
        .padding(18)
        .statisticsPanel(cornerRadius: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Время занятий сегодня")
        .accessibilityValue(studyDurationLabel(milliseconds: breakdown.totalMilliseconds))
    }
}

private struct StudyTimeBreakdownRow: Identifiable {
    let title: String
    let milliseconds: Int
    let tint: Color

    var id: String { title }
}

private struct StudyTimeRow: View {
    let row: StudyTimeBreakdownRow
    let maxMilliseconds: Int

    private var fraction: CGFloat {
        guard maxMilliseconds > 0 else { return 0 }
        return CGFloat(row.milliseconds) / CGFloat(maxMilliseconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.text(row.title))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(oklch(0.82, 0.03, 250, 0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                Text(studyDurationLabel(milliseconds: row.milliseconds))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(oklch(0.99, 0.01, 240))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.08))

                    if row.milliseconds > 0 {
                        Capsule()
                            .fill(row.tint.opacity(0.9))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                }
            }
            .frame(height: 7)
            // Кэшируем полоску в текстуру, чтобы при скролле не пере-композитить
            // слои капсул каждый кадр; текст строки остаётся живым.
            .drawingGroup()
        }
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
                Text(L10n.text(title))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Text(L10n.text(message ?? "Загружаем профиль с сервера."))
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
        case .loadedWithMediaWarnings:
            self.init(
                title: "Часть медиа не скачалась",
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: oklch(0.64, 0.19, 35)
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

    init?(syncStatus: AppUserSyncStatus) {
        switch syncStatus.phase {
        case .idle, .completed:
            return nil
        case .syncing:
            self.init(
                title: "Синхронизация",
                message: syncStatus.progress?.title ?? "Проверяем сервер и загружаем данные выбранного пользователя.",
                systemImage: "arrow.clockwise",
                tint: LovableSurface.primary
            )
        case .warning, .blocked, .failed, .cancelled:
            guard let result = syncStatus.result,
                  let message = result.message else { return nil }
            self.init(result: result, message: message)
        }
    }

    static func == (lhs: TodaySyncStatus, rhs: TodaySyncStatus) -> Bool {
        lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.systemImage == rhs.systemImage
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
                Text(L10n.text(status.title))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Text(L10n.text(status.message))
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
            UserAvatar(user: user, size: 64)
                .overlay(alignment: .bottomTrailing) {
                    if streakDays > 3 {
                        StreakBadge(days: streakDays)
                            .offset(x: 4, y: 4)
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
            Circle()
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
                UserAvatarImage(url: url, initials: user.initials, size: size)
            } else {
                Text(user.initials)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.white.opacity(0.92), lineWidth: 2)
        }
        .shadow(color: oklch(0.18, 0.05, 260, 0.16), radius: 12, x: 0, y: 7)
    }
}

private struct UserAvatarImage: View {
    let url: URL
    let initials: String
    let size: CGFloat

    var body: some View {
        Group {
            #if canImport(UIKit)
            if url.isFileURL, let image = UserAvatarImageCache.image(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                remoteImage
            }
            #else
            remoteImage
            #endif
        }
    }

    private var remoteImage: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                initialsFallback
            }
        }
    }

    private var initialsFallback: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white)
    }
}

#if canImport(UIKit)
@MainActor
private enum UserAvatarImageCache {
    private static var images: [URL: UIImage] = [:]

    static func image(for url: URL) -> UIImage? {
        if let image = images[url] {
            return image
        }
        guard let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        images[url] = image
        return image
    }
}
#endif

private struct StreakBadge: View {
    let days: Int

    private var horizontalPadding: CGFloat {
        days >= 10 ? 5 : 0
    }

    private var intensity: Double {
        min(1, max(0, Double(days - 1) / 13))
    }

    private var badgeFill: Color {
        // Pink at a low streak shifting toward violet as it grows:
        // hue 350 (pink) -> 300 (violet).
        oklch(
            0.70 - 0.06 * intensity,
            0.18 + 0.05 * intensity,
            350 - 50 * intensity
        )
    }

    private var badgeShadow: Color {
        oklch(
            0.44 - 0.05 * intensity,
            0.10 + 0.03 * intensity,
            340 - 45 * intensity,
            0.45
        )
    }

    var body: some View {
        Text("\(days)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: 22, minHeight: 22)
            .foregroundStyle(.white)
            .background(
                badgeFill,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.96), lineWidth: 2)
            }
            .shadow(color: badgeShadow, radius: 4, x: 0, y: 3)
            .accessibilityLabel(LocalizedCounts.dayStreak(days))
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
                        description: Text(L10n.text(userStore.bootstrapState.message ?? "Выполните синхронизацию с сервером."))
                    )
                } else {
                    Section {
                        ForEach(userStore.users) { user in
                            Button {
                                Task {
                                    await userStore.selectAndRefresh(user)
                                }
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Выбрать пользователя")
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
    var practiceCount: Int = 0
    let isEnabled: Bool
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Учить по плану")
                        .font(.system(size: 24, weight: .bold))
                    Text(L10n.text(subtitle))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isPrimary ? 0.72 : 0.6))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(isEnabled ? 0.4 : 0.18))
            }
            .foregroundStyle(.white.opacity(isPrimary ? 1 : 0.72))
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .padding(.vertical, 24)
            .background(
                LinearGradient(
                    colors: [
                        LovableSurface.primary.opacity(isPrimary ? 1 : 0.42),
                        LovableSurface.primaryDeep.opacity(isPrimary ? 1 : 0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .shadow(color: oklch(0.4, 0.22, 260, isPrimary ? 0.35 : 0), radius: 18, x: 0, y: 14)
    }

    private var subtitle: String {
        if stats.studyTotal > 0 {
            return LocalizedCounts.cardsInQueue(stats.studyTotal)
        }
        if practiceCount > 0 {
            return L10n.format("Пока всё · можно повторить %@", LocalizedCounts.cardsForPractice(practiceCount))
        }
        return L10n.text("Пока всё")
    }
}

private struct TodayStudyModesView: View {
    let queueCount: Int
    var newCount: Int = 0
    var dueCount: Int = 0
    var laterCount: Int = 0
    var practiceCount: Int = 0
    var deck: DeckContent? = nil
    var wordListCards: [WordCardContent] = []
    var navigationTitle: String? = nil
    var summaryTitle: String? = nil
    var summaryText: String? = nil
    var summarySystemImage: String? = nil
    var showsSummaryStats = true
    let start: (StudyMode) -> Void

    private var canStart: Bool {
        queueCount > 0 || practiceCount > 0
    }

    private var canShowWordList: Bool {
        !wordListCards.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if canShowWordList {
                    NavigationLink {
                        WordListView(
                            title: "Слова",
                            cards: wordListCards,
                            emptyMessage: "Пока нет слов.",
                            backgroundVariant: .today
                        )
                    } label: {
                        QueueSummaryCard(
                            queueCount: queueCount,
                            newCount: newCount,
                            dueCount: dueCount,
                            laterCount: laterCount,
                            practiceCount: practiceCount,
                            deck: deck,
                            title: summaryTitle,
                            summaryText: summaryText,
                            systemImage: summarySystemImage,
                            showsStats: showsSummaryStats,
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    QueueSummaryCard(
                        queueCount: queueCount,
                        newCount: newCount,
                        dueCount: dueCount,
                        laterCount: laterCount,
                        practiceCount: practiceCount,
                        deck: deck,
                        title: summaryTitle,
                        summaryText: summaryText,
                        systemImage: summarySystemImage,
                        showsStats: showsSummaryStats
                    )
                }

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
                        isEnabled: canStart
                    ) {
                        start(.flashcards)
                    }

                    TodayModeButton(
                        title: "Предложения",
                        subtitle: "Выбери слово для примера с пропуском",
                        systemImage: "text.quote",
                        accent: .blue,
                        isEnabled: canStart
                    ) {
                        start(.clozeMultipleChoice)
                    }

                    TodayModeButton(
                        title: "Колонки",
                        subtitle: "Соедини слово и перевод",
                        systemImage: "rectangle.split.2x1.fill",
                        accent: .green,
                        isEnabled: canStart
                    ) {
                        start(.matching)
                    }

                    TodayModeButton(
                        title: "Колонки аудио",
                        subtitle: "Слушай слово и выбирай перевод",
                        systemImage: "speaker.wave.2.fill",
                        accent: .cyan,
                        isEnabled: canStart
                    ) {
                        start(.matchingAudio)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background { LovableBackground(variant: .today) }
        .navigationTitle(navigationTitle ?? deck?.title ?? L10n.text("Сегодня"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
        .tint(LovableSurface.foreground)
    }
}

struct RandomAllDecksModesView: View {
    let store: DeckStore
    let title: String
    let deckIDs: Set<UUID>?

    @State private var cards: [WordCardContent]
    @State private var session: StudySession?
    @State private var showStudy = false
    @State private var loadError: String?
    @State private var toast: AppToast?
    @State private var toastDismissTask: Task<Void, Never>?

    init(
        store: DeckStore,
        initialCards: [WordCardContent],
        title: String = RandomStudySessionBuilder.title,
        deckIDs: Set<UUID>? = nil
    ) {
        self.store = store
        self.title = title
        self.deckIDs = deckIDs
        _cards = State(initialValue: initialCards)
    }

    var body: some View {
        TodayStudyModesView(
            queueCount: cards.count,
            wordListCards: cards,
            navigationTitle: title,
            summaryTitle: title,
            summaryText: LocalizedCounts.randomCards(cards.count),
            summarySystemImage: "shuffle",
            showsSummaryStats: false,
            start: start
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: regenerateCards) {
                    Image(systemName: "die.face.5")
                        .foregroundStyle(LovableSurface.foreground)
                }
                .accessibilityLabel(L10n.text("Перегенерировать"))
            }
        }
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.snappy(duration: 0.22), value: toast)
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: title)
            }
        }
        .alert("Не удалось начать упражнение", isPresented: loadErrorBinding) {
            Button("ОК", role: .cancel) {
                loadError = nil
            }
        } message: {
            Text(loadError ?? "")
        }
        .onDisappear {
            clearRegeneratedToast()
        }
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { loadError != nil },
            set: { isPresented in
                if !isPresented { loadError = nil }
            }
        )
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            AppToastView(toast: toast)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func regenerateCards() {
        do {
            let refreshedCards = if let deckIDs {
                try store.randomStudyCards(deckIDs: deckIDs)
            } else {
                try store.randomStudyCards()
            }
            guard !refreshedCards.isEmpty else {
                loadError = "Нет карточек для этого упражнения."
                return
            }
            session = nil
            withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                cards = refreshedCards
            }
            presentRegeneratedToast(cardCount: refreshedCards.count)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func presentRegeneratedToast(cardCount: Int) {
        toastDismissTask?.cancel()
        let nextToast = AppToast(
            title: L10n.text("Карточки обновлены"),
            message: LocalizedCounts.randomCards(cardCount),
            systemImage: "die.face.5",
            tint: LovableSurface.primary
        )
        withAnimation(.snappy(duration: 0.22)) {
            toast = nextToast
        }
        toastDismissTask = Task { [id = nextToast.id] in
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run {
                guard toast?.id == id else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    toast = nil
                }
            }
        }
    }

    private func clearRegeneratedToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toast = nil
    }

    private func start(_ mode: StudyMode) {
        do {
            if let deckIDs {
                session = try store.startRandomCardsSession(cards: cards, deckIDs: deckIDs, mode: mode)
            } else {
                session = try store.startRandomCardsSession(cards: cards, mode: mode)
            }
            guard session != nil else {
                loadError = "Нет карточек для этого упражнения."
                return
            }
            showStudy = true
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Экран режимов для общей очереди на сегодня.
/// Учебная сессия пушится отсюда, поэтому Back возвращает на выбор упражнения.
private struct TodayAllDecksModesView: View {
    let store: DeckStore

    // The top card's counts must update after returning from study, so they are
    // @State (seeded from the parent's values) and refreshed by reloadPracticeCount
    // — not immutable lets, which kept stale numbers until a full re-entry.
    @State private var queueCount: Int
    @State private var newCount: Int
    @State private var dueCount: Int
    @State private var laterCount: Int

    @State private var session: StudySession?
    @State private var sessionDeckTitle = ""
    @State private var showStudy = false
    @State private var practiceCount: Int
    @State private var wordListCards: [WordCardContent]
    @State private var loadError: String?
    @State private var isVisible = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var reloadGeneration = 0
    @State private var needsReloadWhenVisible = false

    init(
        store: DeckStore,
        queueCount: Int,
        newCount: Int,
        dueCount: Int,
        laterCount: Int,
        initialPracticeCount: Int,
        initialWordListCards: [WordCardContent]
    ) {
        self.store = store
        _queueCount = State(initialValue: queueCount)
        _newCount = State(initialValue: newCount)
        _dueCount = State(initialValue: dueCount)
        _laterCount = State(initialValue: laterCount)
        _practiceCount = State(initialValue: initialPracticeCount)
        _wordListCards = State(initialValue: initialWordListCards)
    }

    var body: some View {
        TodayStudyModesView(
            queueCount: queueCount,
            newCount: newCount,
            dueCount: dueCount,
            laterCount: laterCount,
            practiceCount: practiceCount,
            wordListCards: wordListCards,
            start: start
        )
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: sessionDeckTitle)
            }
        }
        .alert("Не удалось начать упражнение", isPresented: loadErrorBinding) {
            Button("ОК", role: .cancel) {
                loadError = nil
            }
        } message: {
            Text(loadError ?? "")
        }
        .onAppear {
            isVisible = true
            if needsReloadWhenVisible {
                needsReloadWhenVisible = false
                scheduleLocalDataReload()
            } else if wordListCards.isEmpty {
                // The parent may navigate here with empty initialWordListCards
                // (the dashboard loads them lazily after the lite snapshot). Load
                // the word list on open so "просмотр карт" is not empty.
                reloadPracticeCountImmediately()
            }
        }
        .onDisappear {
            isVisible = false
            cancelScheduledReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: DeckStore.localDataDidChangeNotification)) { _ in
            scheduleLocalDataReload()
        }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            reloadPracticeCountImmediately()
        }
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { loadError != nil },
            set: { isPresented in
                if !isPresented { loadError = nil }
            }
        )
    }

    private func start(_ mode: StudyMode) {
        do {
            if let todaySession = try store.startTodaySession(mode: mode) {
                sessionDeckTitle = TodayStudySessionBuilder.title
                session = todaySession
            } else if let practiceSession = try store.startTodayPracticeSession(mode: mode) {
                sessionDeckTitle = TodayStudySessionBuilder.practiceTitle
                session = practiceSession
            } else {
                return
            }
            showStudy = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadPracticeCountImmediately() {
        cancelScheduledReload()
        let generation = reloadGeneration
        Task { await reloadPracticeCount(generation: generation) }
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
            await reloadPracticeCount(generation: generation)
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

    private func reloadPracticeCount(generation: Int) async {
        guard let snapshot = try? await DeckStore.todayDashboardSnapshot(userID: store.currentUserID) else {
            guard reloadGeneration == generation else { return }
            practiceCount = 0
            wordListCards = []
            return
        }
        guard reloadGeneration == generation else { return }
        practiceCount = snapshot.todayPracticeCount
        // Refresh the top card's counts from the fresh snapshot so the queue
        // tile reflects what was just studied (matches TodayView's aggregation).
        let totals = snapshot.statsByDeckID.values.reduce(DeckStats.zero) { partial, s in
            DeckStats(
                newAvailable: partial.newAvailable + s.newAvailable,
                learningDue: partial.learningDue + s.learningDue,
                reviewDue: partial.reviewDue + s.reviewDue,
                dueLaterToday: partial.dueLaterToday + s.dueLaterToday
            )
        }
        queueCount = totals.studyTotal
        newCount = totals.newAvailable
        dueCount = totals.learningDue + totals.reviewDue
        laterCount = totals.dueLaterToday
        // Build the word-list OFF the main thread to avoid frame hitches when the
        // screen appears: snapshot the warm cache here (MainActor), then assemble
        // queue + content in a detached task. Falls back to DB for cold decks.
        let cachedCards = StudyCardCache.shared.snapshot(userID: store.currentUserID)
        let fullCards: [WordCardContent]
        do {
            fullCards = try await DeckStore.todayWordListSnapshot(userID: store.currentUserID, cachedCards: cachedCards)
        } catch {
            Log.log("WordList", "all-decks load FAILED: \(error.localizedDescription)")
            fullCards = []
        }
        guard reloadGeneration == generation else { return }
        Log.log("WordList", "Today (all decks): showing \(fullCards.count) cards in the card-preview list")
        wordListCards = fullCards
    }
}

/// Экран режимов для конкретной колоды на вкладке «Сегодня».
/// Учим только сегодняшнюю очередь этой колоды.
private struct TodayDeckModesView: View {
    let deck: DeckContent
    let store: DeckStore

    @State private var stats: DeckStats = .zero
    @State private var practiceCount = 0
    @State private var wordListCards: [WordCardContent] = []
    @State private var session: StudySession?
    @State private var showStudy = false
    @State private var loadError: String?

    var body: some View {
        TodayStudyModesView(
            queueCount: stats.studyTotal,
            newCount: stats.newAvailable,
            dueCount: stats.learningDue + stats.reviewDue,
            laterCount: stats.dueLaterToday,
            practiceCount: practiceCount,
            deck: deck,
            wordListCards: wordListCards,
            start: start
        )
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: deck.title)
            }
        }
        .task { await reload() }
        .alert("Не удалось начать упражнение", isPresented: loadErrorBinding) {
            Button("ОК", role: .cancel) {
                loadError = nil
            }
        } message: {
            Text(loadError ?? "")
        }
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            Task { await reload() }
        }
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { loadError != nil },
            set: { isPresented in
                if !isPresented { loadError = nil }
            }
        )
    }

    private func reload() async {
        guard let snapshot = try? await DeckStore.todayDashboardSnapshot(userID: store.currentUserID) else {
            stats = .zero
            practiceCount = 0
            wordListCards = []
            return
        }
        let deckID = deck.id
        stats = snapshot.statsByDeckID[deckID] ?? .zero
        practiceCount = snapshot.todayPracticeCountByDeckID[deckID] ?? 0
        // Word-list built off the main thread (cache snapshot + detached assembly).
        let cachedCards = StudyCardCache.shared.snapshot(userID: store.currentUserID)
        wordListCards = (try? await DeckStore.todayWordListSnapshot(userID: store.currentUserID, deckID: deckID, cachedCards: cachedCards)) ?? []
    }

    private func start(_ mode: StudyMode) {
        do {
            if stats.studyTotal > 0 {
                session = try store.startTodaySession(deck: deck, mode: mode)
            } else {
                session = try store.startTodayPracticeSession(deck: deck, mode: mode)
            }
            guard session != nil else {
                loadError = "Нет карточек для этого упражнения."
                return
            }
            showStudy = true
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct QueueSummaryCard: View {
    let queueCount: Int
    let newCount: Int
    let dueCount: Int
    let laterCount: Int
    var practiceCount: Int = 0
    var deck: DeckContent? = nil
    var title: String? = nil
    var summaryText: String? = nil
    var systemImage: String? = nil
    var showsStats = true
    var showsChevron: Bool = false

    private var isPrimary: Bool {
        queueCount > 0
    }

    private var todayDayNumber: String {
        "\(Calendar.current.component(.day, from: .now))"
    }

    private var todayMonthShort: String {
        Self.monthFormatter.string(from: .now)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("LLL")
        return formatter
    }()

    @ViewBuilder private var deckOrDateAvatar: some View {
        if let deck {
            DeckAvatarView(deck: deck, size: 56)
        } else if let systemImage {
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
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: oklch(0.4, 0.22, 260, 0.28), radius: 12, x: 0, y: 8)
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
                    Text(title ?? deck?.title ?? L10n.text("Дневная очередь"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white.opacity(isPrimary ? 1 : 0.72))
                        .lineLimit(1)
                    Text(effectiveSummaryText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(isPrimary ? 0.55 : 0.45))
                }

                Spacer(minLength: 0)
            }

            if showsStats {
                HStack(spacing: 10) {
                    LovableStat(count: newCount, label: "Новые", color: LovableSurface.blueText)
                    Rectangle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 1, height: 12)
                    LovableStat(count: dueCount, label: "Повторить", color: LovableSurface.amberText)
                    if laterCount > 0 {
                        Rectangle()
                            .fill(.white.opacity(0.1))
                            .frame(width: 1, height: 12)
                        LovableStat(count: laterCount, label: "Позже", color: oklch(0.74, 0.1, 285))
                    }
                }
            }
        }
        .padding(16)
        .padding(.trailing, showsChevron ? 24 : 0)
        .overlay(alignment: .trailing) {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(isPrimary ? 0.4 : 0.24))
                    .padding(.trailing, 16)
            }
        }
        .lovablePanel(cornerRadius: 24)
        .opacity(isPrimary ? 1 : 0.62)
    }

    private var effectiveSummaryText: String {
        if let summaryText {
            return summaryText
        }
        if queueCount == 0, practiceCount > 0 {
            return L10n.format("Очередь закончена · %@", LocalizedCounts.cardsForPractice(practiceCount))
        }
        return LocalizedCounts.cardPhrase(queueCount)
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
                    Text(L10n.text(title))
                        .font(.system(size: 16, weight: .bold))
                    Text(L10n.text(subtitle))
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
    var detail: String? = nil
    var secondaryValue: String? = nil
    var secondarySubtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(title))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(oklch(0.82, 0.03, 250, 0.7))
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
            HStack(alignment: .top, spacing: 12) {
                if let secondaryValue, let secondarySubtitle {
                    DashboardMetricValue(value: value, subtitle: subtitle, isCentered: true)
                        .frame(maxWidth: .infinity)
                    DashboardMetricValue(value: secondaryValue, subtitle: secondarySubtitle, isCentered: true)
                        .frame(maxWidth: .infinity)
                } else {
                    DashboardMetricValue(value: value, subtitle: subtitle, isCentered: true)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            Text(detail.map { L10n.text($0) } ?? " ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(oklch(0.82, 0.03, 250, detail == nil ? 0 : 0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statisticsPanel(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

private struct DashboardMetricValue: View {
    let value: String
    let subtitle: String
    var isCentered = false

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(oklch(0.99, 0.01, 240))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .multilineTextAlignment(isCentered ? .center : .leading)
            Text(L10n.text(subtitle))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(oklch(0.82, 0.03, 250, 0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(isCentered ? .center : .leading)
        }
    }
}

private struct ActivityHeatmap: View {
    let months: [ActivityMonth]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Активность")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(LocalizedCounts.monthPhraseShort(months.count))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(months) { month in
                        ActivityMonthView(month: month)
                            .equatable()
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultScrollAnchor(.trailing)
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .statisticsPanel(cornerRadius: 24)
    }

}

private struct ActivityMonthView: View, Equatable {
    let month: ActivityMonth

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(month.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))

            Grid(horizontalSpacing: 6, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(month.weekdays.enumerated()), id: \.offset) { _, weekday in
                        Text(weekday)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.34))
                            .frame(width: 18, height: 10)
                    }
                }

                ForEach(month.weeks) { week in
                    GridRow {
                        ForEach(week.cells) { cell in
                            if let day = cell.day {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(day.fillColor)
                                    .frame(width: 15, height: 15)
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        if day.isToday {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(day.todayStrokeColor, lineWidth: 1.5)
                                                .frame(width: 15, height: 15)
                                                .shadow(color: day.todayGlowColor, radius: 5)
                                        }
                                    }
                                    .accessibilityLabel(day.accessibilityLabel)
                            } else {
                                Color.clear
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 162, alignment: .leading)
        // Десятки прямоугольников на месяц — это десятки слоёв, которые GPU
        // композитит каждый кадр при скролле. Расплющиваем сетку месяца в одну
        // закэшированную текстуру; она перерисовывается только когда меняется
        // сам месяц (т.е. при обновлении статистики), а не при прокрутке.
        .drawingGroup()
        // drawingGroup растеризует поддерево и теряет per-cell метки VoiceOver,
        // поэтому отдаём сводку по месяцу одним элементом.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let totalCards = month.weeks
            .flatMap(\.cells)
            .compactMap(\.day)
            .reduce(0) { $0 + $1.reviewedCount }
        return "\(month.title): \(LocalizedCounts.cardPhrase(totalCards))"
    }
}

private enum ActivityHeatmapPalette {
    static let empty = oklch(0.32, 0.02, 265, 0.5)
    static let low = oklch(0.55, 0.1, 235, 0.55)
    static let medium = oklch(0.65, 0.15, 235, 0.75)
    static let high = oklch(0.72, 0.18, 235, 0.9)
    static let peak = oklch(0.8, 0.2, 235)
    static let todayGlow = oklch(0.7, 0.18, 235, 0.6)
    static let todayIdleStroke = oklch(0.9, 0.02, 250, 0.62)
    static let todayActiveStroke = oklch(0.97, 0.01, 240, 0.92)
}

private enum ActivityHeatmapLevel: Hashable {
    case empty
    case low
    case medium
    case high
    case peak

    var color: Color {
        switch self {
        case .empty: ActivityHeatmapPalette.empty
        case .low: ActivityHeatmapPalette.low
        case .medium: ActivityHeatmapPalette.medium
        case .high: ActivityHeatmapPalette.high
        case .peak: ActivityHeatmapPalette.peak
        }
    }
}

private struct ActivityMonth: Identifiable, Hashable {
    let id: String
    let title: String
    let weekdays: [String]
    let weeks: [ActivityCalendarWeek]
}

private struct ActivityCalendarWeek: Identifiable, Hashable {
    let id: String
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
    let level: ActivityHeatmapLevel
    let accessibilityLabel: String

    var fillColor: Color {
        level.color
    }

    var todayStrokeColor: Color {
        reviewedCount > 0 ? ActivityHeatmapPalette.todayActiveStroke : ActivityHeatmapPalette.todayIdleStroke
    }

    var todayGlowColor: Color {
        reviewedCount > 0 ? ActivityHeatmapPalette.todayGlow : .clear
    }
}

private enum ActivityCalendarBuilder {
    static func months(from days: [StudyActivityDay], maxCount: Int) -> [ActivityMonth] {
        let calendar = Calendar.current
        let today = StudyDay.start(for: .now, calendar: calendar)
        let todayKey = StudyDay.key(calendar: calendar)
        let byKey = Dictionary(uniqueKeysWithValues: days.map { ($0.dayKey, $0.reviewedCount) })
        let startDate = days.first.flatMap { dateFromDayKey($0.dayKey) } ?? today
        let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start ?? startDate
        let currentMonthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        var months: [ActivityMonth] = []
        var date = monthStart

        while date <= currentMonthStart {
            months.append(month(for: date, todayKey: todayKey, countsByKey: byKey, maxCount: maxCount, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: date) else { break }
            date = next
        }

        return months
    }

    private static func month(
        for monthStart: Date,
        todayKey: String,
        countsByKey: [String: Int],
        maxCount: Int,
        calendar: Calendar
    ) -> ActivityMonth {
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<1
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingSlots = (firstWeekday - calendar.firstWeekday + 7) % 7
        let monthKey = DeckDailyUsage.calendarDayKey(for: monthStart, calendar: calendar)
        var cells = (0..<leadingSlots).map { ActivityCalendarCell(id: "\(monthKey)-blank-\($0)", day: nil) }

        for dayNumber in dayRange {
            guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: monthStart) else { continue }
            let key = DeckDailyUsage.calendarDayKey(for: date, calendar: calendar)
            let reviewedCount = countsByKey[key, default: 0]
            let day = ActivityCalendarDay(
                dayKey: key,
                reviewedCount: reviewedCount,
                isToday: key == todayKey,
                level: level(for: reviewedCount, maxCount: maxCount),
                accessibilityLabel: "\(key): \(LocalizedCounts.cardPhrase(reviewedCount))"
            )
            cells.append(ActivityCalendarCell(id: key, day: day))
        }
        let trailingSlots = (7 - cells.count % 7) % 7
        if trailingSlots > 0 {
            cells.append(contentsOf: (0..<trailingSlots).map {
                ActivityCalendarCell(id: "\(monthKey)-trailing-\($0)", day: nil)
            })
        }

        return ActivityMonth(
            id: monthKey,
            title: title(for: monthStart),
            weekdays: weekdaySymbols(calendar: calendar),
            weeks: weeks(from: cells, monthKey: monthKey)
        )
    }

    private static let weekdaySymbolsByFirstWeekday: [Int: [String]] = {
        let formatter = DateFormatter()
        formatter.locale = .current
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return Dictionary(uniqueKeysWithValues: (1...7).map { firstWeekday in
            let start = firstWeekday - 1
            return (firstWeekday, Array(symbols[start...] + symbols[..<start]))
        })
    }()
    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter
    }()
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        weekdaySymbolsByFirstWeekday[calendar.firstWeekday] ?? weekdaySymbolsByFirstWeekday[1] ?? []
    }

    private static func title(for date: Date) -> String {
        monthTitleFormatter.string(from: date)
    }

    private static func dateFromDayKey(_ dayKey: String) -> Date? {
        dayKeyFormatter.date(from: dayKey)
    }

    private static func weeks(from cells: [ActivityCalendarCell], monthKey: String) -> [ActivityCalendarWeek] {
        stride(from: 0, to: cells.count, by: 7).map { start in
            let end = min(start + 7, cells.count)
            return ActivityCalendarWeek(id: "\(monthKey)-week-\(start / 7)", cells: Array(cells[start..<end]))
        }
    }

    private static func level(for count: Int, maxCount: Int) -> ActivityHeatmapLevel {
        guard count > 0 else { return .empty }
        let ratio = Double(count) / Double(max(maxCount, 1))
        switch ratio {
        case ..<0.25: return .low
        case ..<0.5: return .medium
        case ..<0.75: return .high
        default: return .peak
        }
    }
}

private struct TodayDeckSummary: View {
    let decks: [DeckContent]
    let statsByDeckID: [UUID: DeckStats]
    let store: DeckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Карточки за сегодня по колодам")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LovableSurface.foreground)
                .lineLimit(2)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    DeckAvatarView(deck: deck, size: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(deck.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(LocalizedCounts.cardsToday(stats.studyTotal))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                HStack(spacing: 10) {
                    LovableStat(count: stats.newAvailable, label: "Новые", color: LovableSurface.blueText)
                    Rectangle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 1, height: 12)
                    LovableStat(count: dueTotal, label: "Повторить", color: LovableSurface.amberText)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
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
                .fill(DeckAvatarPalette(seed: deck.id.uuidString).gradient)

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
        .shadow(color: DeckAvatarPalette(seed: deck.id.uuidString).shadowColor, radius: 9, x: 0, y: 8)
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
            Text(L10n.text(label))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct ForecastSection: View {
    let days: [ScheduledReviewDay]
    private var maxCount: Int { max(days.map(\.dueCount).max() ?? 0, 1) }
    private var countColumnLabel: String { "\(days.map(\.dueCount).max() ?? 0)" }

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
                        // Полоска с тенью двигается вместе со скроллом и пере-композитится
                        // каждый кадр. Кэшируем её в текстуру — текст слева/справа остаётся
                        // живым и доступным VoiceOver.
                        .drawingGroup()
                        ZStack(alignment: .trailing) {
                            Text(countColumnLabel)
                                .hidden()
                            Text("\(day.dueCount)")
                                .lineLimit(1)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(oklch(0.97, 0.01, 240))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(16)
            .statisticsPanel(cornerRadius: 24)
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
                    .statisticsPanel(cornerRadius: 20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        WeakCardStatRow(
                            card: card,
                            position: rowPosition(index: index, count: cards.count)
                        )
                    }
                }
            }
        }
    }

    private func rowPosition(index: Int, count: Int) -> WeakCardStatRow.Position {
        if count == 1 { return .single }
        if index == 0 { return .top }
        if index == count - 1 { return .bottom }
        return .middle
    }
}

private struct WeakCardStatRow: View {
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

    let card: WeakCardStat
    let position: Position

    var body: some View {
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

private func shortDay(_ dayKey: String) -> String {
    String(dayKey.suffix(5))
}

private func currentStreakDays(from activity: [StudyActivityDay]) -> Int {
    let activeDayKeys = Set(activity.filter { $0.reviewedCount > 0 }.map(\.dayKey))
    guard !activeDayKeys.isEmpty else { return 0 }

    let calendar = Calendar.current
    let today = StudyDay.start(for: .now, calendar: calendar)
    let todayKey = StudyDay.key(calendar: calendar)
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

private func studyDurationLabel(milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds) / 1000
    if totalSeconds == 0 {
        return LocalizedCounts.minutePhrase(0)
    }
    if totalSeconds < 60 {
        return LocalizedCounts.lessThanMinute()
    }
    let totalMinutes = totalSeconds / 60
    if totalMinutes < 60 {
        return LocalizedCounts.minutePhrase(totalMinutes)
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if minutes == 0 {
        return LocalizedCounts.hourPhrase(hours)
    }
    return "\(LocalizedCounts.hourPhrase(hours)) \(LocalizedCounts.minutePhrase(minutes))"
}
