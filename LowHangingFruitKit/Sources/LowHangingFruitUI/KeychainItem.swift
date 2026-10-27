import Foundation
import Security

/// What a Keychain read found, in three answers rather than two.
///
/// Every store here used to answer "a value, or nil", and nil meant two things:
/// the item is not there, and the Keychain would not say. They need opposite
/// handling. "Not there" is a fact the app can act on (nothing saved, so ask the
/// student to connect, or mint a first identity). "Would not say" is the
/// absence of a fact: the device is locked before first unlock, the item's
/// access list refused this process, the file keychain hiccuped. Acting on it
/// as though it were "not there" signs a student out of a session that is
/// sitting in the Keychain (raising the banner, starting a renewal that
/// overwrites the saved cookies with a handful of fresh ones), or mints a
/// second anonymous backend account while the first one's refresh token is
/// fine (`BackendSession`).
///
/// `unavailable` carries the `OSStatus` so a diagnostic can say why.
enum KeychainRead<Value> {
    case found(Value)
    case notFound
    case unavailable(OSStatus)

    /// The value, for the callers that only ever wanted "a value or nil".
    var value: Value? {
        if case let .found(value) = self { return value }
        return nil
    }

    /// Decodes a found payload. A payload that is present but does not decode
    /// is a corrupt item, which no later read will fix and which is not the
    /// Keychain refusing to answer, so it reads as `notFound` (exactly what
    /// every store's old `try?` chain turned it into).
    func decoded<T>(_ transform: (Value) -> T?) -> KeychainRead<T> {
        switch self {
        case let .found(value):
            if let decoded = transform(value) { return .found(decoded) }
            return .notFound
        case .notFound:
            return .notFound
        case let .unavailable(status):
            return .unavailable(status)
        }
    }
}

extension KeychainRead: Equatable where Value: Equatable {}

/// Counts every `OSStatus` the Keychain helpers see, so a DEBUG diagnostic can
/// say how many writes and reads were refused and why. Before this the stores
/// discarded the status of every `SecItemAdd` and `SecItemDelete`, and a write
/// that failed was indistinguishable from one that landed.
///
/// A process-wide counter on purpose: it answers "has the Keychain been
/// misbehaving in this process", across all seven stores, which no single store
/// can say. Never records an item's contents, service or account.
final class KeychainStatusLog: @unchecked Sendable {
    enum Operation: String, Sendable {
        case read, update, add, delete
    }

    static let shared = KeychainStatusLog()

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failures = 0
    private var lastFailureStatus: OSStatus?

    /// Statuses that are an answer rather than a failure. "Not found" is how a
    /// read, an update-in-place or a delete says there was nothing there, and
    /// the write helper relies on exactly that answer from update.
    private static func isExpected(_ operation: Operation, _ status: OSStatus) -> Bool {
        if status == errSecSuccess { return true }
        switch operation {
        case .read, .update, .delete: return status == errSecItemNotFound
        case .add: return false
        }
    }

    func record(_ operation: Operation, _ status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        counts["\(operation.rawValue) \(status)", default: 0] += 1
        if !Self.isExpected(operation, status) {
            failures += 1
            lastFailureStatus = status
        }
    }

    /// How many calls came back with a status that was neither success nor an
    /// expected "not found".
    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    var lastFailure: OSStatus? {
        lock.lock(); defer { lock.unlock() }
        return lastFailureStatus
    }

    /// Every (operation, status) pair seen and how many times, e.g.
    /// `["update 0": 12, "update -25300": 1, "add 0": 1]`.
    var snapshot: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }

    /// One line for a diagnostic: the failure count first, then each pair.
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let pairs = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "failures \(failures)" + (pairs.isEmpty ? "" : " | \(pairs)")
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        counts = [:]
        failures = 0
        lastFailureStatus = nil
    }
}

/// The one place the app calls `SecItem*`, for all seven generic-password
/// stores (`SessionCookieStore`, `ICSFeedURLStore`, `EdSessionTokenStore`,
/// `BackendIdentityStore`, `CanvasAccessTokenStore`, `PennKeyCredentialStore`,
/// `SyncKeyStore`).
///
/// **Write: update first, add only when there is nothing to update.** The
/// stores used to "upsert" by `SecItemDelete` then `SecItemAdd`, ignoring both
/// statuses. Between the two calls the item does not exist, so a crash, a
/// kill, or an add the Keychain refuses (a device locked at that instant, a
/// full keychain) leaves the student with no credential at all, where an
/// update that is refused leaves the previous one in place.
/// `PennKeyCredentialStore.save` already did it in this order; this is that
/// code, shared. The wrong fix is checking the delete's status before the add:
/// the window between them is the bug, not the unchecked status.
///
/// **Read: three answers** (`KeychainRead`). **Every status is counted**
/// (`KeychainStatusLog`).
///
/// Each seam takes the underlying call as a closure, defaulting to the real
/// `SecItem*` function, so a test can drive the order of calls and the status
/// each returns without touching a Keychain.
enum KeychainItem {
    /// Readable after first unlock so the launch-time auto-sync can replay a
    /// session, and never migrated to another device or into a backup.
    static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// Stores `data` under `base` (class, service, account, and for Ed's token
    /// the explicit non-synchronizable attribute), replacing what is there.
    /// Returns the final `OSStatus`; `errSecSuccess` means the new value is
    /// the one in the Keychain. Any other status means the previous value, if
    /// there was one, is still in place: nothing here ever deletes.
    ///
    /// `errSecDuplicateItem` from the add is another writer winning the race
    /// between our update and our add (the renewer and the foreground both
    /// saving cookies, say). The item exists now, so update it once more
    /// rather than report a failure for a value that should simply land.
    @discardableResult
    static func write(
        _ data: Data,
        base: [String: Any],
        update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) },
        log: KeychainStatusLog = .shared
    ) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        var status = update(base as CFDictionary, attributes as CFDictionary)
        log.record(.update, status)
        guard status == errSecItemNotFound else { return status }

        var query = base
        attributes.forEach { query[$0.key] = $0.value }
        status = add(query as CFDictionary)
        log.record(.add, status)
        guard status == errSecDuplicateItem else { return status }

        status = update(base as CFDictionary, attributes as CFDictionary)
        log.record(.update, status)
        return status
    }

    /// Reads the item at `base`, three ways. A successful call that returned
    /// no data is not "found": it is a Keychain that answered strangely, and
    /// reads as unavailable.
    static func read(
        _ base: [String: Any],
        copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) },
        log: KeychainStatusLog = .shared
    ) -> KeychainRead<Data> {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copy(query as CFDictionary, &result)
        log.record(.read, status)
        return classify(status: status, data: result as? Data)
    }

    /// Pure half of `read`, so the mapping is testable.
    static func classify(status: OSStatus, data: Data?) -> KeychainRead<Data> {
        switch status {
        case errSecSuccess:
            if let data { return .found(data) }
            return .unavailable(errSecDecode)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    /// Deletes the item at `base`. "Not found" is success: the item is gone,
    /// which is what was asked for.
    @discardableResult
    static func delete(
        _ base: [String: Any],
        deleteItem: (CFDictionary) -> OSStatus = { SecItemDelete($0) },
        log: KeychainStatusLog = .shared
    ) -> OSStatus {
        let status = deleteItem(base as CFDictionary)
        log.record(.delete, status)
        return status
    }
}
