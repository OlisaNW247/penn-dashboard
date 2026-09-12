import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Hands out Apple's on-device sentence embedding only once it is already
/// loaded, and never blocks the caller to load it.
///
/// **Why this exists.** On a phone reinstalled today (2026-09-12), the first
/// question to `ask` froze the assistant bubble on the streaming cursor for
/// two minutes with nothing arriving — well past the 60s `URLSession`
/// timeout that would otherwise have shown a visible fallback message, which
/// is what gave away that the stall was happening *before* the network call
/// even started. The cause was `CourseSearch.rerank` calling
/// `NLEmbedding.sentenceEmbedding(for: .english)` directly, synchronously, on
/// whatever thread (in practice the main actor) happened to be building the
/// request. On a fresh install iOS has not yet downloaded that embedding
/// asset; the call blocks the calling thread for as long as the on-demand
/// download takes, with no timeout of its own and entirely outside
/// `URLSession`'s. `retrievedExcerpts`/`CourseSearch(knowledge:)` also builds
/// a fresh BM25 index synchronously, so the whole retrieval path — not just
/// the embedding lookup — has to run off whatever actor asked the question,
/// but the embedding load is the one piece that can legitimately take
/// minutes rather than milliseconds, which is why it gets its own type
/// instead of just "move retrieval to a background task" (see
/// `BackendAssistantResponder.reply` / `OnDeviceAssistantResponder.reply` for
/// that half of the fix).
///
/// **The wrong fix** would be moving the whole search onto a background
/// queue and leaving `NLEmbedding.sentenceEmbedding(for:)` a synchronous call
/// there: the student would still wait minutes for an asset that, on a slow
/// or offline connection, may never arrive at all — just off the main actor
/// instead of on it, which stops the freeze but not the multi-minute answer.
/// BM25 alone is already a complete, ordered answer (`CourseSearch.rerank`
/// falls back to it unchanged when this provider has nothing yet); the
/// embedding is a quality bonus that should apply the moment it's available
/// and never be waited for.
///
/// A lock-protected `state` plus a single background load, kicked off by
/// whichever of `current()`/`warmUp()` asks first and never repeated once it
/// settles into `.ready` or `.unavailable` — asking the system-managed asset
/// daemon to try again on every single question would not make an absent or
/// slow-to-arrive asset appear any faster, only add another idle detached
/// task per question.
public final class SentenceEmbeddingProvider: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case cold
        case loading
        case ready
        case unavailable
    }

    /// The shared instance every call site in the Kit and UI use.
    /// `init(loader:)` stays available (not `private`) purely so tests can
    /// construct an isolated instance with a controllable loader instead of
    /// fighting over process-wide shared state.
    public static let shared = SentenceEmbeddingProvider()

    private let lock = NSLock()
    private let loader: @Sendable () -> AnyObject?
    private var _state: State = .cold
    private var loaded: AnyObject?
    private var hasStartedLoad = false

    /// `loader` runs on a detached background task exactly once; it may
    /// block for minutes (the on-demand asset download) and isolating that
    /// wait off the caller's actor is this type's entire job. Returns
    /// `AnyObject?` rather than `NLEmbedding?` so this file's public surface
    /// says nothing platform-specific — `CourseSearch.rerank` is the only
    /// caller that ever downcasts the result, and only inside its own
    /// `canImport(NaturalLanguage)` block.
    public init(loader: @escaping @Sendable () -> AnyObject?) {
        self.loader = loader
    }

    /// The default loader: `NLEmbedding.sentenceEmbedding(for: .english)`
    /// where `NaturalLanguage` exists, `nil` (permanently `.unavailable`)
    /// everywhere else, including Linux where this Kit's tests run.
    public convenience init() {
        self.init {
            #if canImport(NaturalLanguage)
            return NLEmbedding.sentenceEmbedding(for: .english)
            #else
            return nil
            #endif
        }
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// The loaded embedding, or `nil` if it isn't ready yet. Never blocks:
    /// a `nil` result from `.cold` also starts the background load (once),
    /// so the *next* question — not this one — gets to use it.
    public func current() -> AnyObject? {
        lock.lock()
        let alreadyReady = _state == .ready
        let object = loaded
        let shouldStart = !hasStartedLoad
        if shouldStart { hasStartedLoad = true; _state = .loading }
        lock.unlock()

        if shouldStart { startLoad() }
        return alreadyReady ? object : nil
    }

    /// Starts the background load without wanting the result back — the
    /// call `AssistantView` and `AppState.init` make so the asset has a head
    /// start before the student's first question, rather than the student's
    /// first question being what triggers the download. Idempotent: a
    /// second call while `.loading`, `.ready`, or `.unavailable` does
    /// nothing.
    public func warmUp() {
        lock.lock()
        let shouldStart = !hasStartedLoad
        if shouldStart { hasStartedLoad = true; _state = .loading }
        lock.unlock()

        if shouldStart { startLoad() }
    }

    /// Never called on the caller's thread — always inside a detached task,
    /// which is the entire point of this type existing. Captures `self`
    /// alone (not `loader`/`lock` individually): `self` is already asserted
    /// `@unchecked Sendable`, which is exactly the escape hatch that lets a
    /// `@Sendable` closure reach `NSLock`, a type the compiler does not
    /// itself know is safe to share across threads, without repeating that
    /// assertion at every capture site.
    private func startLoad() {
        Task.detached(priority: .utility) { [self] in
            let value = self.loader()
            self.lock.lock()
            self.loaded = value
            self._state = value == nil ? .unavailable : .ready
            self.lock.unlock()
        }
    }
}
