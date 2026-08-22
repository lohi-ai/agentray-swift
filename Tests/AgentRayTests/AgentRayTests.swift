import XCTest
@testable import AgentRay

/// In-memory replacements for the two things the client touches outside itself.
final class MemoryStore: AgentRayStore {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func remove(forKey key: String) { values[key] = nil }
}

final class RecordingHTTPClient: AgentRayHTTPClient {
    struct Request {
        let url: URL
        let json: [String: Any]
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    var status: Int = 200

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func post(url: URL, body: Data, completion: @escaping (Int?, Error?) -> Void) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        lock.lock()
        _requests.append(Request(url: url, json: json))
        lock.unlock()
        completion(status, nil)
    }

    func requests(toPath path: String) -> [Request] {
        requests.filter { $0.url.path == path }
    }
}

private func makeClient(
    http: RecordingHTTPClient,
    store: AgentRayStore = MemoryStore(),
    batchSize: Int = 20
) -> AgentRay {
    AgentRay(
        configuration: AgentRayConfiguration(
            host: "https://example.test/",
            apiKey: "agentray_test",
            batchSize: batchSize,
            flushInterval: 60
        ),
        store: store,
        http: http
    )
}

private func batchEvents(_ request: RecordingHTTPClient.Request) -> [[String: Any]] {
    request.json["batch"] as? [[String: Any]] ?? []
}

final class AgentRayTests: XCTestCase {
    /// Every event has to carry the platform, or the whole point of the SDK — an
    /// app and a website that stay separable in the same project — is lost.
    func testCaptureTagsPlatform() throws {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http)

        client.capture("user.signup", properties: ["plan": "free"])
        client.flush()

        let batch = try waitForBatch(http)
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch[0]["event"] as? String, "user.signup")
        let props = batch[0]["properties"] as? [String: Any]
        XCTAssertEqual(props?["platform"] as? String, "ios")
        XCTAssertEqual(props?["plan"] as? String, "free")
    }

    /// A caller must not be able to mislabel which app an event came from, even
    /// by accident — the platform is set after the caller's properties.
    func testCallerCannotOverridePlatform() throws {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http)

        client.capture("user.signup", properties: ["platform": "web"])
        client.flush()

        let batch = try waitForBatch(http)
        XCTAssertEqual((batch[0]["properties"] as? [String: Any])?["platform"] as? String, "ios")
    }

    /// Screens ride the event the existing charts already read, with the screen
    /// name in a path shape so Traffic's page list can show them.
    func testScreenSendsPageviewWithPath() throws {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http)

        client.screen("Library")
        client.flush()

        let batch = try waitForBatch(http)
        XCTAssertEqual(batch[0]["event"] as? String, "user.pageview")
        let props = batch[0]["properties"] as? [String: Any]
        XCTAssertEqual(props?["screen"] as? String, "Library")
        XCTAssertEqual(props?["path"] as? String, "/Library")
    }

    /// The anonymous id has to survive a relaunch. If it does not, every launch
    /// is a new "visitor" and the app's people count is really its launch count.
    func testAnonymousIDIsStableAcrossClients() throws {
        let store = MemoryStore()
        let first = makeClient(http: RecordingHTTPClient(), store: store)
        let second = makeClient(http: RecordingHTTPClient(), store: store)

        XCTAssertEqual(first.distinctID, second.distinctID)
        XCTAssertTrue(first.distinctID.hasPrefix("a-"))
    }

    /// The defect this SDK exists to prevent: a person who used the website and
    /// then signed in on the app counting twice. identify must alias the previous
    /// id before switching.
    func testIdentifyAliasesThePreviousID() throws {
        let http = RecordingHTTPClient()
        let store = MemoryStore()
        let client = makeClient(http: http, store: store)
        let anonymous = client.distinctID

        client.identify("user_123", traits: ["email": "alice@example.com"])

        let aliases = http.requests(toPath: "/alias")
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases[0].json["anonymous_id"] as? String, anonymous)
        XCTAssertEqual(aliases[0].json["distinct_id"] as? String, "user_123")
        XCTAssertEqual(aliases[0].json["api_key"] as? String, "agentray_test")

        let identifies = http.requests(toPath: "/identify")
        XCTAssertEqual(identifies.count, 1)
        XCTAssertEqual((identifies[0].json["$set"] as? [String: Any])?["email"] as? String, "alice@example.com")

        XCTAssertEqual(client.distinctID, "user_123")
    }

    /// Identifying the same user again is not a new person and must not mint a
    /// second alias.
    func testIdentifyTwiceAliasesOnce() {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http)

        client.identify("user_123")
        client.identify("user_123")

        XCTAssertEqual(http.requests(toPath: "/alias").count, 1)
    }

    func testIdentifyIgnoresBlankUserID() {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http)
        let before = client.distinctID

        client.identify("   ")

        XCTAssertEqual(client.distinctID, before)
        XCTAssertTrue(http.requests(toPath: "/identify").isEmpty)
    }

    /// Logout has to break the link, or the next person on the device inherits
    /// the last one's history.
    func testResetStartsANewAnonymousIdentity() {
        let http = RecordingHTTPClient()
        let store = MemoryStore()
        let client = makeClient(http: http, store: store)
        let firstAnonymous = client.distinctID

        client.identify("user_123")
        XCTAssertEqual(client.distinctID, "user_123")

        client.reset()
        XCTAssertNotEqual(client.distinctID, "user_123")
        XCTAssertNotEqual(client.distinctID, firstAnonymous)
    }

    /// Reaching the batch size sends without waiting for the timer.
    func testBatchSizeTriggersFlush() throws {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http, batchSize: 2)

        client.capture("a")
        client.capture("b")

        let batch = try waitForBatch(http)
        XCTAssertEqual(batch.count, 2)
    }

    /// A 401 is the server saying the key is wrong. Retrying cannot fix that, so
    /// the batch is dropped rather than re-queued in front of everything else.
    func testClientErrorIsNotRetried() throws {
        let http = RecordingHTTPClient()
        http.status = 401
        let client = makeClient(http: http, batchSize: 1)

        client.capture("a")

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline && http.requests(toPath: "/batch").count < 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(http.requests(toPath: "/batch").count, 1)
    }

    /// A trailing slash on the host must not produce `//batch`.
    func testHostTrailingSlashIsTrimmed() throws {
        let http = RecordingHTTPClient()
        let client = makeClient(http: http, batchSize: 1)

        client.capture("a")

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline && http.requests.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://example.test/batch")
    }

    private func waitForBatch(_ http: RecordingHTTPClient, timeout: TimeInterval = 2) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = http.requests(toPath: "/batch").first {
                return batchEvents(request)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("no batch was sent within \(timeout)s")
        return []
    }
}
