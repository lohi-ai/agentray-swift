import Foundation

/// One event on its way to `POST /batch`.
struct QueuedEvent {
    let event: String
    let distinctID: String
    let properties: [String: Any]
    let timestamp: Date

    func payload(iso: ISO8601DateFormatter) -> [String: Any] {
        [
            "event": event,
            "distinct_id": distinctID,
            "properties": properties,
            "timestamp": iso.string(from: timestamp),
        ]
    }
}

/// The HTTP call, behind a protocol so tests can assert what would have been
/// sent without a server.
public protocol AgentRayHTTPClient: AnyObject {
    func post(url: URL, body: Data, completion: @escaping (Int?, Error?) -> Void)
}

final class URLSessionHTTPClient: AgentRayHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func post(url: URL, body: Data, completion: @escaping (Int?, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { _, response, error in
            completion((response as? HTTPURLResponse)?.statusCode, error)
        }.resume()
    }
}

/// Coalesces events into one `POST /batch` instead of a request per event, and
/// retries a transient failure with bounded backoff.
///
/// Two differences from the browser transport this mirrors, both because a phone
/// is not a tab:
///
/// - **A backgrounded app is not an unloaded page.** There is no `sendBeacon`;
///   the app keeps running and can be killed at any moment, so the flush that
///   matters is the one on `didEnterBackground`, and it asks the OS for a short
///   background task so the request survives the transition.
/// - **A phone is offline often and briefly.** A dropped batch is re-queued at
///   the front rather than discarded, up to `maxQueued` events — a subway ride
///   should cost latency, not data. The cap exists so a permanently offline app
///   does not grow its queue without bound.
final class BatchTransport {
    private let host: String
    private let apiKey: String
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private let maxRetries: Int
    private let maxQueued: Int
    private let http: AgentRayHTTPClient
    private let queue = DispatchQueue(label: "com.agentray.transport")
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var pending: [QueuedEvent] = []
    private var timer: DispatchSourceTimer?
    private var isDelivering = false
    private var isBackgrounded = false
    private var failures = 0
    private var retryAt: Date?
    private let retryDelay: (Int, Int) -> TimeInterval

    init(
        host: String,
        apiKey: String,
        batchSize: Int,
        flushInterval: TimeInterval,
        maxRetries: Int,
        maxQueued: Int,
        http: AgentRayHTTPClient,
        retryDelay: @escaping (Int, Int) -> TimeInterval = BatchTransport.retryDelay
    ) {
        self.host = host
        self.apiKey = apiKey
        self.batchSize = max(1, batchSize)
        self.flushInterval = flushInterval
        self.maxRetries = max(1, maxRetries)
        self.maxQueued = max(batchSize, maxQueued)
        self.http = http
        self.retryDelay = retryDelay
    }

    func enqueue(_ event: QueuedEvent) {
        queue.async {
            self.pending.append(event)
            // Drop from the front when the cap is hit: with a full queue the new
            // event is the one still worth having, and the oldest is the one most
            // likely already stale.
            if self.pending.count > self.maxQueued {
                self.pending.removeFirst(self.pending.count - self.maxQueued)
            }
            if self.pending.count >= self.batchSize {
                self.flushLocked()
            } else {
                self.scheduleLocked()
            }
        }
    }

    func flush() {
        queue.async { self.flushLocked() }
    }

    /// Sends one request that is not part of the event batch — `/alias` and
    /// `/identify`, which must land in order relative to each other and are not
    /// events.
    func send(path: String, body: [String: Any]) {
        guard let url = URL(string: host + path) else { return }
        var payload = body
        payload["api_key"] = apiKey
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        http.post(url: url, body: data) { _, _ in }
    }

    /// Send at most one final batch when entering the background. Playback can
    /// keep the process awake for hours; it must not keep analytics retrying.
    func setBackgrounded(_ backgrounded: Bool) {
        queue.async {
            self.isBackgrounded = backgrounded
            self.cancelTimerLocked()
            self.flushLocked(allowBackground: backgrounded)
        }
    }

    /// The failure count survives requeues and new events. After the short
    /// retry budget, cool down for 30s … 5min (plus jitter) instead of resetting to 1s.
    static func retryDelay(failures: Int, maxRetries: Int) -> TimeInterval {
        let base = failures < maxRetries
            ? min(pow(2, Double(failures - 1)), 8)
            : min(30 * pow(2, Double(min(failures - maxRetries, 4))), 300)
        return base * Double.random(in: 1...1.2)
    }

    // MARK: - private

    private func scheduleLocked() {
        guard timer == nil, !isBackgrounded, !isDelivering, !pending.isEmpty else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(flushInterval, retryAt?.timeIntervalSinceNow ?? 0)
        source.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.flushLocked() }
        timer = source
        source.resume()
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func flushLocked(allowBackground: Bool = false) {
        cancelTimerLocked()
        guard !isDelivering, !pending.isEmpty else { return }
        guard !isBackgrounded || allowBackground else { return }
        if let retryAt, retryAt > Date() {
            scheduleLocked()
            return
        }
        let batch = pending
        pending = []
        deliver(batch)
    }

    private func deliver(_ batch: [QueuedEvent]) {
        guard let url = URL(string: host + "/batch") else { return }
        let body: [String: Any] = [
            "api_key": apiKey,
            "batch": batch.map { $0.payload(iso: iso) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        isDelivering = true
        http.post(url: url, body: data) { [weak self] status, _ in
            guard let self else { return }
            self.queue.async {
                self.isDelivering = false
                // 408/429 are temporary; invalid credentials and malformed
                // payloads remain terminal. All state lives on this queue.
                if let status, (200..<300).contains(status)
                    || ((400..<500).contains(status) && status != 408 && status != 429) {
                    self.failures = 0
                    self.retryAt = nil
                } else {
                    self.failures = min(self.failures + 1, self.maxRetries + 20)
                    self.retryAt = Date().addingTimeInterval(
                        self.retryDelay(self.failures, self.maxRetries)
                    )
                    self.pending.insert(contentsOf: batch, at: 0)
                    if self.pending.count > self.maxQueued {
                        self.pending.removeFirst(self.pending.count - self.maxQueued)
                    }
                }
                self.scheduleLocked()
            }
        }
    }
}
