import Foundation

/// Where the SDK keeps the two ids it owns. Abstracted so the tests can run
/// against an in-memory store instead of the real `UserDefaults`, and so a host
/// app can point it at a shared app-group suite when an extension needs the same
/// identity.
public protocol AgentRayStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func remove(forKey key: String)
}

extension UserDefaults: AgentRayStore {
    public func set(_ value: String, forKey key: String) {
        setValue(value, forKey: key)
    }

    public func remove(forKey key: String) {
        removeObject(forKey: key)
    }
}

/// Identity is the whole reason a native SDK exists rather than a documented
/// `POST /capture`.
///
/// Three things go wrong when an app rolls its own:
///
/// 1. **A fresh id per launch.** Then every session is a new person and the app's
///    "visitors" number is really its launch count.
/// 2. **No alias on login.** Someone who read the website, then installed the app
///    and signed in, arrives as two people. Every funnel that spans both is then
///    the sum of two halves of one person.
/// 3. **No reset on logout.** The next person on that device inherits the
///    previous one's history.
///
/// So the anonymous id is persisted, `identify` links the anonymous history to
/// the user through `POST /alias` before switching, and `reset` clears both.
final class Identity {
    static let anonymousKey = "agentray_anon_id"
    static let distinctKey = "agentray_distinct_id"

    private let store: AgentRayStore
    private let lock = NSLock()

    init(store: AgentRayStore) {
        self.store = store
    }

    /// The stable per-install id. Minted once and kept, so a screen view and a
    /// signup an hour later are the same person.
    var anonymousID: String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = store.string(forKey: Self.anonymousKey), !existing.isEmpty {
            return existing
        }
        let minted = "a-" + UUID().uuidString.lowercased()
        store.set(minted, forKey: Self.anonymousKey)
        return minted
    }

    /// The id events are sent under: the logged-in user when there is one, the
    /// anonymous id otherwise.
    var distinctID: String {
        lock.lock()
        let identified = store.string(forKey: Self.distinctKey)
        lock.unlock()
        if let identified, !identified.isEmpty { return identified }
        return anonymousID
    }

    /// True once `identify` has run — used to decide whether an alias is needed.
    var isIdentified: Bool {
        lock.lock()
        defer { lock.unlock() }
        let identified = store.string(forKey: Self.distinctKey)
        return !(identified ?? "").isEmpty
    }

    /// Switches to `userID` and returns the id that was in use before, or nil
    /// when there is nothing to link (already this user).
    @discardableResult
    func identify(_ userID: String) -> String? {
        let previous = distinctID
        lock.lock()
        store.set(userID, forKey: Self.distinctKey)
        lock.unlock()
        return previous == userID ? nil : previous
    }

    /// Forgets both ids, so the next person on this device starts clean.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        store.remove(forKey: Self.distinctKey)
        store.remove(forKey: Self.anonymousKey)
    }
}
