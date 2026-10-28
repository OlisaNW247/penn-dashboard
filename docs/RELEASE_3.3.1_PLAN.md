# 3.3.1 (17): the merge and release plan, 2026-10-28

## The situation in one paragraph

Three branches have to become one release. `fix/duplicate-category-ids`
(223a0c1) holds the launch-crash fix and 80 hardening commits, stamped
3.2.2 (16) and never uploaded. `origin/v8` (06cc5d4) holds ten of Olisa's
commits from 2026-10-27: Chrome extension, backend, docs, no Swift.
`origin/claude/sharp-newton-qwv18v` (5c2ecba) is what Olisa shipped today
as **3.3.0 (16)**, live since 22:37 UTC: the feedback card, the hardened
update wall, the backend version floor, the automatic floor workflow.
**3.3.0 does not contain the crash fix, so the launch crash is still live,
and build number 16 is now taken.** The release is therefore 3.3.1 (17).

## What is being fixed, in plain words

**A second crash, found on Marco's phone while this plan was being
carried out (2026-10-27 evening).** Five crash reports on the phone, builds
12 to 14, all the same: tapping any Smooth notification killed the app,
because the notification delegate used the `async` form of `didReceive`
and iOS's completion then ran on a background thread where UIKit asserts.
Fixed on this branch (completion-handler form, completion on the main
thread); `docs/LAUNCH_CRASH_2026-10-26.md` has the record. This one *is*
proven by crash reports; the duplicate-key crash still is not.

**The crash.** Open the app, a few seconds later it quits, every time,
reinstalling does not help. Cause: a course whose Canvas assignment groups
have two names that look the same once lowercased ("Homework" and
"homework", two "Assignments" groups in a reused course site). The grade
engine built a lookup table with two entries for one key, and Swift kills
the app for that. Fix: colliding groups get a unique suffix, and every
such lookup table is now first-wins. Ids that never collided are unchanged,
so saved edits still match. 17 tests die with the production error on the
old code and pass on the new. Proven from the code on 2026-10-26 and **by the App Store crash
reports on 2026-10-28**: Organizer → Crashes shows this stack on 6 devices,
all on 3.2.1 (`docs/LAUNCH_CRASH_2026-10-26.md` → "Proven").

**The "frozen" screens.** Three things in the fix branch, one in 3.3.0:
- A reconnect that was not finished (lost signal, gave up, force-quit)
  wrote "onboarding not done" to disk, so the student was stuck on the
  first-run screens on every launch. Now a reconnect is a cover over the
  dashboard with an X, and it never touches that flag.
- A failed Penn sign-in left a spinner forever. Now it says "couldn't sign
  in. try again." with a button.
- A Canvas session that had silently died looked alive because Google
  Analytics cookies saved beside it live for a year. The app now asks
  whether a real session cookie is still fresh. On a dead one the proven
  renew-on-open path runs again.
- (3.3.0) A sheet left open when the update wall rose stayed usable on top
  of the wall while syncing continued underneath. Below the floor the app
  now renders only the wall.

**What is deliberately not lost.** The cookie logic and storage are as they
were on the phones where they work: the 24-hour rule on a no-expiry Canvas
cookie, the Keychain service and account names, the JSON cookie format, the
renewer's login/fill/submit flow (no diff at all). The only read-time
change can make a session read "expired" more often, never less. Keychain
writes now update in place, so items 3.2.1 saved are found, not duplicated.
Verified independently on 2026-10-28; the three cookie suites (48 tests)
pass.

**One behaviour change to tell Olisa about:** Gradescope no longer has a
24-hour local clock; it stays connected until a real login page is seen on
two syncs an hour apart. This was in the changelog as "Olisa to review".

## What the dry run proved (scratch worktree, nothing pushed)

Merge order: fix branch ← v8 ← sharp-newton. Conflicts: CLAUDE.md (two
doc hunks, keep both), `project.yml` and `project.pbxproj` (version
stamps), one comment in `AskCitationLinkTests` (both sides fixed the same
golden). Nothing else. Then:

| Gate | Result |
|---|---|
| `deno task check` | green |
| `deno task test` | 614 passed, 0 failed |
| `swift test --no-parallel` | 3372 tests / 322 suites, all passed |
| iOS Simulator build (app + widget) | BUILD SUCCEEDED, 0 errors |
| iOS device Debug build | BUILD SUCCEEDED, reads 3.3.1 (17) |
| Semantic review of every auto-merged seam | all seven files OK |
| Cookie/Keychain preservation review | preserved |

3372 = 3346 (fix branch) + 26 (sharp-newton's feedback and wall tests).
Nothing has run on a phone yet.

## The game plan

1. **Make the real branch.** In a fresh worktree off
   `origin/fix/duplicate-category-ids`, create `release/3.3.1`. Merge
   `origin/v8`, resolve CLAUDE.md. Merge `origin/claude/sharp-newton-qwv18v`,
   resolve the four files exactly as the dry run did, stamp 3.3.1 / 17 by
   hand in both `project.yml` and `project.pbxproj` (no `xcodegen`). Add
   this file. One merge commit each, so either side can be read in history.
2. **Re-run every gate on the real branch** (the same table above). A
   change that has not been compiled is not done.
3. **Phone.** Install the Debug build over the store copy on Marco's iPhone
   (CoreDevice `8A287085-9C88-5A87-816B-1A8EF80D67AD`; check first that
   Codex has not left a build there that matters). Watch: one refresh with
   no crash and no new `Smooth-*.ips`; the reconnect cover from Profile and
   the banner, X on every step, dashboard after; `-LHFSessionDiagnostics`
   then `-LHFAgeCanvasSession`, expect `canvasSessionExpired false -> true`
   and a renewal in that launch; the feedback card appearing once and
   staying away after X.
4. **Push and PR** `release/3.3.1` → `v8`. Olisa reviews the Gradescope
   clock change and the backend deploy list.
5. **Archive and upload** from the branch tip with the two commands in
   CLAUDE.md → Commands. Before exporting, check App Store Connect →
   TestFlight → Builds that no 17 exists.
6. **Submit** with an expedited review request (crash on launch for a
   subset of users, fixed). Record the release in CLAUDE.md.
7. **Floor.** The `update-floor` workflow on `main` raises the manifest
   floor by itself six hours after a version goes live. It will move to
   3.3.0 at about 04:37 UTC on 2026-10-28 and to 3.3.1 six hours after
   3.3.1 is live. Nothing to do by hand; if 3.3.1 misbehaves, set the
   `UPDATE_FLOOR_HOLD` repository variable within those six hours.
8. **Backend, Olisa's go, after the app is live:** apply the four fix-branch
   migrations in the order `docs/WHAT_CHANGED_3.2.2.md` gives, set
   `LHF_PROBE_SECRET`, deploy the functions, and only then consider
   `LHF_REQUIRE_VERSION_HEADER=true` once the floor is at or above 3.3.0.

## What this plan refuses to do

- Ship without a phone run.
- Touch `SessionCookieStore` / `CanvasSessionRenewer` beyond what the fix
  branch already carries.
- Raise the manifest floor by hand.
- Deploy the backend in the same step as the app.

## Where it stands (2026-10-28, midday)

- PR #14 merged into `v8` at 14:19 UTC (merge commit `4316bba`); `v8`'s
  tree is byte-identical to `fbd34ca`, so the gates above stand for `v8`.
- A Release archive of `fbd34ca`, stamped 3.3.1 (17), was built at 14:20
  UTC (`build/Smooth.xcarchive` in the release worktree; app and widget
  read 3.3.1/17, AlarmKit weak-linked, dSYMs present). **Not exported, not
  uploaded**: Marco's word that morning was to merge, test on his phone,
  then merge his separate onboarding/UI branch, and only then go to the
  App Store. The next store build will therefore come from that later
  tree, not from this archive.
- The crash reports are read and match (the section in
  `docs/LAUNCH_CRASH_2026-10-26.md`); no third cause.
- Still owed: the Debug build on Marco's iPhone for his final check (the
  phone was unplugged when the install was tried), and the onboarding
  merge. That branch is `codex/simplify-canvas-onboarding`, whose work is
  **uncommitted in the main checkout on a base 295 commits behind `v8`**
  and touches `SessionCookieStore`, `CanvasSessionRenewer`,
  `LoginNavigationObserver`, `OnboardingView`, `UpdateGate`, `AppState`
  and the cookie tests, all of which `v8` also changed; expect real
  conflicts in the session code and read every one against the cookie
  rules in CLAUDE.md before taking either side.


### Phone install (2026-10-28, 17:13 UTC)

Debug 3.3.1 (17), built from the release tree, was installed on Marco's iPhone 17 Pro with `xcrun devicectl device install app` and launched. The phone reports Smooth 3.3.1 (17); the process was still alive well past the point where 3.2.1 trapped. Marco's final hands-on test comes next, then the merge of the onboarding/UI branch he names (not `codex/simplify-canvas-onboarding`), then the App Store upload.
