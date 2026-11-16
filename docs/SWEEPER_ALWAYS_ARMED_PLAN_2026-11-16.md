# Plan: the Sweeper stays armed, and the cancel becomes reliable

Written 2026-11-16, after Marco read `docs/SWEEPER_STATUS_RESEARCH_2026-11-16.md`
and reversed one decision of the 2026-11-04 plan
(`docs/REMINDER_SUBMISSION_FIX_SESSION_PROMPT.md`): there will be no "no
alarm unless confirmed" mode. His words: "no dont want no alarm option as
this cd lead to someone missing an assignemnt". So the loud alarm is
registered ahead of time, as today, and every part of this plan is about
cancelling it in time when the work is handed in. The trade is an
occasional wrong ring over a missed one. The 2026-11-04 plan's parts 1 to
3 stand; its part 4 is replaced by what is below. Nothing here is built.

## What the platform allows, in one paragraph

The research settled the shape. An AlarmKit alarm is the system's; no code
of ours runs when it fires, so the ring cannot be gated. Cancelling needs
our process, and iOS lends it to a closed app only three ways: a background
refresh at a time it picks, a silent push from our server at a minute we
pick (best effort, Apple asks for no more than two or three an hour, and
nothing after the student force-quits), and a Notification Service
Extension on an alert push, which runs even after a force-quit but, as far
as Apple documents, cannot touch an alarm. Canvas gives the student's cookie
session one cheap read across every course, `GET /api/v1/planner/items`
over a date window, whose `submissions.submitted` says whether each item is
in. That read is the heart of every phase.

## Phase 1: the phone alone (no server, no key, no privacy change)

Ships first and on its own. Ends the 2026-11-03 case (submitted fifteen
minutes before the ring with Smooth open) outright.

1. **Cancel at observation.** When `updateSubmissionState` or the
   Gradescope scrape learns an item is submitted, remove its pending
   `due:<id>:*` requests and its AlarmKit alarm right there, and stop it
   if it is ringing; the plan-diff removal in `applyNotifications` stays
   as the backstop. Pure test: a fed observation removes exactly that
   item's identifiers and nothing else.
2. **A submissions-only read, `SubmissionStatusClient`**, a small client
   beside `CanvasGradesClient`, not inside Olisa's sync. One call,
   `planner/items?start_date=<today>&end_date=<today+2>&per_page=100`,
   with the saved cookies; returns the set of Canvas assignment ids whose
   `submissions.submitted` is true. Exempt from the 15-minute grades
   throttle. On a 401 it reports a dead session and nothing else; on a 403
   it backs off for the rest of the hour (Canvas's throttle answers 403;
   the headers may be absent for cookie requests). Never writes the
   ledger; its only output is the id set handed to `applySubmissionState`
   and then part 1's cancel.
3. **Last-hour cadence while open.** On the 5-minute tick as before; every
   60 seconds while any non-completed, submittable item is due within 60
   minutes and the scene is active. Pure test of the cadence rule with a
   fixed clock.
4. **One read on the way out.** When the scene goes to the background with
   such an item pending, run the read once inside
   `beginBackgroundTask` (about 30 seconds): the last thing the phone does
   before it may be frozen for the hour is check. Cheap and, unlike every
   other closed-app route, certain to run.
5. **The background wake does the same.** `LHFBackgroundRefresh.run()`
   calls the read before `refreshCanvasGrades` with the throttle bypassed,
   then replans as it already does. Add the DEBUG `LHF-BG` line in
   `UserDefaults.lhf` (time, what ran, how long) and watch Marco's phone
   for 48 hours; if no wake arrives, say so in Known gaps rather than
   faking one with a timer.
6. **The alarm's own buttons check too.** The stop and "turned in" intents
   already run our code on a tap. Stop should run the read before opening
   Canvas: if the item is in fact submitted, mark it done exactly as a
   swipe would, so a wrong ring costs one tap and no Canvas page. Pure
   test on the intent's decision table.
7. **Never-ring rules, as data.** Beside today's exclusions (nothing to
   submit, recurring, found exams), skip `points_possible == 0`,
   `omit_from_final_grade`, and titles naming optional, practice, survey,
   extra credit, ungraded or attendance; a Gradescope-only item rings only
   while the last scrape inside the hour still said "No Submission". Each
   rule a pure function with a test; a DEBUG row per item says why it did
   or did not qualify.
8. **Measure wrong rings.** On a DEBUG build, when an alarm or buzz is
   handled, record whether the item was already submitted at that moment
   (`sweeperRingLogV1`, counts and times, no titles). This is how the
   owners learn whether phase 2 is needed and whether it worked.

Effort: about five days with tests, plus the 48-hour watch. Gate:
`swift test --no-parallel` alone on the Mac, the iOS build, Marco's phone.

## Phase 2: the server as a timer (the closed-app case)

The only route that reaches a closed app at a minute we choose. Needs the
owners' yes to the one question in the research doc and two things from
Olisa.

**What the server holds.** Per install: an APNs device token and a set of
wake minutes. No course, no item, no session, no name. A row dies with the
install's anonymous account (`delete-account`) and on Canvas disconnect.
`docs/PRIVACY.md` gains one paragraph in the same commit.

**Setup, Olisa's half.** As Account Holder he creates an APNs
authentication key (`.p8`, Key ID, Team ID) in the developer portal and
turns Push Notifications on for the bundle id; the key goes into a
Supabase secret, never the repo. Marco adds the `aps-environment`
entitlement and `remote-notification` background mode and registers for
remote notifications at launch (no permission prompt: silent pushes need
none).

**Backend.** A migration for `wake_requests(user_id, device_token, wake_at)`
with RLS by user; a `push-register` route (reuse `device-sync`'s style:
anonymous JWT, `X-Smooth-Version` gate) the phone calls with its token and
its next wake minutes, replacing the previous set; a `wake` Edge Function
that `pg_cron` calls every minute, selects rows with `wake_at` in the past
minute, signs an ES256 JWT (refreshed between 20 and 60 minutes, as Apple
requires) and POSTs to `api.push.apple.com` with `apns-push-type:
background`, `apns-priority: 5`, `apns-expiration` a few minutes out, an
empty `{"aps":{"content-available":1}}` payload, then deletes the rows.
First test is whether an Edge Function's `fetch` speaks HTTP/2 to APNs; if
not, the Vercel front (`backend/connector-front/`) sends it. Deno tests
with a fake APNs; a `node` probe that sends one push to Marco's phone.

**Phone.** `didReceiveRemoteNotification` runs the phase 1 read and
cancel, then replans, inside the 30 seconds; it logs an `LHF-BG` line
("push wake"). The wake minutes the phone registers: for each armed alarm,
due minus lead minus 5 (so the check lands before the ring) and due minus
lead minus 20 (a second chance, since one push may be held), de-duplicated
to the minute so every item due at 11:59 PM is one push. That is at most
two pushes per deadline cluster, inside Apple's "two or three per hour".
Registration is refreshed at every replan and at every `applyNotifications`
diff; a phone with nothing armed registers nothing.

**What it does not cover, said plainly.** A force-quit app (iOS discards
the held push), a push iOS chooses not to deliver, Low Power Mode when iOS
decides so. In those cases phase 1's rules still ring, and the alarm's
Stop button (phase 1, item 6) makes the wrong ring cost one tap.

Effort: about six days, Olisa's key and secret aside; a week of watching
`sweeperRingLogV1` and the `LHF-BG` lines on two phones before calling it
proven.

## Phase 3: if phase 2's pushes prove unreliable

Build only on evidence from phase 2's week. **The alert-push variant with a
Notification Service Extension**: the server sends an alert push at the
same minute; the extension, holding the Canvas cookies through a shared
Keychain access group, runs the read and rewrites a "not turned in" buzz
into a passive "turned in" line when the work is in. It runs after a
force-quit. It cannot drop itself without Apple's filtering entitlement
and cannot cancel the AlarmKit alarm, so it improves the buzz fallback
only; the alarm still rings for a force-quit app. About five days, and a
review risk of a second process holding cookies.

**The extension poke** (Penn, paired laptops): the Chrome extension polls
Canvas inside the last hour and, on seeing a submission, asks the server
to send the phone a wake push now. The server learns only "wake this
device". About three days after phase 2, and Olisa's, since it is his
extension.

## Boundaries

- The alarm is always armed for a qualifying item. No phase adds a
  confirmed-only mode.
- Olisa's sync and Ed code are not touched; the read is a new client.
- Nothing leaves the phone in phase 1. Phase 2's device token and wake
  minutes are the only addition, disclosed in `docs/PRIVACY.md` in the
  same commit.
- Copy stays minimal: no new Settings prose; DEBUG rows only.
- Every phase compiles and passes `swift test --no-parallel` alone on the
  Mac, builds for iOS, and is installed on Marco's connected phone (check
  which build is there first) before it is called done.

## What the owners decide

1. Phase 2 at all: may the server hold a device token and wake minutes per
   install? (Marco and Olisa.)
2. The APNs key and the push capability on the bundle id. (Olisa, as
   Account Holder.)
3. The wake minutes: due minus lead minus 5 and minus 20 are the first
   values; one push instead of two keeps further inside Apple's guidance
   at the cost of the second chance.
