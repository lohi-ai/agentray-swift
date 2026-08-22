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

    init(
        host: String,
        apiKey: String,
        batchSize: Int,
        flushInterval: TimeInterval,
        maxRetries: Int,
        maxQueued: Int,
        http: AgentRayHTTPClient
    ) {
        self.host = host
        self.apiKey = apiKey
        self.batchSize = max(1, batchSize)
        self.flushInterval = flushInterval
        self.maxRetries = max(1, maxRetries)
        self.maxQueued = max(batchSize, maxQueued)
        self.http = http
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

    // MARK: - private

    private func scheduleLocked() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + flushInterval)
        source.setEventHandler { [weak self] in self?.flushLocked() }
        timer = source
        source.resume()
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func flushLocked() {
        cancelTimerLocked()
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        deliver(batch, attempt: 0)
    }

    private func deliver(_ batch: [QueuedEvent], attempt: Int) {
        guard let url = URL(string: host + "/batch") else { return }
        let body: [String: Any] = [
            "api_key": apiKey,
            "batch": batch.map { $0.payload(iso: iso) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        http.post(url: url, body: data) { [weak self] status, _ in
            guard let self else { return }
            if let status {
                // 4xx is the server saying the request itself is wrong — a bad key,
                // a malformed payload. Retrying cannot fix that, and re-queueing
                // would block every later batch behind it forever.
                if (200..<300).contains(status) || (400..<500).contains(status) { return }
            }
            self.queue.async {
                if attempt + 1 >= self.maxRetries {
                    self.requeueLocked(batch)
                    return
                }
                let backoff = min(pow(2.0, Double(attempt)), 8.0)
                self.queue.asyncAfter(deadline: .now() + backoff) {
                    self.deliver(batch, attempt: attempt + 1)
                }
            }
        }
    }

    /// Puts an undelivered batch back at the front so it goes out before newer
    /// events, then re-arms the timer to try again.
    private func requeueLocked(_ batch: [QueuedEvent]) {
        pending.insert(contentsOf: batch, at: 0)
        if pending.count > maxQueued {
            pending.removeFirst(pending.count - maxQueued)
        }
        scheduleLocked()
    }
}
