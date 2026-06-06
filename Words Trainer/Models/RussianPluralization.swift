import Foundation

enum RussianPluralization {
    static func word(for count: Int, one: String, few: String, many: String) -> String {
        let value = abs(count)
        let mod10 = value % 10
        let mod100 = value % 100
        if mod100 >= 11 && mod100 <= 14 { return many }
        if mod10 == 1 { return one }
        if mod10 >= 2 && mod10 <= 4 { return few }
        return many
    }

    static func phrase(_ count: Int, one: String, few: String, many: String) -> String {
        "\(count) \(word(for: count, one: one, few: few, many: many))"
    }

    static func deckWord(for count: Int) -> String {
        word(for: count, one: "колода", few: "колоды", many: "колод")
    }

    static func deckPhrase(_ count: Int) -> String {
        phrase(count, one: "колода", few: "колоды", many: "колод")
    }

    static func cardWord(for count: Int) -> String {
        word(for: count, one: "карточка", few: "карточки", many: "карточек")
    }

    static func cardPhrase(_ count: Int) -> String {
        phrase(count, one: "карточка", few: "карточки", many: "карточек")
    }

    static func studyWord(for count: Int) -> String {
        word(for: count, one: "занятие", few: "занятия", many: "занятий")
    }

    static func gameWord(for count: Int) -> String {
        word(for: count, one: "игра", few: "игры", many: "игр")
    }

    static func wordWord(for count: Int) -> String {
        word(for: count, one: "слово", few: "слова", many: "слов")
    }
}
