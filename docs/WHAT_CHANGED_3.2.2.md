# What each change on `fix/duplicate-category-ids` does

One entry per commit, oldest first, in plain words. Each commit stands on
its own, so any one can be dropped before this branch is merged. "Phone"
means the change has not been run on a device yet, and what to look at
when it is. The branch was cut from `v8` at `e3a57b3` on 2026-10-26.

## Every commit on the branch, oldest first (80 since `v8` `e3a57b3`)

The hashes below are the ones on `fix/duplicate-category-ids` after the
groups were brought together on 2026-10-27. The sections that follow
explain each change in plain words, grouped by the work that produced
them; a group's commits carry the subjects in this table.

| Commit | Subject |
|---|---|
| `b73b603` | Fix the launch crash from two Canvas groups whose names slug alike |
| `f4e448a` | Stamp 3.2.2 (16) for the launch-crash fix |
| `87356d6` | Record the 3.2.2 (16) device build and archive for the launch-crash fix |
| `6c2e638` | Add the 2026-10-25 hardening plan to the branch |
| `a3af5b9` | Present a reconnect as a cover over the dashboard, never as a restart |
| `9350b2a` | Decide "Canvas session expired" by whether a session cookie is still fresh |
| `d4c1d78` | Fix the citation-link golden's escaped slash so the suite is all green |
| `77b9fbb` | Record Release A on the branch and the rebuilt 3.2.2 (16) products |
| `531f1dc` | Probe Canvas instead of deleting cookies when Grade Watcher sees a 401 |
| `ba2c6f0` | Clear a failed Canvas connect's spinner, offer try again, and add save pennkey |
| `d03046a` | Keep what the student did when Canvas is disconnected |
| `8bed8fa` | Let a student's edited due date keep a row from aging out |
| `f0a9287` | Make an un-tick clear the card's hidden twins and carry once |
| `7e89b51` | Re-plan reminders and alarms as soon as Canvas is disconnected |
| `c763eb3` | Type the backend timers as ReturnType<typeof setTimeout> so deno check is green |
| `26515ea` | Close ask-canary behind a secret, clamp its overrides, and cap ask's request body (BE-A) |
| `2eba5ff` | Revoke the usage and quota functions from anon and authenticated, and make the SQL test reproduce Supabase's default grants (BE-B) |
| `cd277e6` | Reserve the quota atomically before the model call, settle in a finally, abort upstream when the client leaves (BE-C) |
| `360ba7f` | Restrict discover-websites to https, an allow-list and public addresses, with capped bodies (BE-F) |
| `37775aa` | Pin the npm specifiers to the locked versions (BE-17) |
| `1b8cb6b` | Make delete-account idempotent (BE-14) |
| `1c3ec8e` | Stop logging and storing upstream error bodies (BE-16) |
| `7339cc4` | Make the monthly quota count sargable and index it (BE-15) |
| `ad6d50d` | Give requireUser's device_links lookup a deadline (BE-11) |
| `29758b4` | Bound extract-profile with a time budget (BE-12, the deadline half) |
| `012ca41` | Make discover-websites' host allow-list opt-in: any public https host by default (BE-F fix-up) |
| `b2fef7a` | Correct the privacy policy and mirror it onto the public page |
| `bc9ada3` | Open only Canvas and Ed links from an ask answer |
| `13be448` | Log course codes, hosts and class counts as private in Release |
| `5ef5872` | Keep every completion when two rows for one id are merged |
| `d3c8bfa` | Treat a failed ledger read as a failure, not as an empty ledger |
| `bf668e6` | Record announcements and release the task blob only after the save lands |
| `7ac1276` | Have grade history report its own health |
| `2c5cbb6` | Keep "turned in" taps through a kill, and commit a swipe before it animates |
| `b1b3399` | Integrate: read the completion record as optional in two new test suites |
| `d0b5e60` | Bound the server-deletion retry, and make it call only when there is an account |
| `8f81fd4` | Keep the unfinished rows whose dates the student edited when Canvas is disconnected |
| `d1a6034` | Correct two statements that no longer matched the code |
| `b89bc30` | Merge submission observation dates in absorb, and say which fields do what |
| `a72bd80` | Retry the legacy grade-history import when a course could not be read |
| `4811473` | Wire the swipe's commit so the dashboard saves before the card animates |
| `48cb988` | Skip, rather than retire and stamp, a crawl the fetch rules refused (BE-F fix-up) |
| `83e5355` | Upgrade an http:// link to https before the fetch guard runs (BE-F fix-up) |
| `09647d5` | Stop re-charging a course that always overruns extract-profile's budget (BE-12 fix-up) |
| `ce30a98` | Correct two comments that misdescribed the code (BE-A fix-up) |
| `acd1ce3` | Re-plan reminders and alarms after a background wake, without a prompt |
| `b5f12a8` | Plan alarms even when notifications are declined |
| `bec3c42` | Give urgent reminders their slots first, and free the buzz slots in alarm mode |
| `ac2f7e1` | Re-plan notifications by diff, count refusals, and isolate one alarm's failure |
| `f8043e9` | Pin the time zone on reminders' calendar triggers |
| `4b15430` | Re-plan reminders from the ledger before the network at launch and foreground |
| `31ff68f` | Let a background wake reuse the live AppState instead of opening a second ledger |
| `411ba12` | Retry a failed alarm cancel once before reporting it (follow-up to the C5 commit) |
| `b69a1d7` | Put a five-second deadline on the pending-notifications read (follow-up to the C5 commit) |
| `d8402df` | Take @MainActor off three test suites and test isUrgent off the main actor (follow-up) |
| `96638dd` | Keep Gradescope connected: no clock, no disconnect on one bad read |
| `cb18e75` | Make Keychain writes safe, and give reads three answers |
| `7d87404` | Sign in to the backend one caller at a time |
| `45ec598` | Stop iCloud prefs from deleting another device's settings |
| `f1dde8f` | A4 fix-up: the reconnect cover must show the Gradescope login pane |
| `724ea1c` | A4 fix-up: a connected Gradescope with no cookies at all must not stay silent |
| `c7d7d8f` | A4 fix-up: a Gradescope that really is empty stops being reported as a failed refresh |
| `95c7e88` | A10 fix-up: a stale flight must not clear a newer identity in its recovery path |
| `5a75816` | A5 fix-up: say exactly what isExpired's confirming re-read guards |
| `10885e1` | Integrate: the Gradescope pane's success check honours the reauth verdict |
| `7cfd588` | Decode stores element by element so one bad element cannot cost a whole store |
| `ca86c3a` | Rehearse the first ledger schema change, and open the store through one door |
| `5cd63c0` | Keep dates independent of the phone's calendar system and time zone |
| `7fe525f` | Pair Canvas with Gradescope once per rebuild, and normalise each title once |
| `a8bcbc9` | Compile regexes once and remember title tokens in the per-item classifiers |
| `aae6fcf` | Cap the ask question at 2,000 characters before it is classified |
| `eb352cf` | Send credentials only to the host they belong to, including across redirects |
| `1142aca` | Pin the Ed thread filter to the Chrome extension's, and flag the anonymous gap |
| `f6e8303` | Fuzz everything that takes outside data, and fix the three things it found |
| `c4a0336` | Send the app through the ledger door, and stop the widget migrating |
| `e0f7f38` | Carry recurring ticks and edited dates across the occurrence-id change |
| `bdb7352` | Keep a copy of a student-authored blob before its unreadable part is overwritten |
| `22f15d8` | Keep the tail of a long ask question, not only the head |
| `2299f22` | Integrate: the recurring re-key reads the ledger as optional and keeps its flag unset on a failed write |
| `dbf1a17` | Integrate: two Kit-group tests read the completion record through the ledger-group helper |

## The first eight, in detail

## `b73b603` Fix the launch crash from two Canvas groups whose names slug alike

**For a student:** the app no longer quits a few seconds after opening
when one of their courses has two assignment groups with names that
look the same once lowercased and stripped of punctuation ("Homework"
and "homework", "Quiz (EC)" and "Quiz - EC", two "Assignments" groups
left by a course copy). This is the launch-day crash on 3.2.1.

**In the code:** category ids were `"map:" + slug(name)`, so two groups
could share one id, and the grade engine built a dictionary that traps
on a duplicate key. Now the group with the lowest Canvas id keeps the
bare id and the others get the group id as a suffix; every dictionary
keyed on Canvas, Gradescope, syllabus or server ids is first-wins
instead of trapping; three percent formatters no longer trap on a
zero-point item. Ids that never collided are byte-identical, so saved
edits and server mappings still match.

**Risk:** low. 17 tests, which die with the production error on the old
source. Phone: open the app and let one refresh run.

## `f4e448a` Stamp 3.2.2 (16)

**For a student:** nothing visible; the version the store will show.

**In the code:** `MARKETING_VERSION` 3.2.2 and `CURRENT_PROJECT_VERSION`
16 in `project.yml` and the Xcode project, by hand, no `xcodegen`.
App Store Connect refuses a build number it has already seen, so check
TestFlight → Builds for a 16 from another Mac before uploading.

## `87356d6` Record the 3.2.2 (16) device build and archive

Docs only: where the Debug phone build and the Release archive are, and
the two commands to install the Debug build.

## `6c2e638` Add the 2026-10-25 hardening plan to the branch

Docs only: the audit's plan, which the rest of the branch implements,
copied from the audit worktree where it was untracked.

## `a3af5b9` Present a reconnect as a cover over the dashboard, never as a restart

**For a student:** tapping "reconnect canvas" (the banner, a Profile row,
the grades screen) opens the sign-in over their dashboard with an X to
close it. If they give up, lose signal, or force-quit mid-login, the
next open is their dashboard, not the first-run walk. Before, a
reconnect wrote "onboarding not done" to disk, and anyone who could not
finish was locked onto the first-run screens on every launch. Also:
the "just exploring? preview with sample data" link no longer shows to
a signed-in student, and leaving preview mode no longer deletes grade
history.

**In the code:** a memory-only `isReconnecting` flag; `ContentView`
presents `OnboardingView` as a `fullScreenCover` (iOS) or sheet (macOS);
`restartOnboarding(for: .canvas/.gradescope)` never writes the persisted
flag; the launch-time refresh re-runs when the cover closes; the close
control sits on every step; `clearPreviewFixtures()` replaces
`clearAll()` on the preview exit. "Start over" and preview mode keep
the old behaviour.

**Risk:** medium, it is sign-in UI. 16 tests. Phone: reconnect from a
Profile row (the row dismisses itself and presents the cover in the
same tick), the X on each step, the refresh after closing, and that the
five-minute refresh loop keeps running under the cover.

## `9350b2a` Decide "Canvas session expired" by whether a session cookie is still fresh

**For a student:** phones that had stopped renewing their Canvas session
silently (the "needs a refresh" banner that never went away on its own)
renew again on open. The cause was Google Analytics cookies saved beside
the session cookie; they live for a year, so the app thought a session
was still there after the real one had expired.

**In the code:** `SessionCookieStore.load` keeps its old per-cookie
check and then asks whether a session-named cookie (`canvas_session`,
`_normandy_session`) is still fresh; if one was ever saved and none is
fresh, the set reads empty, `isExpired` trips, and the proven renew-on-
open path runs. Cookie harvests and the renewer are untouched; a parity
test pins their cookie-name lists together.

**Risk:** low to medium; it is read-time only, Olisa should still
review it. 13 tests. Phone: on Marco's phone, `-LHFSessionDiagnostics`
then `-LHFAgeCanvasSession`; expect `canvasSessionExpired false -> true`
and a renewal in that launch.

## `d4c1d78` Fix the citation-link golden's escaped slash

Test only: the one red test since 2026-10-25 had a hand-typed golden
with `America/New_York` where the encoder writes `America\/New_York`.
The suite is all green from here.

## `77b9fbb` Record Release A on the branch and the rebuilt 3.2.2 (16) products

Docs only: the device checks and the rebuilt products.

## Sign-in edges and what disconnect keeps (group W1a)

### Probe Canvas instead of deleting cookies when Grade Watcher sees a 401
**For a student:** a concluded or restricted course, which Canvas
answers with 401 even on a live session, no longer gets the saved
Canvas session deleted out from under them.
**In the code:** the delete is replaced by one request to
`/api/v1/users/self` with the saved cookies: 200 with JSON means alive
(do nothing), 401 or a redirect to login means dead (the existing
"session expired" path, which starts the silent renewal), anything
else is unknown (do nothing). The renewer itself is untouched.

### Clear a failed Canvas connect's spinner, offer try again, add save pennkey
**For a student:** a Penn sign-in that fails no longer leaves a
spinner forever; the pane shows "couldn't sign in. try again." with a
"try again" control and the "I've finished signing in" button. At other
schools a bouncing single sign-on is retried at most twice. Profile →
accounts gains one row, "save pennkey", while Penn is connected and no
password is saved, opening the existing sheet.
**Limits:** the raw error is not shown (an existing test pins the
fixed sentence; showing the raw error is a copy decision). "Try again"
at Penn reloads the login start and can, until plan item A6 is done,
count a second sighting of the form as "password rejected".

### Keep what the student did when Canvas is disconnected (plus the deletion retry)
**For a student:** disconnecting Canvas no longer deletes finished
work, completion-only rows, rows whose due date they edited, or the
grade history; only unfinished feed rows go. Reconnecting as the same
account pairs the kept rows with the re-fetched ones. If the request
that deletes their server-side rows fails (offline), the app retries it
on later launches and refreshes until it succeeds, says "couldn't reach
smooth · will retry" in Settings meanwhile, gives up on a permanent
refusal, and never mints a new account just to delete it.
**Limits:** switching school and disconnecting Gradescope still purge
as before; unfinished archived rows are still deleted; the disconnect
confirmation copy is unchanged (Marco's call).

### Let a student's edited due date keep a row from aging out
A row that Canvas stopped listing and whose feed date is two weeks past
used to be deleted even when the student had moved its due date to next
week (a granted extension). Aging now looks at the later of the two
dates.

### Make an un-tick clear the card's hidden twins and carry once
Un-ticking a card used to come back ticked on the next rebuild, because
a hidden twin (a Modules reading for the same work) still held the old
completion. Un-ticking now clears every twin, and a completion is
carried between twins once per pair.
**Limit:** the device-sync equivalent (a laptop un-tick) is Olisa's
sync code and is unchanged; the one-line fix is named in the commit.

### Re-plan reminders and alarms as soon as Canvas is disconnected
Nothing rings for a source that is gone. Before, alarms survived a
disconnect until the student next looked at the dashboard.

## Ledger integrity (group W1b)

### Keep every completion when two rows for one id are merged
When the ledger holds two rows for one id (a feed row and a
bookkeeping row), merging kept the wrong one and dropped the tick. The
merge now ORs the completion, copies display fields from the real row,
takes the later of the two submission observations, and breaks ties on
a stable key, so the same row survives whichever order they are read.

### Treat a failed ledger read as a failure, not as an empty ledger
A read error used to look like an empty ledger, and a reconcile against
"empty" could age or flag everything. The read now throws; reconcile,
the completion record and the first-launch backlog decision abort with
nothing written; storage health counts read failures.

### Record announcements and release the task blob only after the save lands
An announcement is marked "processed" and the legacy manual-task blob
is removed only after the ledger confirms the save, so a failed save
cannot lose a task for good. The Ed equivalent is Olisa's and
unchanged.

### Have grade history report its own health
The grade-history store's file carries a version, reads the current
unversioned shape, and its save and load failures feed storage health.
A one-time legacy import that skips a course it cannot read no longer
bumps the version, so it is retried next launch.

### Keep "turned in" taps through a kill, and commit a swipe before it animates
A "turned in" tap on a lock-screen reminder is written to disk until the
dashboard consumes it, so it survives the app not running. The swipe
commits the completion to the ledger before the 0.38-second animation
rather than after (wired through the view model; see the fix-up).

## Privacy and ask links (group W5)

### Correct the privacy policy and mirror it onto the public page
**For a student:** `docs/PRIVACY.md` and the public privacy page now say
the same thing and say what is true today: a delete-and-reinstall
removes the ledger but leaves Keychain items (the saved PennKey
password, cookies, the feed link, the Ed token) on the phone; ask's
summary carries completion state; iCloud sync is opt-in and what it
carries; each ask request leaves one anonymous log row (outcome, token
counts, latency, model, never the question or answer); what the Chrome
extension and phone pairing move. The "Delete my class data" button,
which no longer exists, is gone from the text.
**Risk:** text only. Owner to rule on: whether a reinstall should sweep
the Keychain (plan item B2), and the App Store privacy label, which
still says completions never leave the phone.

### Open only Canvas and Ed links from an ask answer
**For a student:** a link inside an ask answer opens only if it points
at their Canvas or at Ed (`edstem.org`), over https; anything else is
dropped quietly. Source chips under the answer are unchanged, because
they point at course websites the phone itself collected.
**In the code:** `AnswerLinkPolicy` (pure rule, 12 tests) installed as
an `OpenURLAction` on the answer text.
**Risk:** low.

### Log course codes, hosts and class counts as private in Release
**For a student:** three Release log lines that carried a course code, a
host or a class count are now marked private, so they do not appear in
a sysdiagnose. DEBUG diagnostics (`LHF-RENEW`, `LHF-DIAG`) unchanged.
**Risk:** none.

## Backend (group W3): twelve commits, nothing deployed

Every one of these is a change to `backend/` that Olisa deploys when he
chooses; the app on the phone is unaffected until then. `deno task
check` is green on current Deno for the first time; `deno task test`
is 578 tests; the SQL grant test runs under an embedded Postgres
(PGlite) because there is no `psql` or Docker on this Mac.

### Type the backend timers so deno check is green
Five `TS2322 Timeout` errors fixed by typing timers as
`ReturnType<typeof setTimeout>`. No behaviour change.

### Close ask-canary behind a secret, clamp its overrides, cap ask's request body
**Why:** `ask-canary` let any app user pick the model and token cap on
LHF's OpenRouter key. Now it needs `x-lhf-probe-secret` matching the
`LHF_PROBE_SECRET` env var (404 for everyone until the secret is set),
the model comes from an allow-list, `maxTokens`, `reasoning` and
`provider` are clamped, and `ask`'s request body fields are capped
(document 400k chars, excerpts 100k, 40 history turns, question 20k).
**Dashboard:** set `LHF_PROBE_SECRET`, or undeploy the canary; export
the same value where `ask-probe.mjs` runs.

### Revoke the usage and quota functions from anon and authenticated
**Why:** the earlier migrations revoked from `public` only; Supabase's
default grants to `anon` and `authenticated` still let any user call
the usage RPCs and inflate the monthly counter. New migration
`20261027090000_revoke_usage_functions.sql`, default privileges, and the
SQL test now reproduces Supabase's default ACLs so it would catch this.
Also `directory_cache` is revoked from those roles (RLS alone was
holding it).

### Reserve the quota atomically before the model call
**Why:** the quota was checked before the stream and charged only after
a clean finish, so parallel requests and early hang-ups went uncounted.
Now one statement reserves a unit before the model call, tokens settle
in a `finally`, the upstream request is aborted when the client leaves
(`ask`, `extract-announcement`), and `extract-profile`, `map-categories`
reserve the same way. Refund rule: a unit comes back only if the request
never reached the model or failed before the student saw anything while
still connected; a client that hangs up is never refunded. Migration
`20261027100000_reserve_ask_usage.sql` must be applied before the new
`ask` is deployed, or it fails open (unmetered).

### Restrict discover-websites (plus its fix-up)
**Why:** the crawler would fetch any URL it was given, including private
addresses. Now https only, no credentials or odd ports, private,
loopback, link-local and metadata address ranges blocked after
resolving the name, internal-looking names refused, bodies capped with
a deadline, and every redirect re-checked. The host allow-list is
opt-in: with `LHF_DISCOVERY_HOSTS` unset any public https site is
allowed (course sites on their own domains keep working); set it to
narrow. If the Edge Runtime has no `Deno.resolveDns`, discovery refuses
fetches until an allow-list is set: check at deploy time.

### Pin the npm specifiers and ship deno.lock
Reproducible deploys. `sync/index.ts` has one type-only floating import
left, to pin on its next edit.

### Make delete-account idempotent
A second call for a user already gone returns 200, so the phone's retry
(Release A's P6, below) is safe to repeat.

### Stop logging and storing upstream error bodies
Provider error bodies can echo request text; only status and length are
kept now. Trade-off: an unfamiliar 4xx has to be reproduced on the
canary to be read.

### Make the monthly quota count sargable and index it
The monthly query no longer applies a function to the indexed column;
migration `20261027110000_ask_usage_month_range.sql`.

### Give requireUser's device_links lookup a deadline
A slow lookup no longer holds every function's auth step.

### Bound extract-profile with a time budget
40 s (`EXTRACT_PROFILE_BUDGET_MS`). Per-course charging was left out: it
is a product decision (one unit per sync vs one per course).

**Skipped on purpose (Olisa's sync):** BE-D (pool protection), BE-E
(caps), BE-G (course-material sync), BE-09, BE-10, the abandoned-user
TTL sweep. **Step 0 of the plan is still outstanding** (the live
`proacl` query, OpenRouter credit alerts, the anonymous sign-in rate
limit and CAPTCHA, disk alerts).

## Reminders, alarms and the background wake (group W2)

### Re-plan reminders and alarms after a background wake, without a prompt
**For a student:** work handed in on the web while the app was closed no
longer rings; a deadline moved earlier no longer rings late. The wake
re-plans from the fresh ledger through a path that can never show a
permission prompt from the background.
**Phone:** submit something on the web, let a background wake run,
check the alarm is gone.

### Plan alarms even when notifications are declined
AlarmKit is its own permission; declining notifications (the commonest
onboarding answer) no longer switches the Sweeper alarm off.
**Phone:** deny notifications, allow alarms, and the reverse.

### Give urgent reminders their slots first, free the buzz slots in alarm mode
Reminders due in the next ~48 hours are reserved first, the rest
round-robin by class, so a busy week never pushes tomorrow's reminder
out of iOS's ~64-request cap. In alarm mode the 30 slots kept for
buzzes are freed.

### Re-plan notifications by diff, count refusals, isolate one alarm's failure
Instead of removing every pending request and re-adding (a window in
which a kill loses them all), the plan is diffed against what is
pending; failed adds are counted; one AlarmKit failure gives that item
buzzes and leaves every other alarm standing.

### Pin the time zone on reminders' calendar triggers
A reminder planned in Philadelphia fires at the planned instant after
flying to Tokyo. **Phone:** change the time zone with a reminder
pending.

### Re-plan reminders from the ledger before the network at launch and foreground
The first thing a launch does for reminders is plan from what is on
disk; the fetch re-plans again when it lands. A slow network no longer
delays reminders.

### Let a background wake reuse the live AppState
A warm process no longer opens a second ledger container on the same
file; a cold background launch still opens its own, as before.

## Sessions, Keychain, Gradescope, iCloud (group W6)

### Keep Gradescope connected: no clock, no disconnect on one bad read
**For a student:** Gradescope no longer signs itself out after a day
away or after one failed read (the cause of reminders ringing for work
already handed in on Gradescope). Only a real login page, seen on two
syncs at least an hour apart, raises a "reconnect gradescope" line
beside the Canvas one; rows and cookies are kept throughout. A course
that reads empty is held for 24 hours before its rows age.
**Risk:** medium, it touches the Gradescope sync's outcome handling
(Olisa to review). **Phone:** does a Gradescope session survive 25
hours server-side? Leave the phone unopened a day, reopen, watch the
sync.

### Make Keychain writes safe, and give reads three answers
Every Keychain store (cookies, feed link, Ed token, backend identity,
Canvas token, PennKey, sync key) writes update-first, add-only-if-
missing, and checks every status; reads distinguish found, not found
and unavailable. A refused read no longer looks like "signed out"
(no banner), and never mints a new anonymous backend account. Items
written by 3.2.1 are found and updated, not duplicated.

### Sign in to the backend one caller at a time
Two concurrent first callers used to create two anonymous accounts and
orphan one. One in-flight task now, tied to an epoch that disconnect
bumps, so a late result cannot overwrite a newer identity.

### Stop iCloud prefs from deleting another device's settings
`push` can no longer remove a key this device did not remove; the only
removal is Canvas disconnect; the first enable merges with what iCloud
already holds (iCloud wins on a tie) instead of overwriting it.
**Not exercised on real iCloud.**

## Fix-ups from the independent reviews

Each group was read by a separate verifier before it was brought onto
the branch; these are the corrections that came out of that, each its
own commit so the review trail is visible.

- **Alarms:** a failed alarm cancel is retried once before it is
  reported, so a finished item cannot ring after a background wake; the
  pending-notifications read has a five-second deadline (on timeout the
  pass skips stale removal, adds the plan, and counts it); three test
  suites lost their suite-level main-actor mark so the planner's
  nonisolated rule is actually exercised.
- **Backend:** a crawl the fetch rules refused is skipped rather than
  retiring a course's website documents for a week; `http://` links are
  upgraded to https before the guard; a course that always overruns the
  profile budget cools down for 24 hours instead of being re-charged on
  every sync (new migration `20261027120000_profile_budget_cooldown.sql`);
  two comments corrected.
- **Sign-in edges (W1a):** the server-deletion retry gives up on a
  permanent refusal and never mints an account just to delete it; rows
  whose due date the student edited survive a disconnect; two comments
  and the Settings retry line corrected.
- **Ledger (W1b):** the swipe is actually wired (ledger write before the
  animation, through the view model), the legacy grade-history import is
  retried when a course could not be read, and the merge rule takes the
  later submission observation and documents which fields win.
- **Sessions (W6):** the "reconnect gradescope" cover shows the login
  pane (it showed "connected" before); a connected Gradescope with no
  cookies at all counts toward "reconnect" so a restored phone is not
  silent forever; a legitimately empty Gradescope stops being reported as
  a failed refresh after 24 hours; the backend sign-in's recovery path
  checks the epoch so a stale flight cannot wipe a newer identity; one
  comment softened.
- **Kit (W4):** the app itself opens the ledger through the versioned
  door (it was only the widget); recurring-task ids are re-keyed once on
  upgrade for phones outside Eastern time; an unreadable element in a
  student-authored blob is kept aside before the next save; the question
  cap keeps head and tail so a long paste keeps its question.

## A trap found while integrating

Seven `swift test` runs in seven worktrees at once share one scratch
defaults domain on the Mac (`swiftpm-testing-helper`, which is where
`UserDefaults.lhf` lands under the test runner). A run killed mid-way
(the usage-limit cutoff did this) leaves another run's fixtures behind,
and suites that read course preferences or the announcement switch then
fail in a third run, in isolation, with no code to blame. Clear the
domain (`defaults delete swiftpm-testing-helper`) when no run is
active, then re-run. Recorded in CLAUDE.md's traps.

## Integration commits

Four small commits joined the groups: two test suites written in
parallel read the ledger's completion record non-optionally after the
ledger group made it optional (a read failure is never an empty ledger);
the recurring re-key skips a launch whose ledger cannot be read or whose
copies did not save, and leaves its once-only flag unset; and the
Gradescope sign-in pane's success check honours the reauth verdict, the
one-line follow-up the sessions group named.

## Skipped on purpose, and why

From `docs/HARDENING_PLAN_2026-10-25.md`:

- **A6** (banner only when a person is needed; judging renewal outcomes;
  WebView process death) and **A9** (one renewal per process; disconnect
  always wins): both rewrite `CanvasSessionRenewer` and the login
  observer, Olisa's proven sign-in code; Marco asked to see A6 as a plan
  first. The plan's text stands; nothing was coded.
- **A7's renewer half** (the liveness probe before the renewer's merge):
  same reason; only the Grade Watcher half landed.
- **B2** (what a reinstall does): a policy decision for Marco. The
  privacy text now states today's behaviour truthfully instead.
- **B5's Ed half, B8's Ed wire decode, D8's Ed tag bound, P5's fill
  script and Ed launch URL, B13/C7's sync deadlines, D4, D6, BE-D, BE-E,
  BE-G, BE-09, BE-10:** Olisa's sync and Ed code.
- **B4's device-sync twin fix, B15's device-sync log re-key:** `Kit/Sync`,
  Olisa's. One-line fixes are named in the commits.
- **C3** (announcement finds don't ring), **C8** (alarm sound length),
  **C10** (a quiet line when reminders can't arrive), **the visibility
  line and the owner-only export:** product and copy calls for Marco.
- **D3, D5, D7:** "measure first" items; no Instruments run exists yet.
- **P2** (pairing confirmation code): changes the pairing protocol on
  the phone, the backend and the extension together.
- **BE-12's per-course charging:** a product decision (one unit per
  sync or per course).
- **Backend step 0** (the live `proacl` query, OpenRouter credit alerts,
  the anonymous sign-in rate limit and CAPTCHA, disk alerts): needs the
  dashboard.

## Decisions for Marco

1. Reinstall policy (B2): sweep the Keychain on a fresh install, or keep
   today's "a reinstall is not a clean sign-out" and leave the text as it
   now reads.
2. Show the raw error on a failed Penn connect, or keep the fixed
   sentence (an existing test pins the fixed one).
3. Should announcement finds ring the loud alert (C3)? Today they do.
4. One quiet line when reminders cannot arrive (C10): label text.
5. The disconnect confirmation copy, now that finished work is kept.
6. The `<key>.unreadable` copies: surface them, clean them up, or leave.
7. The Chrome extension keeps anonymous Ed posts the app drops (found by
   the parity test); a rule in `chrome-extension/src/core/ed.js` is
   needed.

## What only a phone can answer

In the order the plan gives, plus what the groups added:

1. A3: `-LHFSessionDiagnostics` then `-LHFAgeCanvasSession` on Marco's
   phone; expect `canvasSessionExpired false -> true` and a renewal.
2. A2: reconnect from a Profile row, the banner and the grades screen;
   the xmark on every step; the refresh after closing; airplane mode,
   force-quit, reopen → dashboard.
3. A4: does a Gradescope session survive 25 hours server-side? Leave the
   phone unopened a day and watch the sync; "reconnect gradescope" after
   two login pages an hour apart.
4. A8: a failed Penn connect shows "try again"; the "save pennkey" row.
5. B1: disconnect, relaunch; finished work still in prev; the Settings
   retry line while offline.
6. C1/B13: a background wake drops a finished item's alarm and reuses the
   live `AppState` (`_simulateLaunchForTaskWithIdentifier:` on a debug
   build).
7. C2: notifications denied, alarms allowed, and the reverse; the
   AlarmKit prompt may now appear in the foreground for a student who
   declined notifications.
8. C6: change the time zone with a reminder pending.
9. C4/C5: six classes, every lead time: pending requests at most 60.
10. B10: swipe, then kill the app within a second; the tick survives.
11. B15: a phone outside Eastern time keeps its recurring ticks after
    the upgrade.
12. D: Instruments App Launch and Time Profiler on a six-class account
    before D3-D7 are attempted.

## Olisa's deploy checklist (backend, nothing deployed)

1. Apply `20261027100000_reserve_ask_usage.sql` first, then
   `20261027090000_revoke_usage_functions.sql`,
   `20261027110000_ask_usage_month_range.sql` and
   `20261027120000_profile_budget_cooldown.sql`. Confirm `proacl` in
   `pg_proc` shows `service_role` only for the usage functions.
2. Set `LHF_PROBE_SECRET` (or undeploy `ask-canary`); export the same
   value where `ask-probe.mjs` runs.
3. Deploy `ask`, then check `ask_usage` rises by one per question and no
   `reserve_ask_usage … failing open` lines appear.
4. Deploy `discover-websites` once and check the logs for
   `netguard: this runtime cannot resolve DNS`; if it appears, set
   `LHF_DISCOVERY_HOSTS` or add a resolver.
5. Deploy `extract-announcement`, `extract-profile`, `map-categories`,
   `delete-account`, `ask-canary`. Redeploying `sync`, `device-sync` and
   `pair` picks up the shared auth deadline and pinned imports.
6. Step 0 of the plan: the live grants query, OpenRouter credit alerts,
   the anonymous sign-in rate limit and CAPTCHA, disk alerts.
