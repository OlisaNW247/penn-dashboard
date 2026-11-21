# Fewer wrong rings after a force-quit: the check moves into a notification extension

Written 2026-11-21, research only: nothing here is built, deployed or on a
phone. Marco's ask, the same day: research another way to give the Sweeper
fewer false alarms, "even if it means a more conservative smooth sweeper",
and in particular whether the alarms could be tied to "our server" instead
of the app, since a force-quit app cannot cancel anything. He asked how a
senior engineer at a company like Microsoft would solve it.

This builds on three documents and does not repeat them:
`docs/SWEEPER_STATUS_RESEARCH_2026-11-16.md` (every iOS mechanism that runs
code while the app is closed, with Apple's words), `docs/SWEEPER_ACCURACY_PLAN_2026-11-16.md`
(the always-armed alarm and the cancel), and `docs/SERVER_SWEEPER_DESIGN_2026-11-17.md`
(the `sweeper-wake` timer, built 2026-11-18 and not yet deployed). Read
against `claude/ambassador-header` at `279b14f`.

## 0. The answer in one paragraph

No: iOS has no API that lets a server ring, set or cancel an iPhone alarm.
AlarmKit runs on the phone only. A server can only send a push, and the push
that has been built (`_shared/apns.ts`, `content-available`, a background
push) is the one kind iOS throws away after a force-quit. There is a second
kind that a force-quit does not stop: an **alert push with
`mutable-content`**, which iOS hands to a **Notification Service Extension**,
a small separate program of ours that runs on the phone for about 30
seconds. The extension can read Canvas with the cookies already on the
phone, so the server still knows nothing about the student's work. Earlier
research set this route aside on one assumption: that the extension cannot
cancel an AlarmKit alarm. Nothing Apple publishes settles that, and today's
reading of the SDK and of the alarm daemon's code points the other way (§3).
**One test of about two hours on Marco's phone settles it (§6).** If it
passes, the server's wake-ups change from background pushes to content-free
alert pushes, the new extension does the cancel, and a submission made on
the website with Smooth force-quit no longer rings, with the same privacy
rule as today. If it fails, §5 lists what is still worth doing. Two small
fixes found along the way stand on their own (§4).

## 1. How the big companies do "remind me unless it's done"

There are two patterns. Smooth can use only the second.

**They own the truth.** Outlook, Microsoft To Do and Google Tasks hold the
task on their own servers. When you finish it on a laptop, the server knows
at once, and the reminder is a push the server simply never sends. The
phone decides nothing. Smooth's truth is Canvas's submission record, which
only the student's own login can read. Copying the pattern would mean a
server holding a Canvas credential. The privacy rule forbids that
(CLAUDE.md, intro), and Penn doesn't issue the credential anyway
(CLAUDE.md, Traps, "Penn restricts student Canvas access tokens"). The
version a big company would actually build is an institutional agreement:
Penn issues a Canvas developer key, the server holds a token scoped to
`url:GET|/api/v1/planner/items`, and it reads the planner at due−N before
deciding whether to push. That needs Penn's Canvas admins, and it would
mean the server sees submission state, which the owners would have to
choose to allow and disclose. It is recorded here so nobody has to look it
up again, and it is not recommended.

**They send a push that says nothing, and let the phone decide.** This is
how end-to-end encrypted messengers work. The server can't read the
message, so it sends a push with no content. The service extension on the
phone fetches the real data with keys only the phone holds, then decides
what to show. Smooth's wake already says nothing: the server holds a device
token and some minutes. The one thing missing is the extension. A
force-quit stops the app, not its extensions. DTS on Apple's forums says
the service extension "will indeed run even after the app has been
force-closed. It runs in a separate process"
(developer.apple.com/forums/thread/782103, cited in the 2026-11-16 research
§1).

## 2. What changes from the wake already built

The server side barely moves. The table, the `pg_cron` tick, the minutes
(`fireDate − 15 min` and `− 3 min`), the 24-in-48-hours cap and the delete
paths all stay as built (`SweeperWakePlan.moments`, `sweeper-wake`). What
changes is the request `_shared/apns.ts:169` sends:

- `apns-push-type: alert` instead of `background`, and `apns-priority: 10`
  (5 is allowed too). Only an `alert` push reaches a service extension. The
  filtering entitlement below also requires `alert`: "Otherwise, the
  system always displays the notification banner"
  (…/bundleresources/entitlements/com.apple.developer.usernotifications.filtering).
- `apns-expiration` set to the ring minute, so APNs drops a push held for an
  offline phone instead of delivering it after the ring.
- A body with no content in it: `{"aps":{"alert":{"title":"smooth","body":"checking your next deadline"},"mutable-content":1,"interruption-level":"passive","thread-id":"sweeper"}}`.
  That text shows only if the extension fails. At `passive` it is quiet by
  Apple's definition: "the system adds the notification to the notification
  list without lighting up the screen or playing a sound"
  (…/usernotifications/unnotificationinterruptionlevel/passive). The
  server still learns nothing about which work is due. That is the
  difference from the 2026-11-16 plan's §2.10, which would have sent each
  buzz's class and title to the server. That's not needed: the extension
  fills in the title from the phone.

On the phone, three new pieces:

1. **A sweep manifest, written by the app.** At every replan, for each wake
   minute, the app writes to the App Group the items whose ring that minute
   covers. For each item: its Canvas assignment id, its title, every
   AlarmKit id the Sweeper could have armed for it, and its pending `due:`
   and `loud:` request ids. Those are the ids `SubmissionObservation.cancellations`
   already computes; the AlarmKit ids are pure, from
   `BerserkAlarmPlan.alarmID(assignmentID:fireDate:sound:)`
   (`BerserkAlarmPlan.swift:241`). The extension then never opens the
   SwiftData ledger. The manifest stays on the phone.
2. **The extension** (a new target beside `LHFWidget`). When a push arrives,
   it reads that minute's manifest and reads the saved Canvas cookies from a
   Keychain group shared with the app. It makes one `planner/items` GET for
   the window (the same request `CanvasStructuredSourcesClient.fetchPlannerWindow`
   builds) and runs `SubmissionRead.verdicts(fromPlanner:)`. Then, item by
   item:
   - **Submitted.** Cancel the item's AlarmKit alarms, which is the thing
     §6 tests. Remove its pending `due:`/`loud:` requests. Put the item id
     in an App Group inbox that the app folds into
     `structuredCompletedItemIDs` at its next launch, so the ledger keeps a
     single writer. Rewrite the line to a passive "PS7 is in · sweeper's
     off".
   - **Unsubmitted.** Touch nothing. The line becomes "PS7 · not turned in
     yet", either passive or time-sensitive as the first of the three
     buzzes (Marco's call; passive adds no noise).
   - **Unknown** (no cookies, a 401, a timeout). Touch nothing, and leave
     the generic line. This is the rule already in `SubmissionRead`: an
     unknown read never disarms.

   The extension types no password and opens no web view or Duo prompt. It
   makes one read-only GET.
3. **Cleanup.** When the app next comes to the foreground, it removes the
   delivered `thread-id: sweeper` lines.

**Every failure leaves the alarm as armed**, which is today's behaviour, so
no failure makes the Sweeper quieter. The cases: the student turned
Smooth's notifications off (no alert is delivered, so the extension never
runs), the phone was offline through the ring, the session was dead, or
Canvas didn't answer within the extension's time. That keeps Marco's rule
("no dont want no alarm option as this cd lead to someone missing an
assignemnt", 2026-11-16).

**Optional: Apple's filtering entitlement.** With
`com.apple.developer.usernotifications.filtering`, the "is in" case can be
fully silent: an empty content object "silence[s] push notifications after
your extension receives them" (same page). Apple grants it on request
(developer.apple.com/contact/request/notification-service). The case to
make is a privacy one: the push says nothing, the check happens on the
phone, and nothing about the student's work leaves it. The odds are
unknown. Without the entitlement, a passive line that the app clears later
is the floor, and the design does not depend on getting it.

**What it costs**, beyond the APNs setup the built wake already waits on
(Olisa's steps, CLAUDE.md → Known gaps):
- A second process holds the Canvas cookies. `SessionCookieStore` moves its
  items to a shared Keychain access group, and every reader of it gets
  re-read; the 2026-11-16 research rated this "moderate", of the same kind
  as the hidden renewer. The extension must read the raw saved cookies,
  not `load()`'s 24-hour-gated view: the trap fixed in `890bd11` today
  applies here too.
- A new target in `project.yml`. Adding a target means regenerating the
  project, so the xcodegen trap applies: every Info.plist key goes in
  `info.properties`.
- One sentence in `docs/PRIVACY.md` → "A wake-up call for the Sweeper": the
  wake now arrives as a notification with no content, and the check runs
  on the phone.
- Roughly 4 to 5 days after the test passes, most of it the extension, the
  manifest and the Keychain move. The server change is an afternoon.

## 3. The new evidence on AlarmKit from an extension

Read 2026-11-21 on this Mac (Xcode 26.6, iPhoneOS 26.5 SDK, the iOS 26.5
simulator runtime):

- **The SDK lets an extension call it.** In
  `AlarmKit.framework/Modules/AlarmKit.swiftmodule/arm64e-apple-ios.swiftinterface`,
  `AlarmManager`, `schedule`, `cancel(id:)`, `stop(id:)`, `alarms` and
  `authorizationState` carry only `@available(macCatalyst, unavailable)`.
  None carries `iOSApplicationExtension, unavailable`, the mark Apple uses
  for APIs that extensions may not call. So an extension that calls
  `cancel(id:)` compiles. That alone proves nothing about runtime.
- **The alarm daemon knows how to map an extension to its app.**
  `AlarmKitCore.framework` (the private core behind the daemon) identifies
  each caller by audit token and bundle id (`BSAuditToken`, `bundleID`,
  `authorizationStateForBundleID:`). It contains `containingBundleRecord`,
  the LaunchServices property that leads from an app extension's record to
  its parent app's, and a private `com.apple.private.alarmkit.bundleIdentifier`
  entitlement. Apple's daemons use that lookup when they let an extension
  act for its app, as UserNotifications does. It may also be there only for
  the widget extension that draws the alarm's Live Activity, since a log
  line beside it reads "Cancelling activity with UI provided by the app's
  widget extension".
- **Apple's pages say nothing either way.** `alarmkit/alarmmanager`,
  `cancel(id:)` and `schedule(id:configuration:)` list iOS 26.0 with no
  extension note (read through the developer JSON mirror, 2026-11-21).

So the earlier "assume not until a device says otherwise" was the right
default, but the evidence now leans the other way. That makes the device
test worth its two hours.

## 4. Two fixes that need none of this

**An excused item can never be cancelled by the last-hour poll or a push
wake.** Canvas's planner sends `submitted`, `excused`, `graded`, `missing`
and more for each item (canvas-lms `lib/api/v1/planner_item.rb`, lines
220–226 on master, read 2026-11-21). Smooth decodes `submitted`, `missing`
and `graded` (`CanvasStructuredSources.swift:118-121`), but not `excused`.
`SubmissionRead.verdicts(fromPlanner:)` (`SubmissionRead.swift:42`) looks
only at `submitted` and the planner tick. So when an instructor excuses a
student, the item reads `.unsubmitted`, and only a later grades fetch
(whose `graded` workflow state does count) can silence it. Decode `excused`
and let `excused == true` cancel. Leave `graded` without `submitted` as it
is. An instructor can post a placeholder grade before the work is in, and
silence is the dangerous side. This is about an hour with a test.

**The data half of the optional-work rule needs no word list.** The
2026-11-18 build left out "the zero-points and optional-title rules"
because "the word list needs Marco's word" (CLAUDE.md, Profile → reminders).
The title words do need him. But `points_possible == 0` and
`omit_from_final_grade` are facts Canvas states, and they could ship ahead
of the word list as buzz-only, the same delivery `isBuzzOnly` gives
external-tool work. Buzz-only, not quiet, so nothing that rang today goes
silent.

## 5. If the test fails

If AlarmKit refuses the extension, the extension can still remove the
three buzzes and the reminders (if its notification center reaches the
app's pending requests, which the same test checks) and post the passive
"is in" line. The AlarmKit alarm would still ring, so on iOS 26 with alarms
allowed, nothing improves for the alarm itself. Two options remain, both
Marco's call:

- **Ring in two stages.** The Sweeper's first loud moment at due−N becomes
  the push-checked buzz, and the AlarmKit alarm moves later as the backstop
  (say due−3). Work turned in before due−N is silenced by the extension.
  Work turned in between due−N and due−3 with the app force-quit still
  rings, but in a narrower window than today. The cost: the alarm itself
  comes later.
- **A countdown before the ring.** AlarmKit can combine a schedule and a
  countdown ("either, or both", Apple's sample,
  …/alarmkit/scheduling-an-alarm-with-alarmkit), and its countdown is
  drawn as a Live Activity on the Lock Screen. The Sweeper could show
  "PS7 · rings in 14:59" with a "turned in" button for the last stretch,
  and a tap runs our intent in our own process (a `LiveActivityIntent`,
  2026-11-16 research §1). This needs no wake, and a wrong ring becomes a
  one-tap pre-emption. One thing is unread: whether a schedule plus
  `preAlert` means "count down, then ring at the scheduled minute" or
  "ring at the minute, then count down". That's a 10-minute check on the
  same phone.

Not worth more time: notification actions as a cancel path after a
force-quit (forum reports conflict; developer.apple.com/forums/thread/826318
and /769303), Critical Alerts, PushKit, location wakes, and Live Activity
push updates of the alarm's own activity. The 2026-11-16 research covers
why.

## 6. The test, in order

On Marco's phone, a Debug build of the release line, read through the
`debugWakeLogV1` trace and the App Group plist (CLAUDE.md, Commands). Check
whether another thread has a build on the phone first (memory: the phone is
shared).

1. **No push needed, about 30 minutes.** In the widget extension, which
   already exists, have the timeline provider read
   `AlarmManager.shared.alarms.count` and write it with a timestamp to the
   App Group. Show it on a DEBUG row. Arm one Sweeper alarm, then reload the
   widget. If the widget sees the app's alarm count, the daemon is mapping
   the extension to the app. If it sees zero while the app sees one, the
   answer is almost certainly no, and step 2 can be skipped.
2. **One push, about 90 minutes.** Add a throwaway service-extension
   target. When a push arrives, it (a) lists `AlarmManager.shared.alarms`,
   (b) cancels a test alarm the app armed ten minutes out, (c) removes a
   pending test local notification, and (d) reads one Keychain item through
   a shared access group. It writes each result to the App Group. Force-quit
   Smooth, then send one alert push with `mutable-content: 1` to the
   phone's token from Apple's Push Notifications Console
   (developer.apple.com/notifications/push-notifications-console). The
   console needs no `.p8` key or server, but it does need Push
   Notifications enabled on the App ID, which is Olisa's first step already
   on the list. Wait out the ten minutes.

   **It passes** if the test alarm does not ring, the test notification is
   gone, and the log shows all four results. Pass: build §2, with §4 beside
   it. Fail at (b): §5.
3. **The countdown semantics** (§5), at the same sitting, whatever 1 and 2
   say.

## 7. Recommendation

1. Ship the two fixes in §4 with the next Sweeper change; they need no
   decision except the data rule's buzz-only delivery.
2. Run §6 before building anything else for the force-quit case. It costs
   two hours and decides between a real fix and a narrower one.
3. If it passes, build §2 instead of deploying the silent-push wake as it
   is. The wake's server code carries over almost whole, and the
   background push would then add nothing the alert push doesn't already
   do.
4. Apply for the filtering entitlement whatever the result. It costs a form,
   and the privacy argument is a good one.

## Sources

Opened 2026-11-21:
- Apple, through `developer.apple.com/tutorials/data/documentation/<path>.json`:
  `alarmkit`, `alarmkit/alarmmanager`, `alarmkit/alarmmanager/cancel(id:)`,
  `alarmkit/alarmmanager/schedule(id:configuration:)`,
  `alarmkit/alarmmanager/alarmconfiguration`,
  `alarmkit/alarm/countdownduration-swift.struct` (and `/prealert`,
  `/postalert`), `alarmkit/scheduling-an-alarm-with-alarmkit`,
  `usernotifications/unnotificationserviceextension`,
  `usernotifications/unnotificationinterruptionlevel/passive`,
  `usernotifications/unnotificationactionoptions/foreground`,
  `bundleresources/entitlements/com.apple.developer.usernotifications.filtering`.
- The iPhoneOS 26.5 SDK's AlarmKit Swift interface, and `strings` over
  `AlarmKit`, `AlarmKitCore` and `AlarmKitFoundation` in the iOS 26.5
  simulator runtime.
- canvas-lms `lib/api/v1/planner_item.rb` (raw.githubusercontent.com, master).
- Apple's Push Notifications Console page (search result; the page was not
  read in full, so which team role it needs is unverified).
- Forum threads on notification actions after a force-quit, read only as
  search summaries: developer.apple.com/forums/thread/826318, /769303,
  /736576.
- dev.to "What three months of shipping an AlarmKit app taught me" (a
  developer's account: `cancel` does not stop a ringing alarm, `stop`
  does; consistent with `BerserkAlarmScheduler+Alerting.swift:54-55`).

Cited from the 2026-11-16 research, not re-opened: the DTS thread on
service extensions after a force-quit (/forums/thread/782103) and the
background-push wording ("two or three per hour", "if something force quits
or kills the app, the system discards the held notification").
