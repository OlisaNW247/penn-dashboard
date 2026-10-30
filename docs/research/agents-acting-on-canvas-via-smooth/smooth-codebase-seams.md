# Smooth codebase: Canvas sign-in storage, session upkeep, data held, backend, and seams for an external AI agent

Scope: code-reading of /Users/marcoopertti/penn-dashboard on branch `codex/simplify-canvas-onboarding`, dated 2026-10-30. HEAD is 56ccd01; the working tree has uncommitted edits (e.g. SessionCookieStore.swift +72 lines). "Source" links are repo-relative file paths (line numbers where I read them, otherwise the symbol name). No cookie values, feed URLs or user ids are copied. Paths below abbreviate `LowHangingFruitKit/Sources/` as `Sources/`.

Discrepancies between CLAUDE.md and the code are flagged inline with "CODE vs DOC".

---

## 1. Where Canvas session cookies live, accessibility class, the 24-hour rule, and whether they are synced or sent anywhere

### Takeaway
Canvas (and Gradescope) cookies are one JSON blob per service in the iOS/macOS Keychain, class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, with no access group, so they are private to the app process and never sync. A cookie with no server expiry is treated as dead 24 hours after it was last saved; the working tree (uncommitted) additionally fixes the analytics-cookie hole that CLAUDE.md still calls unfixed.

### Cited Findings
- Storage: generic-password Keychain item, service string `com.lhf.lowhangingfruit.session.<canvas|gradescope>`, account `sessionCookies`, value = JSON array of string dicts (name, value, domain, path, `capturedAt`, optional `expiresDate`, HttpOnly flag). — [Sources/LowHangingFruitUI/SessionCookieStore.swift](lines 29-32, 292-303, 312-345)
- Accessibility class is set at write: `query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, with the comment "Readable after first unlock so the launch-time auto-sync can replay the session; never migrated off this device." — [SessionCookieStore.swift](line 300)
- No `kSecAttrAccessGroup` appears anywhere under Sources/ (grep returned nothing), and the iOS entitlements contain only `application-groups` (`group.com.lhf.lowhangingfruit`), iCloud/CloudKit (`iCloud.com.lhf.lowhangingfruit`) and the ubiquity KV store identifier; no `keychain-access-groups`. So the Keychain items are in the app's default group; the widget extension (separate entitlements file with only the app group) cannot read them. — [App/LHFApp.entitlements](whole file), [LHFWidget/LHFWidget.entitlements]
- Canvas and Gradescope get separate Keychain items so a purge for one cannot touch the other. `clear()` deletes both; `remove(service:)` deletes one. — [SessionCookieStore.swift](lines 15-27, 221-230)
- Replay is by explicit `Cookie` header: `CanvasAuth.apply` sets `Authorization: Bearer` if a token exists, else `HTTPCookie.requestHeaderFields(with: cookies)`; clients set `httpShouldHandleCookies = false`. — [Sources/LowHangingFruitKit/Canvas/CanvasAccessToken.swift](lines 371-379), [Sources/LowHangingFruitKit/Canvas/CanvasGradesClient.swift](lines 175-182)
- The 24-hour rule: `sessionCookieMaxAge = 24*60*60`. In `load(service:)` a cookie with a real `expiresDate` is kept iff the expiry is in the future; a cookie with no expiry is kept iff `now - capturedAt < 24h`; a cookie with neither field is dropped. `capturedAt` is rewritten on every `save`/`merge`, so it is "time since last save", not "time since login". — [SessionCookieStore.swift](lines 59-70, 113-130, 213)
- `isExpired(service:)` = "something is persisted AND `load` returns nothing". This is what flips `AppState.canvasSessionExpired`, which triggers silent renewal and the "needs a refresh" banner. — [SessionCookieStore.swift](lines 204-206); [Sources/LowHangingFruitUI/AppState.swift](lines ~1748-1796; log line "canvasSessionExpired false -> true, triggering silent renewal" ~1794)
- CODE vs DOC (analytics-cookie hole): CLAUDE.md ("One analytics cookie switches the 24-hour rule off", Known gaps #1) says unfixed. The working tree adds `gatedOnLiveSession` (lines ~174-179) and `isCanvasSessionCookieName` (markers `canvas_session`, `_normandy_session`, line ~141): for Canvas, if a session-named cookie was ever persisted and none remains fresh, `load` returns `[]` even when `_ga`-type cookies are unexpired. This is uncommitted (git diff --stat shows SessionCookieStore.swift modified), unreleased, and the 3.0.0 (11) App Store build does not have it. ROADMAP.md Now item 1 still lists it as to-do. — [SessionCookieStore.swift](working tree); [CLAUDE.md](trap "One analytics cookie…"); [ROADMAP.md](lines 28-31)
- Never synced/sent: Keychain `ThisDeviceOnly`; the privacy policy says session cookies and the feed URL are "kept in the iOS Keychain, encrypted at rest, this-device-only"; PROTOCOL principle 1 says Canvas credentials never reach the server. The CloudKit/KV mirror covers only the SwiftData ledger (opt-in) and a fixed allowlist of preference keys. — [docs/PRIVACY.md](lines 16-34); [backend/PROTOCOL.md](line 8-9); [Sources/LowHangingFruitUI/CloudPrefsMirror.swift](header)
- Separate WebKit persistence: the visible login pane and the renewer use a persistent per-service `WKWebsiteDataStore(forIdentifier:)` (Canvas id `8F2D6A10-…01`, Gradescope `…02`). This store holds the IdP (PennKey) and Duo cookies that actually allow silent re-login; it is WebKit-managed and not in the Keychain. — [Sources/LowHangingFruitUI/LoginDataStores.swift](lines ~38-50)
- Other Keychain items next to the cookies, each own service string, all `AfterFirstUnlockThisDeviceOnly`: ICS feed URL (`com.lhf.lowhangingfruit.icsFeedURL`, a bearer credential), PennKey username+password JSON (`com.lhf.lowhangingfruit.pennkeyCredentials`), Canvas access token (`com.lhf.lowhangingfruit.canvasAccessToken`), and the Supabase refresh token per PROTOCOL. — [Sources/LowHangingFruitUI/ICSFeedURLStore.swift](lines 14-40), [PennKeyCredentialStore.swift](lines 46-60), [CanvasAccessTokenStore.swift](lines 47, 70)

### Inferences
- Any second process (an agent on the same device, a widget, a share extension) cannot read the cookies without a Keychain-sharing entitlement change, and even then the 24h clock is Smooth's own heuristic, not Canvas's.
- A cookie handed to a remote agent would have an unknown real server lifetime; Smooth itself does not know the true expiry and reconstructs it via the 24h guess plus 401 detection.

### Gaps
- Real Canvas server-side session lifetime at Penn is not measured anywhere in the repo ("a safety bound, not an attempt to model their real server-side timeout", SessionCookieStore.swift ~line 209-212).
- I did not run the uncommitted gate under test; its test file `Tests/LowHangingFruitKitTests/SessionCookieLiveSessionTests.swift` is untracked.

---

## 2. How CanvasSessionRenewer keeps the session alive; foreground-only vs background crash

### Takeaway
Renewal is a hidden `WKWebView` that loads the Canvas root in the persistent Canvas data store, walks Penn's SAML chain using live IdP/Duo cookies, and if needed fills the saved PennKey password once; it runs only while the app is open in practice, because every background wake crashes first. An agent that needs a valid session at an arbitrary time cannot rely on Smooth to have one.

### Cited Findings
- Mechanism: `@MainActor final class CanvasSessionRenewer`. One `webView.load(URLRequest)` per attempt plus, if the stored PennKey is available, at most one JS submission of the IdP credential form (`j_username`/`j_password`). It never touches the SAML response form returning to Canvas and uses its own `RenewalNavigationDelegate`, not `LoginNavigationObserver`'s. Read-only against the login data store (harvests via `httpCookieStore.getAllCookies`). — [Sources/LowHangingFruitUI/CanvasSessionRenewer.swift](class header comment, rules 1-6)
- Limits: `cooldown = 60*60` (one attempt per hour), `autoLoginCooldown = 6*60*60` (password resubmission), `timeout = 30` s hard cap; `gate(...)` refuses under test runner, while the visible login pane is active, while one is in flight, or inside the cooldown. There is no app-active / foreground check in `gate`. — [CanvasSessionRenewer.swift](`gate`, line ~339)
- Outcomes: `.renewed`, `.landedOnLoginPage`, `.timedOut`, `.abortedByLoginPane`, `.notAttempted`, `.needsDuo` (timed out while parked on Duo's host), `.passwordRejected` (disables auto-login permanently until the student updates it). — [CanvasSessionRenewer.swift](enum Outcome)
- Duo is a hard boundary: the stored credential reaches only the IdP password field; a Duo prompt needs the human. Duo's "remember this device" lasts about 30 days and each successful pass re-issues Duo's `browsertrust` cookie. — [CLAUDE.md](Stay signed in section); [docs/PRIVACY.md](lines 43-80)
- Triggers: `canvasSessionExpired` flipping true (the 24h rule), foreground/launch, and a Grade Watcher 401 (`gradeWatcher.isSessionExpired` -> `attemptSilentCanvasRenewal()`). If a bearer token was in use, a 401 clears the token instead of renewing. — [AppState.swift](lines ~1792-1796, ~3012-3022)
- Foreground verification: renewed in 8 s hands-free on Marco's and Olisa's phones on 2026-09-27; a background renewal has never happened on any phone. — [CLAUDE.md](Stay signed in "Verified on a device")
- Background crash: `LHFBackgroundRefresh.register()` is `@MainActor` and passes a closure to `BGTaskScheduler.register(... using: nil)`; the closure is nonisolated-looking in the comment but is lexically inside a `@MainActor` function. CLAUDE.md says Swift 6 checks that isolation at runtime so the app dies on entry (`_dispatch_assert_queue_fail`, `.ips` reports on Marco's phone 2026-09-24 to 09-27). The committed code at HEAD still has this shape (`handle(refreshTask)` called straight from the closure, lines ~49-55); the `Task { @MainActor in ... }` hop exists only inside `handle`. I did not run it; this matches CLAUDE.md and ROADMAP.md Now ("Fix the background-refresh crash, with a foreground-only re-login"), which is not done. — [Sources/LowHangingFruitUI/BackgroundRefresh.swift](lines 47-56, 86-110); [CLAUDE.md](background-refresh trap); [ROADMAP.md](lines 44-54)
- Fragility (CLAUDE.md Known gaps #2-3, read from code by the prior session, none fixed): a failed silent attempt (network error, 30 s cap, app left mid-attempt) is recorded as "confirmed dead" (`canvasSessionConfirmedDeadV1`, persisted) and raises the banner; cooldowns live in memory; tapping the banner opens the login pane whose pre-login purge includes `duosecurity`, deleting Duo's remembered device. — [CLAUDE.md](Known gaps); [AppState.swift](lines ~545, ~573, ~1365-1373)
- Foreground refresh cadence: 5-minute loop while open; Canvas grades throttled to 15 minutes (`canvasGradesMinInterval`), Gradescope to 15 minutes. — [Sources/LowHangingFruitUI/AutoSyncCoordinator.swift](lines 17, 22); [CLAUDE.md](Background)

### Inferences
- For an agent wanting a valid session "at an arbitrary time": the session is only guaranteed fresh within roughly the last 24 hours of an app-open, and only if the app was opened (renewal requires foreground and, monthly, a human for Duo).
- Silent renewal is Penn-specific in practice (saved PennKey, Penn host markers); other schools' installs have no password-assisted renewal (`PennKeyCredentialsSheet` is gated on `CanvasInstallation.penn`).

### Gaps
- Actual Duo remember-me behaviour for non-Marco/Olisa accounts is not measured.
- Whether the background crash also occurs on the macOS build is not stated (BackgroundTasks code is `#if os(iOS)` only).

---

## 3. What the app knows about assignments and submission status, and how it is fetched

### Takeaway
Each assignment row carries separate Canvas and Gradescope "submitted" booleans with observation timestamps, a user-completion flag, and optional scores; the work list comes from the cookie-less Canvas ICS feed, and submission truth comes from authenticated Canvas `/api/v1` GETs with the session cookies. Every Canvas client in the app is read-only.

### Cited Findings
- `StoredAssignment` (SwiftData ledger, the "never lose anything" tier) fields: `id`, `sourceRaw`, `sourceID`, `kindRaw`, `course`, `title`, `dueAt`, `urlString`, term fields, `firstSeen`, `lastSeenInFeed`, `isGoneFromFeed`, `completedAt`, `userCompleted`, `isCompletionOnly`, `canvasSubmitted`, `gradescopeSubmitted`, `canvasSubmissionObservedAt`, `gradescopeSubmissionObservedAt`, `scoreEarned`, `scoreMax`, archive/link fields. — [Sources/LowHangingFruitKit/Persistence/StoredAssignment.swift](lines 74-200)
- `canvasSubmitted` comment: "Canvas's own submission signal (from Grade Watcher's `workflow_state`)"; the observed-at timestamp records when Canvas last answered, "submitted or not". — [StoredAssignment.swift](lines 133-157)
- Written by `AssignmentStore.applySubmissionState(submittedCanvasAssignmentIDs:scores:observedCanvasAssignmentIDs:fallbackCanvasAssignmentIDs:)` for `.canvas` and `.canvasModules` rows. — [Sources/LowHangingFruitKit/Persistence/AssignmentStore.swift](lines ~800-830)
- Source of that data: `CanvasGradesClient` GETs `/api/v1/courses/:id/assignment_groups?include[]=assignments&include[]=submission&per_page=100` and `/api/v1/courses/:id?include[]=total_scores`, parsing `workflow_state` / `submitted_at`; follows `Link: rel=next` only to trusted same-host URLs; treats 401 or an HTML 200 as `sessionExpired`. — [Sources/LowHangingFruitKit/Canvas/CanvasGradesClient.swift](lines 13-16, 107-125, 160-185)
- Work list source: `CanvasICSClient` fetches the per-user ICS feed with a plain `session.data(from:)` (no cookies, the URL is the credential). The assignment id is the URL fragment `#assignment_<id>` in the ICS event. — [Sources/LowHangingFruitKit/Canvas/CanvasICSClient.swift](lines 4-30); [CLAUDE.md](trap "Canvas assignment id is in the ICS event's URL fragment")
- Other Canvas reads with cookies: announcements, modules, course content/pages (`CanvasAnnouncementsClient`, `CanvasModulesClient`, `CanvasAPI/CanvasCourseContentClient`), discovery via HTML pages (cookie-only). Gradescope: `GradescopeClient` scrapes with the Gradescope cookie. — [Sources/LowHangingFruitKit/Canvas/](dir listing), [Sources/LowHangingFruitKit/CanvasAPI/], [Sources/LowHangingFruitKit/Gradescope/GradescopeClient.swift]
- No Canvas write path exists: the only `httpMethod = "POST"/"DELETE"` calls in the Swift sources are to the Supabase backend, the announcement extractor, and the (gated off) access-token mint/revoke. Nothing submits an assignment, posts, or edits on Canvas. — grep over Sources/ (BackendClient.swift 124/203, BackendSession.swift 166, ClaudeAnnouncementExtractor.swift 62, CanvasAccessTokenMinter.swift 123)
- The app's "done" is student-owned: `userCompleted` is a local tick, independent of Canvas submission; swipe-right on a card sets it. — [StoredAssignment.swift](lines 109-117); [CLAUDE.md](Dashboard cards)
- Widget snapshot: small "next due" JSON in the App Group container (`widget-snapshot.json`) plus a read-only SwiftData reader (`LedgerWidgetReader`, `cloudKitDatabase: .none`). — [Sources/LowHangingFruitKit/Widget/WidgetSnapshot.swift](lines 62, 95-107), [LedgerWidgetReader.swift](lines 24-56)
- CLAUDE.md Known gaps: nothing here has ever been tested against real Canvas or Gradescope data; all grade/submission paths are proven against fixtures only. — [CLAUDE.md](Known gaps #1); [ROADMAP.md](lines 55-57)

### Inferences
- Submission state in Smooth is a point-in-time poll (typically 15 min, stale after session death), which matches the "best-effort, not real-time" posture in project memory.
- Smooth has no CSRF-handling POST code path for Canvas other than the token mint script (an in-page fetch inside an already-authenticated WKWebView); acting as the student would be new code.

### Gaps
- Whether Canvas per-assignment `submission` objects expose enough (attempt, late, excused) is not mapped; Smooth reduces to a boolean.
- Gradescope submission-detection reliability is unverified ("gs-unverified" worktree exists; not read).

---

## 4. The backend: auth model, tables, what is promised never to leave the phone, and collisions with an agent integration

### Takeaway
A small Supabase project (Postgres plus 8 Edge Functions) with anonymous accounts, used for pooled course material and for the `ask` LLM proxy; it never talks to Canvas and by policy never receives credentials, grades, completions, submission state or the work list. Any agent design that moves cookies, tokens or submission state to a server collides directly with published principles.

### Cited Findings
- Functions: `ask`, `ask-canary`, `delete-account`, `discover-websites`, `extract-announcement`, `extract-profile`, `map-categories`, `sync` (+ `_shared`). — [backend/supabase/functions/] (directory listing)
- Auth: Supabase GoTrue anonymous sign-up (`POST /auth/v1/signup`, body `{}`), refresh token in the Keychain, access token as `Authorization: Bearer` on `POST /functions/v1/{name}`. No email, password or name. — [backend/PROTOCOL.md](lines 26-37)
- Principles: (1) "Canvas credentials never reach the server… The server never talks to Canvas." (2) "Never grades, completions, submission state, the work list, the student's name, or transcripts of questions. `CourseDocument.submitted` is stripped before upload." (3) sharing key is the numeric Canvas course id. (4) anonymous identity. (5) on-device fallback. — [backend/PROTOCOL.md](lines 7-24)
- Tables (RLS enabled on all): `courses`, `course_documents`, `course_profiles`, `enrollments`, `ask_usage` (init migration), `catalog_courses`, `course_websites`, `directory_cache`, `ask_outcomes` (outcome/latency/tokens, never question or answer). — [backend/supabase/migrations/20260907000000_init.sql] (lines 22-116, 226-230), [20260907120000_catalog.sql] (37, 76), [20260907180000_websites.sql] (31, 83, 89-90), [20260922090000_ask_outcomes.sql] (27, 50)
- Enrollment is client-asserted, not verified; recorded as a deliberate limitation (verifying would require server-held Canvas credentials, which principle 1 forbids). — [backend/PROTOCOL.md](lines 714-722); [docs/PRIVACY.md](lines 200-212)
- `ask` model: CODE vs DOC. `ask/index.ts` line 238 defaults to `openai/gpt-4.1-mini` (hedge `z-ai/glm-5.3-flash`), matching CLAUDE.md, but PROTOCOL.md's "Model" section (lines 704-712) still says default `z-ai/glm-5.3-flash` and fallback `openai/gpt-5.6-luna`. PROTOCOL.md is stale there (trust the code). — [backend/supabase/functions/ask/index.ts](line 238); [backend/PROTOCOL.md](lines 704-712)
- Privacy posture to quote: "The student's own data stays on-device; course material is pooled server-side; ask has an on-device fallback." Grades, completions, submission state, work list, name, and Canvas/Gradescope cookies never leave the phone; PennKey password only goes to Penn's login page; no analytics/tracking/third-party SDKs. Disconnecting Canvas deletes enrollments, usage rows and the anonymous account. — [CLAUDE.md](intro); [docs/PRIVACY.md](lines 1-34, 85-140, 189-224)
- CODE vs DOC, possible privacy-copy mismatch: PRIVACY.md (line ~114) says the ask request sends "an on-device summary of your dashboard (built without your name, grades, or completion state)". But `AssistantContextDocument.render` writes each work item as `course | title | due … | done/outstanding/nothing to submit | source` using `WorkFacts.isCompleted`, so a done/outstanding status per item does go to the server (and to the LLM) on the server ask path. Not verified whether the server path builds the document with completion included; flagged for the writer rather than asserted. — [Sources/LowHangingFruitKit/Assistant/AssistantContextDocument.swift](lines 108-140, 283-295); [docs/PRIVACY.md](line ~113-115)
- Penn-only server features: pooled materials, ask server path, announcement AI assist and stay-signed-in are Penn-only because the backend keys material by numeric Canvas course id. — [CLAUDE.md](Schools section)
- Second-brain-style collision list for an agent integration: (a) sending cookies/tokens to any server contradicts PROTOCOL principle 1 and PRIVACY "never leave the phone"; (b) sending the work list or submission state contradicts principle 2; (c) a server that acts on Canvas would "talk to Canvas", contradicting principle 1; (d) "No third-party SDKs" and "no analytics" constrain embedding an agent SDK; (e) `docs/PRIVACY.md` must change in the same commit as any behaviour it describes. — sources above; [CLAUDE.md](Start-here table)

### Inferences
- The existing backend is a content-pooling and LLM-proxy service with no per-user work-state store; an agent that needs per-student state would need either on-device mediation or a new, policy-breaking server table.
- The anonymous account has no stable link to a real identity, so it cannot be used to authorize an external agent as "this student" without new design.

### Gaps
- I did not read `sync`, `extract-*`, or `map-categories` function bodies, only PROTOCOL and migrations.
- Not verified whether the live backend is deployed with the same function versions as the repo (memory notes say some backend changes are undeployed).

---

## 5. The Canvas access-token path: what exists, why it is gated off, implications for giving an agent a token

### Takeaway
A complete mint-at-login, store, and bearer-use path exists but is switched off by `FeatureFlags.canvasAccessTokens = false`, because Penn's Canvas disables student-created tokens; so no student at Penn can hold a scoped token today, and the current design gives an agent only cookies.

### Cited Findings
- Components: `CanvasAccessToken` struct (token, id, hint, `expiresAt`, `createdAt`), `CanvasAccessTokenPolicy` (lifetime 120 days minus 1 hour, renewal window one week before expiry), `CanvasAccessTokenMint` (script/parse), `CanvasAccessTokenMinter` (WKWebView `fetch` POST inside a signed-in Canvas page, CSRF-guarded endpoint, 15 s timeout, called once right after an interactive login), `CanvasAccessTokenStore` (Keychain), and an `accessToken:` parameter on every `/api/v1` client via `CanvasAuth.apply`. — [Sources/LowHangingFruitKit/Canvas/CanvasAccessToken.swift](lines 1-80, 119-121, 371-379); [Sources/LowHangingFruitUI/CanvasAccessTokenMinter.swift](lines 1-30); [CanvasAccessTokenStore.swift](lines 47-114)
- Gate: `static let canvasAccessTokens = false`, with `canvasAccessTokenValue(_:)` skipping Keychain reads when false. Reason in the doc comment: Olisa's Canvas settings page showed "+ New Access Token" disabled with "Your Canvas administrators have chosen to limit your ability to generate your own access token", i.e. Canvas's restrict-student-tokens setting, so every mint would 403 for Penn students. — [Sources/LowHangingFruitUI/FeatureFlags.swift](flag + comment, lines ~38-66); [CLAUDE.md](trap "Penn restricts student Canvas access tokens")
- The flag exists "for the day Penn issues an OAuth developer key (what the Canvas Student app uses) or lifts the restriction". — [FeatureFlags.swift]; [ROADMAP.md](lines 114-116)
- Bearer tokens are only honoured on `/api/` paths, so `CanvasDiscoveryClient` (HTML pages) must stay cookie-only regardless of the flag. — [CLAUDE.md](same trap)
- Considered and rejected: scraping the password back out of the login page's DOM to synthesise a token ("defeats the whole point of a scoped, revocable token"). — [CLAUDE.md](same trap)
- Token minting is a POST, so it was deliberately kept out of `CanvasSessionRenewer` (rule 1 there is GET-only). — [CanvasAccessTokenMinter.swift](header comment)
- Other schools were not tested for the same restriction; CLAUDE.md says to check "on any other Penn account". Minting at non-Penn installs is also behind the same global flag. — [CLAUDE.md](trap)

### Inferences
- A scoped, revocable, 120-day bearer token is the clean primitive for an external agent, but at Penn it is blocked by institutional policy, not by Smooth's code; at a school that allows student tokens the mint code could be re-enabled with the flag.
- Instructure also supports OAuth developer keys that an institution would have to issue; Smooth has no OAuth client code (only the note that Canvas Student uses that route).

### Gaps
- Which of the 220 bundled schools allow student-generated tokens: unknown, not in `docs/canvas-directory/`.
- Whether the mint code would work against real Canvas: tests only, never exercised live.

---

## 6. Local surfaces today: URL scheme, App Intents, Shortcuts, Siri, widget, iCloud/CloudKit, share sheet, local network

### Takeaway
There is effectively no inbound integration surface: no URL scheme, no App Intents/Siri, no `NSUserActivity`, no share extension, no local server. The only cross-process channels are the widget's App Group snapshot and the opt-in CloudKit ledger/KV mirror.

### Cited Findings
- Grep over `App/`, `LHFWidget/`, `project.yml` and `Sources/` for `AppIntent`, `INIntent`, `CFBundleURLTypes`, `CFBundleURLSchemes`, `onOpenURL`, `NSUserActivity`, `handlesExternalEvents`, `NWListener`, `ShareLink`, `UIApplicationShortcut` returned no hits in app code. (My first run also matched copies under `.claude/worktrees/*`; those are ignored.) — grep, 2026-10-30
- Only extension: the WidgetKit extension (`NSExtensionPointIdentifier: com.apple.widgetkit-extension`). — [project.yml](lines 148-169); [LHFWidget/Info.plist]
- Siri/Shortcuts is a roadmap item only: "Siri / Shortcuts: 'what's due tomorrow?', answered by the on-device responder". — [ROADMAP.md](lines 105-107)
- App Group `group.com.lhf.lowhangingfruit` (macOS uses `24A3TDB277.group…` when sandboxed) shared by app and widget: `widget-snapshot.json` plus the SwiftData store opened read-only by the widget. — [Sources/LowHangingFruitKit/Widget/WidgetSnapshot.swift](lines 4-60, 95-107)
- CloudKit: entitlement `iCloud.com.lhf.lowhangingfruit` present; the ledger uses `cloudKitDatabase: .private(cloudContainerID)` only when Profile → sync (default off) was on at launch, else pinned `.none`. Preferences mirror through `NSUbiquitousKeyValueStore` with a fixed allowlist; cookies/PennKey/feed URL are never mirrored. CLAUDE.md calls sync "Phase A" with little soak time. — [Sources/LowHangingFruitKit/Persistence/AssignmentStore.swift](lines 82-138); [CloudPrefsMirror.swift](header); [CLAUDE.md](Known gaps)
- Debug-only launch arguments (`-LHFDemoData`, `-LHFShowAssistant`, `-LHFAgeCanvasSession`, `-LHFSessionDiagnostics`, `-LHFFullOnboardingReview`) are DEBUG builds only, not a product surface. — [CLAUDE.md](Commands)
- Mac build adds a menu-bar extra that keeps the sync loop alive and open-at-login; no inbound API. — [Sources/LowHangingFruitUI/LHFScenes.swift]; [CLAUDE.md](Mac)
- Developer-facing read of device state exists only via `devicectl` against a debug build (App Group plist, crash logs); not for end users. — [CLAUDE.md](Commands)
- Outbound-only network surfaces: Canvas/Gradescope fetches, Supabase, the `update-manifest` GitHub raw URL (fail-open update gate). — [CLAUDE.md](Update gate)

### Inferences
- The least invasive new seams would be App Intents / a URL scheme that returns the on-device work list (the on-device `OnDeviceAssistantResponder` already computes exact answers), because it needs no new network egress; sharing a session would be a much larger change.
- CloudKit private DB is Apple-account-scoped; an external agent platform (ChatGPT, Claude) has no access to it.

### Gaps
- I did not inspect Info.plist/`project.yml` for `BGTaskSchedulerPermittedIdentifiers` or universal-links entitlements beyond the greps above.
- macOS-specific entitlements (`App/LHFApp-macOS.entitlements`) have the same keys per grep; sandbox details beyond that not read.

---

## 7. LoginNavigationObserver: SAML return, the Canvas Student universal-link problem, and why it matters for handing a session to a different process

### Takeaway
iOS can reroute the SAML return hop into the Canvas Student app, so the login WebView never sees the signed-in page; Smooth defeats this by re-issuing the hop programmatically, which means the session is tightly coupled to one in-app WKWebView and its persistent data store.

### Cited Findings
- Problem (confirmed 2026-09-12): with Canvas Student installed, Connect Canvas opens that app and never connects; deleting it fixed it. WebKit treats a main-frame cross-host navigation traced to a user gesture as a universal-link candidate; the Penn IdP to `canvas.upenn.edu` SAML POST is exactly that. — [Sources/LowHangingFruitUI/LoginNavigationObserver.swift](lines 161-175); [CLAUDE.md](trap)
- Fix: `appLinkGuardHost` (Penn's pane only; nil for Gradescope) detects the cross-host hop, cancels it, and re-issues it with a programmatic `WKWebView.load`, rebuilding the POST body from the IdP's on-screen form via `formSerializerScript`. The wrong fix (replaying `navigationAction.request`) fails because WebKit strips POST bodies, turning the SAML POST into a bodyless GET. Duplicate main-frame POSTs to the same URL are cancelled; a 20 s cap applies to a committed credential POST. — [LoginNavigationObserver.swift](lines 59-62, 186-200, 576-700)
- The hidden renewer deliberately does not use this class; it has a separate local delegate and never resubmits the SAML response form. — [CanvasSessionRenewer.swift](rule 1 comment)
- Update to the owner's 2026-10-08 note: Penn's app-association file "now claims only `/canvas/login`"; the Canvas Student app (8.12.1) did not take the hidden renewer's return hop on the same phone. — [CLAUDE.md](analytics-cookie trap)
- The auto-fill of the IdP form in the visible pane is done by this observer; the saved PennKey is the only credential ever injected. — [LoginNavigationObserver.swift](header); [Sources/LowHangingFruitKit/Canvas/PennKeyLoginForm.swift]
- Working-tree changes exist to this file (25 lines) and to OnboardingView (331 lines) for the new authenticated-page-evidence connect flow (`CanvasLoginEvidence.swift`, untracked). Not yet exercised end-to-end on a device (CLAUDE.md Known gaps). — git diff --stat, 2026-10-30

### Inferences
- The valid Canvas session is bound to this app's WKWebView persistent data store (IdP, Duo and Canvas cookies) as well as the Keychain copy. Handing only the Canvas cookie to another process loses the ability to silently renew it, because the renewal capability lives in the IdP/Duo cookies in the WKWebsiteDataStore plus the saved password.
- Any design that runs the login in another process or in the system browser (ASWebAuthenticationSession, Safari) would face the same universal-link hijack and the same Duo requirement, with no Smooth guard code.

### Gaps
- Behaviour of the guard on macOS is not documented in the files I read.
- Non-Penn SSO schools (Okta, Shibboleth) have no field evidence for the guard; `appLinkGuardHost` is Penn-specific.

---

## 8. Traps in CLAUDE.md that bear directly on sharing a session out of the app

### Takeaway
Four traps matter most: the 24-hour rule is the trigger that keeps students signed in; one analytics cookie silently disabled it; background refresh has never run; and Penn forbids student access tokens. Together they say a valid session is a foreground, Penn-specific, roughly daily-renewed artefact.

### Cited Findings
- **24-hour trap.** `fac110d` (2026-09-24) removed the rule treating a no-expiry Canvas cookie as dead after 24 h, reasoning the server should decide. But the rule is the trigger for renew-on-open; without it renewal only ran after a Grade Watcher 401, and one such attempt on 2026-09-26 sat on Duo until the 30 s timeout, latched `needsDuo`, and showed the reconnect banner. Restored byte-for-byte from `39b2fff` for Penn (`df759f8`, `a16ea07`). Implication: Smooth's own local clock, not Canvas's server, decides "stale". — [CLAUDE.md](trap "The 24-hour cookie rule…"); [ROADMAP.md](Tried and parked)
- **Analytics-cookie trap.** `CanvasLoginPane.connect()` keeps every cookie on `canvas.upenn.edu` and the renewer keeps every cookie whose domain contains "canvas", so `_ga`, `_gid` and `last_known_canvas_host` ride along with year-long expiries; `load` then never returns empty, `isExpired` stays false, no banner and no renew-on-open, while the app sends Canvas only analytics cookies and no session. Read off Marco's phone 2026-10-08. Fix in working tree (uncommitted `gatedOnLiveSession`), not released. Implication: any copy of "the cookie set" exported from the Keychain may contain non-session cookies and a dead session. — [CLAUDE.md](trap); [SessionCookieStore.swift](working tree, lines ~141-179)
- **Background-refresh crash.** Every BGAppRefreshTask wake since 2026-08-24 dies on entry (Swift 6 isolation check in a `BGTaskScheduler` handler), so background refresh and background re-login have never run; fixing the crash alone would switch on untested background re-logins, so ROADMAP plans the crash fix together with a foreground-only guard on the renewer. Implication: no unattended refresh of either data or session exists today. — [CLAUDE.md](trap); [ROADMAP.md](lines 44-54)
- **Penn token restriction.** Penn's Canvas disables student access-token creation; a mint would 403 for every Penn student, so the whole path is gated off by `FeatureFlags.canvasAccessTokens = false`. Implication: no scoped, revocable credential is available for an agent at Penn; only the session cookie is. — [CLAUDE.md](trap); [FeatureFlags.swift]
- **Universal-link trap** (see section 7) bears on any login done outside the in-app WKWebView. — [CLAUDE.md](trap "An installed Canvas Student app…")
- **Stay-signed-in is fragile in the live build** (3.0.0 build 11): failed silent attempts are recorded as dead; banner bound directly to `canvasSessionExpired`; reconnect pane purges Duo trust. — [CLAUDE.md](Known gaps)
- **Policy flag in stay-signed-in.** Penn's Acceptable Use Policy asks students not to share PennKey passwords; Smooth's feature stores it on-device "comparable to a password manager's autofill". Giving any third party the password or session is a different act. — [docs/PRIVACY.md](lines ~76-84)
- **CODE vs DOC.** `PennKeyCredentialStore.swift`'s doc comment still says the student "explicitly turned the 'stay signed in' toggle on; it is off by default"; CLAUDE.md says the toggle was removed 2026-09-24 and the sheet is offered after every interactive Penn login. Trust CLAUDE.md (and PRIVACY.md line 43-50, which says "after you sign in… it offers"). — [PennKeyCredentialStore.swift](lines 9-20); [CLAUDE.md](Stay signed in)
- **Release/doc staleness.** CLAUDE.md states test baseline 1411/140 for V7 on 2026-09-27; project memory describes later v8 lines with ~3300 tests. This branch is a descendant of V7 (3.0.0 line). Branch/version claims in CLAUDE.md should be treated as potentially stale (it says so itself). — [CLAUDE.md](Test baseline, Branches)

### Inferences
- Implications list (short, not a design):
  1. Read-only agent access to the work list can be served on-device (ledger, `OnDeviceAssistantResponder`, ICS feed) without touching cookies or the server, and fits all current privacy promises.
  2. Server-held or agent-held Canvas cookies would contradict PROTOCOL principle 1 and the privacy copy, and would need PRIVACY.md and review-notes changes in the same commit.
  3. Acting on Canvas as the student has no code today; it would be new POST/PUT paths with CSRF (session) or Bearer (token, blocked at Penn), with Canvas API semantics for submissions not yet explored.
  4. Session validity is a foreground, roughly daily, Penn-specific, Duo-monthly process; an agent cannot assume a session at an arbitrary time.
  5. The Keychain is not shared with any extension; an App Intent or URL scheme in the main app is the natural seam for an on-device agent; a remote agent would need an explicit, user-visible handoff.

### Gaps
- None of the above (including the working-tree fixes) has been compiled or run in this research; CLAUDE.md's rule "a change that has not been compiled is not done" applies to the uncommitted files.
- I did not read `docs/persistence-explained.md`, `docs/CANVAS_LOGIN_HARDENING.md`, or `docs/CANVAS_LOGIN_DIAGNOSIS.md`; section 1-2 rely on code comments and CLAUDE.md for their content.
