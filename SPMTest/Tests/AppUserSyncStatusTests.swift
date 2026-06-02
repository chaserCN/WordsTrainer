import Foundation
import Testing
@testable import WordsTrainerLogic

struct AppUserSyncStatusTests {
    @Test("syncing status is relevant only to its selected user")
    func syncingStatusRelevance() {
        let selectedUserID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let otherUserID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let status = AppUserSyncStatus.syncing(userID: selectedUserID, startedAt: Date(timeIntervalSince1970: 10))

        #expect(status.isSyncing)
        #expect(status.isRelevant(to: selectedUserID))
        #expect(!status.isRelevant(to: otherUserID))
        #expect(!AppUserSyncStatus.idle.isRelevant(to: selectedUserID))
    }

    @Test(
        "refresh results map to sync phases",
        arguments: [
            (AppUserRefreshResult.loaded(userCount: 1, assignmentCount: 1, activeAssignmentCount: 1), AppUserSyncPhase.completed),
            (AppUserRefreshResult.loadedWithMediaWarnings(userCount: 1, assignmentCount: 1, activeAssignmentCount: 1, failedMediaCount: 2), AppUserSyncPhase.warning),
            (AppUserRefreshResult.missingConfiguration, AppUserSyncPhase.blocked),
            (AppUserRefreshResult.emptyServer, AppUserSyncPhase.blocked),
            (AppUserRefreshResult.cancelled, AppUserSyncPhase.cancelled),
            (AppUserRefreshResult.failed("boom"), AppUserSyncPhase.failed),
        ]
    )
    func resultPhaseMapping(result: AppUserRefreshResult, phase: AppUserSyncPhase) {
        let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let startedAt = Date(timeIntervalSince1970: 10)
        let finishedAt = Date(timeIntervalSince1970: 20)

        let status = AppUserSyncStatus.finished(
            result: result,
            userID: userID,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        #expect(status.phase == phase)
        #expect(status.userID == userID)
        #expect(status.startedAt == startedAt)
        #expect(status.finishedAt == finishedAt)
        #expect(status.result == result)
    }
}
