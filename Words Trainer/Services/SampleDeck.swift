import Foundation

enum SampleDeck {
    static let animalsID = UUID(uuidString: "A1000001-0000-4000-8000-000000000001")!

    static let animals = DeckContent(
        id: animalsID,
        title: "Animals A1",
        avatarSystemName: "pawprint.fill",
        languageCode: "en",
        newCardsPerDay: 10,
        reviewCardsPerDay: 50,
        cards: [
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000001")!,
                word: "cat",
                translation: "кот",
                clozePrompt: "The ___ is sleeping on the sofa.",
                clozeAnswer: "cat",
                explanation: "Короткое слово, как «кот».",
                distractors: ["dog", "bird", "fish"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000002")!,
                word: "dog",
                translation: "собака",
                clozePrompt: "Her ___ loves to run in the park.",
                clozeAnswer: "dog",
                explanation: "dog — собака, частый питомец.",
                distractors: ["cat", "horse", "cow"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000003")!,
                word: "bird",
                translation: "птица",
                clozePrompt: "A small ___ is singing in the tree.",
                clozeAnswer: "bird",
                distractors: ["fish", "cat", "mouse"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000004")!,
                word: "horse",
                translation: "лошадь",
                clozePrompt: "The ___ runs fast across the field.",
                clozeAnswer: "horse",
                distractors: ["cow", "dog", "fish"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000005")!,
                word: "cow",
                translation: "корова",
                clozePrompt: "The ___ gives milk.",
                clozeAnswer: "cow",
                distractors: ["horse", "bird", "mouse"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000006")!,
                word: "fish",
                translation: "рыба",
                clozePrompt: "A ___ swims in the river.",
                clozeAnswer: "fish",
                distractors: ["bird", "cat", "dog"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000007")!,
                word: "mouse",
                translation: "мышь",
                clozePrompt: "A tiny ___ lives under the floor.",
                clozeAnswer: "mouse",
                distractors: ["cat", "cow", "horse"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000008")!,
                word: "rabbit",
                translation: "кролик",
                clozePrompt: "The ___ likes carrots.",
                clozeAnswer: "rabbit",
                distractors: ["fish", "bird", "cow"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000009")!,
                word: "sheep",
                translation: "овца",
                clozePrompt: "The ___ has soft wool.",
                clozeAnswer: "sheep",
                distractors: ["dog", "rabbit", "mouse"]
            ),
            WordCardContent(
                id: UUID(uuidString: "B1000001-0000-4000-8000-000000000010")!,
                word: "duck",
                translation: "утка",
                clozePrompt: "A ___ swims on the pond.",
                clozeAnswer: "duck",
                distractors: ["horse", "cat", "sheep"]
            ),
        ]
    )
}
