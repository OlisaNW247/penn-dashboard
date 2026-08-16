# Canvas Login Hardening — Decision Record

Status: **implemented** (Groups 1–3; Group 4 skipped, see below).
Scope: `v2.5` (shipped App Store build / active dev branch, per
docs/CANVAS_LOGIN_DIAGNOSIS.md §0).

This is the fix pass following docs/CANVAS_LOGIN_DIAGNOSIS.md's diagnosis of
the Shibboleth "Stale Request" bug. That document's root-cause ranking (H1/H2:
a dead Canvas/Penn-SSO session cookie resident in the shared, persistent
`WKWebsiteDataStore.default()`) had already been partly addressed by three
commits on this branch before this pass started (`018148a`, `726a0bf`,
`385cdc2`, `0590585` — cookie expiry tracking, a "Reset login data" escape
hatch, and a pre-login purge). This pass hardens what was still missing and
fixes bugs introduced or left over by that earlier work.

## What actually shipped, by group

### Group 1 — login pane hardening

**1a. Disabled back/forward swipe on login WebViews; added explicit Reload /
Start over controls.**
`allowsBackForwardNavigationGestures` is now `false` on both the Canvas and
Gradescope login WebViews (`makeWebView`, `OnboardingView.swift`). A
full-bleed login pane has no chrome, so a swipe-back onto an
already-consumed login form — resubmitting it — is indistinguishable from a
real tap and produces exactly Shibboleth's "Stale Request," with no way
forward. Both `CanvasLoginPane` and `GradescopeLoginPane` now show explicit
**Reload** (reloads the current page) and **Start over** (re-purges this
login's cookies/cache and loads a fresh sign-in page, in place) controls in
the action bar.

**1b. Fixed the purge needle list — it was matching nothing for two of its
four entries.**
`WKWebsiteDataStore.fetchDataRecords` reports `displayName` as the eTLD+1
(registrable domain), not the full host: a cookie on `canvas.upenn.edu` or
`idp.pennkey.upenn.edu` both report `displayName == "upenn.edu"`. The old
needle list (`["canvas", "upenn", "pennkey", "duosecurity"]`) had two
needles — `"canvas"` and `"pennkey"` — that could never match any real
record. `AppState.canvasLoginDomainHints` is now `["upenn", "duosecurity",
"instructure"]`: drops the dead needles, adds `"instructure"` for
Instructure-hosted Canvas SaaS domains. Pinned down in
`CanvasLoginHardeningTests.canvasLoginDomainHintsMatchRealDisplayNames` /
`oldDeadNeedlesDontMatchRealDisplayNames`.

**1c. Moved the pre-login purge out of `makeWebView` into the pane's
`.task`, gated on WebView creation.**
Previously, `makeWebView` created the `WKWebView` synchronously and fired an
async `Task` that purged then loaded — so the WebView object existed (and
theoretically could receive navigation) while the purge was still in flight.
Now each pane (`CanvasLoginPane`/`GradescopeLoginPane`) runs the purge in a
`.task(id: purgeGeneration)` *before* the WebView is created at all — an
`isPurging` flag gates which view renders. This guarantees the purge fully
completes before the first request goes out, and — via the `.task(id:)`
re-run semantics — fires exactly once per Connect tap or "Start over" tap,
never re-entrant with an in-flight login navigation.

**1d. Added a genuine Mobile Safari user agent.**
New `LoginUserAgent.mobileSafari` (centralized, one file) constructs a UA
string matching the running device/iOS version's actual Mobile Safari UA at
runtime — `WKWebView`'s default UA omits Safari's own `Version/x.y …
Safari/604.1` tokens, which is exactly the kind of thing SSO/bot-protection
fingerprinting can key on. Applied via `webView.customUserAgent` in
`makeWebView`.

### Group 2 — session integrity

**2a. Per-service, persistent, isolated `WKWebsiteDataStore`s.**
New `LoginDataStores.swift` vends `LoginDataStores.canvas` /
`.gradescope` — each a `WKWebsiteDataStore(forIdentifier:)` instance, one
`static let` per service, so the WebView's `WKWebViewConfiguration` and the
pane's post-login cookie capture always read the exact same store instance
(the documented failure mode: reading the wrong store returns an empty
cookie list and "No session was found yet"). Deliberately NOT
`.nonPersistent()` — an ephemeral store is the worst input to WebKit's ITP
classifier and would force a full Duo re-prompt on every Connect tap.
`WebsiteDataReset` and `AppState.disconnectCanvas`/`disconnectGradescope`
were updated to purge the correct isolated store instead of `.default()`.

**2b. Stopped reinjecting persisted cookies into the live login store.**
`AutoSyncCoordinator.canvasCookies()` / `gradescopeCookies()` used to write
the Keychain-persisted cookie set back into the WebView's cookie jar ("keep
the login warm"). That serves no purpose for the actual HTTP fetches (every
client attaches an explicit `Cookie` header — see 2c) and is exactly the
mechanism that can poison a fresh login attempt with a dead cookie. The
reinjection lines were removed; the functions now only *read* from the
isolated login stores.

> **Deviation from the brief, logged for the record:** the brief described
> this function as having "ZERO consumers" and suggested deleting it
> entirely. That was true of an earlier snapshot of this branch, but by the
> time this pass ran, `canvasCookies()`/`gradescopeCookies()` had real
> consumers — `AutoSyncCoordinator.refreshCanvasGrades` (driving automatic
> submission detection, which stays active even with Grade Watcher's UI
> hidden — see `FeatureFlags.swift`) and `GradeWatcherView.performRefresh`.
> Deleting the functions outright would have broken both. The narrower fix
> (stop the reinjection, keep the read path) achieves the stated goal — the
> login store can no longer be poisoned by this code — without regressing
> either caller.

**2c. `httpShouldHandleCookies = false` everywhere an explicit `Cookie`
header is also set.**
`CanvasDiscoveryClient`, `CanvasGradesClient`, and `GradescopeClient` all
attach the session cookie as an explicit header while also leaving
`httpShouldHandleCookies = true` — undefined behavior (`HTTPCookieStorage.shared`
can overwrite/duplicate the header). All three now set it to `false`.

**2d. `HTTPCookieStorage.shared` is now included in a full reset.**
`WebsiteDataReset.purgeAllLoginStores()` sweeps the legacy `.default()`
store, both isolated per-service stores, *and* `HTTPCookieStorage.shared` — a
separate, non-WebKit cookie jar `URLSession` can also read from, previously
never cleared by anything. Wired into `AppState.resetAllLoginData()`.

**2e. Cookies are now keyed by service, not by domain substring.**
`SessionCookieStore` used to store every persisted cookie in one Keychain
blob and filter by `domain.contains(needle)` on read/remove. Since Canvas
and a Gradescope-via-PennKey login can both leave cookies on
`upenn.edu`/`pennkey.upenn.edu`, a Canvas-scoped
`remove(domainContains: "upenn")` could delete Gradescope's PennKey session
too. `SessionCookieStore` is now keyed by an explicit `Service` enum
(`.canvas` / `.gradescope`), stored under **separate Keychain items** — a
purge/disconnect of one service is structurally incapable of touching the
other's cookies, regardless of what domain they're on. `AppState`,
`AutoSyncCoordinator`, `GradeWatcherStore`, and `GradeWatcherView` were all
updated to the new `save(_:service:)` / `load(service:)` / `remove(service:)`
API. Existing on-device data under the old single-blob key is not migrated —
see "Migration / user impact" below.

### Group 3 — never trap the user again

**3a. Observe-only `WKNavigationDelegate`.**
New `LoginNavigationObserver` (`LoginNavigationObserver.swift`) — assigned as
`webView.navigationDelegate` in `makeWebView`. Strictly observe-only: every
`decidePolicyFor` call unconditionally `.allow`s; there is no `.cancel`, no
URL rewriting, and no auto-purge-and-retry (a false-positive "known error
page" detection auto-purging mid-flow would burn a second `SAMLRequest` and
could make the bug worse). It provides:
- A plain-language `loadError` on `didFailProvisionalNavigation`/`didFail`
  (offline, DNS failure, timeout), shown in the action bar instead of a
  blank box.
- An in-memory redirect log (`LoginRedirectLogEntry`: host + path + HTTP
  status **only** — no query string, no cookie value, no token), capped at
  30 entries, also mirrored into a process-lifetime `LoginDiagnosticsLog`
  singleton so Settings' diagnostics report (3e) can read it after the
  login pane closes.
- Known-IdP-error-page detection: `didFinish` reads `document.title` via
  `evaluateJavaScript` and checks it against a short list of Shibboleth/IdP
  error markers ("stale request", "session has expired", …). On a match, the
  pane swaps the WebView for a plain-language `LoginErrorCard` with
  **Start over** and (Canvas only) **Use calendar link instead** buttons —
  both user-initiated, no automatic action.

**3b. "Paste your Canvas calendar link" as a first-class path.**
New `PasteFeedLinkSheet` — reachable from onboarding (a low-emphasis link
under the step list) and from Settings → Account (when Canvas isn't
connected). Accepts `webcal://` and rewrites it to `https://`
(`AppState.rewritingWebcalScheme`, tested in
`CanvasLoginHardeningTests`) since Canvas's own "copy calendar feed" button
hands out a `webcal://` link that `URLSession` can't fetch directly.
`AppState.updateCanvasICSURL`/`sync()` already supported a manually-set feed
URL; this just gives it a UI. Copy is explicit about scope: connects the
assignment/deadline dashboard only, not submission status
(`CanvasICSClient` hardcodes `submitted: false`) or Grade Watcher
(feature-flagged off, and cookie-authed regardless).

**3c. ICS feed URL moved from UserDefaults to Keychain.**
New `ICSFeedURLStore` — the feed URL is itself a bearer credential (a
per-user token embedded in the URL; anyone with the link can fetch that
student's assignments with no further auth), so it belongs in the Keychain
like `SessionCookieStore`'s cookies, not unencrypted UserDefaults.
`AppState.init`/`updateCanvasICSURL` were switched over.
`ICSFeedURLStore.load()` performs a one-time, transparent migration from the
old UserDefaults key on first read (see "Migration" below) — existing
connected users are not signed out by this change. Excluded from the
diagnostics report (3e) and from the redirect log (3a) by construction —
neither ever handles the feed URL's value, only host/path/status of the
*login* pane's own requests.

**3d. `canvasSessionExpired`, distinct from `isCanvasConnected`.**
New `AppState.canvasSessionExpired` (published, read-only), derived from
`SessionCookieStore.isExpired(service: .canvas)` — true only when a Canvas
cookie session was captured at some point and every persisted entry has
since aged out, as opposed to never having had one. Recomputed on launch,
after connect/disconnect, and on the dashboard's periodic refresh
(`ContentView.refresh()`). Deliberately orthogonal to `isCanvasConnected`
(`!canvasICSURL.isEmpty`): a feed-only (paste-link) user, or one whose feed
is still syncing fine, is never nagged — they never captured a cookie
session for it to expire. When true, `ContentView` shows a low-key
"Your Canvas login needs a refresh" banner linking to reconnect.

**3e. Copyable diagnostics report.**
New `DiagnosticsReport.generate(state:)`, exposed via a "Copy diagnostics
report" button in Settings → Troubleshooting. Includes: app version, device
model, OS version, each service's connected/expired state, a best-effort
"which connect path was used" for Canvas (in-app login vs. pasted link vs.
not connected, inferred from local `SessionCookieStore` state only — no
network call), and the redirect log from 3a (host/path/status only). Never
includes credentials, cookie values, or the ICS feed URL/token.

### Group 4 — skipped

**4. Deriving `baseURL` from the pasted feed's host** (multi-institution
support in `CanvasDiscoveryClient`/`CanvasGradesClient`) was **not**
implemented in this pass. It's explicitly lowest-priority in the brief
("only if low-risk"), and this pass ran out of allotted effort after Groups
1–3. Both clients still hardcode `https://canvas.upenn.edu`. Tracked here as
the next thing to pick up, not forgotten.

## Migration / user impact

Two Keychain-shaped changes in this pass are NOT backward-compatible with
data written by earlier builds, and existing connected users will see the
following **one-time** effects after updating:

- **Group 2e (service-keyed cookies):** the old single-blob
  `SessionCookieStore` (Keychain service
  `com.lhf.lowhangingfruit.session`) is not read by the new
  per-service-keyed storage (`com.lhf.lowhangingfruit.session.canvas` /
  `.gradescope`). A user who was mid-session (cookie-based login, not
  feed-only) at update time will see `canvasSessionExpired` /
  Gradescope's "reconnect" state the next time a cookie-authed fetch runs,
  and will need to log in again via the WebView. Their Canvas **calendar
  feed** (the dashboard's actual data source) is unaffected — see next
  point.
- **Group 3c (ICS feed URL → Keychain):** explicitly migrated, not a
  regression — `ICSFeedURLStore.load()` reads the old UserDefaults key on
  first launch after update and copies it into the Keychain transparently.
  The dashboard keeps working with zero user action.

Net effect: after this update ships, a previously-connected user's
**dashboard** (the ICS feed) keeps working uninterrupted; their **cookie
session** (submission-status auto-detection, Canvas Scan, Grade Watcher if
re-enabled) will silently degrade to "needs reconnect" once, surfaced by the
3d banner, self-resolved by tapping it and logging in again.

## VERIFY — what was actually run

- **`swift build`** (library + `LowHangingFruitUI` target): **green**, no
  warnings, after every group's changes.
- **`swift build --build-tests`** (compiles the test target without
  executing): **green** — confirms every new/edited test file (see below)
  type-checks against the changed APIs.
- **`xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit
  -destination 'generic/platform=iOS Simulator' build`**: **BUILD
  SUCCEEDED**, run twice (after Group 1/2, and again after Group 3) against
  the full app target (app + widget extension), confirming the whole thing
  links and packages, not just the Swift package in isolation.
- **`swift test` (actually executing the suite): could not be run in this
  environment.** Every attempt — the original 194-test baseline, a
  `--skip SessionCookieStoreTests` run, and an isolated single-suite
  `--filter AssignmentDeduplicatorTests` run, including one with the
  sandbox explicitly disabled — hung indefinitely with 0% CPU
  (`swiftpm-testing-helper`/`swift-test` stuck in an uninterruptible sleep,
  not making progress). This reproduces identically on a completely
  untouched pre-existing test (`AssignmentDeduplicatorTests`, not edited in
  this pass), so it's an environment limitation of this sandboxed shell
  (most likely `swift test`'s XCTest-bundle-launch IPC requiring a session
  type this shell doesn't have), not a regression introduced here.
  **Compensating verification used instead:** `swift build --build-tests`
  (type-checks all tests) + manual trace of every new test's logic + the two
  full `xcodebuild` app-target builds above. This should be re-run as
  `swift test` in a normal Xcode/Terminal session before merging to confirm
  the actual pass/fail baseline — I was not able to do that from here.

### Tests added

- `CanvasLoginHardeningTests.swift` (new): purge-needle-matches-real-`displayName`
  regression tests (1b, and a companion test documenting why the old
  needles were dead), `webcal://` rewriting (3b, 4 cases), and
  `SessionCookieStore.isExpired(service:)` (3d, 3 cases: never-connected,
  all-stale, still-live).
- `SessionCookieStoreTests.swift` (rewritten for the new service-keyed API,
  2e): all existing cases ported to `service:`-qualified calls, plus new
  cases for cross-service isolation (`servicesAreIsolated`,
  `removeIsScopedToServiceNotDomain` — the exact Penn-SSO-shared-domain
  scenario 2e exists to fix) and `loadAll()`.

## Post-ship fix: cross-suite Keychain test race (2026-08-16)

`swift test` could finally be run for real (in a normal, non-sandboxed shell —
see the "could not be run in this environment" note above, which was an
artifact of that earlier sandboxed session, not a real environment limit) and
turned up 2 failures, both in this document's item 2e/3d work:

- `SessionCookieStoreTests.swift:49` — a cookie saved with a future
  `expiresDate` sometimes didn't come back from `load(service: .canvas)`.
- `CanvasLoginHardeningTests.swift:95` — `SessionCookieStore.isExpired(service:
  .canvas)` sometimes reported `true` while a live, non-expired cookie was on
  record.

**Root cause: a test-isolation race, not a cookie-serialization bug.**
`SessionCookieStore` is process-wide Keychain state — one Keychain item per
`Service`, read via `SecItemCopyMatching` and written via a non-atomic
`SecItemDelete` + `SecItemAdd` pair in `write()` (Keychain has no upsert).
`SessionCookieStoreTests` already knew this and is marked `@Suite(...,
.serialized)` specifically so its own `.canvas`/`.gradescope` tests never run
concurrently with each other. But item 3d's `isExpired(service:)` tests were
added to a *different*, unserialized suite — `CanvasLoginHardeningTests` —
that also calls `SessionCookieStore.save`/`.clear`/`.isExpired` for
`.canvas`. Swift Testing parallelizes by default both within an unserialized
suite and across suites, so `CanvasLoginHardeningTests`' `.canvas` tests ran
concurrently with (a) each other and (b) `SessionCookieStoreTests`' `.canvas`
tests, all hammering the exact same Keychain item
(`com.lhf.lowhangingfruit.session.canvas`). A `clear()` (or the delete half
of a concurrent `write()`) landing between another thread's `save()` and its
subsequent `load()`/`isExpired()` check silently dropped that thread's write
— reproduced deterministically by running `CanvasLoginHardeningTests` alone
repeatedly (`swift test --filter CanvasLoginHardeningTests`), which failed on
its own with no other suite involved. Cookies *without* a server expiry
happened to survive more often only because of which races landed in which
timing windows, not because of anything specific to `expiresDate` encoding —
confirmed by a standalone reproduction of the full `HTTPCookie` →
`[String: String]` → `HTTPCookie(properties:)` round trip, which round-trips
`expires` correctly every time in isolation, and by `swift test --filter
SessionCookieStoreTests` alone passing 100% (including the future-expiry
case) before any fix.

**Fix:** moved the three `isExpired(service:)` tests from
`CanvasLoginHardeningTests` (unserialized) into `SessionCookieStoreTests`
(`.serialized`, and already the suite that owns this shared Keychain
resource) — see `SessionCookieStoreTests.swift`'s "Group 3d" section.
`CanvasLoginHardeningTests.swift` keeps a comment pointing to the new
location and explaining why. No production code changed for this part; the
bug was in test placement, not in `SessionCookieStore` itself.

**Round-trip attribute audit.** Per the "if `expires` was lost, others may be
too" concern, audited `SessionCookieStore.dict(from:)` /
`SessionCookieStore.cookie(from:)` (`Sources/LowHangingFruitUI/SessionCookieStore.swift`)
for every cookie attribute that matters for replaying a session. `secure`
and `expiresDate` were already round-tripped correctly. `isHTTPOnly` and
`sameSitePolicy` were **not** captured at all — every persisted cookie
silently lost those two attributes on every save, unconditionally (a real,
separate, pre-existing gap, unrelated to the race above). This wasn't
breaking session replay in practice, because cookies are replayed manually
via `HTTPCookie.requestHeaderFields(with:)` (name=value pairs only, per this
file's own header comment) rather than through `HTTPCookieStorage`/WebKit,
where `HttpOnly`/`SameSite` would matter. Still fixed for full fidelity and
to close off future uses of these persisted cookies that would care:
`dict(from:)` now also stores `httpOnly` (`"1"`/`"0"`) and `sameSite` (the
raw `HTTPCookieStringPolicy` string) when present, and `cookie(from:)`
restores both via `HTTPCookiePropertyKey("HttpOnly")` and `.sameSitePolicy`.
`domain`/`path`/`name`/`value` were already round-tripped correctly and
covered by existing tests.

New regression test: `SessionCookieStoreTests.fullFidelityRoundTrip` builds a
realistic Canvas-like cookie (name, value, domain, path, `secure`,
`httpOnly`, `sameSite=Lax`, a future `expiresDate`) via the real
`HTTPCookieStringPolicy` API, saves/loads it through the real Keychain path,
and asserts every one of those attributes survives — not just that the
cookie's name is still present, which is all the pre-existing tests checked.

**Verified:** `cd LowHangingFruitKit && swift test` — 206 tests (205 + the
new full-fidelity test), 0 failures, run 5 times back-to-back to confirm the
race is actually gone rather than just timing-lucky.
`xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit
-destination 'generic/platform=iOS Simulator' build` — `BUILD SUCCEEDED`.

## App Store review considerations

- **In-app third-party credential collection.** Unchanged from before this
  pass: the app still presents Canvas's and Gradescope's own login pages
  inside a `WKWebView` (never a custom-built login form), and never sees
  passwords — this is the same posture Apple's guidelines expect for
  "log into your school/work account" flows. The new paste-link fallback
  (3b) actually *reduces* how often a reviewer or user needs to pass through
  third-party SSO at all.
- **Privacy policy coverage for diagnostics.** `docs/PRIVACY.md` was updated
  in this pass to disclose the diagnostics report (3e) and the paste-link
  fallback (3b). The diagnostics report is user-initiated, copies to the
  system clipboard only, and the app never transmits it anywhere itself —
  worth restating in review notes if asked, since "diagnostics"/"logging"
  language can otherwise read as telemetry.
- **Preview/demo mode.** Untouched by this pass — `enterPreviewMode()`
  remains the reviewer path that needs no Canvas/Gradescope account at all,
  and none of Groups 1–3 change its behavior.
- **Keychain migration (see above).** Not a review blocker, but worth a
  release note: existing TestFlight/App Store users will see one reconnect
  prompt for the cookie-session side of Canvas after updating.

## How to confirm this on a real iPhone

1. Update to this build (or run from Xcode onto a device/simulator signed in
   as yourself).
2. **Group 1 check (the original bug):** Settings → Account → Disconnect
   Canvas if currently connected, then Connect Canvas from onboarding or
   Settings. Log in normally. This should no longer produce "Stale Request"
   on a fresh attempt. To specifically exercise 1a: mid-login, swipe from
   the left edge — it should NOT navigate back (gesture is disabled); use
   the **Reload** or **Start over** buttons in the action bar instead.
3. **Group 2 check:** Connect both Canvas and Gradescope (if you have both).
   Disconnect Canvas only (Settings → Account). Confirm Gradescope stays
   connected and its next sync still works — this is the isolated-store /
   service-keyed-cookie fix (2a/2e) actually holding.
4. **Group 3 check:**
   - Onboarding → "Or paste your Canvas calendar link instead" (or Settings
     → Account → "Paste calendar link instead" if Canvas isn't connected):
     paste your feed link from Canvas → Calendar → Calendar Feed (a
     `webcal://` link is fine) and confirm the dashboard populates with no
     login at all.
   - Settings → Troubleshooting → "Copy diagnostics report", then paste
     into Notes — confirm it contains device/version info and no
     credentials/links/cookies.
   - If a Canvas cookie session goes stale (most users won't hit this
     immediately after a fresh login), confirm the "Your Canvas login needs
     a refresh" banner appears on the dashboard and disappears after
     reconnecting.
