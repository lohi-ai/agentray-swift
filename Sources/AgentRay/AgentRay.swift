import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How the client is wired up. Only `host` and `apiKey` are required.
public struct AgentRayConfiguration {
    /// Base URL of the AgentRay server, e.g. `https://agentray.example.com`.
    public var host: String
    /// Project API key (Settings → API keys).
    public var apiKey: String
    /// Flush once this many events are buffered.
    public var batchSize: Int
    /// Flush at most this long after the first buffered event.
    public var flushInterval: TimeInterval
    /// Delivery attempts per batch before the batch goes back in the queue.
    public var maxRetries: Int
    /// Ceiling on buffered events while offline. Oldest are dropped past it.
    public var maxQueuedEvents: Int
    /// Value written to the `platform` property on every event. Override only if
    /// this build is not the iOS app — a Mac Catalyst or tvOS target may want to
    /// separate itself.
    public var platform: String

    public init(
        host: String,
        apiKey: String,
        batchSize: Int = 20,
        flushInterval: TimeInterval = 3,
        maxRetries: Int = 3,
        maxQueuedEvents: Int = 500,
        platform: String = "ios"
    ) {
        self.host = host
        self.apiKey = apiKey
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.maxRetries = maxRetries
        self.maxQueuedEvents = maxQueuedEvents
        self.platform = platform
    }
}

/// The AgentRay client for native Apple apps.
///
/// It exists because "we have a website and an app" was, until it shipped, a
/// hand-rolled integration: the documented path was a `curl` example, and an app
/// that follows one gets a new anonymous id every launch, no link between a
/// person's web and app history, and no way for any chart to tell the two
/// audiences apart. Those are not conveniences — each one silently changes the
/// numbers the product is read from.
///
/// ```swift
/// AgentRay.start(host: "https://agentray.example.com", apiKey: "agentray_…")
///
/// // On each screen
/// AgentRay.shared.screen("Library")
///
/// // On login — links this install's anonymous history to the user
/// AgentRay.shared.identify("user_123", traits: ["email": "alice@example.com"])
///
/// // On logout
/// AgentRay.shared.reset()
/// ```
public final class AgentRay {
    /// The screen event name. It is `user.pageview` on purpose: the Traffic and
    /// Product surfaces read that name, so an app screen shows up in the charts
    /// the owner already has instead of needing new ones. `screen` and `path`
    /// carry which screen it was.
    public static let screenEvent = "user.pageview"

    private static var _shared: AgentRay?

    /// The client created by `start`. Accessing it before `start` traps, because
    /// silently dropping events is a worse failure than a loud one at boot.
    public static var shared: AgentRay {
        guard let client = _shared else {
            fatalError("AgentRay.start(host:apiKey:) must be called before AgentRay.shared")
        }
        return client
    }

    /// Whether `start` has run — for a host app that captures conditionally.
    public static var isStarted: Bool { _shared != nil }

    @discardableResult
    public static func start(host: String, apiKey: String) -> AgentRay {
        start(configuration: AgentRayConfiguration(host: host, apiKey: apiKey))
    }

    @discardableResult
    public static func start(configuration: AgentRayConfiguration) -> AgentRay {
        let client = AgentRay(configuration: configuration)
        _shared = client
        return client
    }

    private let configuration: AgentRayConfiguration
    private let identity: Identity
    private let transport: BatchTransport
    private var observers: [NSObjectProtocol] = []

    init(
        configuration: AgentRayConfiguration,
        store: AgentRayStore = UserDefaults.standard,
        http: AgentRayHTTPClient? = nil
    ) {
        var config = configuration
        while config.host.hasSuffix("/") { config.host.removeLast() }
        self.configuration = config
        self.identity = Identity(store: store)
        self.transport = BatchTransport(
            host: config.host,
            apiKey: config.apiKey,
            batchSize: config.batchSize,
            flushInterval: config.flushInterval,
            maxRetries: config.maxRetries,
            maxQueued: config.maxQueuedEvents,
            http: http ?? URLSessionHTTPClient()
        )
        observeLifecycle()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The id events are currently attributed to.
    public var distinctID: String { identity.distinctID }

    /// Queue an event. Delivery is batched; call `flush()` to force it.
    public func capture(_ event: String, properties: [String: Any] = [:]) {
        var props = properties
        // Set last so a caller cannot accidentally mislabel which app this is.
        props["platform"] = configuration.platform
        transport.enqueue(QueuedEvent(
            event: event,
            distinctID: identity.distinctID,
            properties: props,
            timestamp: Date()
        ))
    }

    /// Record a screen view. Call it from `onAppear` / `viewDidAppear`.
    public func screen(_ name: String, properties: [String: Any] = [:]) {
        var props = properties
        props["screen"] = name
        // Traffic's "Top pages" reads `path`. Giving the screen a path shape puts
        // app screens in that list beside the website's pages, where the platform
        // split is what tells them apart.
        if props["path"] == nil {
            props["path"] = name.hasPrefix("/") ? name : "/" + name
        }
        capture(Self.screenEvent, properties: props)
    }

    /// Switch to an identified user, and link everything this install did before
    /// now to them.
    ///
    /// The alias is what stops one human counting as two — the person who read
    /// the marketing site, installed the app, and signed in is one person across
    /// both. It is sent before the pending events are flushed, so the server has
    /// the link before the events that need it arrive.
    public func identify(_ userID: String, traits: [String: Any] = [:]) {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let previous = identity.identify(trimmed) {
            transport.send(path: "/alias", body: [
                "anonymous_id": previous,
                "distinct_id": trimmed,
            ])
        }
        transport.send(path: "/identify", body: [
            "distinct_id": trimmed,
            "$set": traits,
        ])
        flush()
    }

    /// Start a fresh anonymous identity. Call on logout, or the next person on
    /// this device inherits the last one's history.
    public func reset() {
        flush()
        identity.reset()
    }

    /// Send everything buffered now.
    public func flush() {
        transport.flush()
    }

    // MARK: - lifecycle

    /// A phone app is killed, not unloaded: there is no `pagehide` and no
    /// `sendBeacon`. Backgrounding is the last reliable moment to get the buffer
    /// out, so flush there — and again on termination for the case where the user
    /// swipes the app away from the switcher.
    private func observeLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.flushInBackgroundTask()
            }
            observers.append(observer)
        }
        #endif
    }

    /// Asks the OS for a few seconds of background time so a flush started at
    /// the moment of backgrounding is not cut off mid-request.
    private func flushInBackgroundTask() {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        let application = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = application.beginBackgroundTask(withName: "agentray.flush") {
            application.endBackgroundTask(task)
            task = .invalid
        }
        flush()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if task != .invalid {
                application.endBackgroundTask(task)
                task = .invalid
            }
        }
        #else
        flush()
        #endif
    }
}
