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
                "Services/AppBackgroundSync.swift",
                "Services/AppSettings.swift",
                "Services/DeckStore.swift",
                "Services/FrameHitchMonitor.swift",
                "Services/WordAudioPlayer.swift",
            ],
            sources: [
                "Models/AppUser.swift",
                "Models/AppUserSyncStatus.swift",
                "Models/DeckMatchingRecord.swift",
                "Models/LocalizedCounts.swift",
                "Models/StudyMode.swift",
                "Models/StudyStats.swift",
                "Models/UUID+Database.swift",
                "Models/WeakCardsPractice.swift",
                "Models/WordCardContent.swift",
                "Services/AppDataPaths.swift",
                "Services/AppUserStore.swift",
                "Services/ContentDatabase.swift",
                "Services/DeckDetailSnapshotBuilder.swift",
                "Services/DeckStatisticsSnapshotBuilder.swift",
                "Services/Log.swift",
                "Services/ServerSyncClient.swift",
                "Services/StudyCardCache.swift",
                "Services/TodayReadOnlySnapshotBuilder.swift",
                "Services/TodaySessionDataLoader.swift",
                "Services/TodaySnapshotBuilder.swift",
                "SRS/BinaryFSRS.swift",
                "SRS/CardProgress.swift",
                "SRS/DeckStats.swift",
                "SRS/MatchingPairScheduler.swift",
                "SRS/StudyDay.swift",
                "SRS/StudyQueue.swift",
                "SRS/StudySession.swift",
                "SRS/StudySessionFactory.swift",
                "SRS/TodayStudySessionBuilder.swift",
            ]
        ),
        .testTarget(
            name: "WordsTrainerLogicTests",
            dependencies: ["WordsTrainerLogic"],
            path: "Tests"
        ),
    ]
)
