// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SPMTestWordsTrainer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WordsTrainerLogic", targets: ["WordsTrainerLogic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/open-spaced-repetition/swift-fsrs", branch: "main"),
    ],
    targets: [
        .target(
            name: "WordsTrainerLogic",
            dependencies: [
                .product(name: "FSRS", package: "swift-fsrs"),
            ],
            path: ".",
            exclude: [
                "Tests",
                "README.md",
                "Models/UUID+Database.swift",
            ],
            sources: [
                "Models/StudyMode.swift",
                "Models/StudyStats.swift",
                "Models/WordCardContent.swift",
                "SRS/BinaryFSRS.swift",
                "SRS/CardProgress.swift",
                "SRS/DeckStats.swift",
                "SRS/MatchingPairScheduler.swift",
                "SRS/StudyQueue.swift",
                "SRS/StudySession.swift",
            ]
        ),
        .testTarget(
            name: "WordsTrainerLogicTests",
            dependencies: ["WordsTrainerLogic"],
            path: "Tests"
        ),
    ]
)
