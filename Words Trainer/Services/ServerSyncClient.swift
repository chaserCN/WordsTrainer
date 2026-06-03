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
    let matchingRecords: [ServerMatchingRecordPayload]
    let dailyUsage: [ServerDailyUsagePayload]
    let hasDailyUsageSnapshot: Bool
    let statsSummary: ServerStatsSummaryPayload
    let hasStatsSummarySnapshot: Bool

    init(
        user: ServerUser?,
        users: [ServerUser],
        assignments: [ServerDeckAssignment],
        content: ServerContentPayload,
        media: [ServerMediaObject],
        progress: [ServerProgressPayload],
        reviews: [ServerReviewEventPayload],
        matchingRecords: [ServerMatchingRecordPayload],
        dailyUsage: [ServerDailyUsagePayload] = [],
        hasDailyUsageSnapshot: Bool = true,
        statsSummary: ServerStatsSummaryPayload = .empty,
        hasStatsSummarySnapshot: Bool = true
    ) {
        self.user = user
        self.users = users
        self.assignments = assignments
        self.content = content
        self.media = media
        self.progress = progress
        self.reviews = reviews
        self.matchingRecords = matchingRecords
        self.dailyUsage = dailyUsage
        self.hasDailyUsageSnapshot = hasDailyUsageSnapshot
        self.statsSummary = statsSummary
        self.hasStatsSummarySnapshot = hasStatsSummarySnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case user
        case users
        case assignments
        case content
        case media
        case progress
        case reviews
        case matchingRecords
        case dailyUsage
        case statsSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decodeIfPresent(ServerUser.self, forKey: .user)
        users = try container.decodeIfPresent([ServerUser].self, forKey: .users) ?? []
        assignments = try container.decodeIfPresent([ServerDeckAssignment].self, forKey: .assignments) ?? []
        content = try container.decodeIfPresent(ServerContentPayload.self, forKey: .content) ?? .empty
        media = try container.decodeIfPresent([ServerMediaObject].self, forKey: .media) ?? []
        progress = try container.decodeIfPresent([ServerProgressPayload].self, forKey: .progress) ?? []
        reviews = try container.decodeIfPresent([ServerReviewEventPayload].self, forKey: .reviews) ?? []
        matchingRecords = try container.decodeIfPresent([ServerMatchingRecordPayload].self, forKey: .matchingRecords) ?? []
        dailyUsage = try container.decodeIfPresent([ServerDailyUsagePayload].self, forKey: .dailyUsage) ?? []
        hasDailyUsageSnapshot = container.contains(.dailyUsage)
        statsSummary = try container.decodeIfPresent(ServerStatsSummaryPayload.self, forKey: .statsSummary) ?? .empty
        hasStatsSummarySnapshot = container.contains(.statsSummary)
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
}

struct ServerContentPayload: Decodable, Sendable {
    static let empty = ServerContentPayload(cards: [], examples: [], forms: [], distractors: [])

    let cards: [ServerCardContent]
    let examples: [ServerExampleContent]
    let forms: [ServerWordFormContent]
    let distractors: [ServerDistractorContent]
}

struct ServerCardContent: Decodable, Sendable {
    let deckVersionId: UUID
    let cardId: UUID
    let status: String
    let lemma: String
    let displayWord: String
    let partOfSpeech: String?
    let translation: String
    let shortDefinition: String?
    let memoryHint: String?
    let etymology: String?
    let usageNote: String?
    let synonymNote: String?
    let grammarNote: String?
    let notes: String?
    let imageMediaId: UUID?
    let audioWordMediaId: UUID?
    let sortOrder: Int?
}

struct ServerExampleContent: Decodable, Sendable {
    let deckVersionId: UUID
    let exampleId: UUID
    let cardId: UUID
    let template: String
    let answer: String
    let answerFormKey: String?
    let translation: String?
    let note: String?
    let imageMediaId: UUID?
    let audioExampleMediaId: UUID?
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
    let exampleId: UUID
    let text: String
    let sourceCardId: UUID?
    let priority: Int?
}

struct ServerMediaObject: Decodable, Sendable {
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
    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
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
    var progress: [ServerProgressPayload] = []
    var matchingRecords: [ServerMatchingRecordPayload] = []
    var deckPreferences: [ServerDeckPreferencePayload] = []

    var isEmpty: Bool {
        reviews.isEmpty && progress.isEmpty && matchingRecords.isEmpty && deckPreferences.isEmpty
    }
}

struct ServerReviewEventPayload: Codable, Sendable {
    let clientEventId: UUID
    let deckId: UUID
    let deckVersionId: UUID?
    let cardId: UUID
    let mode: String
    let outcome: String
    let reviewedAt: String
    let durationMs: Int?
    let wasNew: Bool
    let previousState: String?
    let newState: String?
}

struct ServerProgressPayload: Codable, Sendable {
    let cardId: UUID
    let deckId: UUID
    let fsrsData: JSONValue
    let dueAt: String?
    let state: String?
    let updatedAt: String?
}

struct ServerMatchingRecordPayload: Codable, Sendable {
    let deckId: UUID
    let deckVersionId: UUID?
    let bestDurationSeconds: Double
    let pairCount: Int
    let achievedAt: String
}

struct ServerDeckPreferencePayload: Codable, Sendable {
    let deckId: UUID
    let isEnabled: Bool
    let updatedAt: String?
}

struct ServerDailyUsagePayload: Codable, Sendable {
    let deckId: UUID
    let dayKey: String
    let newCardsStudied: Int
}

struct ServerStatsSummaryPayload: Codable, Sendable {
    static let empty = ServerStatsSummaryPayload(activityDays: [], weakCards: [])

    let activityDays: [ServerStudyActivityDayPayload]
    let weakCards: [ServerWeakCardStatPayload]
}

struct ServerStudyActivityDayPayload: Codable, Sendable {
    let dayKey: String
    let reviewedCount: Int
    let passedCount: Int
}

struct ServerWeakCardStatPayload: Codable, Sendable {
    let cardId: UUID
    let deckId: UUID
    let failedCount: Int
    let reviewedCount: Int
    let lastFailedAt: String?
}

struct ServerSyncEventsResponse: Decodable, Sendable {
    let acceptedReviewIds: [UUID]
    let duplicateReviewIds: [UUID]
    let progressCardIds: [UUID]
    let matchingRecordDeckIds: [UUID]
    let deckPreferenceDeckIds: [UUID]
    let rejectedReviewIds: [UUID]
    let rejectedProgressCardIds: [UUID]
    let rejectedMatchingRecordDeckIds: [UUID]
    let rejectedDeckPreferenceDeckIds: [UUID]
    let serverRevision: String?

    init(
        acceptedReviewIds: [UUID],
        duplicateReviewIds: [UUID],
        progressCardIds: [UUID],
        matchingRecordDeckIds: [UUID],
        deckPreferenceDeckIds: [UUID],
        rejectedReviewIds: [UUID] = [],
        rejectedProgressCardIds: [UUID] = [],
        rejectedMatchingRecordDeckIds: [UUID] = [],
        rejectedDeckPreferenceDeckIds: [UUID] = [],
        serverRevision: String?
    ) {
        self.acceptedReviewIds = acceptedReviewIds
        self.duplicateReviewIds = duplicateReviewIds
        self.progressCardIds = progressCardIds
        self.matchingRecordDeckIds = matchingRecordDeckIds
        self.deckPreferenceDeckIds = deckPreferenceDeckIds
        self.rejectedReviewIds = rejectedReviewIds
        self.rejectedProgressCardIds = rejectedProgressCardIds
        self.rejectedMatchingRecordDeckIds = rejectedMatchingRecordDeckIds
        self.rejectedDeckPreferenceDeckIds = rejectedDeckPreferenceDeckIds
        self.serverRevision = serverRevision
    }

    private enum CodingKeys: String, CodingKey {
        case acceptedReviewIds
        case duplicateReviewIds
        case progressCardIds
        case matchingRecordDeckIds
        case deckPreferenceDeckIds
        case rejectedReviewIds
        case rejectedProgressCardIds
        case rejectedMatchingRecordDeckIds
        case rejectedDeckPreferenceDeckIds
        case serverRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acceptedReviewIds = try container.decodeIfPresent([UUID].self, forKey: .acceptedReviewIds) ?? []
        duplicateReviewIds = try container.decodeIfPresent([UUID].self, forKey: .duplicateReviewIds) ?? []
        progressCardIds = try container.decodeIfPresent([UUID].self, forKey: .progressCardIds) ?? []
        matchingRecordDeckIds = try container.decodeIfPresent([UUID].self, forKey: .matchingRecordDeckIds) ?? []
        deckPreferenceDeckIds = try container.decodeIfPresent([UUID].self, forKey: .deckPreferenceDeckIds) ?? []
        rejectedReviewIds = try container.decodeIfPresent([UUID].self, forKey: .rejectedReviewIds) ?? []
        rejectedProgressCardIds = try container.decodeIfPresent([UUID].self, forKey: .rejectedProgressCardIds) ?? []
        rejectedMatchingRecordDeckIds = try container.decodeIfPresent([UUID].self, forKey: .rejectedMatchingRecordDeckIds) ?? []
        rejectedDeckPreferenceDeckIds = try container.decodeIfPresent([UUID].self, forKey: .rejectedDeckPreferenceDeckIds) ?? []
        serverRevision = try container.decodeIfPresent(String.self, forKey: .serverRevision)
    }
}

enum JSONValue: Codable, Sendable {
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
    case invalidResponse
    case networkUnavailable
    case timedOut
    case cannotConnect
    case cannotFindHost
    case secureConnectionFailed
    case cancelled
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "SERVER_BASE_URL и HOUSEHOLD_SYNC_TOKEN не настроены."
        case .invalidBaseURL(let value):
            "SERVER_BASE_URL некорректный: \(value)."
        case .invalidResponse:
            "Сервер вернул некорректный ответ."
        case .networkUnavailable:
            "Нет подключения к интернету. Проверьте сеть и попробуйте снова."
        case .timedOut:
            "Сервер не ответил вовремя. Попробуйте ещё раз."
        case .cannotConnect:
            "Не удалось подключиться к серверу. Проверьте адрес сервера и сеть."
        case .cannotFindHost:
            "Не удалось найти сервер. Проверьте SERVER_BASE_URL."
        case .secureConnectionFailed:
            "Не удалось установить защищённое соединение с сервером."
        case .cancelled:
            "Синхронизация отменена."
        case .httpStatus(let code):
            Self.httpStatusMessage(code)
        }
    }

    private static func httpStatusMessage(_ code: Int) -> String {
        switch code {
        case 401, 403:
            "Сервер отклонил HOUSEHOLD_SYNC_TOKEN. Проверьте семейный sync token."
        case 404:
            "Сервер доступен, но endpoint /v1/bootstrap не найден."
        case 500..<600:
            "На сервере ошибка HTTP \(code). Попробуйте позже."
        default:
            "Сервер вернул HTTP \(code)."
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

    func bootstrap(selectedUserID: UUID?, cachedDeckVersionIDs: [UUID] = []) async throws -> ServerBootstrap {
        var headers: [String: String] = [
            "X-FlashGame-Time-Zone": TimeZone.current.identifier
        ]
        if !cachedDeckVersionIDs.isEmpty {
            headers["X-FlashGame-Cached-Deck-Version-Ids"] = cachedDeckVersionIDs
                .map { $0.uuidString.lowercased() }
                .joined(separator: ",")
        }
        let data = try await data(
            for: "bootstrap",
            method: "GET",
            selectedUserID: selectedUserID,
            headers: headers
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ServerBootstrap.self, from: data)
        } catch {
            throw ServerSyncError.invalidResponse
        }
    }

    func uploadEvents(
        _ payload: ServerSyncEventsPayload,
        selectedUserID: UUID?
    ) async throws -> ServerSyncEventsResponse {
        guard !payload.isEmpty else {
            return ServerSyncEventsResponse(
                acceptedReviewIds: [],
                duplicateReviewIds: [],
                progressCardIds: [],
                matchingRecordDeckIds: [],
                deckPreferenceDeckIds: [],
                serverRevision: nil
            )
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let responseData = try await self.data(
            for: "sync/events",
            method: "POST",
            selectedUserID: selectedUserID,
            body: data
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ServerSyncEventsResponse.self, from: responseData)
        } catch {
            throw ServerSyncError.invalidResponse
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

        let endpoint = path
            .split(separator: "/")
            .reduce(baseURL.appendingPathComponent("v1")) { partial, component in
                partial.appendingPathComponent(String(component))
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
            throw ServerSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.logger.error("HTTP \(method, privacy: .public) \(endpoint.absoluteString, privacy: .public) status=\(http.statusCode, privacy: .public)")
            throw ServerSyncError.httpStatus(http.statusCode)
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
        stringValue(userDefaultsKeys: [Keys.baseURL], bundleKeys: ["SERVER_BASE_URL"])
    }

    private var householdSyncToken: String? {
        stringValue(
            userDefaultsKeys: [Keys.householdSyncToken],
            bundleKeys: ["HOUSEHOLD_SYNC_TOKEN"]
        )
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
