import Foundation
import FSRS
import Testing
@testable import WordsTrainerLogic

@Suite(.serialized)
struct ContentDatabaseTests {
    private let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let deckID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let versionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let cardID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let mediaID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let audioWordMediaID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let exampleImageMediaID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let audioExampleMediaID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let exampleID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    @Test("rebuildDerivedStats counts only passed new-card reviews")
    func rebuildDerivedStatsCountsOnlyPassedNewReviews() throws {
        try withIsolatedDatabase { database in
            let passedReviewID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
            let failedReviewID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
            let reviewedAt = "2026-06-02T12:00:00.000Z"
            try database.importServerBootstrap(
                bootstrap(
                    reviews: [
                        reviewJSON(id: passedReviewID, outcome: "remembered", reviewedAt: reviewedAt, wasNew: true),
                        reviewJSON(id: failedReviewID, outcome: "forgot", reviewedAt: reviewedAt, wasNew: true),
                    ]
                ),
                selectedUserID: userID
            )

            let reviewedDate = try #require(Self.isoDate(reviewedAt))
            let dailyUsage = try database.dailyUsage(deckID: deckID, dayKey: DeckDailyUsage.dayKey(for: reviewedDate))
            let usage = try #require(dailyUsage)
            #expect(usage.newCardsStudied == 1)
        }
    }

    @Test("server daily usage snapshot replaces locally rebuilt usage")
    func serverDailyUsageSnapshotReplacesLocallyRebuiltUsage() throws {
        try withIsolatedDatabase { database in
            let reviewID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
            let reviewedAt = "2026-06-02T12:00:00.000Z"
            try database.importServerBootstrap(
                bootstrap(
                    reviews: [
                        reviewJSON(id: reviewID, outcome: "remembered", reviewedAt: reviewedAt, wasNew: true),
                    ]
                ),
                selectedUserID: userID
            )
            let reviewedDate = try #require(Self.isoDate(reviewedAt))
            #expect(
                try database.dailyUsage(deckID: deckID, dayKey: DeckDailyUsage.dayKey(for: reviewedDate))?.newCardsStudied == 1
            )

            try database.importServerBootstrap(
                bootstrap(
                    dailyUsage: [
                        dailyUsageJSON(dayKey: "2026-06-02", newCardsStudied: 4),
                    ]
                ),
                selectedUserID: userID
            )

            let dailyUsage = try database.dailyUsage(deckID: deckID, dayKey: "2026-06-02")
            let usage = try #require(dailyUsage)
            #expect(usage.newCardsStudied == 4)
        }
    }

    @Test("server daily usage snapshot keeps unsynced local reviews counted")
    func serverDailyUsageSnapshotKeepsUnsyncedLocalReviewsCounted() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    dailyUsage: [
                        dailyUsageJSON(dayKey: "2026-06-02", newCardsStudied: 2),
                    ]
                ),
                selectedUserID: userID
            )
            let reviewedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            try database.saveStudyReview(
                StudyReviewEvent(
                    id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .remembered,
                    reviewedAt: reviewedAt,
                    durationMS: 1000,
                    wasNew: true,
                    previousState: "new",
                    newState: "review"
                )
            )

            try database.importServerBootstrap(
                bootstrap(
                    dailyUsage: [
                        dailyUsageJSON(dayKey: "2026-06-02", newCardsStudied: 2),
                    ]
                ),
                selectedUserID: userID
            )

            let dailyUsage = try database.dailyUsage(deckID: deckID, dayKey: "2026-06-02")
            let usage = try #require(dailyUsage)
            #expect(usage.newCardsStudied == 3)
        }
    }

    @Test("reviewed card IDs return cards reviewed during requested day")
    func reviewedCardIDsReturnCardsReviewedDuringRequestedDay() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let reviewedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let previousDay = try #require(Self.isoDate("2026-06-01T12:00:00.000Z"))

            try database.saveStudyReview(
                StudyReviewEvent(
                    id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .remembered,
                    reviewedAt: previousDay,
                    durationMS: 1000,
                    wasNew: true,
                    previousState: "new",
                    newState: "review"
                )
            )
            try database.saveStudyReview(
                StudyReviewEvent(
                    id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .clozeMultipleChoice,
                    outcome: .correct,
                    source: .todayQueue,
                    reviewedAt: reviewedAt,
                    durationMS: 1000,
                    wasNew: false,
                    previousState: "review",
                    newState: "review"
                )
            )

            #expect(try database.reviewedCardIDs(day: reviewedAt, calendar: calendar) == [cardID])
            #expect(try database.reviewedCardIDs(day: reviewedAt, deckID: deckID, calendar: calendar) == [cardID])
            #expect(try database.reviewedCardIDs(day: reviewedAt, deckID: deckID, source: .todayQueue, calendar: calendar) == [cardID])
            #expect(try database.reviewedCardIDs(day: reviewedAt, deckID: deckID, source: .deckSession, calendar: calendar).isEmpty)
            #expect(try database.reviewedCardIDs(day: reviewedAt, deckID: UUID(), calendar: calendar).isEmpty)
            #expect(
                try database.reviewedCardIDs(
                    day: reviewedAt.addingTimeInterval(24 * 60 * 60),
                    calendar: calendar
                ).isEmpty
            )
        }
    }

    @Test("empty server daily usage snapshot clears synced local usage")
    func emptyServerDailyUsageSnapshotClearsSyncedLocalUsage() throws {
        try withIsolatedDatabase { database in
            let reviewID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
            try database.importServerBootstrap(
                bootstrap(
                    reviews: [
                        reviewJSON(
                            id: reviewID,
                            outcome: "remembered",
                            reviewedAt: "2026-06-02T12:00:00.000Z",
                            wasNew: true
                        ),
                    ]
                ),
                selectedUserID: userID
            )
            #expect(try database.dailyUsage(deckID: deckID, dayKey: "2026-06-02")?.newCardsStudied == 1)

            try database.importServerBootstrap(
                bootstrap(dailyUsage: []),
                selectedUserID: userID
            )

            #expect(try database.dailyUsage(deckID: deckID, dayKey: "2026-06-02") == nil)
        }
    }

    @Test("unique study card count counts repeated reviews once")
    func uniqueStudyCardCountCountsRepeatedReviewsOnce() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    reviews: [
                        reviewJSON(
                            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                            outcome: "remembered",
                            reviewedAt: "2026-06-02T12:00:00.000Z",
                            wasNew: true
                        ),
                        reviewJSON(
                            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                            outcome: "forgot",
                            reviewedAt: "2026-06-02T12:10:00.000Z",
                            wasNew: false
                        ),
                    ]
                ),
                selectedUserID: userID
            )

            let since = try #require(Self.isoDate("2026-06-02T00:00:00.000Z"))
            #expect(try database.studyReviewCount(since: since).total == 2)
            #expect(try database.uniqueStudyCardCount(since: since) == 1)
        }
    }

    @Test("server matching attempts import into local statistics")
    func serverMatchingAttemptsImportIntoLocalStatistics() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    matchingAttempts: [
                        matchingAttemptJSON(
                            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                            mode: "matching",
                            completedAt: "2026-06-02T12:00:00.000Z"
                        ),
                        matchingAttemptJSON(
                            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                            mode: "matching_audio",
                            completedAt: "2026-06-02T12:10:00.000Z"
                        ),
                    ]
                ),
                selectedUserID: userID
            )

            let since = try #require(Self.isoDate("2026-06-02T00:00:00.000Z"))
            #expect(try database.matchingAttemptCount(since: since) == 2)
        }
    }

    @Test("matching attempt count combines normal and audio columns")
    func matchingAttemptCountCombinesNormalAndAudioColumns() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let since = try #require(Self.isoDate("2026-06-02T00:00:00.000Z"))
            let completedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let earlier = try #require(Self.isoDate("2026-06-01T12:00:00.000Z"))

            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                    deckID: deckID,
                    mode: .matching,
                    source: .deckSession,
                    completedAt: completedAt,
                    duration: 12,
                    pairCount: 4
                )
            )
            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                    deckID: deckID,
                    mode: .matchingAudio,
                    source: .deckSession,
                    completedAt: completedAt,
                    duration: 14,
                    pairCount: 4
                )
            )
            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
                    deckID: deckID,
                    mode: .flashcards,
                    source: .deckSession,
                    completedAt: completedAt,
                    duration: 10,
                    pairCount: 4
                )
            )
            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
                    deckID: deckID,
                    mode: .matching,
                    source: .deckSession,
                    completedAt: earlier,
                    duration: 11,
                    pairCount: 4
                )
            )

            #expect(try database.matchingAttemptCount(since: since) == 2)
        }
    }

    @Test("study time breakdown combines review and matching durations")
    func studyTimeBreakdownCombinesReviewAndMatchingDurations() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    matchingAttempts: [
                        matchingAttemptJSON(
                            id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                            mode: "matching_audio",
                            completedAt: "2026-06-02T12:30:00.000Z"
                        ),
                    ]
                ),
                selectedUserID: userID
            )
            let since = try #require(Self.isoDate("2026-06-02T00:00:00.000Z"))
            let reviewedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let earlier = try #require(Self.isoDate("2026-06-01T12:00:00.000Z"))

            try database.saveStudyReview(
                StudyReviewEvent(
                    id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .remembered,
                    reviewedAt: reviewedAt,
                    durationMS: 120_000,
                    wasNew: true,
                    previousState: "new",
                    newState: "review"
                )
            )
            try database.savePracticeReview(
                PracticeReviewEvent(
                    id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .clozeTyping,
                    outcome: .correct,
                    source: .todayPractice,
                    practicedAt: reviewedAt,
                    durationMS: 45_000
                )
            )
            try database.saveStudyReview(
                StudyReviewEvent(
                    id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .remembered,
                    reviewedAt: earlier,
                    durationMS: 90_000,
                    wasNew: false,
                    previousState: "review",
                    newState: "review"
                )
            )
            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
                    deckID: deckID,
                    mode: .matching,
                    source: .deckSession,
                    completedAt: reviewedAt,
                    duration: 14.25,
                    pairCount: 4
                )
            )
            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
                    deckID: deckID,
                    mode: .matchingAudio,
                    source: .deckSession,
                    completedAt: reviewedAt,
                    duration: 20,
                    pairCount: 4
                )
            )

            let breakdown = try database.studyTimeBreakdown(since: since)
            #expect(breakdown.flashcardsMilliseconds == 120_000)
            #expect(breakdown.sentenceMilliseconds == 45_000)
            #expect(breakdown.matchingMilliseconds == 14_250)
            #expect(breakdown.matchingAudioMilliseconds == 32_000)
            #expect(breakdown.totalMilliseconds == 211_250)
        }
    }

    @Test("server practice reviews import into local time statistics")
    func serverPracticeReviewsImportIntoLocalTimeStatistics() throws {
        try withIsolatedDatabase { database in
            let practiceReviewID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
            try database.importServerBootstrap(
                bootstrap(
                    practiceReviews: [
                        practiceReviewJSON(
                            id: practiceReviewID,
                            mode: "cloze_typing",
                            practicedAt: "2026-06-02T12:00:00.000Z",
                            durationMS: 45_000
                        ),
                    ]
                ),
                selectedUserID: userID
            )

            let since = try #require(Self.isoDate("2026-06-02T00:00:00.000Z"))
            let breakdown = try database.studyTimeBreakdown(since: since)
            #expect(breakdown.flashcardsMilliseconds == 0)
            #expect(breakdown.sentenceMilliseconds == 45_000)
            #expect(breakdown.matchingMilliseconds == 0)
            #expect(breakdown.matchingAudioMilliseconds == 0)
            #expect(try database.pendingServerSyncBatch().practiceReviewIDs.isEmpty)
        }
    }

    @Test("weak cards exclude review cards with low failure rate")
    func weakCardsExcludeReviewCardsWithLowFailureRate() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    reviews: reviewJSONs(outcomes: [
                        "forgot",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                    ])
                ),
                selectedUserID: userID
            )
            let updatedAt = try #require(Self.isoDate("2026-06-03T12:00:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress(
                    cardID: cardID,
                    fsrsCard: Card(due: updatedAt, state: .review),
                    updatedAt: updatedAt
                )
            )

            #expect(try database.weakCards(limit: 10).isEmpty)
            #expect(try database.weakCards(limit: 10, deckID: deckID).isEmpty)
        }
    }

    @Test("weak cards keep review cards with high failure rate")
    func weakCardsKeepReviewCardsWithHighFailureRate() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    reviews: reviewJSONs(outcomes: [
                        "forgot",
                        "forgot",
                        "remembered",
                        "remembered",
                        "remembered",
                    ])
                ),
                selectedUserID: userID
            )
            let updatedAt = try #require(Self.isoDate("2026-06-03T12:00:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress(
                    cardID: cardID,
                    fsrsCard: Card(due: updatedAt, state: .review),
                    updatedAt: updatedAt
                )
            )

            #expect(try database.weakCards(limit: 10).map(\.cardID) == [cardID])
            #expect(try database.weakCards(limit: 10, deckID: deckID).map(\.cardID) == [cardID])
        }
    }

    @Test("weak cards keep failed cards that are still learning")
    func weakCardsKeepFailedCardsThatAreStillLearning() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    reviews: reviewJSONs(outcomes: [
                        "forgot",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                        "remembered",
                    ])
                ),
                selectedUserID: userID
            )
            let updatedAt = try #require(Self.isoDate("2026-06-03T12:00:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress(
                    cardID: cardID,
                    fsrsCard: Card(due: updatedAt, state: .learning),
                    updatedAt: updatedAt
                )
            )

            #expect(try database.weakCards(limit: 10).map(\.cardID) == [cardID])
            #expect(try database.weakCards(limit: 10, deckID: deckID).map(\.cardID) == [cardID])
        }
    }

    @Test("server progress does not overwrite newer unsynced local progress")
    func serverProgressDoesNotOverwriteNewerUnsyncedLocalProgress() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let localDate = try #require(Self.isoDate("2026-06-03T12:00:00.000Z"))
            let localProgress = CardProgress.newCard(cardID: cardID, now: localDate)
            try database.saveProgress(deckID: deckID, progress: localProgress)

            try database.importServerBootstrap(
                bootstrap(
                    progress: [
                        progressJSON(
                            dueAt: "2026-06-04T12:00:00.000Z",
                            updatedAt: "2026-06-02T12:00:00.000Z"
                        ),
                    ]
                ),
                selectedUserID: userID
            )

            let progress = try #require(database.progressMap(deckID: deckID)[cardID])
            #expect(progress.updatedAt == localDate)
            #expect(progress.fsrsCard.due == localDate)
        }
    }

    @Test("newer server progress replaces older unsynced local progress")
    func newerServerProgressReplacesOlderUnsyncedLocalProgress() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let localDate = try #require(Self.isoDate("2026-06-01T12:00:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress.newCard(cardID: cardID, now: localDate)
            )

            try database.importServerBootstrap(
                bootstrap(
                    progress: [
                        progressJSON(
                            dueAt: "2026-06-04T12:00:00.000Z",
                            updatedAt: "2026-06-02T12:00:00.000Z"
                        ),
                    ]
                ),
                selectedUserID: userID
            )

            let progress = try #require(database.progressMap(deckID: deckID)[cardID])
            #expect(progress.updatedAt == Self.isoDate("2026-06-02T12:00:00.000Z"))
            #expect(progress.fsrsCard.due == Self.isoDate("2026-06-04T12:00:00.000Z"))
        }
    }

    @Test("missing server progress removes synced local progress")
    func missingServerProgressRemovesSyncedLocalProgress() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    progress: [
                        progressJSON(
                            dueAt: "2026-06-04T12:00:00.000Z",
                            updatedAt: "2026-06-02T12:00:00.000Z"
                        ),
                    ]
                ),
                selectedUserID: userID
            )
            #expect(try database.progressMap(deckID: deckID)[cardID] != nil)

            try database.importServerBootstrap(bootstrap(progress: []), selectedUserID: userID)

            #expect(try database.progressMap(deckID: deckID)[cardID] == nil)
        }
    }

    @Test("incremental bootstrap without progress preserves synced local progress")
    func incrementalBootstrapWithoutProgressPreservesSyncedLocalProgress() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(
                    progress: [
                        progressJSON(
                            dueAt: "2026-06-04T12:00:00.000Z",
                            updatedAt: "2026-06-02T12:00:00.000Z"
                        ),
                    ]
                ),
                selectedUserID: userID
            )
            #expect(try database.progressMap(deckID: deckID)[cardID] != nil)

            try database.importServerBootstrap(
                bootstrap(progress: []),
                selectedUserID: userID,
                progressSnapshotIsComplete: false
            )

            #expect(try database.progressMap(deckID: deckID)[cardID] != nil)
        }
    }

    @Test("missing server progress keeps unsynced local progress")
    func missingServerProgressKeepsUnsyncedLocalProgress() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let localDate = try #require(Self.isoDate("2026-06-03T12:00:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress.newCard(cardID: cardID, now: localDate)
            )

            try database.importServerBootstrap(bootstrap(progress: []), selectedUserID: userID)

            let progress = try #require(database.progressMap(deckID: deckID)[cardID])
            #expect(progress.updatedAt == localDate)
        }
    }

    @Test("pendingServerSyncBatch exports unsynced local events and mark uploaded clears them")
    func pendingBatchExportsUnsyncedEventsAndClearsAfterUpload() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let reviewedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let dueAt = try #require(Self.isoDate("2026-06-05T12:00:00.000Z"))
            let reviewID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

            try database.saveStudyReview(
                StudyReviewEvent(
                    id: reviewID,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .remembered,
                    reviewedAt: reviewedAt,
                    durationMS: 1200,
                    wasNew: true,
                    previousState: "new",
                    newState: "review"
                )
            )
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress.newCard(cardID: cardID, now: dueAt)
            )
            let practiceReviewID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
            try database.savePracticeReview(
                PracticeReviewEvent(
                    id: practiceReviewID,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .clozeMultipleChoice,
                    outcome: .correct,
                    source: .todayPractice,
                    practicedAt: reviewedAt,
                    durationMS: 900
                )
            )
            try database.saveMatchingRecord(
                DeckMatchingRecord(
                    deckID: deckID,
                    bestDuration: 12.5,
                    pairCount: 4,
                    achievedAt: reviewedAt
                )
            )
            let matchingAttemptID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
            try database.saveMatchingAttempt(
                MatchingAttemptEvent(
                    id: matchingAttemptID,
                    deckID: deckID,
                    mode: .matching,
                    source: .deckSession,
                    completedAt: reviewedAt,
                    duration: 14.25,
                    pairCount: 4
                )
            )

            let batch = try database.pendingServerSyncBatch()
            #expect(batch.reviewIDs == [reviewID])
            #expect(batch.practiceReviewIDs == [practiceReviewID])
            #expect(batch.progressCardIDs == [cardID])
            #expect(batch.matchingDeckIDs == [deckID])
            #expect(batch.matchingAttemptIDs == [matchingAttemptID])
            #expect(batch.payload.reviews.map(\.clientEventId) == [reviewID])
            #expect(batch.payload.practiceReviews.map(\.clientEventId) == [practiceReviewID])
            #expect(batch.payload.practiceReviews[0].mode == "clozeMultipleChoice")
            #expect(batch.payload.practiceReviews[0].source == "today_practice")
            #expect(batch.payload.progress.map(\.cardId) == [cardID])
            #expect(batch.payload.matchingRecords.map(\.deckId) == [deckID])
            #expect(batch.payload.matchingAttempts.map(\.clientEventId) == [matchingAttemptID])
            #expect(batch.payload.matchingAttempts[0].mode == "matching")
            #expect(batch.payload.matchingAttempts[0].durationMs == 14250)
            #expect(batch.payload.deckPreferences.isEmpty)
            #expect(batch.payload.reviews[0].mode == "flashcards")
            #expect(batch.payload.reviews[0].outcome == "remembered")

            try database.markServerSyncBatchUploaded(batch, syncedAt: reviewedAt)

            let emptyBatch = try database.pendingServerSyncBatch()
            #expect(emptyBatch.isEmpty)
        }
    }

    @Test("pending reviews are exported after assignment becomes inactive")
    func pendingReviewsAreExportedAfterAssignmentBecomesInactive() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let reviewedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let reviewID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

            try database.saveStudyReview(
                StudyReviewEvent(
                    id: reviewID,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .remembered,
                    reviewedAt: reviewedAt,
                    durationMS: 1200,
                    wasNew: true,
                    previousState: "new",
                    newState: "review"
                )
            )
            try database.importServerBootstrap(
                bootstrap(assignmentStatus: "inactive", includeContent: false),
                selectedUserID: userID
            )

            let batch = try database.pendingServerSyncBatch()
            #expect(batch.reviewIDs == [reviewID])
            #expect(batch.payload.reviews.map(\.clientEventId) == [reviewID])
        }
    }

    @Test("mark uploaded keeps newer progress pending when it changed after batch snapshot")
    func markUploadedKeepsNewerProgressPending() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let firstDate = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let secondDate = try #require(Self.isoDate("2026-06-02T12:01:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress.newCard(cardID: cardID, now: firstDate)
            )

            let inFlightBatch = try database.pendingServerSyncBatch()
            #expect(inFlightBatch.progressCardIDs == [cardID])
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress.newCard(cardID: cardID, now: secondDate)
            )
            try database.markServerSyncBatchUploaded(inFlightBatch, syncedAt: firstDate)

            let nextBatch = try database.pendingServerSyncBatch()
            let progressPayload = try #require(nextBatch.payload.progress.first)
            #expect(nextBatch.progressCardIDs == [cardID])
            #expect(progressPayload.updatedAt == "2026-06-02T12:01:00.000Z")
        }
    }

    @Test("mark uploaded keeps newer matching record pending when it changed after batch snapshot")
    func markUploadedKeepsNewerMatchingRecordPending() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let firstDate = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let secondDate = try #require(Self.isoDate("2026-06-02T12:01:00.000Z"))
            try database.saveMatchingRecord(
                DeckMatchingRecord(deckID: deckID, bestDuration: 18.5, pairCount: 4, achievedAt: firstDate)
            )

            let inFlightBatch = try database.pendingServerSyncBatch()
            #expect(inFlightBatch.matchingDeckIDs == [deckID])
            try database.saveMatchingRecord(
                DeckMatchingRecord(deckID: deckID, bestDuration: 15.2, pairCount: 4, achievedAt: secondDate)
            )
            try database.markServerSyncBatchUploaded(inFlightBatch, syncedAt: firstDate)

            let nextBatch = try database.pendingServerSyncBatch()
            let matchingPayload = try #require(nextBatch.payload.matchingRecords.first)
            #expect(nextBatch.matchingDeckIDs == [deckID])
            #expect(matchingPayload.achievedAt == "2026-06-02T12:01:00.000Z")
        }
    }

    @Test("local deck preference disables deck and syncs through outbox")
    func localDeckPreferenceDisablesDeckAndSyncsThroughOutbox() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            #expect(try database.loadDecks().first?.isActive == true)

            let updatedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            try database.setDeckUserEnabled(false, deckID: deckID, updatedAt: updatedAt)

            let disabledDeck = try #require(database.loadDecks().first)
            #expect(!disabledDeck.isActive)
            let batch = try database.pendingServerSyncBatch()
            #expect(batch.deckPreferenceDeckIDs == [deckID])
            #expect(batch.payload.deckPreferences.map(\.deckId) == [deckID])
            #expect(batch.payload.deckPreferences[0].isEnabled == false)

            try database.markServerSyncBatchUploaded(batch, syncedAt: updatedAt)
            #expect(try database.pendingServerSyncBatch().isEmpty)
        }
    }

    @Test("mark uploaded keeps newer deck preference pending when it changed after batch snapshot")
    func markUploadedKeepsNewerDeckPreferencePending() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let firstDate = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            let secondDate = try #require(Self.isoDate("2026-06-02T12:01:00.000Z"))
            try database.setDeckUserEnabled(false, deckID: deckID, updatedAt: firstDate)

            let inFlightBatch = try database.pendingServerSyncBatch()
            #expect(inFlightBatch.deckPreferenceDeckIDs == [deckID])
            try database.setDeckUserEnabled(true, deckID: deckID, updatedAt: secondDate)
            try database.markServerSyncBatchUploaded(inFlightBatch, syncedAt: firstDate)

            let nextBatch = try database.pendingServerSyncBatch()
            let preferencePayload = try #require(nextBatch.payload.deckPreferences.first)
            #expect(nextBatch.deckPreferenceDeckIDs == [deckID])
            #expect(preferencePayload.isEnabled)
            #expect(preferencePayload.updatedAt == "2026-06-02T12:01:00.000Z")
        }
    }

    @Test("server deck preference snapshot drives effective deck activity")
    func serverDeckPreferenceSnapshotDrivesEffectiveDeckActivity() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(
                bootstrap(userEnabled: false, preferenceUpdatedAt: "2026-06-02T12:00:00.000Z"),
                selectedUserID: userID
            )

            let disabledDeck = try #require(database.loadDecks().first)
            #expect(!disabledDeck.isActive)
            #expect(disabledDeck.cards.map(\.id) == [cardID])

            try database.importServerBootstrap(
                bootstrap(includeContent: false, userEnabled: true, preferenceUpdatedAt: "2026-06-02T13:00:00.000Z"),
                selectedUserID: userID
            )

            #expect(try database.loadDecks().first?.isActive == true)
        }
    }

    @Test("pending progress FSRS JSON payload decodes back into a card")
    func pendingProgressFSRSJSONPayloadRoundtripsToCard() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let dueAt = try #require(Self.isoDate("2026-06-05T12:00:00.000Z"))
            try database.saveProgress(
                deckID: deckID,
                progress: CardProgress.newCard(cardID: cardID, now: dueAt)
            )

            let batch = try database.pendingServerSyncBatch()
            let progressPayload = try #require(batch.payload.progress.first)
            let data = try JSONEncoder().encode(progressPayload.fsrsData)
            let decoded = try JSONDecoder().decode(Card.self, from: data)
            #expect(decoded.due == dueAt)
            #expect(progressPayload.dueAt == "2026-06-05T12:00:00.000Z")
        }
    }

    @Test("import marks deck version cached after content commit")
    func importMarksDeckVersionCachedAfterContentCommit() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)

            #expect(try database.cachedDeckVersionIDs() == [versionID])
        }
    }

    @Test("import ignores legacy assignment deck version and uses current version")
    func importIgnoresLegacyAssignmentDeckVersionAndUsesCurrentVersion() throws {
        try withIsolatedDatabase { database in
            let legacyVersionID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!

            try database.importServerBootstrap(
                bootstrap(legacyAssignmentVersionID: legacyVersionID),
                selectedUserID: userID
            )

            let deck = try #require(database.loadDecks().first)
            #expect(deck.cards.map(\.id) == [cardID])
            #expect(try database.cachedDeckVersionIDs() == [versionID])
        }
    }

    @Test("cached deck version bootstrap without content preserves local cards")
    func cachedDeckVersionBootstrapWithoutContentPreservesLocalCards() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(), selectedUserID: userID)
            let initialDeck = try #require(database.loadDecks().first)
            #expect(initialDeck.cards.map(\.id) == [cardID])

            try database.importServerBootstrap(bootstrap(includeContent: false), selectedUserID: userID)

            let cachedDeck = try #require(database.loadDecks().first)
            #expect(cachedDeck.cards.map(\.id) == [cardID])
            #expect(try database.cachedDeckVersionIDs() == [versionID])
        }
    }

    @Test("missing assignment removes visible state and cleans unused deck cache")
    func missingAssignmentRemovesVisibleStateAndCleansUnusedDeckCache() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(cardImageMediaID: mediaID, media: [mediaJSON()]), selectedUserID: userID)
            #expect(try database.loadDecks().map(\.id) == [deckID])
            #expect(try database.cachedDeckVersionIDs() == [versionID])
            #expect(try database.mediaObjects(ids: [mediaID]).map(\.id) == [mediaID])

            let deckFolderURL = try AppDataPaths.deckFolderURL(deckID: deckID)
            let mediaFolderURL = deckFolderURL.appendingPathComponent(AppDataPaths.deckMediaFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: mediaFolderURL, withIntermediateDirectories: true)
            let mediaFileURL = mediaFolderURL.appendingPathComponent("\(mediaID.databaseString).png")
            try Data([1, 2, 3]).write(to: mediaFileURL)
            #expect(FileManager.default.fileExists(atPath: mediaFileURL.path))

            let failedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            try database.saveStudyReview(
                StudyReviewEvent(
                    id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
                    cardID: cardID,
                    deckID: deckID,
                    mode: .flashcards,
                    outcome: .forgot,
                    reviewedAt: failedAt,
                    durationMS: 1000,
                    wasNew: false,
                    previousState: "review",
                    newState: "review"
                )
            )
            #expect(try database.weakCards(limit: 10).map(\.cardID) == [cardID])

            try database.importServerBootstrap(
                bootstrap(includeAssignment: false, includeContent: false),
                selectedUserID: userID
            )

            #expect(try database.loadDecks().isEmpty)
            #expect(try database.cachedDeckVersionIDs().isEmpty)
            #expect(try database.mediaObjects(ids: [mediaID]).isEmpty)
            #expect(try database.weakCards(limit: 10).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: deckFolderURL.path))

            try database.importServerBootstrap(bootstrap(includeContent: false), selectedUserID: userID)
            let reintroducedDeck = try #require(database.loadDecks().first)
            #expect(reintroducedDeck.cards.isEmpty)
        }
    }

    @Test("archived assignment keeps deck cached but removes it from active weak cards")
    func archivedAssignmentKeepsDeckCachedButRemovesItFromActiveWeakCards() throws {
        try withIsolatedDatabase { database in
            let failedAt = try #require(Self.isoDate("2026-06-02T12:00:00.000Z"))
            try database.importServerBootstrap(
                bootstrap(
                    reviews: [
                        reviewJSON(
                            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                            outcome: "forgot",
                            reviewedAt: "2026-06-02T12:00:00.000Z",
                            wasNew: false
                        ),
                    ]
                ),
                selectedUserID: userID
            )
            #expect(try database.weakCards(limit: 10).map(\.cardID) == [cardID])

            try database.importServerBootstrap(
                bootstrap(
                    assignmentStatus: "archived",
                    includeContent: false
                ),
                selectedUserID: userID
            )

            let deck = try #require(database.loadDecks().first)
            #expect(deck.id == deckID)
            #expect(!deck.isActive)
            #expect(deck.cards.map(\.id) == [cardID])
            #expect(try database.cachedDeckVersionIDs() == [versionID])
            #expect(try database.weakCards(limit: 10).isEmpty)
            #expect(try database.studyReviewCount(since: failedAt).total == 1)
        }
    }

    @Test("archived assignment keeps unused cleanup from deleting cached deck files")
    func archivedAssignmentKeepsUnusedCleanupFromDeletingCachedDeckFiles() throws {
        try withIsolatedDatabase { database in
            try database.importServerBootstrap(bootstrap(cardImageMediaID: mediaID, media: [mediaJSON()]), selectedUserID: userID)
            let deckFolderURL = try AppDataPaths.deckFolderURL(deckID: deckID)
            let mediaFolderURL = deckFolderURL.appendingPathComponent(AppDataPaths.deckMediaFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: mediaFolderURL, withIntermediateDirectories: true)
            let mediaFileURL = mediaFolderURL.appendingPathComponent("\(mediaID.databaseString).png")
            try Data([1, 2, 3]).write(to: mediaFileURL)

            try database.importServerBootstrap(
                bootstrap(assignmentStatus: "archived", includeContent: false),
                selectedUserID: userID
            )

            #expect(FileManager.default.fileExists(atPath: mediaFileURL.path))
            #expect(try database.cachedDeckVersionIDs() == [versionID])
            #expect(try database.mediaObjects(ids: [mediaID]).map(\.id) == [mediaID])
        }
    }

    @Test("loadDecks resolves card and example media through bulk media lookup")
    func loadDecksResolvesCardAndExampleMediaThroughBulkLookup() throws {
        try withIsolatedDatabase { database in
            let mediaIDs = [mediaID, audioWordMediaID, exampleImageMediaID, audioExampleMediaID]
            try database.importServerBootstrap(
                bootstrap(
                    cardImageMediaID: mediaID,
                    audioWordMediaID: audioWordMediaID,
                    exampleImageMediaID: exampleImageMediaID,
                    audioExampleMediaID: audioExampleMediaID,
                    media: mediaIDs.map { mediaJSON(id: $0) }
                ),
                selectedUserID: userID
            )
            let mediaFolderURL = try AppDataPaths.deckFolderURL(deckID: deckID)
                .appendingPathComponent(AppDataPaths.deckMediaFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: mediaFolderURL, withIntermediateDirectories: true)
            for id in mediaIDs {
                try Data([1, 2, 3]).write(to: mediaFolderURL.appendingPathComponent("\(id.databaseString).png"))
            }

            let deck = try #require(database.loadDecks().first)
            let card = try #require(deck.cards.first)
            #expect(card.imageURL?.lastPathComponent == "\(mediaID.databaseString).png")
            #expect(card.audioWordURL?.lastPathComponent == "\(audioWordMediaID.databaseString).png")
            #expect(card.clozeExampleImageURL?.lastPathComponent == "\(exampleImageMediaID.databaseString).png")
            #expect(card.audioExampleURL?.lastPathComponent == "\(audioExampleMediaID.databaseString).png")
        }
    }

    @Test("bootstrap server revision is readable after reopening database")
    func bootstrapServerRevisionIsReadableAfterReopeningDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashgame-db-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppDataPaths.dataDirectoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        AppDataPaths.dataDirectoryOverride = root
        let database = try ContentDatabase(userID: userID)
        try database.importServerBootstrap(
            bootstrap(serverRevision: "123"),
            selectedUserID: userID
        )
        #expect(try database.serverRevision() == "123")

        let reopenedDatabase = try ContentDatabase(userID: userID)
        #expect(try reopenedDatabase.serverRevision() == "123")
    }

    @Test("concurrent database opens serialize setup")
    func concurrentDatabaseOpensSerializeSetup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashgame-db-tests-\(UUID().uuidString)", isDirectory: true)
        let testUserID = userID
        defer {
            AppDataPaths.dataDirectoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        AppDataPaths.dataDirectoryOverride = root
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let database = try ContentDatabase(userID: testUserID)
                    return try database.loadDecks().count
                }
            }

            for try await deckCount in group {
                #expect(deckCount == 0)
            }
        }
    }

    private func withIsolatedDatabase(_ operation: (ContentDatabase) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashgame-db-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppDataPaths.dataDirectoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        AppDataPaths.dataDirectoryOverride = root
        let database = try ContentDatabase(userID: userID)
        try operation(database)
    }

    private func bootstrap(
        progress: [String] = [],
        reviews: [String] = [],
        practiceReviews: [String] = [],
        matchingAttempts: [String] = [],
        dailyUsage: [String]? = nil,
        includeAssignment: Bool = true,
        assignmentStatus: String = "active",
        includeContent: Bool = true,
        cardImageMediaID: UUID? = nil,
        audioWordMediaID: UUID? = nil,
        exampleImageMediaID: UUID? = nil,
        audioExampleMediaID: UUID? = nil,
        media: [String] = [],
        userEnabled: Bool = true,
        preferenceUpdatedAt: String? = nil,
        legacyAssignmentVersionID: UUID? = nil,
        serverRevision: String? = nil
    ) throws -> ServerBootstrap {
        let cardImageMediaValue = cardImageMediaID.map { #"""# + $0.databaseString + #"""# } ?? "null"
        let audioWordMediaValue = audioWordMediaID.map { #"""# + $0.databaseString + #"""# } ?? "null"
        let exampleImageMediaValue = exampleImageMediaID.map { #"""# + $0.databaseString + #"""# } ?? "null"
        let audioExampleMediaValue = audioExampleMediaID.map { #"""# + $0.databaseString + #"""# } ?? "null"
        let preferenceUpdatedAtValue = preferenceUpdatedAt.map { #"""# + $0 + #"""# } ?? "null"
        let contentJSON = includeContent
            ? """
              {
                "cards": [
                  {
                    "deck_version_id": "\(versionID.databaseString)",
                    "card_id": "\(cardID.databaseString)",
                    "status": "active",
                    "lemma": "test",
                    "display_word": "test",
                    "part_of_speech": "noun",
                    "translation": "test translation",
                    "short_definition": null,
                    "memory_hint": null,
                    "etymology": null,
                    "usage_note": null,
                    "synonym_note": null,
                    "grammar_note": null,
                    "notes": null,
                    "image_media_id": \(cardImageMediaValue),
                    "audio_word_media_id": \(audioWordMediaValue),
                    "sort_order": 1
                  }
                ],
                "examples": [
                  {
                    "deck_version_id": "\(versionID.databaseString)",
                    "example_id": "\(exampleID.databaseString)",
                    "card_id": "\(cardID.databaseString)",
                    "template": "This is a {{blank}}.",
                    "answer": "test",
                    "answer_form_key": null,
                    "translation": "Это тест.",
                    "note": null,
                    "image_media_id": \(exampleImageMediaValue),
                    "audio_example_media_id": \(audioExampleMediaValue),
                    "sort_order": 1
                  }
                ],
                "forms": [],
                "distractors": []
              }
              """
            : """
              {
                "cards": [],
                "examples": [],
                "forms": [],
                "distractors": []
              }
              """
        let assignmentDeckVersionValue = legacyAssignmentVersionID.map { #"""# + $0.databaseString + #"""# } ?? "null"
        let assignmentsJSON = includeAssignment
            ? """
              [
                {
                  "user_id": "\(userID.databaseString)",
                  "deck_id": "\(deckID.databaseString)",
                  "deck_version_id": \(assignmentDeckVersionValue),
                  "assignment_status": "\(assignmentStatus)",
                  "title": "Test Deck",
                  "avatar_system_name": "book",
                  "avatar_media_id": null,
                  "language_code": "en",
                  "current_version_id": "\(versionID.databaseString)",
                  "version_number": 1,
                  "version_status": "published",
                  "user_enabled": \(userEnabled ? "true" : "false"),
                  "preference_updated_at": \(preferenceUpdatedAtValue),
                  "manifest": {
                    "new_cards_per_day": 10,
                    "review_cards_per_day": 100
                  }
                }
              ]
              """
            : "[]"
        let json = """
        {
          "user": {
            "id": "\(userID.databaseString)",
            "display_name": "Test Learner",
            "avatar_media_id": null
          },
          "users": [
            {
              "id": "\(userID.databaseString)",
              "display_name": "Test Learner",
              "avatar_media_id": null
            }
          ],
          "assignments": \(assignmentsJSON),
          "content": \(contentJSON),
          "media": [\(media.joined(separator: ","))],
          "progress": [\(progress.joined(separator: ","))],
          "reviews": [\(reviews.joined(separator: ","))],
          "practice_reviews": [\(practiceReviews.joined(separator: ","))],
          "matching_attempts": [\(matchingAttempts.joined(separator: ","))],
          \(dailyUsage.map { #""daily_usage": ["# + $0.joined(separator: ",") + #"],"# } ?? "")
          \(serverRevision.map { #""serverRevision": ""# + $0 + #"","# } ?? "")
          "matching_records": []
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ServerBootstrap.self, from: Data(json.utf8))
    }

    private func reviewJSON(
        id: UUID,
        outcome: String,
        reviewedAt: String,
        wasNew: Bool
    ) -> String {
        """
        {
          "client_event_id": "\(id.databaseString)",
          "deck_id": "\(deckID.databaseString)",
          "deck_version_id": "\(versionID.databaseString)",
          "card_id": "\(cardID.databaseString)",
          "mode": "flashcards",
          "outcome": "\(outcome)",
          "reviewed_at": "\(reviewedAt)",
          "duration_ms": 1000,
          "was_new": \(wasNew ? "true" : "false"),
          "previous_state": "new",
          "new_state": "review"
        }
        """
    }

    private func reviewJSONs(outcomes: [String], day: String = "2026-06-02") -> [String] {
        outcomes.enumerated().map { index, outcome in
            let id = UUID(uuidString: String(format: "55555555-5555-4555-8555-%012d", index + 1))!
            let reviewedAt = String(format: "%@T12:%02d:00.000Z", day, index)
            return reviewJSON(id: id, outcome: outcome, reviewedAt: reviewedAt, wasNew: false)
        }
    }

    private func practiceReviewJSON(
        id: UUID,
        mode: String,
        practicedAt: String,
        durationMS: Int
    ) -> String {
        """
        {
          "client_event_id": "\(id.databaseString)",
          "deck_id": "\(deckID.databaseString)",
          "deck_version_id": "\(versionID.databaseString)",
          "card_id": "\(cardID.databaseString)",
          "mode": "\(mode)",
          "outcome": "correct",
          "source": "today_practice",
          "practiced_at": "\(practicedAt)",
          "duration_ms": \(durationMS)
        }
        """
    }

    private func matchingAttemptJSON(
        id: UUID,
        mode: String,
        completedAt: String
    ) -> String {
        """
        {
          "client_event_id": "\(id.databaseString)",
          "deck_id": "\(deckID.databaseString)",
          "mode": "\(mode)",
          "source": "deck_session",
          "completed_at": "\(completedAt)",
          "duration_ms": 12000,
          "pair_count": 4
        }
        """
    }

    private func mediaJSON(id: UUID? = nil) -> String {
        let id = id ?? mediaID
        return """
        {
          "id": "\(id.databaseString)",
          "storage_key": "media/\(id.databaseString).png",
          "sha256": null,
          "mime_type": "image/png",
          "byte_size": 3,
          "width": 1,
          "height": 1
        }
        """
    }

    private func progressJSON(
        dueAt: String,
        updatedAt: String
    ) throws -> String {
        let dueDate = try #require(Self.isoDate(dueAt))
        let progress = CardProgress.newCard(cardID: cardID, now: dueDate)
        let fsrsObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress.fsrsCard))
        let fsrsData = try JSONSerialization.data(withJSONObject: fsrsObject)
        let fsrsJSON = String(decoding: fsrsData, as: UTF8.self)
        return """
        {
          "card_id": "\(cardID.databaseString)",
          "deck_id": "\(deckID.databaseString)",
          "fsrs_data": \(fsrsJSON),
          "due_at": "\(dueAt)",
          "state": "review",
          "updated_at": "\(updatedAt)"
        }
        """
    }

    private func dailyUsageJSON(
        dayKey: String,
        newCardsStudied: Int
    ) -> String {
        """
        {
          "deck_id": "\(deckID.databaseString)",
          "day_key": "\(dayKey)",
          "new_cards_studied": \(newCardsStudied)
        }
        """
    }

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
