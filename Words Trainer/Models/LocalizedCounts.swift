import Foundation

nonisolated enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments.map(normalizedFormatArgument))
    }

    private static func normalizedFormatArgument(_ argument: CVarArg) -> CVarArg {
        if let value = argument as? Int {
            return Int32(value)
        }
        return argument
    }
}

nonisolated enum LocalizedCounts {
    static func deckPhrase(_ count: Int) -> String {
        localizedPlural("count.decks", count)
    }

    static func cardPhrase(_ count: Int) -> String {
        localizedPlural("count.cards", count)
    }

    static func cardsInQueue(_ count: Int) -> String {
        localizedFormat("count.cards.in_queue", cardPhrase(count))
    }

    static func cardsInWeak(_ count: Int) -> String {
        localizedFormat("count.cards.in_weak", cardPhrase(count))
    }

    static func cardsToday(_ count: Int) -> String {
        localizedFormat("count.cards.today", cardPhrase(count))
    }

    static func cardsForPractice(_ count: Int) -> String {
        localizedFormat("count.cards.for_practice", cardPhrase(count))
    }

    static func randomCards(_ count: Int) -> String {
        localizedPlural("count.cards.random", count)
    }

    static func dayPhrase(_ count: Int) -> String {
        localizedPlural("count.days", count)
    }

    static func daysPeriod(_ count: Int) -> String {
        localizedFormat("count.days.period", dayPhrase(count))
    }

    static func dayStreak(_ count: Int) -> String {
        localizedFormat("count.days.streak", dayPhrase(count))
    }

    static func hourPhrase(_ count: Int) -> String {
        localizedPlural("count.hours.short", count)
    }

    static func minutePhrase(_ count: Int) -> String {
        localizedPlural("count.minutes.short", count)
    }

    static func monthPhraseShort(_ count: Int) -> String {
        localizedPlural("count.months.short", count)
    }

    static func lessThanMinute() -> String {
        localizedFormat("duration.less_than", minutePhrase(1))
    }

    static func wordWord(for count: Int) -> String {
        localizedPlural("count.words.word", count)
    }

    static func gameWord(for count: Int) -> String {
        localizedPlural("count.games.word", count)
    }

    private static func localizedPlural(_ key: String, _ count: Int) -> String {
        let format = NSLocalizedString(key, comment: "")
        return String.localizedStringWithFormat(format, Int32(count))
    }

    private static func localizedFormat(_ key: String, _ argument: String) -> String {
        let format = NSLocalizedString(key, comment: "")
        return String(format: format, locale: .current, argument)
    }
}
