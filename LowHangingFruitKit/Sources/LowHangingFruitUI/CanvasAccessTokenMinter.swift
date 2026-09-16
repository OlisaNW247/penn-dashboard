import Foundation
import LowHangingFruitKit
import WebKit

/// Runs `CanvasAccessTokenMint.script` inside a live, already-signed-in
/// Canvas `WKWebView` and turns whatever comes back into a `CanvasAccessToken`
/// — the one piece of this feature that has to touch WebKit at all (see
/// `CanvasAccessToken.swift`'s doc comment in the Kit for why the mint has to
/// run as an in-page `fetch` rather than a bare `URLSession` POST: Canvas's
/// tokens endpoint is CSRF-guarded, and only a page Canvas itself served can
/// read that token out of `document.cookie`).
///
/// Called exactly once, right after a real interactive Canvas login
/// (`CanvasLoginPane.connect()` in `OnboardingView.swift`), never from
/// anywhere unattended — see that call site's own comment for why minting
/// from inside `CanvasSessionRenewer` instead was considered and rejected
/// (that class's rule 1 is GET-only; this is a POST, so it does not belong
/// there even though the renewer also runs inside `LoginDataStores.canvas`).
@MainActor
enum CanvasAccessTokenMinter {
    /// How long to wait for Canvas to answer before giving up and treating
    /// this as a failed mint. The login has already succeeded by the time
    /// this runs (see the call site) — a hang here must not be able to trap
    /// the student on the login pane indefinitely, so this races the actual
    /// JavaScript call against a plain timer and takes whichever finishes
    /// first.
    private static let timeout: TimeInterval = 15

    /// Mints a Canvas personal access token inside `webView`'s currently
    /// loaded, already-authenticated page. Never throws: every failure mode
    /// (a non-2xx Canvas response, a malformed reply, a JavaScript error, a
    /// timeout) comes back as `.failure`, because a mint failure must never
    /// interrupt or fail the login flow it rides on — cookie mode is always
    /// the fallback (see `CanvasAuth.apply`), so the worst case here is
    /// "nothing changes," never "the student can't get in."
    ///
    /// Races the JavaScript call against a hard timeout using the exact
    /// idempotent-resume shape `CanvasSessionRenewer`'s `SettleWaiter`
    /// already established for "race a WebKit completion against a timer"
    /// (see that file) — an `@MainActor` waiter class rather than a bare
    /// `Task`/`TaskGroup` race, deliberately: a `withTaskGroup` here would
    /// need its child-task closures to be `@Sendable`, and one of them has
    /// to capture `webView` itself (not `Sendable`) to make the
    /// `callAsyncJavaScript` call at all. Routing the race through a single
    /// `@MainActor`-isolated class instance instead means only that
    /// instance's own methods ever touch the shared "have we resumed yet"
    /// state, and nothing here needs to be `Sendable` to begin with.
    static func mint(in webView: WKWebView, now: Date = Date()) async -> Result<CanvasAccessToken, CanvasAccessTokenMint.Failure> {
        let script = CanvasAccessTokenMint.script(
            purpose: CanvasAccessTokenPolicy.purpose,
            expiresAt: CanvasAccessTokenPolicy.expiry(from: now)
        )

        let waiter = MintWaiter()

        // `callAsyncJavaScript` treats `script` as the body of an implicit
        // async function (see `CanvasAccessTokenMint.script`'s own doc
        // comment) and hands back whatever it `return`s — here, the
        // JSON-encoded `{status, body}` envelope as a bridged Swift
        // `String`. `contentWorld: .defaultClient` runs it in the page's
        // own world (not an isolated one), which is required for
        // `document.cookie` and same-origin `fetch` to see the real,
        // already-authenticated session exactly as the page itself would.
        // `callAsyncJavaScript(_:arguments:in:in:completionHandler:)` really
        // does take two `in` labels (frame, then content world) — that is
        // Apple's own signature, not a typo here.
        webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { result in
            switch result {
            case let .success(value):
                guard let envelope = value as? String else {
                    waiter.signal(.failure(.malformed("script result was not a String")))
                    return
                }
                waiter.signal(CanvasAccessTokenMint.parseScriptResult(envelope, now: now))
            case .failure:
                // A JavaScript-level exception (the script threw, or WebKit
                // couldn't even run it) rather than a Canvas HTTP error —
                // the script itself never throws on a non-2xx response (see
                // its doc comment: `fetch` only rejects for network
                // failures), so this is "couldn't tell," exactly like a
                // decode failure.
                waiter.signal(.failure(.malformed("javascript evaluation failed")))
            }
        }

        let timeoutTask = Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            waiter?.signal(.failure(.malformed("mint timed out after \(Int(timeout))s")))
        }
        let result = await waiter.wait()
        timeoutTask.cancel()
        return result
    }

    /// Best-effort `DELETE /api/v1/users/self/tokens/:id` for a token being
    /// replaced (a fresh mint superseding an older one — see
    /// `CanvasLoginPane.connect()`) or removed on disconnect
    /// (`AppState.disconnectCanvas()`). Fire-and-forget: every error is
    /// swallowed, because a revoke that fails leaves nothing worse than an
    /// extra row under the student's own Canvas → Settings → Approved
    /// Integrations, which they can also remove by hand, and the ONE thing
    /// that must never happen is a revoke failure blocking or reversing the
    /// local clear/replace it rides alongside.
    ///
    /// Authenticates as `token` itself (`Authorization: Bearer <token>`) —
    /// Canvas's tokens endpoint accepts a token deleting itself, and this
    /// runs long after the WebView/cookie session that minted it may already
    /// be gone (disconnect purges cookies before this call in
    /// `AppState.disconnectCanvas`), so the token is the only credential
    /// guaranteed to still be in hand. Uses `token.id` when present, falling
    /// back to nothing (a no-op) rather than guessing — `tokenHint` is a
    /// display fragment, not a usable path segment, and Canvas's own `:id`
    /// route segment is the numeric id or nothing.
    static func revoke(_ token: CanvasAccessToken) async {
        guard let id = token.id, let url = URL(string: "https://canvas.upenn.edu/api/v1/users/self/tokens/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// Exactly-once-resumable result holder shared between the `callAsyncJavaScript`
/// completion handler and the timeout `Task` in `mint(in:now:)` above —
/// the identical shape to `CanvasSessionRenewer`'s `SettleWaiter` (see that
/// file's doc comment for the full reasoning): whichever of "Canvas
/// answered" or "timeout fired" happens first wins and resumes the
/// continuation, and the loser's call to `signal(_:)` becomes a harmless
/// no-op instead of a double-resume (a fatal error) or a continuation that
/// never resumes at all.
@MainActor
private final class MintWaiter {
    private var continuation: CheckedContinuation<Result<CanvasAccessToken, CanvasAccessTokenMint.Failure>, Never>?
    private var hasResumed = false

    func wait() async -> Result<CanvasAccessToken, CanvasAccessTokenMint.Failure> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal(_ value: Result<CanvasAccessToken, CanvasAccessTokenMint.Failure>) {
        guard !hasResumed, let continuation else { return }
        hasResumed = true
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
