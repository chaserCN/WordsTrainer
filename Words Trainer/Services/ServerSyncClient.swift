import Foundation

struct ServerBootstrap: Decodable, Sendable {
    let user: ServerUser?
    let users: [ServerUser]
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

enum ServerSyncError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "SERVER_BASE_URL и DEVICE_TOKEN не настроены."
        case .invalidResponse:
            "Сервер вернул некорректный ответ."
        case .httpStatus(let code):
            "Сервер вернул HTTP \(code)."
        }
    }
}

final class ServerSyncClient {
    static let shared = ServerSyncClient()

    private enum Keys {
        static let baseURL = "server.baseURL"
        static let deviceToken = "server.deviceToken"
    }

    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    var isConfigured: Bool {
        baseURL != nil && deviceToken != nil
    }

    func bootstrap(selectedUserID: UUID?) async throws -> ServerBootstrap {
        guard let baseURL, let deviceToken else {
            throw ServerSyncError.missingConfiguration
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/bootstrap"))
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if let selectedUserID {
            request.setValue(selectedUserID.uuidString.lowercased(), forHTTPHeaderField: "X-FlashGame-User-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerSyncError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ServerBootstrap.self, from: data)
    }

    private var baseURL: URL? {
        if let value = stringValue(userDefaultsKey: Keys.baseURL, bundleKey: "SERVER_BASE_URL") {
            return URL(string: value)
        }
        return nil
    }

    private var deviceToken: String? {
        stringValue(userDefaultsKey: Keys.deviceToken, bundleKey: "DEVICE_TOKEN")
    }

    private func stringValue(userDefaultsKey: String, bundleKey: String) -> String? {
        if let value = defaults.string(forKey: userDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
