import Foundation

enum AppUserRefreshResult: Equatable, Sendable {
    case loaded(userCount: Int, assignmentCount: Int, activeAssignmentCount: Int)
    case loadedWithMediaWarnings(
        userCount: Int,
        assignmentCount: Int,
        activeAssignmentCount: Int,
        failedMediaCount: Int
    )
    case missingConfiguration
    case emptyServer
    case cancelled
    case failed(String)

    var message: String? {
        switch self {
        case .loaded(let userCount, let assignmentCount, let activeAssignmentCount):
            if userCount == 0 {
                nil
            } else if assignmentCount == 0 {
                "Пользователи загружены, но выбранному пользователю пока не назначены колоды."
            } else if activeAssignmentCount == 0 {
                "Колоды загружены, но все назначения сейчас неактивны."
            } else {
                "Синхронизация выполнена."
            }
        case .loadedWithMediaWarnings(_, _, _, let failedMediaCount):
            "Данные загружены, но не удалось скачать медиа: \(failedMediaCount). Повторите синхронизацию позже."
        case .missingConfiguration:
            "Нужно настроить SERVER_BASE_URL и HOUSEHOLD_SYNC_TOKEN."
        case .emptyServer:
            "Сервер доступен, но пользователей пока нет."
        case .cancelled:
            "Синхронизация была прервана. Попробуйте ещё раз."
        case .failed(let message):
            message
        }
    }
}

enum AppUserSyncPhase: Equatable, Sendable {
    case idle
    case syncing
    case completed
    case warning
    case blocked
    case failed
    case cancelled
}

struct AppUserSyncStatus: Equatable, Sendable {
    let phase: AppUserSyncPhase
    let userID: UUID?
    let startedAt: Date?
    let finishedAt: Date?
    let result: AppUserRefreshResult?

    static let idle = AppUserSyncStatus(
        phase: .idle,
        userID: nil,
        startedAt: nil,
        finishedAt: nil,
        result: nil
    )

    var isSyncing: Bool {
        phase == .syncing
    }

    func isRelevant(to selectedUserID: UUID?) -> Bool {
        guard phase != .idle else { return false }
        return userID == selectedUserID
    }

    static func syncing(userID: UUID?, startedAt: Date = .now) -> AppUserSyncStatus {
        AppUserSyncStatus(
            phase: .syncing,
            userID: userID,
            startedAt: startedAt,
            finishedAt: nil,
            result: nil
        )
    }

    static func finished(
        result: AppUserRefreshResult,
        userID: UUID?,
        startedAt: Date?,
        finishedAt: Date = .now
    ) -> AppUserSyncStatus {
        AppUserSyncStatus(
            phase: phase(for: result),
            userID: userID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            result: result
        )
    }

    private static func phase(for result: AppUserRefreshResult) -> AppUserSyncPhase {
        switch result {
        case .loaded:
            .completed
        case .loadedWithMediaWarnings:
            .warning
        case .missingConfiguration, .emptyServer:
            .blocked
        case .cancelled:
            .cancelled
        case .failed:
            .failed
        }
    }
}
