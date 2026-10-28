import Foundation

/// A small thread-safe memo for a pure function of a string, for the checks
/// the dashboard rebuild repeats on the same few hundred inputs every time
/// anything changes (a title's tokens, whether a course key names a program
/// site).
///
/// Only for functions whose answer depends on the key and nothing else: a
/// cached answer is returned for as long as the process lives, so anything
/// that also reads a clock, a setting or a store must not go through here.
///
/// Bounded: past `capacity` entries it starts over. It does not track
/// recency, because an eviction policy is more machinery than a cache of a
/// few hundred strings needs, and the failure it guards against (a key space
/// that grows with user input) is a slow leak, not a hot loop.
final class BoundedMemo<Value: Sendable>: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var table: [String: Value] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// The remembered answer for `key`, or `compute(key)`, remembered.
    /// `compute` runs outside the lock, so two threads racing on a new key
    /// each compute it and the second store wins, which costs one redundant
    /// computation and never a stall behind another thread's.
    func value(for key: String, compute: (String) -> Value) -> Value {
        lock.lock()
        if let hit = table[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let computed = compute(key)

        lock.lock()
        defer { lock.unlock() }
        if table.count >= capacity { table.removeAll(keepingCapacity: true) }
        table[key] = computed
        return computed
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return table.count
    }
}
