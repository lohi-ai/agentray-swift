import XCTest
@testable import AgentRay

private final class DeferredHTTP: AgentRayHTTPClient {
    private let lock = NSLock()
    private var callbacks: [(Int?, Error?) -> Void] = []
    private var bodies: [Data] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
    func post(url: URL, body: Data, completion: @escaping (Int?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        bodies.append(body)
        callbacks.append(completion)
    }
    func complete(_ status: Int) {
        lock.lock()
        let callback = callbacks.removeFirst()
        lock.unlock()
        callback(status, nil)
    }
}

final class BatchTransportTests: XCTestCase {
    private func transport(_ http: DeferredHTTP, delay: TimeInterval = 0.15) -> BatchTransport {
        BatchTransport(host: "https://example.test", apiKey: "test", batchSize: 1,
                       flushInterval: 0.01, maxRetries: 1, maxQueued: 10,
                       http: http, retryDelay: { _, _ in delay })
    }
    private func enqueue(_ transport: BatchTransport) {
        transport.enqueue(QueuedEvent(event: "test", distinctID: "test", properties: [:], timestamp: Date()))
    }
    private func waitFor(_ count: Int, _ http: DeferredHTTP) {
        let limit = Date().addingTimeInterval(2)
        while http.count < count && Date() < limit { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(http.count, count)
    }
    func testEnqueuesAndExplicitFlushCannotBypassOutageCooldown() {
        let http = DeferredHTTP()
        let transport = transport(http, delay: 0.4)
        enqueue(transport)
        waitFor(1, http)
        http.complete(503)
        for _ in 0..<20 { enqueue(transport); transport.flush() }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(http.count, 1)
        waitFor(2, http)
        http.complete(200)
        enqueue(transport)
        waitFor(3, http)
        http.complete(200)
    }
    func testBackgroundFailureWaitsForForeground() {
        let http = DeferredHTTP()
        let transport = transport(http)
        enqueue(transport)
        waitFor(1, http)
        transport.setBackgrounded(true)
        http.complete(503)
        enqueue(transport)
        transport.flush()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(http.count, 1)
        transport.setBackgrounded(false)
        waitFor(2, http)
        http.complete(200)
    }
    func testOnlyOneBatchCanBeInFlight() {
        let http = DeferredHTTP()
        let transport = transport(http)
        enqueue(transport)
        waitFor(1, http)
        for _ in 0..<5 { enqueue(transport); transport.flush() }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(http.count, 1)
        http.complete(200)
        waitFor(2, http)
        http.complete(200)
    }
    func testBackgroundTransitionFlushesPendingOnce() {
        let http = DeferredHTTP()
        let transport = BatchTransport(host: "https://example.test", apiKey: "test",
                                       batchSize: 20, flushInterval: 60, maxRetries: 3,
                                       maxQueued: 100, http: http)
        enqueue(transport)
        transport.setBackgrounded(true)
        waitFor(1, http)
        http.complete(200)
        enqueue(transport)
        transport.flush()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(http.count, 1)
        transport.setBackgrounded(false)
        waitFor(2, http)
        http.complete(200)
    }
    func testRateLimitAndRequestTimeoutAreRetried() {
        for status in [408, 429] {
            let http = DeferredHTTP()
            let transport = transport(http, delay: 0.01)
            enqueue(transport)
            waitFor(1, http)
            http.complete(status)
            waitFor(2, http)
            http.complete(200)
        }
    }
    func testRetryDelayKeepsGrowingPastShortBudget() {
        XCTAssertTrue((1...1.2).contains(BatchTransport.retryDelay(failures: 1, maxRetries: 3)))
        XCTAssertTrue((30...36).contains(BatchTransport.retryDelay(failures: 3, maxRetries: 3)))
        XCTAssertTrue((60...72).contains(BatchTransport.retryDelay(failures: 4, maxRetries: 3)))
        XCTAssertTrue((300...360).contains(BatchTransport.retryDelay(failures: 20, maxRetries: 3)))
    }
}
