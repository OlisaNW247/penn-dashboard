import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `CanvasAccessTokenStore` persists the Canvas personal access token
/// `CanvasAccessTokenMinter` mints from inside the login WebView, in its own
/// Keychain item (never `UserDefaults` — see that type's doc comment for why
/// a bearer credential this powerful belongs in Tier 3).
///
/// Like `SessionCookieStoreTests`, this suite touches a real, process-wide
/// Keychain item, so every test clears it before and after
/// (`withCleanStore`) and the suite is `.serialized` so its own tests never
/// race each other over that same item. It does NOT serialize against
/// `CanvasTokenWiringTests`' one test that also touches this store
/// (`noteCanvasAccessTokenRejected` calling `CanvasAccessTokenStore.clear()`)
/// — Swift Testing runs distinct suites concurrently by default, and folding
/// every Keychain-touching test into one suite (the fix `SessionCookieStoreTests`'
/// own doc comment describes for cookies) was rejected here only because the
/// task that produced this file named the two suites explicitly and
/// separately. This is the same shape as this repo's two documented,
/// accepted pre-existing flakes (CLAUDE.md, "Two known flakes"), not a new
/// one this file introduces from nothing.
@Suite("Canvas access token store", .serialized)
struct CanvasAccessTokenStoreTests {
    private func withCleanStore(_ body: () -> Void) {
        CanvasAccessTokenStore.clear()
        defer { CanvasAccessTokenStore.clear() }
        body()
    }

    private func token(
        secret: String = "1234~abcdefghijklmnopqrstuvwxyz",
        id: String? = "9001",
        tokenHint: String? = "...wxyz",
        expiresAt: Date? = Date().addingTimeInterval(100 * 86_400),
        createdAt: Date = Date()
    ) -> CanvasAccessToken {
        CanvasAccessToken(token: secret, id: id, tokenHint: tokenHint, expiresAt: expiresAt, createdAt: createdAt)
    }

    @Test("A saved token round-trips every field through load()")
    func roundTrip() {
        withCleanStore {
            let original = token()
            CanvasAccessTokenStore.save(original)
            let loaded = CanvasAccessTokenStore.load()
            #expect(loaded == original)
        }
    }

    @Test("save() replaces whatever was stored before, not merges with it")
    func saveReplaces() {
        withCleanStore {
            CanvasAccessTokenStore.save(token(secret: "old-secret", id: "1"))
            CanvasAccessTokenStore.save(token(secret: "new-secret", id: "2"))
            let loaded = CanvasAccessTokenStore.load()
            #expect(loaded?.token == "new-secret")
            #expect(loaded?.id == "2")
        }
    }

    @Test("clear() removes the persisted token")
    func clearRemoves() {
        withCleanStore {
            CanvasAccessTokenStore.save(token())
            CanvasAccessTokenStore.clear()
            #expect(CanvasAccessTokenStore.load() == nil)
        }
    }

    @Test("load() is nil when nothing was ever saved")
    func loadNilWhenEmpty() {
        withCleanStore {
            #expect(CanvasAccessTokenStore.load() == nil)
        }
    }

    // MARK: - usable(now:) / bearer(now:)

    @Test("usable(now:) returns a token that hasn't expired yet")
    func usableWhileFresh() {
        withCleanStore {
            let future = Date().addingTimeInterval(3600)
            CanvasAccessTokenStore.save(token(expiresAt: future))
            #expect(CanvasAccessTokenStore.usable(now: Date()) != nil)
        }
    }

    @Test("usable(now:) is nil once the token's own expiresAt has passed")
    func notUsableOnceExpired() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            CanvasAccessTokenStore.save(token(expiresAt: past))
            #expect(CanvasAccessTokenStore.usable(now: Date()) == nil)
        }
    }

    @Test("usable(now:) treats a nil expiresAt as never-expiring")
    func nilExpiryNeverExpires() {
        withCleanStore {
            CanvasAccessTokenStore.save(token(expiresAt: nil))
            let farFuture = Date().addingTimeInterval(10 * 365 * 86_400)
            #expect(CanvasAccessTokenStore.usable(now: farFuture) != nil)
        }
    }

    @Test("bearer(now:) hands back the raw secret when usable")
    func bearerReturnsSecret() {
        withCleanStore {
            CanvasAccessTokenStore.save(token(secret: "the-actual-secret", expiresAt: Date().addingTimeInterval(3600)))
            #expect(CanvasAccessTokenStore.bearer(now: Date()) == "the-actual-secret")
        }
    }

    @Test("bearer(now:) is nil when the stored token has expired")
    func bearerNilWhenExpired() {
        withCleanStore {
            CanvasAccessTokenStore.save(token(expiresAt: Date().addingTimeInterval(-1)))
            #expect(CanvasAccessTokenStore.bearer(now: Date()) == nil)
        }
    }

    @Test("bearer(now:) is nil when nothing was ever saved")
    func bearerNilWhenAbsent() {
        withCleanStore {
            #expect(CanvasAccessTokenStore.bearer(now: Date()) == nil)
        }
    }
}
