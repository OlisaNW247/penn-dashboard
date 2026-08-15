# Canvas Login "Stale Request" — Diagnosis

Status: **diagnosis only, no fix implemented.**
Scope: shipped App Store build (`v2.5` tag/branch) and whether the same bug is
present on the current working branch.

## 0. Branch situation

`~/lhf-app` is currently checked out on `v2.5`, which **is** the tip of active
development (latest commit 2026‑08‑11, "New app icon") — per project memory,
`v2.5` is simultaneously the shipped App Store build *and* the current working
branch. `git status` shows only two unrelated local diffs (`LHFWidget/Info.plist`,
`project.pbxproj` — Xcode build-system churn, not app logic). `main`
(2026‑06‑23) and `V2` (2026‑07‑19) are older/earlier snapshots, not the active
branch. **There is no divergence to reconcile: the code analyzed below is both
what shipped and what's running today.** See §6 for what this means for a fix.

## 1. The Canvas connect flow, as it exists in code

**Start URL (checklist item 1).** `CanvasLoginPane` loads the plain Canvas SP
resource, not a hardcoded IdP/SAML URL:

```
LowHangingFruitKit/Sources/LowHangingFruitUI/OnboardingView.swift:349
    LoginWebView(url: URL(string: "https://canvas.upenn.edu")!)
```

No `idp`, `SAMLRequest`, `execution=`, `conversation=`, or saved query string
anywhere in the app's source for this URL. **This rules out a hardcoded/stale
IdP URL as the cause** — confirmed further in §4 by fetching that URL live
just now (2026‑08‑15) and observing a clean, fresh 302 chain:
`https://canvas.upenn.edu/` → `https://canvas.upenn.edu/login/saml` →
`https://idp.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO?SAMLRequest=...`
— a brand-new `SAMLRequest` generated on the spot. Penn's SSO is healthy for a
cookie-less request right now.

**Persistence (checklist item 2).** The WebView is built with the **default,
shared, persistent** data store — not `.nonPersistent()`, and not a fresh
instance per presentation:

```
LowHangingFruitKit/Sources/LowHangingFruitUI/OnboardingView.swift:540-548
@MainActor
private func makeWebView(url: URL) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.load(URLRequest(url: url))
    return webView
}
```

Every presentation of `CanvasLoginPane` (and `GradescopeLoginPane`) creates a
*new* `WKWebView`, but all of them share the *same* `WKWebsiteDataStore.default()`
cookie jar, app‑wide, for the lifetime of the process. **A codebase-wide search
found zero calls to `removeData`, `deleteCookie`, or any `WKWebsiteDataStore`
reset** — the live cookie jar is never cleared by anything, ever:

```
$ grep -rn "removeData\|deleteCookie" --include="*.swift" .
(no matches)
```

**Navigation interception (item 3).** No `WKNavigationDelegate` or
`WKUIDelegate` is ever assigned to the WebView (`makeWebView` above sets
neither `.navigationDelegate` nor `.uiDelegate`). There is no
`decidePolicyFor`, no `.cancel`/re-`load()`, no URL rewriting anywhere in the
codebase (confirmed by grep across all `.swift` files). **This rules out
URL-rewriting/redirect-stripping as a cause.**

**New windows / multi-webview (item 4).** No `createWebViewWith` handling
exists (no `uiDelegate` at all, see above) — a `target=_blank` popup (e.g. a
Duo 2FA popup, if Penn ever uses one) would silently be swallowed by WebKit's
default behavior. Only one `WKWebView` is ever in play for a given login pane;
no `ASWebAuthenticationSession`/`SFSafariViewController` anywhere in the repo.
This is a real secondary risk (see H4) but doesn't match the specific "Stale
Request" text, which is a *session-state* rejection, not a broken-popup
symptom.

**State restoration (item 5).** No saved/replayed login-form URL. The webview
always loads the fixed literal `https://canvas.upenn.edu` (or
`https://www.gradescope.com/login`) on every presentation
(`OnboardingView.swift:349`, `:407`). What *is* replayed on every
presentation, however, is **cookie state** (see §2) — which is the actual
mechanism behind "5 times in a row, identical."

**User agent / headers / cache (item 6).** `URLRequest(url: url)` uses the
default `.useProtocolCachePolicy`; no custom UA or headers are set anywhere.
Minor, secondary factor at most (see H4 below) — not the primary cause.

**Cookie handling — the actual smoking gun.** See §2.

## 2. The cookie-carryover mechanism (root cause candidate)

Three pieces of code interact to keep a **dead Canvas/Penn-SSO session cookie
alive in the shared `WKWebsiteDataStore.default()` indefinitely**, and to feed
it back to a freshly-opened login WebView:

1. **Nothing purges the live cookie jar on disconnect.**
   ```
   LowHangingFruitKit/Sources/LowHangingFruitUI/AppState.swift:275-284
   func disconnectCanvas() {
       SessionCookieStore.remove(domainContains: "canvas")   // Keychain only
       SessionCookieStore.remove(domainContains: "upenn")    // Keychain only
       updateCanvasICSURL("")
       canvasCourseIDsByCode = [:]
       ...
   }
   ```
   This purges the **Keychain-persisted** copy of the cookie
   (`SessionCookieStore`), but never touches `WKWebsiteDataStore.default()`
   itself. If the Canvas Shibboleth SP session cookie set into the WebView's
   live cookie jar during the *original* successful login is still sitting
   there (it is — nothing evicts it), it survives disconnect/reconnect for the
   rest of the app's process lifetime.

2. **Persisted cookies have no expiry and are replayed forever.**
   ```
   LowHangingFruitKit/Sources/LowHangingFruitUI/SessionCookieStore.swift:84-92
   private static func dict(from cookie: HTTPCookie) -> [String: String] {
       [
           "name": cookie.name, "value": cookie.value,
           "domain": cookie.domain, "path": cookie.path,
           "secure": cookie.isSecure ? "1" : "0",
       ]   // <-- no expiresDate captured, ever
   }
   ```
   Cookies persisted to Keychain at connect time
   (`OnboardingView.swift:371-377`, `connect()`) carry no expiry information,
   so there is no client-side way to know the underlying Penn/Canvas session
   has died server-side. They get reconstructed and replayed as live session
   cookies (`HTTPCookie(properties:)`, `:94-104`) with no staleness check.

3. **The persisted (possibly dead) cookie is auto-reinjected into the same
   live `WKWebsiteDataStore.default()` that the login WebView will read from**
   — automatically, on launch, on activation, and every 5 minutes:
   ```
   LowHangingFruitKit/Sources/LowHangingFruitUI/AutoSyncCoordinator.swift:76-86
   static func canvasCookies() async -> [HTTPCookie] {
       ...
       let persisted = SessionCookieStore.load()
       let cookieStore = WKWebsiteDataStore.default().httpCookieStore
       for cookie in persisted { await cookieStore.setCookie(cookie) }   // <-- unconditional
       ...
   }
   ```
   Called from:
   ```
   LowHangingFruitKit/Sources/LowHangingFruitUI/ContentView.swift:221-230
   /// Runs on launch, on activation, and on the 5-minute loop...
   private func refresh() async {
       await state.syncIfConfigured()
       await AutoSyncCoordinator.syncConnectedServices(state: state)
       await AutoSyncCoordinator.refreshCanvasGrades(state: state)   // guarded by isCanvasConnected
       ...
   }
   ```
   `refreshCanvasGrades` is gated by `guard state.isCanvasConnected else { return }`
   (`AutoSyncCoordinator.swift:43`), but `FeatureFlags.swift:24` documents
   explicitly that **this still runs in the shipped 1.0/`v2.5` build even
   though Grade Watcher's UI is hidden** ("automatic submission detection...
   is derived from that same payload"). So the reinjection is live in
   production for any user who is (or recently was, within the same process)
   `isCanvasConnected == true`.

**Putting it together:** the first time a user logs into Canvas, the SP
(`canvas.upenn.edu`) drops a session cookie into `WKWebsiteDataStore.default()`.
That cookie is never actively cleared by the app — not on disconnect, not
between login attempts, not on a timer. It only stops being replayed if the
*app process itself* dies (WKWebView drops true session cookies on quit — but
the background loop re-seeds an equivalent value from Keychain on every
relaunch/activation anyway, per point 3). When the user reopens "Connect
Canvas," a brand-new `WKWebView` is created, but it's pointed at the same
poisoned data store (`websiteDataStore = .default()`), so it silently presents
the dead cookie to `canvas.upenn.edu` on the very first request. Canvas's SP,
seeing what looks like an existing session, tries to quietly resume/validate
it against Penn's IdP instead of starting a clean SP-initiated login — and
because that session/conversation is no longer valid server-side, the IdP
immediately returns **"Stale Request"** — Shibboleth's generic name for "this
doesn't correspond to any login flow I currently have open." This happens
before the user interacts with the page at all, and reproduces identically on
every subsequent attempt within the same app process, because the same dead
cookie is replayed every time. That matches all four observed characteristics
of the bug: immediate, on first load, identical text, 5/5 reproducible.

## 3. Ranked root-cause hypotheses

| # | Hypothesis | Likelihood |
|---|---|---|
| H1 | Dead Canvas/Penn-SSO session cookie resident in the shared, persistent `WKWebsiteDataStore.default()` (originally set by an earlier, now-expired login; never cleared by `disconnectCanvas()` or anything else) is replayed to `canvas.upenn.edu` on the very first request of a new login attempt, causing the SP to attempt a session resume that the IdP rejects as stale. | **60%** |
| H2 | Same mechanism as H1, but the cookie's staleness is *continuously refreshed* into the live store by the automatic background loop (`AutoSyncCoordinator.canvasCookies()`, running every 5 min / on launch / on activation while `isCanvasConnected`) replaying a Keychain-persisted, expiry-untracked cookie — so the poisoning can happen even without an explicit Disconnect step, purely from normal Penn SSO session timeout over time. | **25%** |
| H3 | New-window/popup swallow: if Penn's flow ever needs a JS popup (e.g. a Duo 2FA interstitial), `createWebViewWith` is unhandled (no `uiDelegate` set at all — `OnboardingView.swift:540-548`), so the popup navigation is silently dropped. This produces a *different* symptom (stuck/blank page) more than this exact error text, so it's a plausible contributor in some cases but unlikely to be *the* cause of the literal "Stale Request" screen. | **8%** |
| H4 | Minor amplifier only, not sufficient alone: `URLRequest(url:)` uses the default `.useProtocolCachePolicy` (`OnboardingView.swift:546`), so a cached redirect from a previous failed attempt could theoretically be replayed from WebKit's HTTP cache rather than hitting the network. Weak on its own — IdP SSO redirect responses are normally marked non-cacheable — but not ruled out from the code. | **7%** |

H1 + H2 are two framings of the same underlying defect (missing cookie
hygiene around the shared `WKWebsiteDataStore.default()`); together they
account for **85%** of the likelihood mass and point at the same fix.

### How to confirm H1/H2 definitively
- Cheapest: see §5.
- More rigorous (needs a debug build): add a one-line log of
  `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` right before
  `makeWebView(url:)` loads `https://canvas.upenn.edu` in `CanvasLoginPane`.
  If a `canvas.upenn.edu`-domain cookie (e.g. `_shibsession_...` or a Canvas
  session cookie) is already present *before* the page ever loads, H1/H2 is
  confirmed on the spot.

### Fix if confirmed (not implemented here)
Small, contained — not structural:
1. In `disconnectCanvas()` (`AppState.swift:275`), also purge the live
   WebKit cookie jar, not just Keychain — e.g.
   `WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
   cookies.filter { $0.domain contains "canvas"/"upenn"/"shib" }.forEach {
   cookieStore.delete($0) } }`.
2. Do the same defensively right before `makeWebView` loads a fresh login
   (belt-and-suspenders — guarantees every "Connect Canvas" tap starts from a
   clean SP session regardless of how it got dirty).
3. Optionally, track real expiry on persisted cookies in `SessionCookieStore`
   (currently dropped entirely, `SessionCookieStore.swift:84-92`) so dead
   cookies stop being reinjected by `AutoSyncCoordinator.canvasCookies()` once
   they're past their real lifetime.

## 4. Hypotheses that cannot be evaluated from code alone

- **Penn-side infrastructure change.** Checked live (2026‑08‑15,
  via `WebFetch https://canvas.upenn.edu/`): the SP→IdP redirect chain is
  healthy right now and produces a fresh `SAMLRequest` for a cookie-less
  request (`https://idp.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO?SAMLRequest=...`).
  This makes "Penn's login endpoint is just broken/moved" **unlikely** as a
  standalone explanation, but doesn't rule out a subtler change (e.g. shorter
  SP session lifetime, different Shibboleth `RelayState` handling, or
  Duo policy changes) that would only surface with a *stale cookie* present —
  which is exactly what H1/H2 describe anyway. To test directly: have someone
  with a real PennKey log into `https://canvas.upenn.edu` from plain **mobile
  Safari** (not the app) and confirm it succeeds cleanly.
- **Duo 2FA popup behavior specifically for this app's WKWebView config.**
  Can't be exercised without a live PennKey/Duo-enrolled account in front of
  the actual broken build.
- **Whether the *specific* dead cookie value in a given failing user's data
  store is a Shibboleth SP session cookie vs. a Canvas-native session
  cookie vs. something else** — code shows *a* cookie gets carried forward,
  but confirming exactly which cookie name/domain requires the on-device log
  described in §3.

## 5. Cheapest diagnostic to run right now

Two steps, cheapest first, that cleanly discriminate the top candidates:

1. **Log into `https://canvas.upenn.edu` in plain Safari on the same device**
   (not the app). If that succeeds cleanly, Penn's SSO is healthy right now
   and the bug is conclusively inside the app (H1–H4), not upstream (§4).
2. **Fully delete the LHF app and reinstall it** (not just force-quit —
   deleting wipes the app's container, including `WKWebsiteDataStore.default()`'s
   on-disk cookie DB), then go straight to "Connect Canvas" without doing
   anything else first.
   - **If this fixes it:** confirms H1 (a dead cookie already resident in the
     WebView's data store was the cause) — the *cleanest* possible
     confirmation, since it also happens to sidestep H2 (the reinjection path
     it relies on is gated behind `isCanvasConnected`, which resets to
     `false` on reinstall).
   - **If it still fails identically after a clean reinstall:** H1/H2 are
     ruled out; escalate to the Safari test in step 1 and to Penn IT/status
     channels.

## 6. Is this present in the current working branch too?

**Yes, unconditionally** — `v2.5` is both the shipped tag and the tip of
active development right now (§0); every file cited above (`OnboardingView.swift`,
`AutoSyncCoordinator.swift`, `AppState.swift`, `SessionCookieStore.swift`,
`ContentView.swift`, `FeatureFlags.swift`) is the exact code currently checked
out, with no uncommitted changes to any of them. There is no "shipped vs.
dev" divergence to reconcile for this bug — whatever fix lands will need to go
on `v2.5` directly (and, if `V2`/`main` are still maintained in parallel,
ported there too — `V2`'s `SessionCookieStore`/`AutoSyncCoordinator`, checked
in §... above, has the *same* missing-cookie-clear pattern, just via
UserDefaults instead of Keychain, so it's very likely equally affected).
