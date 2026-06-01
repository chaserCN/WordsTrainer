import SwiftUI

struct AppRootView: View {
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
    }
}

struct TodayView: View {
    @State private var store: DeckStore?
    @State private var decks: [DeckContent] = []
    @State private var statsByDeckID: [UUID: DeckStats] = [:]
    @State private var activity: [StudyActivityDay] = []
    @State private var session: StudySession?
    @State private var sessionDeckTitle = ""
    @State private var showTodayModes = false
    @State private var showStudy = false
    @State private var loadError: String?

    private var activeDecks: [DeckContent] {
        decks.filter(\.isActive)
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
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TodayHeader()

                        StudyTodayCard(
                            stats: totalStats,
                            isEnabled: totalStats.studyTotal > 0,
                            action: {
                                showTodayModes = true
                            }
                        )

                        TodayDeckSummary(decks: activeDecks, statsByDeckID: statsByDeckID)

                        ActivityHeatmap(days: filledActivity(days: 70))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Сегодня")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(isPresented: $showTodayModes) {
                if store != nil {
                    TodayStudyModesView(
                        queueCount: totalStats.studyTotal,
                        start: startToday(mode:)
                    )
                }
            }
            .navigationDestination(isPresented: $showStudy) {
                if let session, let store {
                    StudySessionView(session: session, store: store, deckTitle: sessionDeckTitle)
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
        .onChange(of: showStudy) { _, isShowing in
            guard !isShowing else { return }
            Task { await reload() }
        }
    }

    private func reload() async {
        do {
            let deckStore: DeckStore
            if let store {
                deckStore = store
            } else {
                deckStore = try DeckStore()
                store = deckStore
            }
            decks = try deckStore.allDecks()
            var nextStats: [UUID: DeckStats] = [:]
            for deck in decks where deck.isActive {
                nextStats[deck.id] = try deckStore.stats(for: deck)
            }
            statsByDeckID = nextStats
            activity = try deckStore.studyActivity(days: 70)
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

    private func filledActivity(days: Int) -> [StudyActivityDay] {
        let byKey = Dictionary(uniqueKeysWithValues: activity.map { ($0.dayKey, $0) })
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<days).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = DeckDailyUsage.dayKey(for: date, calendar: calendar)
            return byKey[key] ?? StudyActivityDay(dayKey: key, reviewedCount: 0, passedCount: 0)
        }
    }
}

struct StatisticsView: View {
    @State private var store: DeckStore?
    @State private var todayCount: StudyReviewCount = .zero
    @State private var weekCount: StudyReviewCount = .zero
    @State private var monthCount: StudyReviewCount = .zero
    @State private var activity: [StudyActivityDay] = []
    @State private var scheduledDays: [ScheduledReviewDay] = []
    @State private var weakCards: [WeakCardStat] = []
    @State private var loadError: String?

    private var studyDaysCount: Int {
        activity.filter { $0.reviewedCount > 0 }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        StatisticsHeader()

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            DashboardMetric(title: "Сегодня", value: "\(todayCount.total)", subtitle: cardsLabel(todayCount.total))
                            DashboardMetric(title: "7 дней", value: "\(weekCount.total)", subtitle: cardsLabel(weekCount.total))
                            DashboardMetric(title: "30 дней", value: "\(monthCount.total)", subtitle: cardsLabel(monthCount.total))
                            DashboardMetric(title: "Дни занятий", value: "\(studyDaysCount)", subtitle: "за 30 дней")
                        }

                        ForecastSection(days: scheduledDays)
                        WeakCardsSection(cards: weakCards)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Статистика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
    }

    private func reload() async {
        do {
            let deckStore: DeckStore
            if let store {
                deckStore = store
            } else {
                deckStore = try DeckStore()
                store = deckStore
            }
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: .now)
            let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            let monthStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
            todayCount = try deckStore.studyReviewCount(since: todayStart)
            weekCount = try deckStore.studyReviewCount(since: weekStart)
            monthCount = try deckStore.studyReviewCount(since: monthStart)
            activity = try deckStore.studyActivity(days: 30)
            scheduledDays = try deckStore.scheduledReviewDays(days: 7)
            weakCards = try deckStore.weakCards(limit: 10)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct TodayHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Сегодня")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("Закрой дневную очередь и держи ритм.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatisticsHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Статистика")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("Регулярность, объем и ближайшие повторения.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StudyTodayCard: View {
    let stats: DeckStats
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Учить сегодня")
                        .font(.title2.bold())
                    Text(isEnabled ? "\(stats.studyTotal) карточек в очереди" : "На сегодня всё готово")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.title3.bold())
            }
            .foregroundStyle(.white)
            .padding(20)
            .background(
                LinearGradient(
                    colors: [.cyan.opacity(isEnabled ? 0.9 : 0.38), .blue.opacity(isEnabled ? 0.82 : 0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct TodayStudyModesView: View {
    let queueCount: Int
    let start: (StudyMode) -> Void

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Учить сегодня")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("\(queueCount) \(cardsLabel(queueCount)) в дневной очереди.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Режим")
                            .font(.headline)
                            .foregroundStyle(.white)

                        TodayModeButton(
                            title: "Карточки",
                            subtitle: "\(queueCount) \(cardsLabel(queueCount)) в очереди",
                            systemImage: "rectangle.on.rectangle.angled",
                            accent: .orange,
                            isEnabled: queueCount > 0
                        ) {
                            start(.flashcards)
                        }

                        TodayModeButton(
                            title: "Предложения",
                            subtitle: "\(queueCount) \(cardsLabel(queueCount)) в очереди",
                            systemImage: "text.quote",
                            accent: .blue,
                            isEnabled: queueCount > 0
                        ) {
                            start(.clozeMultipleChoice)
                        }

                        TodayModeButton(
                            title: "Колонки",
                            subtitle: "\(queueCount) \(cardsLabel(queueCount)) сегодня",
                            systemImage: "rectangle.split.2x1.fill",
                            accent: .green,
                            isEnabled: queueCount > 0
                        ) {
                            start(.matching)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Сегодня")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
                    .foregroundStyle(isEnabled ? accent : .white.opacity(0.42))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(accent.opacity(isEnabled ? 0.16 : 0.08)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(18)
            .foregroundStyle(.white)
            .background(Color.white.opacity(isEnabled ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(isEnabled ? 0.12 : 0.06), lineWidth: 1)
            }
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
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
                    .font(.headline)
                Spacer()
                Text("\(months.count) мес.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
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
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

}

private struct ActivityMonthView: View {
    let month: ActivityMonth
    let maxCount: Int

    private let columns = Array(repeating: GridItem(.fixed(18), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(month.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(month.weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(width: 18, height: 10)
                }

                ForEach(month.cells) { cell in
                    if let day = cell.day {
                        Circle()
                            .fill(color(for: day.reviewedCount))
                            .frame(width: 8, height: 8)
                            .frame(width: 18, height: 18)
                            .overlay {
                                if day.isToday {
                                    Circle()
                                        .stroke(.white.opacity(0.72), lineWidth: 1.2)
                                        .frame(width: 13, height: 13)
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
        guard count > 0 else { return .white.opacity(0.13) }
        let intensity = min(1, 0.25 + Double(count) / Double(maxCount) * 0.75)
        return .cyan.opacity(intensity)
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

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = DateFormatter().veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("По колодам")
                .font(.headline)
                .foregroundStyle(.white)

            if decks.isEmpty {
                Text("Нет включенных колод.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
            } else {
                VStack(spacing: 8) {
                    ForEach(decks) { deck in
                        let stats = statsByDeckID[deck.id] ?? .zero
                        HStack {
                            Text(deck.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(stats.studyTotal)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.cyan)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }
}

private struct ForecastSection: View {
    let days: [ScheduledReviewDay]
    private var maxCount: Int { max(days.map(\.dueCount).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("План на неделю")
                .font(.headline)
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                ForEach(days) { day in
                    HStack(spacing: 10) {
                        Text(shortDay(day.dayKey))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(width: 44, alignment: .leading)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.cyan.opacity(0.72))
                                .frame(width: max(4, proxy.size.width * CGFloat(day.dueCount) / CGFloat(maxCount)))
                        }
                        .frame(height: 8)
                        Text("\(day.dueCount)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct WeakCardsSection: View {
    let cards: [WeakCardStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Часто забываемые")
                .font(.headline)
                .foregroundStyle(.white)

            if cards.isEmpty {
                Text("Пока нет слов для дополнительного повтора.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.word)
                                    .font(.subheadline.weight(.semibold))
                                Text(card.translation)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.58))
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.cyan.opacity(0.8))
                                .padding(8)
                                .background(.cyan.opacity(0.12), in: Circle())
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
    }
}

private func shortDay(_ dayKey: String) -> String {
    String(dayKey.suffix(5))
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
