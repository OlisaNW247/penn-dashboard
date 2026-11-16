# Better access to assignment status, so the Sweeper rings only when it must

Written 2026-11-16, research only: nothing here is built, deployed or on a
phone. Marco's ask: "research other potential ways to help smooth have
better access to assignment status, super important that like smooth
sweeper only goes off when it needs to." The plan already written for the
first fix is `docs/REMINDER_SUBMISSION_FIX_SESSION_PROMPT.md` (2026-11-04,
agreed by Marco, not started); this document places it among every other
route found, and names the one question only the owners can answer.

Every claim below rests on a page opened on 2026-11-16, named beside it.
Apple's documentation pages render client-side and return only a title to
a plain fetch, so they were read through Apple's own JSON mirror of each
page (`developer.apple.com/tutorials/data/documentation/<path>.json`); the
human URL is the one cited. Where the only source is a forum post, it
says so. Where a page could not be opened, the claim is marked unverified
rather than quoted from memory. The research passes were run by
subagents and the two claims the recommendation leans on hardest (how
Canvas keys a cookie request for throttling, and the planner's
`submitted` field) were re-read from the canvas-lms source by a second
pass.

## 0. The finding in one paragraph

No iOS mechanism runs our code at an exact chosen time once the student
has force-quit the app, and the three things that do fire at an exact
time (a local notification, an AlarmKit alarm, a Time Sensitive
notification) fire without running any code of ours. So "check Canvas at
the moment the Sweeper rings" cannot be built on this platform. What can
be built is the reverse: never register a loud alarm until a fresh read
of Canvas has confirmed the item is still unsubmitted, cancel it the
moment a later read says otherwise, and arrange as many chances for that
read as iOS allows. Those chances are: the app being open (certain), a
background refresh (best effort, learned from the student's habits), and
a push from our own server at a chosen minute (best effort, "two or three
per hour" in Apple's words, never after a force-quit). The one mechanism
that does run our code after a force-quit at a server-chosen minute is an
alert push with a Notification Service Extension, and it can read Canvas,
but it cannot cancel an AlarmKit alarm as far as Apple documents, and it
cannot drop its own notification without an entitlement Apple grants by
request. Canvas offers the student's app one cheap, cookie-readable call
that covers every course at once (`planner/items`, with a `submitted`
flag per item), no push, no webhook and no email a student app could use.
Gradescope offers one HTML table per course and an email receipt.

## 1. What runs our code while the app is closed, and when

The short answers first, then each mechanism. "Exact time" means our
code runs at due-minus-N minutes because we asked for that minute.

| Mechanism | Runs our code? | At an exact time? | After force-quit? | How often |
|---|---|---|---|---|
| BGAppRefreshTask | yes, 30 s | no, a floor only | no (DTS, forum) | learned from usage; off in Low Power Mode |
| BGProcessingTask | yes, minutes | no | once, then waits (DTS, forum) | system-chosen, "system friendly times" |
| BGContinuedProcessingTask (iOS 26) | yes | no; starts from a tap | no, cancelled | user-started only |
| Silent push (`content-available`) | yes, 30 s | server-chosen minute, best effort | no, held push discarded | "two or three per hour" |
| Alert push + Notification Service Extension | yes, about 30 s, in its own process | server-chosen minute, when delivered | yes (DTS, forum) | per alert push |
| Live Activity push | no | n/a | not documented | hourly budget |
| AlarmKit alarm | no, only a button's intent | yes, exact | yes, "persist regardless" (Apple FAQ, forum) | no documented cap |
| Local notification | no | yes, exact | yes | 64 pending |
| Time Sensitive / Critical | no | with the trigger | with the trigger | n/a |
| Shortcuts time-of-day automation | yes, an App Intent | yes, user-set | not documented | user must build it |
| Widget timeline | no code at the entry's time | no | n/a | 40 to 70 refreshes a day |
| Background URLSession | wakes on completion | a floor only | no, transfers cancelled | per transfer |

**BGAppRefreshTask**, what the app has today (`BackgroundRefresh.swift`,
`earliestBeginDate` 15 minutes). Apple: the system "decides the best time
to launch your background task, and provides your app up to 30 seconds"
(developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app);
`earliestBeginDate` means only that the task "won't begin sooner"
(…/backgroundtasks/bgtaskrequest/earliestbegindate). WWDC 2019 session
707: launches depend on "how the user has historically used your app",
and a date too far out may mean "we may choose to not launch your task at
all" (developer.apple.com/videos/play/wwdc2019/707/). Background App
Refresh "is disabled automatically when a device is operating in
low-power mode" (…/uikit/uiapplication/backgroundrefreshstatus). After a
force-quit, Apple's own engineers say on the forums that it "does not
relaunch for quit app and never has" (developer.apple.com/forums/thread/793189,
a forum claim by DTS; no documentation page states it). Nothing in the
documentation says how many wakes a day to expect, and the often-quoted
"seven days of history" figure was not found on any page opened. On this
project no wake has ever been seen on a phone (CLAUDE.md, Known gaps),
which the plan's part 3 is meant to settle.

**BGProcessingTask.** "Several minutes of runtime", at system-chosen
times, with `requiresNetworkConnectivity` to be set when it needs the
network (WWDC 2019/707; …/backgroundtasks/bgprocessingtaskrequest). Not a
timer either. The DTS thread above says it runs once after a force-quit
and then waits for the app to be launched again (forum claim).

**BGContinuedProcessingTask (iOS 26)** is for work the student starts with
a tap and watches in a Live Activity: "Submission needs to occur as a
result of a person's action" and "the system cancels any running tasks if
a person closes the app in the app switcher"
(…/backgroundtasks/bgcontinuedprocessingtaskrequest;
…/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados). It
cannot start itself at due-minus-N. Not for us.

**Silent push.** The one route by which a server can run our code at a
minute it chooses. Apple's wording, from "Pushing background updates to
your app": "the system doesn't guarantee their delivery. In addition, the
system may throttle the delivery of background notifications if the total
number becomes excessive … don't try to send more than two or three per
hour"; "the system may hold and delay the delivery of the notification";
"when the system receives a new background notification, it discards the
older notification and only holds the newest one"; and "if something
force quits or kills the app, the system discards the held notification"
(developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).
The request must carry `apns-push-type: background` and `apns-priority:
5`; "Using priority 10 is an error"
(…/usernotifications/sending-notification-requests-to-apns). The app gets
about 30 seconds. Low Power Mode is not mentioned on either page. For us:
a push per student per deadline cluster (every item due at 11:59 PM is
one wake) is well inside "two or three per hour", and the 30 seconds are
enough for one `planner/items` call and a cancel. What it cannot do is
reach a force-quit app, and iOS may deliver it late or not at all.

**Alert push with a Notification Service Extension.** The extension runs
in its own process when an alert push with `mutable-content: 1` arrives,
has "about 30 seconds", and may rewrite the title, body and attachments
(…/usernotifications/unnotificationserviceextension;
…/usernotifications/modifying-content-in-newly-delivered-notifications).
DTS on the forums: it "will indeed run even after the app has been
force-closed. It runs in a separate process"
(developer.apple.com/forums/thread/782103, forum claim). It cannot
suppress the notification: without the filtering entitlement, when time
runs out "the system displays the original content", and the entitlement
`com.apple.developer.usernotifications.filtering` is granted by request
(…/bundleresources/entitlements/com.apple.developer.usernotifications.filtering).
So a server-sent "Sweeper" alert whose extension reads Canvas and finds
the work submitted could rewrite itself into a quiet "turned in" line and
lower its interruption level, but could not vanish. Whether the extension
can call `AlarmManager.cancel` to stop a scheduled AlarmKit alarm is
documented nowhere (see AlarmKit below); assume not until a device says
otherwise. Reading Canvas from the extension would need the saved cookies
in a Keychain access group shared with it, which keeps the session on the
phone and so inside the privacy rule.

**Live Activity pushes** update the activity's UI from the server under
an hourly budget (…/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications);
a Live Activity "can't access the network", and nothing says app code
runs. They draw the alarm's card already (`BerserkAlarmActivity`); they
cannot check anything.

**AlarmKit.** The alarm is system-owned: it "overrides both a device's
focus and silent mode, if necessary"
(…/alarmkit/scheduling-an-alarm-with-alarmkit); `fixed(_:)` is "a
one-shot alarm that fires at a specific time" (…/alarmkit/alarm/schedule);
the store is a daemon's ("Fetches all alarms from the daemon that belong
to the current client", …/alarmkit/alarmmanager/alarms), and Apple's
AlarmKit FAQ on the forums says "all alarms are expected to persist
regardless of app or device state changes, once they are successfully
scheduled" and "there is no set number as a limit … the device may impose
a limit" with an error `maximumLimitReached`
(developer.apple.com/forums/thread/797158, an Apple-authored forum post).
**No app code runs when it fires.** `alarmUpdates` is an `AsyncSequence`
the app iterates while running, and no page says it wakes a suspended
app; the only code of ours that runs is the `LiveActivityIntent` behind
the stop or secondary button, and only on a tap
(…/alarmkit/alarmmanager/alarmconfiguration; WWDC 2025/230: "AlarmKit
gives you the ability to run your own code when someone taps an alarm
button"). A `LiveActivityIntent` is one where "the system launches your
app process without opening the app" (…/appintents/liveactivityintent),
so a button tap very likely runs in our process, which is what the
takeover's "turned in" relies on today. `cancel(id:)` "deletes the alarm
from the system" (…/alarmkit/alarmmanager/cancel(id:)) and Apple says
nothing about which processes may call it. The countdown form (a
pre-alert interval drawn as a Live Activity) is a UI state, not a hook.
Low Power Mode is not documented. The wrong fix, which looks natural, is
to "check at fire time": there is no fire-time code to put it in.

**Local notifications and interruption levels.** A trigger fires with no
code: "if the delivery of the notification occurs when your app isn't
running …, the system interacts with the user for you"
(…/usernotifications/scheduling-a-notification-locally-from-your-app).
64 pending requests, no way around it (an Apple engineer,
developer.apple.com/forums/thread/811171, forum claim).
`removePendingNotificationRequests(withIdentifiers:)` removes pending
requests and ignores ones that have fired
(…/usernotifications/unusernotificationcenter/removependingnotificationrequests(withidentifiers:)).
`timeSensitive` "breaks through system notification controls";
`critical` "bypasses the mute switch" and needs "a special entitlement
issued by Apple" (…/usernotifications/unnotificationinterruptionlevel;
…/usernotifications/unauthorizationoptions/criticalalert); the Critical
Alerts request page sits behind an Apple ID sign-in and was not read.
The app holds the Time Sensitive entitlement today
(`App/LHFApp.entitlements`); its documentation page could not be opened.

**Shortcuts automations.** A "Time of Day" personal automation can run
without asking (support.apple.com/guide/shortcuts/apdfbdbd7123/ios) and
could run one of our App Intents, which may live "in your app, app
extension, framework" (…/appintents/appintent). The student would have to
build the automation themself in Shortcuts, per deadline or per day; the
app cannot create it. Real, but not a product.

**Widgets.** The timeline provider runs in WidgetKit's process on a
budget of "from 40 to 70 refreshes" a day, entries "at least about 5
minutes apart", and an entry's date renders a view, it runs nothing
(…/widgetkit/keeping-a-widget-up-to-date). A widget button runs an App
Intent, but only when tapped.

**Everything else.** PushKit VoIP pushes need CallKit ("if you are unable
to support CallKit in your app, you cannot use PushKit",
…/pushkit/responding-to-voip-notifications-from-pushkit), so they are
out. Significant-change location relaunches a terminated app on about 500
metres of movement, not on time (…/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()).
A background `URLSession` can start a transfer no sooner than a date and
wake the app when it completes, but "if the user terminates the app from
the multitasking screen, the system cancels all of the session's
background transfers"
(…/foundation/urlsessionconfiguration/background(withidentifier:)); a
scheduled Canvas GET through it is a legitimate trick for a suspended,
not-quit app, with the same floor-not-promise caveat as everything else.
Legacy `setMinimumBackgroundFetchInterval` is interval-based and
superseded. HealthKit and Bluetooth wake on data, not time.

## 2. Learning submission state from Canvas, faster and cheaper

**Cookies versus tokens.** A GET on `/api/v1` with the `canvas_session`
cookie is allowed: the authentication chain falls back to the pseudonym
session when no token is present (`lib/authentication_methods.rb`), and
CSRF protection skips GET and HEAD and skips API requests that are not
in-app (`lib/canvas/request_forgery_protection.rb`), so a cookie POST
needs `X-CSRF-Token`, which the submit path already sends. Every read
below is a cookie GET. Penn's restriction on student-made access tokens
stands (CLAUDE.md, Traps); Instructure's 2025 deploy notes describe the
admin checkbox as "Restrict students from creating personal access
tokens" (community.canvaslms.com, seen only as a search result, label
unverified).

**The reads a student's session can make.**

- `GET /api/v1/planner/items?start_date=…&end_date=…`: every course in
  one paginated call. The documented `submissions` example shows
  `excused`, `graded`, `late`, `missing`, `needs_grading`,
  `with_feedback` (canvas.instructure.com/doc/api/planner.html), and the
  source builds the hash with more: `submitted: submission&.has_submission?`,
  `excused`, `graded`, `posted_at`, `late`, `missing`, `needs_grading`,
  `has_feedback`, `redo_request` (`lib/api/v1/planner_item.rb`,
  `submission_statuses`, read twice). `filter=complete_items` means
  "marked complete or submitted". The phone already reads this endpoint
  for Planner ticks (`CanvasStructuredSourcesClient`); a one-call "is
  anything due in the next hour still unsubmitted" is a window of one day
  on the same call. **This is the cheapest cross-course read Canvas
  offers a student.**
- `GET /api/v1/courses/:id/assignments?include[]=submission`: one call
  per course, the caller's submission on each assignment, loaded in a
  single server-side query (`lib/api/v1/assignment.rb`,
  `@context.submissions.where(assignment_id: …).for_user(users)`); an
  absent `submission` key means none. The course-material client already
  uses it; the grades fetch uses the heavier
  `assignment_groups?include[]=assignments&include[]=submission`
  (`CanvasGradesClient.swift:107`).
- `GET /api/v1/courses/:id/students/submissions`: one call per course,
  `workflow_state` in `submitted | unsubmitted | graded |
  pending_review`, `submitted_at` "if an actual submission has been
  made", `missing`, `late`, `excused` (canvas.instructure.com/doc/api/submissions.html).
  Per-assignment `…/submissions/:user_id` is one call per item, the worst
  shape.
- `GET /api/v1/users/self/missing_submissions`: cross-course but past-due
  only (canvas.instructure.com/doc/api/users.html). `todo` and
  `upcoming_events` carry no submission state.
- GraphQL at `/api/graphql` takes `current_user` and `session` into its
  context (`app/controllers/graphql_controller.rb`) but is a POST, so the
  CSRF header is needed; the docs' only submissions example is per
  assignment (canvas.instructure.com/doc/api/file.graphql.html). No
  advantage over the planner call for this question.
- No `ETag` or `If-Modified-Since` was found on the calendar feed
  controller, and the assignments and submissions controllers were not
  checked (unverified).

**Rate limits, from the source** (`app/middleware/request_throttle.rb`,
read in full by two passes): a leaky bucket with `maximum: 800`, `hwm:
600`, `outflow: 10` per second, `up_front_cost: 50`; a throttled request
answers 403 by default (429 only with a setting). A cookie request is
keyed by the user id (`tag_identifier("user", …)` comes before
`"session"`), and the two headers are added only when the identifier
does not start with `session`, so a signed-in cookie request should see
`X-Request-Cost` and `X-Rate-Limit-Remaining`; whether Penn's deployment
matches is a thing to read off one response. At an outflow of ten a
second, a call a minute across a handful of courses is far below the
leak; the cost that matters is Canvas's own measured cost per request,
which is not published. The API docs also say each access token has its
own quota (canvas.instructure.com/doc/api/file.throttling.html).

**What Canvas will not give a student's app.**

- **Live Events / Data Services.** `submission_created` fires "anytime an
  end user or API request submits or re-submits an assignment", delivered
  by SQS or signed webhook (developerdocs.instructure.com/services/canvas/data-services/…);
  subscriptions are made by account admins in the Data Services tool
  (community posts, seen as search results). Only Penn could subscribe
  and relay, and relaying a student's submission events through our
  server is a privacy-line change in itself.
- **Canvas's own notifications.** There is no student "assignment
  submitted" notification: the categories in `app/models/notification.rb`
  include Due Date, Grading, Submission Comment and "All Submissions",
  the last described as "(Instructor and Admin only)". So a student gets
  no email or push from Canvas when their own submission lands, and
  there is nothing for an email-reading route to read.
- **A push channel.** `communication_channels` of type `push` need a
  developer key with "an SNS ARN configured on it"
  (canvas.instructure.com/doc/api/communication_channels.html): that is
  the Canvas Student app's route, under Instructure's own key, and not
  one a cookie can take.
- **The ICS feed** carries no submission state: `to_ics` in
  `app/models/calendar_event.rb` never references submissions and sets no
  status, and the feed controller renders with no `ETag`.
- **A developer key for Smooth.** On Canvas Cloud the institution's admin
  issues keys (canvas.instructure.com/doc/api/file.oauth.html), so a
  per-student OAuth token at Penn means Penn's Canvas admins creating a
  key for us; no Instructure partner program for keys was found. The
  canvas-ios repository's login code could not be read (the guessed path
  404ed), so how Canvas Student holds its session is unverified beyond
  the OAuth doc's description of a native app watching the redirect and
  keeping tokens in the keychain.

## 3. Gradescope

No official student or third-party API was found (help.gradescope.com,
unofficial clients' own READMEs). What a student's session can read is
the course page `/courses/:id`: one HTML table, one row per assignment,
the name and id in the first cell, the status in the second ("Submitted"
or a score when graded, otherwise the raw cell text such as "No
Submission"), release and due dates in `datetime` attributes of the third
(the unofficial `nyuoss/gradescope-api` parser, `_assignment_helpers.py`,
`get_assignments_student_view`; the phone's `GradescopeHTMLParser` reads
the same table). A per-submission JSON exists at
`/courses/:c/assignments/:a/submissions/:s.json` (same client). No
lightweight "last modified" signal was found.

Gradescope emails the student a receipt after a submission, from
no-reply@gradescope.com, listing course, assignment and time; students
cannot turn it off (Boston University and UNH help pages, not
Gradescope's own, whose student-notifications article answered 403).
Reading a student's email is not something this app does or should
start doing for an alarm. Gradescope's mobile app has due-date reminders
one, three or five days ahead (help.gradescope.com/article/alyonjbud4-mobile-app,
seen as a search result). Whether Canvas learns of a Gradescope
submission before a grade is posted back through the LTI is unconfirmed;
a community thread on a "submission status discrepancy" between the two
exists (community.canvaslms.com, not opened).

What the Chrome extension could read that the phone cannot: nothing
different, the same table, but with a session that stays alive because
the browser's SSO keeps it so, and on a machine that is often on at
11 PM. The phone's Gradescope cookies age out after a day without a
successful sync (CLAUDE.md, Traps).

## 4. Server-side routes inside the privacy rule

The rule: the server never holds a Canvas or Gradescope session or
password. Three routes keep it.

**A. The server as a timer: a silent push at due-minus-N.** The phone
sends the server its APNs device token and a short list of ring minutes;
`pg_cron` runs a job every minute (Supabase documents `cron.schedule`
with `net.http_post` to an Edge Function, and `pg_cron` accepts `[1-59]
seconds` intervals; supabase.com/docs/guides/functions/schedule-functions,
supabase.com/docs/guides/cron, the pg_cron README) and the function sends
a background push to each device whose minute has come. The phone wakes
for 30 seconds, runs the planner call, and cancels or keeps its alarm.
Setup: an APNs auth key (`.p8`, Key ID, Team ID, ES256 JWT refreshed "no
more than once every 20 minutes and no less than once every 60 minutes",
…/usernotifications/establishing-a-token-based-connection-to-apns), made
by the Account Holder, Olisa; the `aps-environment` entitlement and push
registration in the app, which it does not have today; a device-token
table. Cost: none beyond the developer membership; FCM is also free
(firebase.google.com/pricing) and adds nothing for iOS, since it rides
APNs. APNs speaks HTTP/2 only; whether an Edge Function's `fetch`
negotiates HTTP/2 to `api.push.apple.com` needs a live test, and the
Vercel front is a fallback host. Delivery odds are Apple's words above:
best effort, late or never under load, never after a force-quit, and the
`backgroundRefreshStatus` line suggests Low Power Mode is unfriendly to
it. **What leaves the phone**: a device token (which identifies the
install to Apple, not the student) and a set of minutes; sending minutes
rather than item ids tells the server nothing about which work is due,
only that this install wants a wake then. That is still a new per-user
datum and a change to `docs/PRIVACY.md`. **The wrong fix**: letting the
server decide whether to ring and sending an alert push with the
assignment's name. That needs the server to know submission state, which
is exactly what the rule forbids.

**B. The alert-push variant with a Notification Service Extension.** The
server sends an alert push at due-minus-N; the extension, holding the
Canvas cookies through a shared Keychain group, reads `planner/items`,
and rewrites the alert to a quiet "turned in" at passive level when the
work is in, or leaves the loud "not turned in" otherwise. It survives a
force-quit, which nothing else does. It cannot drop the notice without
the filtering entitlement, and it cannot touch the AlarmKit alarm as far
as anything documents, so it fits the three-buzz fallback, not the alarm.
Apple would be reviewing an extension that reads a university site with
saved cookies; the risk is of the same kind as the hidden renewer's and
not larger. The server learns the same two things as route A.

**C. The laptop as the always-on checker.** The Chrome extension already
reads Canvas and Gradescope with the browser's sessions and syncs
completions to the phone end-to-end encrypted (`docs/CHROME_EXTENSION.md`).
It could poll submission state every minute inside the last hour and
write a completion into the encrypted snapshot the moment one appears.
The phone still has to wake to read it, which is the same wall as
before; the extension could ask the server to "poke" the phone (route A's
push, sent on request instead of on a timer), with the server learning
only that a device should wake now. It depends on the laptop being on
and Chrome running (MV3 service-worker alarms have their own minimum
period, not checked here), and it is Penn only. A second-order help, not
a first.

Not inside the rule, listed to name them: Penn subscribing to Live
Events and relaying `submission_created` to our server (the server then
holds per-student submission events), and any server-held session.

## 5. On-phone routes

**Polling inside the last hour while the app is open.** The planner call
every minute for items due within 60 minutes, exempt from the 15-minute
grades throttle (`AutoSyncCoordinator.swift:22`), is the plan's part 2
and costs Canvas one request a minute per student with no per-course
fan-out. Watch `X-Rate-Limit-Remaining` on the response; if Penn's
deployment hides it for cookie requests, back off on any 403 instead.

**At the moment the alarm fires.** Nothing of ours runs (section 1). The
app learns an alarm is ringing only if it is running (`alarmUpdates`) or
when it next launches and finds the id missing from `alarms`, which Apple
offers as the way to tell a one-shot fired (…/alarmkit/alarmmanager/alarms).
A tap on "turned in" runs our intent in our process. So the ring itself
can never be gated; only its registration can.

**Arm only from a confirmed read**, the plan's part 4: register the
Sweeper alarm for an item only inside a short window before it is due,
from a pass that has just read Canvas and seen the item unsubmitted; an
item the app could not confirm in that window gets the quiet reminder
and no loud alarm. That trades a missed ring for a wrong ring, which is
Marco's stated preference. Routes A to C above are ways to make the
confirming read happen more often when the app is closed; they change
nothing in this rule. **The wrong fix**: arming days ahead and trying to
cancel in time. Cancelling needs our process, and sections 1 and 4 say
how rarely iOS lends it to us.

**Cancel at observation**, the plan's part 1: when any read reports a
submission, remove that item's pending requests and alarm then, not at
the next replan. Cheap and already specified.

**Items that must never ring.** Today the Sweeper skips completed items,
anything that takes no submission (`showsNothingToSubmit`, which covers
Canvas `none`, `on_paper` and `not_graded`, calendar events, readings,
preparation tasks), recurring occurrences and found exams
(`NotificationScheduler.swift:1036`). Add, as data Canvas states:
`points_possible` of 0, `omit_from_final_grade`, a title naming optional,
practice, survey, extra credit, ungraded or attendance; an in-class quiz
is already out (`docs/QUIZ_MISSED_2026-11-09.md`); a Gradescope-only
item has no Canvas submission record to confirm against, so it should
ring only when a Gradescope scrape inside the window still says "No
Submission", or not at all. A pooled, course-level `alarm_worthy` verdict
from `extract-facts` stays a later step and needs Olisa's go (the plan,
part 4).

## 6. Comparison, order of work, and the one question

| Route | App closed? | Latency to see a submission | Delivery guarantee | Leaves the phone | Review risk | Effort | Depends on |
|---|---|---|---|---|---|---|---|
| Cancel at observation (plan 1) | no | at the next read | n/a | nothing new | none | 1 day | nothing |
| Planner poll every minute in the last hour (plan 2) | no | about 1 minute while open | certain while open | nothing new | none | 2 days | nothing |
| Arm the Sweeper only from a confirmed read (plan 4) | no (by design: unconfirmed means no loud alarm) | n/a | certain for what rings | nothing new | none | 2 days | plan 2 |
| Background refresh proven and bypassing the throttle (plan 3) | suspended yes, force-quit no | minutes to hours, learned | none | nothing new | none | 2 days plus 48 h of watching | a phone |
| A. Server timer silent push | suspended yes, force-quit no | about the push's minute | best effort, "two or three per hour" | device token, ring minutes | low | 4 to 6 days | APNs key from Olisa, `aps-environment`, PRIVACY.md |
| B. Alert push + service extension | yes, force-quit too | the push's minute | alert delivery is reliable; the rewrite needs Canvas to answer in 30 s | device token, ring minutes | moderate (cookies in an extension) | 5 to 7 days | A's setup, Keychain sharing |
| C. Extension poke | laptop on | about 1 minute | as A | as A, plus the poke | low | 3 days after A | A, Olisa (extension), Penn only |
| Shortcuts automation | yes | user-set | per user | nothing | none | 1 day | each student building it |
| Penn Live Events relay | yes | seconds | high | per-student submission events | low | weeks | Penn's admins; a privacy-line change |
| Gradescope email receipt | n/a | seconds | n/a | the student's mail | high | n/a | not for this app |

**Recommended order.** The four parts of the written plan first and in
their order, because every later route is only another chance for the
read those parts make decisive: (1) cancel at observation, (2) the
planner poll in the last hour, (4) arm only from a confirmed read, then
(3) prove the background wake on a phone and let it run the poll. Those
four need no key, no deploy and no new disclosure, and they end the
2026-11-03 case (submitted fifteen minutes before, app open) outright.
Then route A, the server timer push, which is the only way to reach a
closed app and whose cost is one key and one short privacy paragraph.
Route B is worth building only if A's pushes prove too unreliable on
real phones over a week, since it reaches the force-quit case at the
price of a second process holding cookies. Route C after A, when Olisa
has a day for the extension. Not pursued: Critical Alerts (an entitlement
Apple grants for safety uses), PushKit, location, email.

**The one question for Marco and Olisa.** May the server hold, per
install, an APNs device token and the minutes at which that install
wants to be woken? Nothing about which course or which work, no
session, no state; but it is the first per-user record on the server
whose purpose is to reach the phone, it goes into `docs/PRIVACY.md`, and
the key that signs the pushes can only be made by the Account Holder. A
yes unlocks routes A to C; a no means the Sweeper's accuracy rests on the
four plan parts alone, and a student who submits on the website with the
app closed and iOS never waking it in time still hears the quiet reminder
and, if the alarm was armed from a read inside the hour, the alarm.

## Sources not opened

Named here so nobody quotes them as read: Apple's time-sensitive
entitlement page and the Critical Alerts request page (404 as JSON;
sign-in); WWDC 2020 session 10063; TN3115; the Canvas Notifications
guide; Instructure's admin guide for developer keys and for the student
access-token restriction (seen as search results only); the canvas-ios
login code; Gradescope's own student-notifications and mobile-app
articles (403, redirect); the `in_app?` definition in
`application_controller.rb` (the file was too long for the fetch and the
summarized middle is where it sits); Chrome's MV3 alarm minimum period.
