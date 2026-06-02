import Foundation
import Testing
@testable import WordsTrainerLogic

@Suite(.serialized)
struct ServerSyncClientTests {
    @Test("bootstrap sends selected user, cached deck versions, timezone and auth headers")
    func bootstrapSendsSyncContractHeaders() async throws {
        let suiteName = "ServerSyncClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://example.test/root", forKey: "server.baseURL")
        defaults.set("test-token", forKey: "server.householdSyncToken")

        let selectedUserID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let cachedVersionA = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let cachedVersionB = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let captured = LockedRequest()
        StubURLProtocol.handler = { request in
            captured.request = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(Self.bootstrapJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = ServerSyncClient(session: Self.stubSession(), userDefaultsSuiteName: suiteName)
        _ = try await client.bootstrap(
            selectedUserID: selectedUserID,
            cachedDeckVersionIDs: [cachedVersionA, cachedVersionB]
        )

        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "https://example.test/root/v1/bootstrap")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "X-FlashGame-User-Id") == selectedUserID.databaseString)
        #expect(request.value(forHTTPHeaderField: "X-FlashGame-Time-Zone") == TimeZone.current.identifier)
        #expect(
            request.value(forHTTPHeaderField: "X-FlashGame-Cached-Deck-Version-Ids")
                == "\(cachedVersionA.databaseString),\(cachedVersionB.databaseString)"
        )
    }

    @Test("bootstrap omits selected user and cached deck versions when absent")
    func bootstrapOmitsOptionalHeadersWhenAbsent() async throws {
        let suiteName = "ServerSyncClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://example.test", forKey: "server.baseURL")
        defaults.set("test-token", forKey: "server.householdSyncToken")

        let captured = LockedRequest()
        StubURLProtocol.handler = { request in
            captured.request = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(Self.bootstrapJSON.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = ServerSyncClient(session: Self.stubSession(), userDefaultsSuiteName: suiteName)
        _ = try await client.bootstrap(selectedUserID: nil)

        let request = try #require(captured.request)
        #expect(request.value(forHTTPHeaderField: "X-FlashGame-User-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "X-FlashGame-Cached-Deck-Version-Ids") == nil)
    }

    @Test("uploadEvents sends selected user and decodes rejected ids")
    func uploadEventsDecodesRejectedIds() async throws {
        let suiteName = "ServerSyncClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://example.test", forKey: "server.baseURL")
        defaults.set("test-token", forKey: "server.householdSyncToken")

        let selectedUserID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let cardID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let deckID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let rejectedReviewID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let rejectedMatchingDeckID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let rejectedPreferenceDeckID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let captured = LockedRequest()
        StubURLProtocol.handler = { request in
            captured.request = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let json = """
            {
              "acceptedReviewIds": [],
              "duplicateReviewIds": [],
              "progressCardIds": [],
              "matchingRecordDeckIds": [],
              "deckPreferenceDeckIds": [],
              "rejectedReviewIds": ["\(rejectedReviewID.uuidString)"],
              "rejectedProgressCardIds": ["\(cardID.uuidString)"],
              "rejectedMatchingRecordDeckIds": ["\(rejectedMatchingDeckID.uuidString)"],
              "rejectedDeckPreferenceDeckIds": ["\(rejectedPreferenceDeckID.uuidString)"],
              "serverRevision": "42"
            }
            """
            return (response, Data(json.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = ServerSyncClient(session: Self.stubSession(), userDefaultsSuiteName: suiteName)
        let response = try await client.uploadEvents(
            ServerSyncEventsPayload(
                progress: [
                    ServerProgressPayload(
                        cardId: cardID,
                        deckId: deckID,
                        fsrsData: .object(["state": .string("review")]),
                        dueAt: nil,
                        state: "review",
                        updatedAt: "2026-06-02T12:00:00.000Z"
                    )
                ]
            ),
            selectedUserID: selectedUserID
        )

        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "https://example.test/v1/sync/events")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "X-FlashGame-User-Id") == selectedUserID.databaseString)
        #expect(response.rejectedReviewIds == [rejectedReviewID])
        #expect(response.rejectedProgressCardIds == [cardID])
        #expect(response.rejectedMatchingRecordDeckIds == [rejectedMatchingDeckID])
        #expect(response.rejectedDeckPreferenceDeckIds == [rejectedPreferenceDeckID])
        #expect(response.serverRevision == "42")
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let bootstrapJSON = """
    {
      "user": null,
      "users": [],
      "assignments": [],
      "content": {
        "cards": [],
        "examples": [],
        "forms": [],
        "distractors": []
      },
      "media": [],
      "progress": [],
      "reviews": [],
      "matching_records": [],
      "daily_usage": [],
      "stats_summary": {
        "activity_days": [],
        "weak_cards": []
      }
    }
    """
}

private final class LockedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        get {
            lock.withLock { storedRequest }
        }
        set {
            lock.withLock { storedRequest = newValue }
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
