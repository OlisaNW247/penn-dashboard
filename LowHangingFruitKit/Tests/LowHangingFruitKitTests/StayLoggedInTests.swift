import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the "stay signed in" feature's `AppState` wiring
/// (CLAUDE.md's "stay signed in" entry): `stayLoggedInEnabled`,
/// `autoLoginDisabledReason`, `hasOfferedStayLoggedIn`, `canAutoLogin`, and
/// the methods that mutate them.
///
/// `AppState` persists these three flags into the process-wide
/// `UserDefaults.lhf`, so every test backs up and restores the exact keys it
/// touches — the same `withCleanFlags` discipline `CloudSyncToggleTests` uses
/// for its own key, not the per-instance-seam workaround
/// `forceCanvasSessionConfirmedDeadForTesting()` exists for. That seam is
/// needed specifically because `canvasSessionConfirmedDead` changes what a
/// CONCURRENTLY-CONSTRUCTED `AppState` in another suite does at `init` (the
/// first-launch hold — see that method's own doc comment for the incident).
/// None of these three flags feed any such cross-suite behavior: nothing
/// else in `AppState.init` branches on them, so a backed-up-and-restored
/// write to `UserDefaults.lhf` around each test is exactly as hermetic here
/// as it already is for `cloudSyncEnabledKey`. `.serialized` for the same
/// reason `CloudSyncToggleTests` gives: two tests racing a
/// backup/restore of the same shared key could lose each other's writes.
///
/// `PennKeyCredentialStore` is a real, process-wide Keychain item, same
/// caveat `SessionCookieStoreTests`/`CanvasAccessTokenStoreTests` already
/// carry (CLAUDE.md, "Two known flakes") — every test that touches it clears
/// it before and after.
@MainActor
@Suite("Stay signed in", .serialized)
struct StayLoggedInTests {
    private static let enabledKey = "stayLoggedInEnabledV1"
    private static let reasonKey = "autoLoginDisabledReasonV1"
    private static let awaitingDuoKey = "autoLoginAwaitingDuoV1"
    private static let offeredKey = "hasOfferedStayLoggedInV1"
    private static let touchedKeys = [enabledKey, reasonKey, awaitingDuoKey, offeredKey]

    /// Mirrors `CloudSyncToggleTests.withCleanFlag` / `AnnouncementWatcherWiringTests
    /// .withRestoredDefaults`: snapshot, run `body`, put everything back
    /// exactly as found (`nil` restored by removal, not a placeholder).
    private func withCleanFlags(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let saved = Self.touchedKeys.map { ($0, defaults.object(forKey: $0)) }
        PennKeyCredentialStore.clear()
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            PennKeyCredentialStore.clear()
        }
        for key in Self.touchedKeys {
            defaults.removeObject(forKey: key)
        }
        body()
    }

    // MARK: - Defaults

    @Test("nothing persisted means off, no reason, and not yet offered")
    func defaultsAreOffAndUnoffered() {
        withCleanFlags {
            let state = AppState()
            #expect(state.stayLoggedInEnabled == false)
            #expect(state.autoLoginDisabledReason == nil)
            #expect(state.hasOfferedStayLoggedIn == false)
            #expect(state.canAutoLogin == false)
        }
    }

    // MARK: - enableStayLoggedIn(username:password:)

    @Test("enableStayLoggedIn saves credentials, flips the flag, and clears any reason")
    func enableStayLoggedInSavesAndEnables() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")

            #expect(state.stayLoggedInEnabled == true)
            #expect(state.autoLoginDisabledReason == nil)
            #expect(PennKeyCredentialStore.hasCredentials == true)
            let loaded = PennKeyCredentialStore.load()
            #expect(loaded?.username == "student")
            #expect(loaded?.password == "hunter2")
        }
    }

    @Test("enableStayLoggedIn re-entering a password clears a prior rejection")
    func enableStayLoggedInClearsRejection() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "wrong")
            state.noteAutoLoginRejected()
            #expect(state.autoLoginDisabledReason != nil)

            state.enableStayLoggedIn(username: "student", password: "corrected")
            #expect(state.autoLoginDisabledReason == nil)
            #expect(state.canAutoLogin == true)
        }
    }

    @Test("an empty username or password is refused — no partial credential is ever stored")
    func enableStayLoggedInRefusesEmptyFields() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "", password: "hunter2")
            #expect(state.stayLoggedInEnabled == false)
            #expect(PennKeyCredentialStore.hasCredentials == false)

            state.enableStayLoggedIn(username: "student", password: "")
            #expect(state.stayLoggedInEnabled == false)
            #expect(PennKeyCredentialStore.hasCredentials == false)
        }
    }

    // MARK: - disableStayLoggedIn()

    @Test("disableStayLoggedIn clears the Keychain and both flags")
    func disableStayLoggedInClearsEverything() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteAutoLoginRejected()

            state.disableStayLoggedIn()

            #expect(state.stayLoggedInEnabled == false)
            #expect(state.autoLoginDisabledReason == nil)
            #expect(PennKeyCredentialStore.hasCredentials == false)
        }
    }

    // MARK: - noteAutoLoginRejected() / the rejection only clears via enableStayLoggedIn()

    @Test("noteAutoLoginRejected sets a reason and canAutoLogin becomes false")
    func rejectedSetsReasonAndDisablesAutoLogin() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            #expect(state.canAutoLogin == true)

            state.noteAutoLoginRejected()

            #expect(state.autoLoginDisabledReason != nil)
            #expect(state.canAutoLogin == false)
            // The username stays on file so `PennKeyCredentialsSheet` can
            // prefill it for "update password" — only the outcome/flag
            // changed, not the stored credential.
            #expect(PennKeyCredentialStore.hasCredentials == true)
        }
    }

    @Test("noteAutoLoginRejected persists the reason across a relaunch")
    func rejectedReasonPersists() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteAutoLoginRejected()

            let relaunched = AppState()
            #expect(relaunched.autoLoginDisabledReason != nil)
            #expect(relaunched.stayLoggedInEnabled == true)
            #expect(relaunched.canAutoLogin == false)
        }
    }

    // MARK: - canAutoLogin truth table

    @Test("canAutoLogin is false when the toggle is off, even with credentials on file")
    func canAutoLoginFalseWhenToggleOff() {
        withCleanFlags {
            let state = AppState()
            PennKeyCredentialStore.save(username: "student", password: "hunter2")
            #expect(state.stayLoggedInEnabled == false)
            #expect(state.canAutoLogin == false)
        }
    }

    @Test("canAutoLogin is false when enabled but no credentials are actually on file")
    func canAutoLoginFalseWhenCredentialsMissing() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            // Simulate the credential having disappeared from under the flag
            // (should never happen in practice, but this is the one place
            // that must not trust the toggle blindly if it does).
            PennKeyCredentialStore.clear()
            #expect(state.canAutoLogin == false)
        }
    }

    @Test("canAutoLogin is true only when enabled, credentialed, and unrejected")
    func canAutoLoginTrueWhenAllThreeHold() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            #expect(state.canAutoLogin == true)
        }
    }

    // MARK: - noteStayLoggedInOffered()

    @Test("noteStayLoggedInOffered persists across a relaunch")
    func offeredPersists() {
        withCleanFlags {
            let state = AppState()
            #expect(state.hasOfferedStayLoggedIn == false)
            state.noteStayLoggedInOffered()
            #expect(state.hasOfferedStayLoggedIn == true)

            let relaunched = AppState()
            #expect(relaunched.hasOfferedStayLoggedIn == true)
        }
    }

    // MARK: - disconnectCanvas() takes the password with it

    @Test("disconnectCanvas clears stay-signed-in credentials and flags")
    func disconnectCanvasClearsStayLoggedIn() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            #expect(PennKeyCredentialStore.hasCredentials == true)

            state.disconnectCanvas()

            #expect(state.stayLoggedInEnabled == false)
            #expect(state.autoLoginDisabledReason == nil)
            #expect(PennKeyCredentialStore.hasCredentials == false)
        }
    }

    // MARK: - stayLoggedInDiagnosticDescription (DiagnosticsReport's one line)

    @Test("diagnostic description never mentions a username or password")
    func diagnosticDescriptionShape() {
        withCleanFlags {
            let state = AppState()
            #expect(state.stayLoggedInDiagnosticDescription == "off")

            state.enableStayLoggedIn(username: "student", password: "hunter2")
            #expect(state.stayLoggedInDiagnosticDescription == "on")
            #expect(!state.stayLoggedInDiagnosticDescription.contains("student"))
            #expect(!state.stayLoggedInDiagnosticDescription.contains("hunter2"))

            state.noteAutoLoginRejected()
            #expect(state.stayLoggedInDiagnosticDescription.hasPrefix("on (disabled:"))
            #expect(!state.stayLoggedInDiagnosticDescription.contains("student"))
            #expect(!state.stayLoggedInDiagnosticDescription.contains("hunter2"))
        }
    }

    // MARK: - .needsDuo → autoLoginAwaitingDuo (real-device finding, 2026-09-21)
    //
    // A real-device run of "simulate canvas logout" reported `.needsDuo`
    // (the stored password was accepted, Duo asked) and the dashboard showed
    // no reconnect banner and no Grade Watcher button — two bugs:
    // `confirmedDeadAfterRenewal(.needsDuo)` returning `current` instead of
    // `true` (covered in `CanvasSessionDeadStateTests`), and nothing latching
    // the silent path shut, which would have let `CanvasSessionRenewer`
    // resubmit the (correct!) password every `autoLoginCooldown` and push a
    // fresh, unattended Duo prompt on a loop. `noteRenewalOutcomeForTesting(_:)`
    // drives the exact same outcome-handling code
    // `performSilentCanvasRenewal()` runs after a real attempt — see that
    // seam's own doc comment for why `swift test` can't produce a genuine
    // `.needsDuo` end to end.

    @Test("a .needsDuo outcome latches autoLoginAwaitingDuo, confirms the session dead, but leaves the VISIBLE path armed")
    func needsDuoLatchesAwaitingDuo() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            #expect(state.canAutoLogin == true)
            #expect(state.canAutoLoginSilently == true)
            #expect(state.autoLoginAwaitingDuo == false)

            state.noteRenewalOutcomeForTesting(.needsDuo)

            // The silent path stands down...
            #expect(state.autoLoginAwaitingDuo == true)
            #expect(state.canAutoLoginSilently == false)
            // ...but the visible pane (the student tapping the banner
            // themselves) stays fully armed — `canAutoLogin` is unaffected.
            #expect(state.canAutoLogin == true)
            // And the reconnect banner/Grade Watcher availability signal
            // actually fires — this is the other half of the real-device bug.
            #expect(state.canvasSessionExpired == true)
        }
    }

    @Test("autoLoginAwaitingDuo persists across a relaunch")
    func awaitingDuoPersists() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteRenewalOutcomeForTesting(.needsDuo)
            #expect(state.autoLoginAwaitingDuo == true)

            let relaunched = AppState()
            #expect(relaunched.autoLoginAwaitingDuo == true)
            #expect(relaunched.canAutoLogin == true)
            #expect(relaunched.canAutoLoginSilently == false)
        }
    }

    @Test("noteCanvasLoginSessionCaptured clears the awaiting-Duo latch — a real login just answered it")
    func realLoginClearsAwaitingDuo() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteRenewalOutcomeForTesting(.needsDuo)
            #expect(state.canAutoLoginSilently == false)

            state.noteCanvasLoginSessionCaptured()

            #expect(state.autoLoginAwaitingDuo == false)
            #expect(state.canAutoLogin == true)
            #expect(state.canAutoLoginSilently == true)
        }
    }

    @Test("enableStayLoggedIn clears a stale awaiting-Duo latch")
    func enableStayLoggedInClearsAwaitingDuo() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteRenewalOutcomeForTesting(.needsDuo)
            #expect(state.autoLoginAwaitingDuo == true)

            state.enableStayLoggedIn(username: "student", password: "hunter2")

            #expect(state.autoLoginAwaitingDuo == false)
            #expect(state.canAutoLoginSilently == true)
        }
    }

    @Test("disableStayLoggedIn clears the awaiting-Duo latch along with everything else")
    func disableStayLoggedInClearsAwaitingDuo() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteRenewalOutcomeForTesting(.needsDuo)
            #expect(state.autoLoginAwaitingDuo == true)

            state.disableStayLoggedIn()

            #expect(state.autoLoginAwaitingDuo == false)
            #expect(state.canAutoLogin == false)
            #expect(state.canAutoLoginSilently == false)
        }
    }

    @Test("a .renewed outcome does not clear an existing awaiting-Duo latch")
    func renewedDoesNotClearAwaitingDuo() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteRenewalOutcomeForTesting(.needsDuo)
            #expect(state.autoLoginAwaitingDuo == true)

            state.noteRenewalOutcomeForTesting(.renewed)

            // A plain cookie-only renewal proves the Canvas session is
            // alive, not that Duo has been answered — see
            // `applyRenewalOutcome`'s doc comment.
            #expect(state.autoLoginAwaitingDuo == true)
            #expect(state.canAutoLoginSilently == false)
        }
    }

    @Test("stayLoggedInDiagnosticDescription reports the awaiting-Duo state, never a rejection it doesn't have")
    func diagnosticDescriptionReportsAwaitingDuo() {
        withCleanFlags {
            let state = AppState()
            state.enableStayLoggedIn(username: "student", password: "hunter2")
            state.noteRenewalOutcomeForTesting(.needsDuo)
            #expect(state.stayLoggedInDiagnosticDescription == "on (awaiting duo)")
        }
    }
}

// NOTE on `LoginNavigationObserver` attempt-counting coverage: the brief for
// this task asked for it "if it can be driven without a real WKWebView."
// `attemptAutoLoginIfNeeded(_ webView: WKWebView)` is `private` (reachable
// from this file via `@testable import`) but it reads `webView.url`, which
// is a read-only property WebKit itself sets only via a real navigation —
// there is no way to fabricate "this WKWebView just finished loading a
// specific URL" without an actual navigation, and `swift test` has no
// window server / network path to Penn's IdP to drive one (the same
// limitation `CanvasSessionRenewerTests`' own header comment documents for
// `CanvasSessionRenewer`'s WebView orchestration). The one-submission-per-
// script-invocation half of the "never resubmit" guarantee IS covered,
// pure and WebView-free, by `PennKeyLoginFormTests` (`window.__lhfAutoLogin`
// in the generated script, and `outcome(from:)`'s mapping); the
// Swift-side attempt counter (`autoLoginAttempts` reaching 1, then the
// second sighting reporting `.rejected` and never a third submission) is
// left to device verification, same as the rest of this class's WebView
// plumbing.
