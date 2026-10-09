# Why App Store users get signed out of Canvas, and Olisa's phone doesn't

Written 2026-10-09. Read-only investigation; no code changed. Branch `v8`.

## The premise was wrong, and that is the first finding

The investigation started from "Olisa's iPhone has an old Xcode build
that never logs out; App Store users do." `xcrun devicectl device info
apps` on the iPhone 17 (`C9A0CCE1…`) reports:

```
bundleVersion 11, version 3.0.0, builtByDeveloper False
```

and every attempt to list or copy its containers fails with
`ContainerLookupErrorDomain error 7`, which `devicectl` returns for apps
it did not install. So the phone runs **3.0.0 build 11 from the App
Store**, the same binary as every complaining user: the store page shows
3.0.0 released about 2026-10-01, and iOS replaced the old Xcode build
in place when the update shipped, keeping its data container and its
Keychain items (same team `24A3TDB277`, same bundle id, no explicit
keychain access group, so the default access group is identical for
Debug and App Store signing).

The code on both sides is therefore the same commit, `ddef468`. A
three-way diff of every auth path (owner's last Xcode build `f0ce8bd`,
the release `ddef468`, and the 1.1.2/2.0.1 ancestors of the old 1.2.1)
confirms it independently: between `f0ce8bd` and `ddef468` the Penn
session code was restored byte for byte (`df759f8`, `a16ea07`); nothing
under `#if DEBUG` touches cookies, renewal or the dead-session latch;
signing, entitlements, Keychain attributes and the WebView store UUIDs
are identical across all three. Full table: the diff report in the
session scratchpad, summarised in the next section.

**So the difference is not code. It is state the owner's phone has and a
typical user lacks.**

## What the owner's phone has

1. A saved PennKey password (`PennKeyCredentialStore`), entered during
   the stay-signed-in work in September, carried across the update.
2. A live Duo "remember this device" trust, re-issued on every
   successful silent renewal (CLAUDE.md, "Stay signed in": verified
   2026-09-27 on this phone, renewed hands-free in 8 s).
3. Daily use, so the 24-hour cookie rule fires while the IdP session is
   often still alive.

With those three, the 24-hour rule flips `canvasSessionExpired`,
`CanvasSessionRenewer` fills the IdP form with the stored password, Duo
trusts the browser, Canvas issues a fresh cookie, and nothing is ever
shown. Remove any one of them and the same build shows a banner.

## Most likely root cause (H1): no saved PennKey password

Evidence, all at `ddef468`:

- `SessionCookieStore.load` drops a no-expiry Canvas cookie 24 hours
  after its last save (`SessionCookieStore.swift:109-111,144`). This is
  by design; it is the renewal trigger (CLAUDE.md, 24-hour trap).
- The renewer only gets credentials when `canAutoLoginSilently`
  (`AppState.swift:1487`, closure at `:1925-1930` reading
  `PennKeyCredentialStore.load()`). Without them it is a GET-only
  reload that rides whatever IdP session the WebView still has.
- Penn's IdP session does not last a day. So the GET-only renewal ends
  on the login form, `.landedOnLoginPage`
  (`CanvasSessionRenewer.swift:596-600`), which sets the sticky
  `canvasSessionConfirmedDeadV1` (`AppState.swift:1850-1862`) and the
  dashboard shows **"your canvas login needs a refresh"**
  (`ContentView.swift:398-400`).
- The password is only ever offered after an *interactive* Canvas login
  (`OnboardingView.swift:351`, `canvasConnected()`). A student who
  updated from 1.2.1 with a working session never logged in
  interactively on 3.0.0, so was never offered it; a student who tapped
  "not now" is in the same place. Either way the cycle is: open the app
  after a night, banner, tap, PennKey, Duo, a day of quiet, banner.

What's New promises "If Canvas logs you out, the app quietly reconnects
on its own." That is true only for students who saved the password, and
the app never says so.

Confirms H1: affected users report the plain "needs a refresh" banner,
roughly daily, and say they never saved the password (or were never
asked). Refutes it: users who did save it and still see banners (then H2
or H3).

## Other hypotheses, ranked

**H2. Duo trust is lost, and `needs duo` latches.** The visible Canvas
pane purges `duosecurity` website data every time it appears
(`OnboardingView.swift:860-866`, hints from
`CanvasInstallation.swift:28-34`). Every manual reconnect therefore
discards Duo's remember-device cookie; unless the student ticks "trust
this browser" again, the next unattended renewal with a saved password
ends `.needsDuo`, which sets `autoLoginAwaitingDuoV1` and the dead flag
(`AppState.swift:1957,1968`), cleared only by an interactive login
(`:2257-2260`). Banner: **"tap to finish signing in — duo needs you"**.
This is the one that would bite students who *did* save the password.
Marco's 2026-09-26 sign-out had this shape.

**H3. One bad renewal latches "dead" with no retry.** `.timedOut` (30 s,
`CanvasSessionRenewer.swift:139`) and `.landedOnLoginPage` both set the
sticky flag. Renewal fires on the false-to-true *edge* of
`canvasSessionExpired` (`AppState.swift:1790`); after the latch the only
retry is a Grade Watcher 401 (`:3015-3019`, hourly cooldown) and only
while some Canvas cookie still exists. A slow Duo page or a launch on a
bad connection is enough to show the banner until the student logs in
by hand.

**H4. The first 3.0.0 launch after the update.** Same Keychain item
names since 1.1.2, so a 1.2.1 session older than 24 h is dropped at the
first 3.0.0 launch and H1 runs immediately, which is why the complaints
started with the release.

**H5. Gradescope is a separate cause.** At `ddef468` Gradescope cookies
are re-stamped only at login (no `merge`), so a no-expiry cookie older
than 24 h is dropped, and `AutoSyncCoordinator.swift:28-33` disconnects
when the cookie set is empty. Reports that say "Gradescope" rather than
"Canvas" belong here, not to H1.

**H6. The reconnect banner now opens a school picker** (`restartOnboarding`
starts at `.schoolSelection`, `OnboardingView.swift:69-71`), and picking
any school other than the current one calls `disconnectCanvas()`
(`AppState.swift:2465-2470`), deleting the saved password, the cookies and
the WebView data. New in 3.0.0; rare, but it turns a password-saving
student back into an H1 student.

**H7 (low).** `loadDicts` returns `[]` on any Keychain read error
(`SessionCookieStore.swift:193-204`); before first unlock after a
reboot that reads as "no session". Only reachable from a background
launch, and background wakes crash first (CLAUDE.md trap).

**Ruled out by the code:** team, bundle id or entitlement drift (none);
WebView store UUID change (none since 1.1.2); the update gate (fail
open, floor still 1.2.1); any Debug-vs-Release logic difference (none);
development vs App Store provisioning (affects `get-task-allow` and APNs
only).

## Fix plan, in order of leverage (nothing implemented yet)

1. **Offer the password where the problem shows.** When the dashboard
   shows "needs a refresh" and no password is saved, the reconnect
   flow should present the stay-signed-in sheet on the way *in*, with
   one line that this is what makes "quietly reconnects" true. Also
   offer it once to upgraders on first launch with a live session, not
   only after an interactive login. (H1, H4.)
2. **Stop purging Duo on every pane appearance.** Purge `duosecurity`
   only on disconnect and on a rejected password, never on an ordinary
   reconnect, so a trust the student granted survives their next manual
   login. (H2.)
3. **Retry instead of latching.** Treat `.timedOut` as unknown, not
   dead; retry a silent renewal on each foreground while
   `canAutoLogin`, with the existing one-hour cooldown, and only latch
   after a second landing on the login form. Keep `.needsDuo` and
   `.passwordRejected` sticky, since only a human clears those. (H3.)
4. **Gradescope parity.** Re-stamp Gradescope cookies on every
   successful sync, as Canvas already does, and disconnect only on a
   proven auth failure. (H5.)
5. **Reconnect must not start at the school picker** for an install
   that already chose a school; start at the Canvas login and keep the
   picker behind an explicit "change school". (H6.)
6. **A visible sign-in health line** in Profile → accounts, in release
   builds: password saved yes/no, Duo trusted until a date, last silent
   renewal outcome and time. The troubleshooting section was removed in
   56fdefa, so today an affected student can only describe a banner;
   this is the cheapest diagnostic for the next report.
7. **Background refresh**: fix the crash together with the
   foreground-only guard already on `ROADMAP.md` → Now, so the 24-hour
   rule gets a chance to renew before the student opens the app.
8. **Housekeeping that this investigation surfaced:** CLAUDE.md still
   says 1.2.1 is live; it is 3.0.0. The `update-manifest` floor can now
   be raised to 3.0.0, since 3.0.0 is downloadable.

Verification for each: a TestFlight build with `-LHFAgeCanvasSession`
on two phones, one with a saved password and Duo trust, one with
neither, opened after 25 hours; then three affected students on the
next release reporting which banner they see over a week.

## Still open, and what each would settle

- Which banner affected students see, how often, whether they saved
  the password, whether they ticked Duo's "trust this browser", fresh
  install or update: separates H1, H2, H3, H5, H6.
- Whether the owner's phone has the password saved and Duo trusted
  today: expected yes to both; a no would weaken the whole argument.
- Penn's IdP session and Duo remember lifetimes: not in the repo;
  they set how long a GET-only renewal can succeed.
