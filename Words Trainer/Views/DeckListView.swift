import SwiftData
import SwiftUI

struct DeckListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeckRecord.title) private var decks: [DeckRecord]

    @State private var store: DeckStore?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if let loadError {
                    ContentUnavailableView("Ошибка", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if decks.isEmpty {
                    ContentUnavailableView("Нет колод", systemImage: "books.vertical", description: Text("Загрузка…"))
                } else if let store {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            DeckListHeader(deckCount: decks.count)

                            LazyVStack(spacing: 16) {
                                ForEach(decks) { deck in
                                    NavigationLink {
                                        DeckDetailView(deck: deck, store: store)
                                    } label: {
                                        DeckCardView(deck: deck, store: store)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Колоды")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            await bootstrap()
        }
    }

    private func bootstrap() async {
        let deckStore = DeckStore(modelContext: modelContext)
        store = deckStore
        do {
            try deckStore.seedIfNeeded()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct DeckListHeader: View {
    let deckCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сегодня")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("Выбери колоду и продолжай интервальные повторения.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))

            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .foregroundStyle(.cyan)
                Text("\(deckCount) колод\(deckCount == 1 ? "а" : "")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension DeckStats {
    var dueTotal: Int { learningDue + reviewDue }
}

struct DeckCardView: View {
    let deck: DeckRecord
    let store: DeckStore

    @State private var stats: DeckStats = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                DeckIcon(symbolName: deck.avatarSystemName)

                VStack(alignment: .leading, spacing: 6) {
                    Text(deck.title)
                        .font(.title3.bold())
                        .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.13))

                    Text("\(deck.cards.count) карточек · \(deck.languageCode.uppercased())")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.45, green: 0.46, blue: 0.55))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.24))
                    .padding(.top, 6)
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
        .accessibilityLabel("\(deck.title), новых \(stats.newAvailable), повторить \(stats.dueTotal), всего \(deck.cards.count)")
        .task(id: deck.id) {
            stats = (try? store.stats(for: deck)) ?? .zero
        }
    }
}

struct DeckDetailView: View {
    let deck: DeckRecord
    let store: DeckStore

    @State private var stats: DeckStats = .zero
    @State private var session: StudySession?
    @State private var showStudy = false

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DeckDetailHero(deck: deck, stats: stats)

                    StudySection(title: "Упражнения") {
                        StudyActionButton(
                            title: "Предложения",
                            subtitle: "Выбери слово для примера с пропуском",
                            systemImage: "text.quote",
                            accent: .blue,
                            isEnabled: stats.studyTotal > 0
                        ) {
                            start(.clozeMultipleChoice)
                        }

                        StudyActionButton(
                            title: "Колонки",
                            subtitle: "Соедини слово и перевод",
                            systemImage: "rectangle.split.2x1.fill",
                            accent: .green,
                            isEnabled: !deck.cards.isEmpty
                        ) {
                            start(.matching)
                        }
                    }

                    StudySection(title: "Помню / Забыл") {
                        StudyActionButton(
                            title: "Быстрый проход",
                            subtitle: "Покажи слово и отметь: помню или забыл",
                            systemImage: "eye.fill",
                            accent: .purple,
                            isEnabled: stats.studyTotal > 0
                        ) {
                            start(.recall)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(deck.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $showStudy) {
            if let session {
                StudySessionView(session: session, store: store, deckTitle: deck.title)
            }
        }
        .task(id: deck.id) {
            stats = (try? store.stats(for: deck)) ?? .zero
        }
    }

    private func start(_ mode: StudyMode) {
        session = try? store.startSession(deck: deck, mode: mode)
        showStudy = session != nil
    }
}

private struct DeckDetailHero: View {
    let deck: DeckRecord
    let stats: DeckStats

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                DeckIcon(symbolName: deck.avatarSystemName, size: 68)

                VStack(alignment: .leading, spacing: 6) {
                    Text(deck.title)
                        .font(.title.bold())
                        .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.13))
                    Text("\(deck.cards.count) карточек · \(deck.languageCode.uppercased())")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.45, green: 0.46, blue: 0.55))
                }

                Spacer()
            }

            HStack(spacing: 10) {
                DeckMetricCard(title: "Новые", value: stats.newAvailable, tint: .blue)
                DeckMetricCard(title: "Повторить", value: stats.dueTotal, tint: .orange)
            }
        }
        .padding(20)
        .background(LightCardBackground(cornerRadius: 30))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.75), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 18)
    }
}

private struct StudySection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
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
                    .font(.headline)
                    .foregroundStyle(isEnabled ? accent : .white.opacity(0.42))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(accent.opacity(isEnabled ? 0.16 : 0.08)))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
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

private struct DeckMetricCard: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2.bold())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(Color(red: 0.45, green: 0.46, blue: 0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

private struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.14),
                    Color(red: 0.09, green: 0.08, blue: 0.20),
                    Color(red: 0.03, green: 0.10, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.blue.opacity(0.26))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -130, y: -260)

            Circle()
                .fill(.purple.opacity(0.24))
                .frame(width: 300, height: 300)
                .blur(radius: 85)
                .offset(x: 150, y: 280)
        }
        .ignoresSafeArea()
    }
}

private struct LightCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.96),
                        Color(red: 0.94, green: 0.96, blue: 1.0).opacity(0.94),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

#Preview {
    DeckListView()
        .modelContainer(for: [DeckRecord.self, CardRecord.self, CardProgressRecord.self, DeckDailyUsageRecord.self], inMemory: true)
}
