import Foundation
import OSLog

struct ServerBootstrap: Decodable, Sendable {
    let user: ServerUser?
    let users: [ServerUser]
    let assignments: [ServerDeckAssignment]
    let content: ServerContentPayload
    let media: [ServerMediaObject]
    let progress: [ServerProgressPayload]
    let reviews: [ServerReviewEventPayload]
    let practiceReviews: [ServerPracticeReviewPayload]
    let studyDataResets: [ServerStudyDataResetPayload]
    let matchingRecords: [ServerMatchingRecordPayload]
    let matchingAttempts: [ServerMatchingAttemptPayload]
    let userSettings: [ServerUserSettingsPayload]
    let serverRevision: String?

    init(
        user: ServerUser?,
        users: [ServerUser],
        assignments: [ServerDeckAssignment],
        content: ServerContentPayload,
        media: [ServerMediaObject],
        progress: [ServerProgressPayload],
        reviews: [ServerReviewEventPayload],
        practiceReviews: [ServerPracticeReviewPayload] = [],
        studyDataResets: [ServerStudyDataResetPayload] = [],
        matchingRecords: [ServerMatchingRecordPayload],
        matchingAttempts: [ServerMatchingAttemptPayload] = [],
        userSettings: [ServerUserSettingsPayload] = [],
        serverRevision: String? = nil
    ) {
        self.user = user
        self.users = users
        self.assignments = assignments
        self.content = content
        self.media = media
        self.progress = progress
        self.reviews = reviews
        self.practiceReviews = practiceReviews
        self.studyDataResets = studyDataResets
        self.matchingRecords = matchingRecords
        self.matchingAttempts = matchingAttempts
        self.userSettings = userSettings
        self.serverRevision = serverRevision
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case user
        case users
        case snapshot
    }

    private enum SnapshotKeys: String, CodingKey {
        case assignments
        case content
        case media
        case progress
        case reviews
        case practiceReviews
        case studyDataResets
        case matchingRecords
        case matchingAttempts
        case userSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snapshot = try container.nestedContainer(keyedBy: SnapshotKeys.self, forKey: .snapshot)
        user = try container.decodeIfPresent(ServerUser.self, forKey: .user)
        users = try container.decodeIfPresent([ServerUser].self, forKey: .users) ?? []
        assignments = try snapshot.decodeIfPresent([ServerDeckAssignment].self, forKey: .assignments) ?? []
        content = try snapshot.decodeIfPresent(ServerContentPayload.self, forKey: .content) ?? .empty
        media = try snapshot.decodeIfPresent([ServerMediaObject].self, forKey: .media) ?? []
        progress = try snapshot.decodeIfPresent([ServerProgressPayload].self, forKey: .progress) ?? []
        reviews = try snapshot.decodeIfPresent([ServerReviewEventPayload].self, forKey: .reviews) ?? []
        practiceReviews = try snapshot.decodeIfPresent([ServerPracticeReviewPayload].self, forKey: .practiceReviews) ?? []
        studyDataResets = try snapshot.decodeIfPresent([ServerStudyDataResetPayload].self, forKey: .studyDataResets) ?? []
        matchingRecords = try snapshot.decodeIfPresent([ServerMatchingRecordPayload].self, forKey: .matchingRecords) ?? []
        matchingAttempts = try snapshot.decodeIfPresent([ServerMatchingAttemptPayload].self, forKey: .matchingAttempts) ?? []
        userSettings = try snapshot.decodeIfPresent([ServerUserSettingsPayload].self, forKey: .userSettings) ?? []
        serverRevision = try container.decodeIfPresent(String.self, forKey: .revision)
    }
}

struct ServerSyncChanges: Decodable, Sendable {
    let users: [ServerUser]
    let assignments: [ServerDeckAssignment]
    let content: ServerContentPayload
    let media: [ServerMediaObject]
    let progress: [ServerProgressPayload]
    let reviews: [ServerReviewEventPayload]
    let practiceReviews: [ServerPracticeReviewPayload]
    let studyDataResets: [ServerStudyDataResetPayload]
    let matchingRecords: [ServerMatchingRecordPayload]
    let matchingAttempts: [ServerMatchingAttemptPayload]
    let userSettings: [ServerUserSettingsPayload]
    let serverRevision: String?

    private enum CodingKeys: String, CodingKey {
        case changes
        case toRevision
    }

    private enum ChangeKeys: String, CodingKey {
        case users
        case assignments
        case content
        case media
        case progress
        case reviews
        case practiceReviews
        case studyDataResets
        case matchingRecords
        case matchingAttempts
        case userSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let changes = try container.nestedContainer(keyedBy: ChangeKeys.self, forKey: .changes)
        users = try changes.decodeIfPresent([ServerUser].self, forKey: .users) ?? []
        assignments = try changes.decodeIfPresent([ServerDeckAssignment].self, forKey: .assignments) ?? []
        content = try changes.decodeIfPresent(ServerContentPayload.self, forKey: .content) ?? .empty
        media = try changes.decodeIfPresent([ServerMediaObject].self, forKey: .media) ?? []
        progress = try changes.decodeIfPresent([ServerProgressPayload].self, forKey: .progress) ?? []
        reviews = try changes.decodeIfPresent([ServerReviewEventPayload].self, forKey: .reviews) ?? []
        practiceReviews = try changes.decodeIfPresent([ServerPracticeReviewPayload].self, forKey: .practiceReviews) ?? []
        studyDataResets = try changes.decodeIfPresent([ServerStudyDataResetPayload].self, forKey: .studyDataResets) ?? []
        matchingRecords = try changes.decodeIfPresent([ServerMatchingRecordPayload].self, forKey: .matchingRecords) ?? []
        matchingAttempts = try changes.decodeIfPresent([ServerMatchingAttemptPayload].self, forKey: .matchingAttempts) ?? []
        userSettings = try changes.decodeIfPresent([ServerUserSettingsPayload].self, forKey: .userSettings) ?? []
        serverRevision = try container.decodeIfPresent(String.self, forKey: .toRevision)
    }
}

struct ServerUser: Decodable, Sendable {
    let id: UUID
    let displayName: String
    let avatarMediaId: UUID?

    var appUser: AppUser {
        AppUser(
            id: id,
            displayName: displayName,
            avatarMediaID: avatarMediaId,
            avatarImageURL: nil,
            accentHue: Self.accentHue(for: id)
        )
    }

    private static func accentHue(for id: UUID) -> Double {
        let total = id.uuidString.unicodeScalars.reduce(0) { partial, scalar in
            partial + Int(scalar.value)
        }
        return Double(total % 360)
    }
}

struct ServerDeckManifest: Decodable, Sendable {
    let newCardsPerDay: Int?
    let reviewCardsPerDay: Int?
}

struct ServerDeckAssignment: Decodable, Sendable {
    let userId: UUID
    let deckId: UUID
    let deckVersionId: UUID?
    let assignmentStatus: String
    let title: String
    let avatarSystemName: String?
    let avatarMediaId: UUID?
    let languageCode: String
    let currentVersionId: UUID?
    let versionNumber: Int?
    let versionStatus: String?
    let manifest: ServerDeckManifest?
    let userEnabled: Bool?
    let preferenceUpdatedAt: String?
    let deckGroupId: UUID?
    let deckGroupTitle: String?
    let deckGroupSortOrder: Int?
    let deckSortOrder: Int?
}

struct ServerContentPayload: Decodable, Sendable {
    static let empty = ServerContentPayload(cards: [], senses: [], examples: [], sentenceQuestions: [], forms: [], distractors: [])

    let cards: [ServerCardContent]
    let senses: [ServerSenseContent]
    let examples: [ServerExampleContent]
    let sentenceQuestions: [ServerSentenceQuestionContent]
    let forms: [ServerWordFormContent]
    let distractors: [ServerDistractorContent]

    init(
        cards: [ServerCardContent],
        senses: [ServerSenseContent],
        examples: [ServerExampleContent],
        sentenceQuestions: [ServerSentenceQuestionContent],
        forms: [ServerWordFormContent],
        distractors: [ServerDistractorContent]
    ) {
        self.cards = cards
        self.senses = senses
        self.examples = examples
        self.sentenceQuestions = sentenceQuestions
        self.forms = forms
        self.distractors = distractors
    }

    private enum CodingKeys: String, CodingKey {
        case cards
        case senses
        case examples
        case sentenceQuestions
        case forms
        case distractors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cards = try container.decodeIfPresent([ServerCardContent].self, forKey: .cards) ?? []
        senses = try container.decodeIfPresent([ServerSenseContent].self, forKey: .senses) ?? []
        examples = try container.decodeIfPresent([ServerExampleContent].self, forKey: .examples) ?? []
        sentenceQuestions = try container.decodeIfPresent(
            [ServerSentenceQuestionContent].self,
            forKey: .sentenceQuestions
        ) ?? []
        forms = try container.decodeIfPresent([ServerWordFormContent].self, forKey: .forms) ?? []
        distractors = try container.decodeIfPresent([ServerDistractorContent].self, forKey: .distractors) ?? []
    }
}

struct ServerCardContent: Decodable, Sendable {
    let deckVersionId: UUID
    let cardId: UUID
    let status: String
    let lemma: String
    let displayWord: String
    let partOfSpeech: String?
    let etymology: String?
    let notes: String?
    let primarySenseId: UUID?
    let audioWordMediaId: UUID?
    let sortOrder: Int?
}

struct ServerSenseContent: Decodable, Sendable {
    let deckVersionId: UUID
    let senseId: UUID
    let cardId: UUID
    let status: String
    let displayPattern: String?
    let translation: String
    let note: String?
    let imageMediaId: UUID?
    let sortOrder: Int?
}

struct ServerExampleContent: Decodable, Sendable {
    let deckVersionId: UUID
    let cardId: UUID
    let senseId: UUID
    let text: String
    let translation: String?
    let note: String?
    let sortOrder: Int?
}

struct ServerSentenceQuestionContent: Decodable, Sendable {
    let deckVersionId: UUID
    let cardId: UUID
    let senseId: UUID
    let template: String
    let answer: String
    let translation: String?
    let answerFormKey: String?
    let audioAnswerMediaId: UUID?
    let sortOrder: Int?
}

struct ServerWordFormContent: Decodable, Sendable {
    let deckVersionId: UUID
    let cardId: UUID
    let formKey: String
    let text: String
    let sortOrder: Int?
}

struct ServerDistractorContent: Decodable, Sendable {
    let id: UUID
    let deckVersionId: UUID
    let senseId: UUID
    let text: String
    let sourceCardId: UUID?
    let priority: Int?
}

nonisolated struct ServerMediaObject: Decodable, Sendable {
    let id: UUID
    let storageKey: String?
    let sha256: String?
    let mimeType: String?
    let byteSize: Int?
    let width: Int?
    let height: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case storageKey
        case sha256
        case mimeType
        case byteSize
        case width
        case height
    }

    init(
        id: UUID,
        storageKey: String?,
        sha256: String?,
        mimeType: String?,
        byteSize: Int?,
        width: Int?,
        height: Int?
    ) {
        self.id = id
        self.storageKey = storageKey
        self.sha256 = sha256
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        byteSize = try container.decodeFlexibleIntIfPresent(forKey: .byteSize)
        width = try container.decodeFlexibleIntIfPresent(forKey: .width)
        height = try container.decodeFlexibleIntIfPresent(forKey: .height)
    }
}

private extension KeyedDecodingContainer {
    nonisolated func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        guard let stringValue = try decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let value = Int(stringValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected an integer or numeric string."
            )
        }
        return value
    }
}

struct ServerSyncEventsPayload: Encodable, Sendable {
    var reviews: [ServerReviewEventPayload] = []
    var practiceReviews: [ServerPracticeReviewPayload] = []
    var progress: [ServerProgressPayload] = []
    var matchingRecords: [ServerMatchingRecordPayload] = []
    var matchingAttempts: [ServerMatchingAttemptPayload] = []
    var deckPreferences: [ServerDeckPreferencePayload] = []

    var isEmpty: Bool {
        reviews.isEmpty
            && practiceReviews.isEmpty
            && progress.isEmpty
            && matchingRecords.isEmpty
            && matchingAttempts.isEmpty
            && deckPreferences.isEmpty
    }
}

struct ServerReviewEventPayload: Codable, Sendable {
    let clientEventId: UUID
    let deckId: UUID
    let deckVersionId: UUID?
    let cardId: UUID
    let senseId: UUID
    let mode: String
    let outcome: String
    let source: String?
    let reviewedAt: String
    let durationMs: Int?
    let wasNew: Bool
    let previousState: String?
    let newState: String?
}

struct ServerProgressPayload: Codable, Sendable {
    let senseId: UUID
    let cardId: UUID
    let deckId: UUID
    let fsrsData: JSONValue
    let dueAt: String?
    let state: String?
    let updatedAt: String?

    init(
        senseId: UUID,
        cardId: UUID,
        deckId: UUID,
        fsrsData: JSONValue,
        dueAt: String?,
        state: String?,
        updatedAt: String?
    ) {
        self.senseId = senseId
        self.cardId = cardId
        self.deckId = deckId
        self.fsrsData = fsrsData
        self.dueAt = dueAt
        self.state = state
        self.updatedAt = updatedAt
    }
}

struct ServerPracticeReviewPayload: Codable, Sendable {
    let clientEventId: UUID
    let deckId: UUID
    let deckVersionId: UUID?
    let cardId: UUID
    let senseId: UUID
    let mode: String
    let outcome: String
    let source: String
    let practicedAt: String
    let durationMs: Int?
}

struct ServerMatchingRecordPayload: Codable, Sendable {
    let deckId: UUID
    let deckVersionId: UUID?
    let bestDurationSeconds: Double
    let pairCount: Int
    let achievedAt: String
}

struct ServerMatchingAttemptPayload: Codable, Sendable {
    let clientEventId: UUID
    let deckId: UUID?
    let deckVersionId: UUID?
    let mode: String
    let source: String
    let completedAt: String
    let durationMs: Int
    let pairCount: Int
}

struct ServerDeckPreferencePayload: Codable, Sendable {
    let deckId: UUID
    let isEnabled: Bool
    let updatedAt: String?
}

struct ServerStudyDataResetPayload: Codable, Sendable {
    let userId: UUID
    let deckId: UUID?
    let resetAt: String
    let serverRevision: String?
}

struct ServerUserSettingsPayload: Codable, Sendable {
    let userId: UUID
    let randomCardCount: Int
    let updatedAt: String?
    let serverRevision: String?
}

struct ServerSyncEventsResponse: Decodable, Sendable {
    let acceptedReviewIds: [UUID]
    let duplicateReviewIds: [UUID]
    let acceptedPracticeReviewIds: [UUID]
    let duplicatePracticeReviewIds: [UUID]
    let progressSenseIds: [UUID]
    let matchingRecordDeckIds: [UUID]
    let acceptedMatchingAttemptIds: [UUID]
    let duplicateMatchingAttemptIds: [UUID]
    let deckPreferenceDeckIds: [UUID]
    let rejectedReviewIds: [UUID]
    let rejectedPracticeReviewIds: [UUID]
    let rejectedProgressSenseIds: [UUID]
    let rejectedMatchingRecordDeckIds: [UUID]
    let rejectedMatchingAttemptIds: [UUID]
    let rejectedDeckPreferenceDeckIds: [UUID]
    let serverRevision: String?

    init(
        acceptedReviewIds: [UUID],
        duplicateReviewIds: [UUID],
        acceptedPracticeReviewIds: [UUID] = [],
        duplicatePracticeReviewIds: [UUID] = [],
        progressSenseIds: [UUID],
        matchingRecordDeckIds: [UUID],
        acceptedMatchingAttemptIds: [UUID] = [],
        duplicateMatchingAttemptIds: [UUID] = [],
        deckPreferenceDeckIds: [UUID],
        rejectedReviewIds: [UUID] = [],
        rejectedPracticeReviewIds: [UUID] = [],
        rejectedProgressSenseIds: [UUID] = [],
        rejectedMatchingRecordDeckIds: [UUID] = [],
        rejectedMatchingAttemptIds: [UUID] = [],
        rejectedDeckPreferenceDeckIds: [UUID] = [],
        serverRevision: String?
    ) {
        self.acceptedReviewIds = acceptedReviewIds
        self.duplicateReviewIds = duplicateReviewIds
        self.acceptedPracticeReviewIds = acceptedPracticeReviewIds
        self.duplicatePracticeReviewIds = duplicatePracticeReviewIds
        self.progressSenseIds = progressSenseIds
        self.matchingRecordDeckIds = matchingRecordDeckIds
        self.acceptedMatchingAttemptIds = acceptedMatchingAttemptIds
        self.duplicateMatchingAttemptIds = duplicateMatchingAttemptIds
        self.deckPreferenceDeckIds = deckPreferenceDeckIds
        self.rejectedReviewIds = rejectedReviewIds
        self.rejectedPracticeReviewIds = rejectedPracticeReviewIds
        self.rejectedProgressSenseIds = rejectedProgressSenseIds
        self.rejectedMatchingRecordDeckIds = rejectedMatchingRecordDeckIds
        self.rejectedMatchingAttemptIds = rejectedMatchingAttemptIds
        self.rejectedDeckPreferenceDeckIds = rejectedDeckPreferenceDeckIds
        self.serverRevision = serverRevision
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
        case duplicates
        case rejected
        case toRevision
    }

    private enum GroupKeys: String, CodingKey {
        case reviewIds
        case practiceReviewIds
        case progressSenseIds
        case matchingRecordDeckIds
        case matchingAttemptIds
        case deckPreferenceDeckIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accepted = try container.nestedContainer(keyedBy: GroupKeys.self, forKey: .accepted)
        let duplicates = try container.nestedContainer(keyedBy: GroupKeys.self, forKey: .duplicates)
        let rejected = try container.nestedContainer(keyedBy: GroupKeys.self, forKey: .rejected)
        acceptedReviewIds = try accepted.decodeIfPresent([UUID].self, forKey: .reviewIds) ?? []
        duplicateReviewIds = try duplicates.decodeIfPresent([UUID].self, forKey: .reviewIds) ?? []
        acceptedPracticeReviewIds = try accepted.decodeIfPresent([UUID].self, forKey: .practiceReviewIds) ?? []
        duplicatePracticeReviewIds = try duplicates.decodeIfPresent([UUID].self, forKey: .practiceReviewIds) ?? []
        progressSenseIds = try accepted.decodeIfPresent([UUID].self, forKey: .progressSenseIds) ?? []
        matchingRecordDeckIds = try accepted.decodeIfPresent([UUID].self, forKey: .matchingRecordDeckIds) ?? []
        acceptedMatchingAttemptIds = try accepted.decodeIfPresent([UUID].self, forKey: .matchingAttemptIds) ?? []
        duplicateMatchingAttemptIds = try duplicates.decodeIfPresent([UUID].self, forKey: .matchingAttemptIds) ?? []
        deckPreferenceDeckIds = try accepted.decodeIfPresent([UUID].self, forKey: .deckPreferenceDeckIds) ?? []
        rejectedReviewIds = try rejected.decodeIfPresent([UUID].self, forKey: .reviewIds) ?? []
        rejectedPracticeReviewIds = try rejected.decodeIfPresent([UUID].self, forKey: .practiceReviewIds) ?? []
        rejectedProgressSenseIds = try rejected.decodeIfPresent([UUID].self, forKey: .progressSenseIds) ?? []
        rejectedMatchingRecordDeckIds = try rejected.decodeIfPresent([UUID].self, forKey: .matchingRecordDeckIds) ?? []
        rejectedMatchingAttemptIds = try rejected.decodeIfPresent([UUID].self, forKey: .matchingAttemptIds) ?? []
        rejectedDeckPreferenceDeckIds = try rejected.decodeIfPresent([UUID].self, forKey: .deckPreferenceDeckIds) ?? []
        serverRevision = try container.decodeIfPresent(String.self, forKey: .toRevision)
    }
}

nonisolated enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init?(jsonObject: Any) {
        switch jsonObject {
        case let dictionary as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, value) in dictionary {
                guard let converted = JSONValue(jsonObject: value) else { return nil }
                object[key] = converted
            }
            self = .object(object)
        case let array as [Any]:
            var values: [JSONValue] = []
            for value in array {
                guard let converted = JSONValue(jsonObject: value) else { return nil }
                values.append(converted)
            }
            self = .array(values)
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case _ as NSNull:
            self = .null
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum ServerSyncError: LocalizedError {
    case missingConfiguration
    case invalidBaseURL(String)
    case invalidResponse(String? = nil)
    case networkUnavailable
    case timedOut
    case cannotConnect
    case cannotFindHost
    case secureConnectionFailed
    case cancelled
    case httpStatus(code: Int, path: String? = nil)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            L10n.text("SERVER_BASE_URL и HOUSEHOLD_SYNC_TOKEN не настроены.")
        case .invalidBaseURL(let value):
            L10n.format("SERVER_BASE_URL некорректный: %@.", value)
        case .invalidResponse(let detail):
            if let detail, !detail.isEmpty {
                L10n.format("Сервер вернул некорректный ответ: %@.", detail)
            } else {
                L10n.text("Сервер вернул некорректный ответ.")
            }
        case .networkUnavailable:
            L10n.text("Нет подключения к интернету. Проверьте сеть и попробуйте снова.")
        case .timedOut:
            L10n.text("Сервер не ответил вовремя. Попробуйте ещё раз.")
        case .cannotConnect:
            L10n.text("Не удалось подключиться к серверу. Проверьте адрес сервера и сеть.")
        case .cannotFindHost:
            L10n.text("Не удалось найти сервер. Проверьте SERVER_BASE_URL.")
        case .secureConnectionFailed:
            L10n.text("Не удалось установить защищённое соединение с сервером.")
        case .cancelled:
            L10n.text("Синхронизация отменена.")
        case .httpStatus(let code, let path):
            Self.httpStatusMessage(code, path: path)
        }
    }

    private static func httpStatusMessage(_ code: Int, path: String?) -> String {
        switch code {
        case 401, 403:
            L10n.text("Сервер отклонил HOUSEHOLD_SYNC_TOKEN. Проверьте семейный sync token.")
        case 404:
            if let path, !path.isEmpty {
                L10n.format("Сервер доступен, но ресурс %@ не найден (404).", path)
            } else {
                L10n.text("Сервер доступен, но запрошенный ресурс не найден (404).")
            }
        case 500..<600:
            L10n.format("На сервере ошибка HTTP %d. Попробуйте позже.", code)
        default:
            L10n.format("Сервер вернул HTTP %d.", code)
        }
    }
}

struct ServerSyncClient: Sendable {
    static let shared = ServerSyncClient()
    private static let logger = Logger(subsystem: "com.uniweb.wordtrainer.Words-Trainer", category: "ServerSync")

    private enum Keys {
        static let baseURL = "server.baseURL"
        static let householdSyncToken = "server.householdSyncToken"
    }

    private let session: URLSession
    private let userDefaultsSuiteName: String?

    init(session: URLSession = .shared, userDefaultsSuiteName: String? = nil) {
        self.session = session
        self.userDefaultsSuiteName = userDefaultsSuiteName
    }

    var isConfigured: Bool {
        baseURLString != nil && householdSyncToken != nil
    }

    func bootstrap(
        selectedUserID: UUID?,
        cachedDeckVersionIDs: [UUID] = [],
        deviceID: UUID?
    ) async throws -> ServerBootstrap {
        var headers: [String: String] = [:]
        if !cachedDeckVersionIDs.isEmpty {
            headers["X-FlashGame-Cached-Deck-Version-Ids"] = cachedDeckVersionIDs
                .map { $0.uuidString.lowercased() }
                .joined(separator: ",")
        }
        let data = try await data(
            for: "bootstrap",
            method: "GET",
            selectedUserID: selectedUserID,
            deviceID: deviceID,
            headers: headers
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ServerBootstrap.self, from: data)
        } catch {
            throw ServerSyncError.invalidResponse("bootstrap decode: \(error.localizedDescription)")
        }
    }

    func changes(
        selectedUserID: UUID,
        sinceRevision: String,
        cachedDeckVersionIDs: [UUID] = [],
        deviceID: UUID?
    ) async throws -> ServerSyncChanges {
        var headers: [String: String] = [:]
        if !cachedDeckVersionIDs.isEmpty {
            headers["X-FlashGame-Cached-Deck-Version-Ids"] = cachedDeckVersionIDs
                .map { $0.uuidString.lowercased() }
                .joined(separator: ",")
        }
        let data = try await data(
            for: "sync/changes?sinceRevision=\(sinceRevision)",
            method: "GET",
            selectedUserID: selectedUserID,
            deviceID: deviceID,
            headers: headers
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ServerSyncChanges.self, from: data)
        } catch {
            throw ServerSyncError.invalidResponse("sync/changes decode: \(error.localizedDescription)")
        }
    }

    func uploadEvents(
        _ payload: ServerSyncEventsPayload,
        selectedUserID: UUID?,
        deviceID: UUID?
    ) async throws -> ServerSyncEventsResponse {
        guard !payload.isEmpty else {
            return ServerSyncEventsResponse(
                acceptedReviewIds: [],
                duplicateReviewIds: [],
                acceptedPracticeReviewIds: [],
                duplicatePracticeReviewIds: [],
                progressSenseIds: [],
                matchingRecordDeckIds: [],
                acceptedMatchingAttemptIds: [],
                duplicateMatchingAttemptIds: [],
                deckPreferenceDeckIds: [],
                rejectedPracticeReviewIds: [],
                rejectedMatchingAttemptIds: [],
                serverRevision: nil
            )
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let responseData = try await self.data(
            for: "sync/events",
            method: "POST",
            selectedUserID: selectedUserID,
            body: data,
            deviceID: deviceID
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ServerSyncEventsResponse.self, from: responseData)
        } catch {
            throw ServerSyncError.invalidResponse("sync/events decode: \(error.localizedDescription)")
        }
    }

    func downloadMedia(id: UUID) async throws -> Data {
        try await data(for: "media/\(id.uuidString.lowercased())", method: "GET", selectedUserID: nil)
    }

    private func data(
        for path: String,
        method: String,
        selectedUserID: UUID?,
        body: Data? = nil,
        deviceID: UUID? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard let baseURLString, let householdSyncToken else {
            throw ServerSyncError.missingConfiguration
        }
        guard let baseURL = URL(string: baseURLString),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host != nil else {
            throw ServerSyncError.invalidBaseURL(baseURLString)
        }

        let pathParts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var endpoint = pathParts[0]
            .split(separator: "/")
            .reduce(baseURL.appendingPathComponent("v1")) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        if pathParts.count > 1,
           var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = pathParts[1]
            endpoint = components.url ?? endpoint
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("Bearer \(householdSyncToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let selectedUserID {
            request.setValue(selectedUserID.uuidString.lowercased(), forHTTPHeaderField: "X-FlashGame-User-Id")
        }
        if let deviceID {
            request.setValue(deviceID.uuidString.lowercased(), forHTTPHeaderField: "X-FlashGame-Device-Id")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        Self.logger.info("HTTP \(method, privacy: .public) \(endpoint.absoluteString, privacy: .public) selectedUserID=\(selectedUserID?.uuidString ?? "nil", privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Self.logger.error("HTTP \(method, privacy: .public) \(endpoint.absoluteString, privacy: .public) failed urlError=\(error.code.rawValue, privacy: .public) \(error.localizedDescription, privacy: .public)")
            throw Self.syncError(from: error)
        }
        guard let http = response as? HTTPURLResponse else {
            Self.logger.error("HTTP \(method, privacy: .public) \(endpoint.absoluteString, privacy: .public) invalid non-HTTP response")
            throw ServerSyncError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.logger.error("HTTP \(method, privacy: .public) \(endpoint.absoluteString, privacy: .public) status=\(http.statusCode, privacy: .public)")
            throw ServerSyncError.httpStatus(code: http.statusCode, path: endpoint.path)
        }
        Self.logger.info("HTTP \(method, privacy: .public) \(endpoint.absoluteString, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        return data
    }

    private static func syncError(from error: URLError) -> ServerSyncError {
        switch error.code {
        case .cancelled:
            .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            .networkUnavailable
        case .timedOut:
            .timedOut
        case .cannotConnectToHost:
            .cannotConnect
        case .cannotFindHost, .dnsLookupFailed:
            .cannotFindHost
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            .secureConnectionFailed
        default:
            .cannotConnect
        }
    }

    private var baseURLString: String? {
        serverConfigValue(
            localKey: "LOCAL_SERVER_BASE_URL",
            remoteKey: "REMOTE_SERVER_BASE_URL",
            legacyKey: "SERVER_BASE_URL"
        ) ?? stringValue(userDefaultsKeys: [Keys.baseURL], bundleKeys: ["SERVER_BASE_URL"])
    }

    private var householdSyncToken: String? {
        serverConfigValue(
            localKey: "LOCAL_HOUSEHOLD_SYNC_TOKEN",
            remoteKey: "REMOTE_HOUSEHOLD_SYNC_TOKEN",
            legacyKey: "HOUSEHOLD_SYNC_TOKEN"
        ) ?? stringValue(
            userDefaultsKeys: [Keys.householdSyncToken],
            bundleKeys: ["HOUSEHOLD_SYNC_TOKEN"]
        )
    }

    private func serverConfigValue(localKey: String, remoteKey: String, legacyKey: String) -> String? {
        for resourceName in ["ServerConfig.local", "ServerConfig"] {
            guard let config = serverConfig(named: resourceName) else { continue }

            let selectedKey = useLocalServer(in: config) ? localKey : remoteKey
            if let value = trimmedString(config[selectedKey]) {
                return value
            }
            if let value = trimmedString(config[legacyKey]) {
                return value
            }
        }
        return nil
    }

    private func serverConfig(named resourceName: String) -> [String: Any]? {
        guard let configURL = Bundle.main.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: configURL),
              let config = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            return nil
        }
        return config
    }

    private func useLocalServer(in config: [String: Any]) -> Bool {
        switch config["USE_LOCAL_SERVER"] {
        case let value as Bool:
            return value
        case let value as Int:
            return value != 0
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "local"].contains(normalized)
        default:
            return false
        }
    }

    private func trimmedString(_ rawValue: Any?) -> String? {
        guard let value = rawValue as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stringValue(userDefaultsKeys: [String], bundleKeys: [String]) -> String? {
        for bundleKey in bundleKeys {
            if let value = Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        for resourceName in ["ServerConfig.local", "ServerConfig"] {
            if let configURL = Bundle.main.url(forResource: resourceName, withExtension: "plist"),
               let data = try? Data(contentsOf: configURL),
               let config = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ) as? [String: String] {
                for bundleKey in bundleKeys {
                    if let value = config[bundleKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        return value
                    }
                }
            }
        }
        for userDefaultsKey in userDefaultsKeys {
            if let value = userDefaults.string(forKey: userDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private var userDefaults: UserDefaults {
        guard let userDefaultsSuiteName else { return .standard }
        return UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
    }
}
