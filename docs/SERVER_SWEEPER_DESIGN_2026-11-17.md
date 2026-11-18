# The server-side Sweeper timer: design

Written 2026-11-17. Design only: nothing built, nothing deployed, nothing on a
phone, no branch of the ship line touched. The plain-language companion is
`docs/SERVER_SWEEPER_EXPLAINED_2026-11-17.md`. This document is **Release 2 of
`docs/SWEEPER_ACCURACY_PLAN_2026-11-16.md` (its §2), worked through to the
field, header and hour**, after reading Apple's and Canvas's documentation
again on 2026-11-17 and the code it touches. Where it agrees with that plan it
says so briefly and does not repeat it; where it differs it says why (§11).
The research document (`docs/SWEEPER_STATUS_RESEARCH_2026-11-16.md`) is where
the iOS and Canvas mechanisms were first established; this one cites only
what it re-read.

**Rules it rests on.** Marco, 2026-11-16: "no dont want no alarm option as
this cd lead to someone missing an assignemnt." The alarm is armed days
ahead as today (`NotificationScheduler.plannedAlarms`, horizon
`horizonDays` = 14); only a confirmed read of "submitted" cancels it; a
failed, partial, rate-limited or absent read cancels nothing. Marco,
2026-11-16, to the research's one question: "Yes, plan it": the server may
hold, per install, an APNs device token and the minutes at which that
install wants to be woken, and nothing else. The server never holds a Canvas
or Gradescope session, password or cookie, and never talks to Canvas as the
student (`backend/PROTOCOL.md` → Principles 1 and 2). Olisa's sync and Ed
code are not touched. Nothing is done until compiled; nothing is verified
until it has run on Marco's phone. No secret in the repo, a chat or a log.

**Code read for this** (tree `05ee0a8`, 2026-11-17; symbols, not line
numbers, are the stable references): `NotificationScheduler.swift`
(`plannedAlarms`, `loudAlerts`, `horizonDays`, `maxLoudItems`,
`sweeperMinuteOptions`, `rescheduleWithoutPrompting`), `SweeperPlan.swift`
(`SweeperSettings.qualifies`, `resolved(for:)`, `nextSweep`),
`BerserkAlarmPlan.swift` (`alarms(for:)`, `alarmID(assignmentID:fireDate:sound:)`,
`reconcile`), `BerserkAlarmScheduler.swift` (`cancel(id:)`, `stop(id:)`,
`storedAlarms`, `stopRinging(among:)`), `BerserkAlarmDelivery.swift`
(`applyReminders`, the finished-alarm enumeration over every minutes × sound),
`BackgroundRefresh.swift` (`run()`, `replan`, `LiveAppStateRegistry.beginWake`,
the `@Sendable` launch handler), `AutoSyncCoordinator.swift`
(`refreshCanvasGrades`, `canvasGradesMinInterval` = 15 min, the chain into
`refreshCourseIntel` and `refreshCourseKnowledge`), `App/LHFApp.swift` (a plain
`App`, no delegate; `LHFBackgroundRefresh.register()` in `init`),
`project.yml` / `App/Info.plist` (`UIBackgroundModes: [fetch]`), and
`backend/PROTOCOL.md` (Principles, Auth, the `agent-snapshot` section as the
register for a per-student table).

## 0. The shape, in six lines

1. The phone keeps arming the AlarmKit alarm (or the three buzzes) days ahead,
   exactly as today. Nothing here changes when or whether an alarm is set.
2. After each replan the phone computes a short list of **wake moments**
   (timestamps, no items) and uploads it with its APNs device token.
3. A Postgres job ticks every minute and an Edge Function sends one silent
   push per device whose moment has come.
4. The push wakes the phone for up to 30 seconds. It runs one cheap read
   against Canvas (`planner/items`, every course at once) and, only when a
   Gradescope-only item is inside the window, one Gradescope page per such
   course, with the phone's own sessions.
5. A read that positively says "submitted" cancels that item's alarm and
   buzzes then and there (Release 1's cancel-at-observation hook). Any other
   answer changes nothing.
6. When the push is late, dropped, or the app force-quit, nothing happens and
   the alarm rings as armed. The server never says "cancel"; it only says
   "now would be a good time to look".

## 1. The ring schedule the phone uploads

### 1.1 What is in it

```
PUT /functions/v1/sweeper-wake
Authorization: Bearer <anonymous-account JWT>     (verified in code by requireUser, §3.1)
X-Smooth-Version: <marketing version>               (required from day one)
{
  "token":       "<64 to 200 hex chars>",           -- APNs device token, hex
  "environment": "production" | "development",      -- which APNs host the token belongs to
  "moments":     ["2026-11-20T04:34:00Z", ...],     -- ≤ 24, whole minutes, UTC, all inside the next 48 h
  "plan":        "<16 hex chars>"                   -- a hash of the moments, so the server can answer "unchanged"
}
```

That is the whole body. **What is never in it:** an assignment id, a course
id or code, a title, a URL, a due date as such, a lead time, a sound, a class
setting, a grade, a completion, a name. A moment is a timestamp the phone
would like to be nudged at; the server cannot tell from it which item is due
or when (the lead time and the two offsets are the phone's business and
vary per class). The function refuses any extra key with `400 bad_request`
and reason `forbidden_field`, the rule `agent-snapshot` already applies,
rather than trimming, so a client bug shows as a count.

### 1.2 How the phone computes the moments

A pure rule in the Kit, `SweeperWakePlan.moments(from: [PlannedAlarm], now: Date) -> [Date]`
(`LowHangingFruitKit/Sources/LowHangingFruitKit/Alarms/SweeperWakePlan.swift`,
beside `BerserkAlarmMetadata`), tested with a fixed clock:

- Input is `NotificationScheduler.plannedAlarms(from:)`, the same selection
  that arms the alarm, so the server is asked to wake the phone for exactly
  the items that will ring and no others. On a phone where the delivery is
  the three buzzes (`LoudAlertDelivery.buzzes`), the same selection is used:
  `plannedAlarms` is `loudAlerts` under another timing, so it exists either
  way.
- For each alarm, two moments: `fireDate - 15 min` and `fireDate - 3 min`,
  each truncated down to the minute, UTC. Two because Apple's throttle is per
  device per hour and a single late push is the common failure (plan §2.7).
  15 and 3 rather than 10 and 2 so that a push that arrives a few minutes
  late (Apple: the system "may hold and delay the delivery") still lands
  before the ring.
- Deduplicated (every item due at 11:59 PM is one pair of moments), sorted,
  moments already past dropped, cut at 48 hours ahead, cut at 24 entries
  nearest first. Twenty-four is generous: a day's deadlines cluster at a few
  minutes, and `maxLoudItems` is ten.
- `plan` is the first 16 hex characters of SHA-256 over the sorted moments
  joined by `|`; the server stores it and the phone keeps the last one it
  sent in memory so an unchanged schedule costs no request.

### 1.3 When the phone sends it

- From `ContentView.settleAfterFetch`, after `scheduler.reschedule`, through a
  new pass `sweeperWakePass()` beside `deviceSyncPass()` and
  `agentSnapshotPass()`, with the same gates: a backend is configured, the
  install is past onboarding, foreground only, and additionally
  `FeatureFlags.sweeperWake`, `NotificationScheduler.isEnabled`,
  `loudAlertEnabled`, and a token is known. At most once per 10 minutes
  **unless the moments or token changed**, in which case at once: a
  submission the foreground just saw removes its moments, and a new
  assignment adds them, and both should reach the server before the next
  tick that matters.
- Never from a background wake (BGTask or push): a wake has 30 seconds and
  a schedule that is stale by one wake costs at worst one needless nudge.
- The anonymous JWT is the one every function call already carries;
  `requireUser` resolves a linked Chrome extension to its phone as
  everywhere, but the extension never calls this function (it has no APNs
  token), so `callerUserId == userId` in practice.

### 1.4 Deletion

`DELETE /functions/v1/sweeper-wake` (no body) removes every row of the
caller. Sent when: reminders are switched off (`NotificationScheduler.setEnabled(false)`),
the Sweeper's onboarding switch goes off (`setLoudAlertEnabled(false)`; there
is no Sweeper switch after onboarding since 2026-11-12, so in practice this
is onboarding or every class excluded, which empties `plannedAlarms` and is
sent as a PUT with `moments: []` instead), Canvas is disconnected
(`disconnectCanvas`; `delete-account`'s `deleteUserData` also removes the row,
belt and braces), and when `FeatureFlags.sweeperWake` is false at a foreground
while a defaults flag `sweeperWakeEverSentV1` says a row may exist. The
server deletes a row on its own after one `410 Unregistered` or three
consecutive failures of any other kind (§3.4).

### 1.5 The token

- `UIApplication.registerForRemoteNotifications()` at the first foreground
  that passes the gates above. Apple: without notification authorization "the
  system delivers all remote notifications to your app silently"
  (developer.apple.com/documentation/uikit/uiapplication/registerforremotenotifications()),
  and a background push shows nothing anyway, so **no new prompt** is put to
  the student; the existing reminder permission is untouched.
- There is no app delegate today. Add a minimal
  `@UIApplicationDelegateAdaptor` in `App/LHFApp.swift` (iOS only, `#if os(iOS)`)
  with three methods: `didRegisterForRemoteNotificationsWithDeviceToken`
  (bytes → lowercase hex → `AppState.noteDeviceToken(_:)`),
  `didFailToRegisterForRemoteNotificationsWithError` (count it, never log the
  error's description, which can carry nothing sensitive but also tells
  nothing useful), and the wake handler of §4. Apple: "Device tokens can
  change periodically, so caching the value risks sending an invalid token to
  your server" and "APNs device tokens are of variable length. Do not hard-code
  their size" (…/uikit/uiapplicationdelegate/application(_:didregisterforremotenotificationswithdevicetoken:)).
  So: register at every foreground that passes the gates (the call is cheap
  when nothing changed), keep the token in memory plus `UserDefaults.lhf`
  (`sweeperWakeTokenV1`, so the plan hash can tell "changed" across launches;
  Apple's "never cache" is about trusting a stale one, which the re-register
  at every foreground prevents), and accept 64 to 200 hex characters on the
  server.
- `environment` is `development` for a Debug build (`#if DEBUG`), `production`
  otherwise, because a token minted under the development `aps-environment`
  is only valid on `api.sandbox.push.apple.com` and Apple answers
  `BadDeviceToken` for a token on the wrong host (…/usernotifications/handling-notification-responses-from-apns:
  "Verify that the request contains a valid token and that the token matches
  the environment").

### 1.6 The app's capability and plist changes

- `App/LHFApp.entitlements` (iOS only, beside the Time Sensitive key):
  `aps-environment` = `development`; Xcode rewrites it to `production` in the
  archive when the App ID has Push Notifications enabled. Verify on the
  archived `.app` with `codesign -d --entitlements - <path>/Smooth.app`.
- `UIBackgroundModes` gains `remote-notification` beside `fetch`, in **both**
  `project.yml` (`info.properties`) and `App/Info.plist` (the xcodegen trap,
  CLAUDE.md → Traps). Apple: "To receive background notifications, you must
  add the remote notifications background mode to your app"
  (…/usernotifications/pushing-background-updates-to-your-app).
- The Push Notifications capability on the App ID `com.lhf.lowhangingfruit`
  in the developer portal (Olisa, or Marco if his role allows), then
  `-allowProvisioningUpdates` regenerates the profile at the next build.
- `LHFWidget` needs nothing: the push is the app's.

## 2. The server-side timer: a table plus pg_cron plus pg_net

### 2.1 Which mechanism, and why

Supabase offers no "scheduled Edge Function" of its own; the documented way
is **`pg_cron` inside Postgres calling the function through `pg_net`**:
"Schedule Edge Functions with pg_cron … In combination with the pg_net
extension, this allows us to invoke Edge Functions periodically on a set
schedule" (supabase.com/docs/guides/functions/schedule-functions). The
alternatives, and why not:

- **Vercel cron on the connector front** (`backend/connector-front/`): the
  Hobby plan's cron floor is once a day; a per-minute cron needs a paid plan
  for a job that is otherwise free on Supabase. Kept as the fallback host for
  the *send* only (§3.5), not the clock.
- **GitHub Actions `schedule`**: a five-minute floor and no timeliness
  promise; the `update-floor` workflow uses it because ten minutes late is
  fine there. Here two minutes late is the difference between a cancelled and
  a wrong ring.
- **A long-running loop inside an Edge Function** (`EdgeRuntime.waitUntil`):
  bounded by the wall-clock limit ("Maximum Duration (Wall clock limit)":
  150 s on Free, 400 s on Paid, supabase.com/docs/guides/functions/limits),
  so it cannot be the clock.
- **`agent_sweep_expired`'s pattern** (the sweep that runs on one `/authorize`
  in fifty, migration `20261109090000_agent_hardening.sql`, whose own comment
  says "pg_cron would be better and needs the dashboard to enable"): a timer
  driven by someone else's traffic is not a timer.

So: `pg_cron`, every minute, which Supabase states as the floor for the
documented pattern ("up to a minute precision", the `pg_net` page) and well
inside its advice ("no more than 8 Jobs run concurrently. Each Job should run
no more than 10 minutes", supabase.com/docs/guides/cron). **One-time setup:**
the `pg_cron` and `pg_net` extensions must be enabled on the project
(Integrations → Cron in the dashboard, or `create extension` in the
migration, which the SQL check in Docker also runs). Job history is in
`cron.job_run_details`, the first place to look when a tick seems to have
missed.

### 2.2 The table

Migration `20261118090000_sweeper_wake.sql`, re-runnable, in the register of
the agent migrations:

```sql
create table if not exists public.sweeper_wakes (
  device_token  text primary key,                           -- hex, 64..200 chars
  user_id       uuid not null references auth.users (id) on delete cascade,
  environment   text not null check (environment in ('production', 'development')),
  moments       timestamptz[] not null default '{}',        -- ≤ 24, minute grain, ≤ 48 h ahead (function-enforced)
  plan_hash     text,                                       -- the phone's 16 hex chars
  updated_at    timestamptz not null default now(),
  last_sent_for timestamptz,                                -- the moment most recently sent (minute grain)
  failures      smallint not null default 0
);
create index if not exists sweeper_wakes_user_idx on public.sweeper_wakes (user_id);
alter table public.sweeper_wakes enable row level security;
revoke all on public.sweeper_wakes from anon, authenticated;
grant all on public.sweeper_wakes to service_role;
```

Service role only, no policy for `anon` or `authenticated`, like the six agent
tables (`backend/PROTOCOL.md` → Tables). One row per token; a student may
briefly have two (a reinstall before the old row is deleted), and both are
deleted with the account by the cascade. **No column can hold a course,
assignment, title, URL, grade or state**, and `test/rls.test.sql` pins the
column list so a later migration cannot add one quietly.

`last_sent_for` is a *moment*, not a send time: the tick picks rows where some
moment is in `[now - 60 s, now)` and `last_sent_for is distinct from` that
moment, so two overlapping ticks cannot double-send and a tick that dies half
way leaves the unsent rows for the next minute. A GIN index on `moments` is
not needed at this scale (one array scan over at most a few thousand rows a
minute); add it if `cron.job_run_details` shows the select taking seconds.

### 2.3 The job

```sql
select cron.schedule(
  'sweeper-wake-tick', '* * * * *',
  $$ select net.http_post(
       url     := (select decrypted_secret from vault.decrypted_secrets where name = 'sweeper_wake_tick_url'),
       headers := jsonb_build_object(
         'Content-Type', 'application/json',
         'x-sweeper-tick-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sweeper_wake_tick_secret')),
       body    := '{}'::jsonb,
       timeout_milliseconds := 5000) $$);
```

Two Vault secrets, created once by hand (`vault.create_secret`), never in the
migration: the function's URL and a random tick secret that is also set as
the function secret `LHF_SWEEPER_TICK_SECRET`. Supabase's own example posts
the project's secret key in an `apikey` header and warns "Any role that can
log in to your database can read the secret key while the request waits"; a
dedicated secret that can do nothing but trigger a tick is the smaller
blast radius, which is why `/tick` authenticates with it (§3.1) and not with
the service-role key. `pg_net` is asynchronous and "HTTP requests are not
started until the transaction is committed"; its default timeout is 2 s and
the call above asks for 5 s, which is why the tick **answers before it
sends** (§3.3).

## 3. The Edge Function `sweeper-wake`

`backend/supabase/functions/sweeper-wake/index.ts`, `verify_jwt = false` in
`config.toml` (the bearer is verified in code, see `/tick` below), three
routes on the method and path:

### 3.1 Routes

- `PUT /` (the phone): `requireUser`, then validate (hex token 64..200;
  `environment` in the two values; `moments` an array of at most 24 ISO 8601
  instants, each truncated to the minute, each in `(now, now + 48 h]`, past
  ones dropped silently and over-horizon ones refused with 400; `plan` 16 hex
  or absent; no other key). Upsert the row for the token, setting `user_id`
  to the caller (a token that moves to another anonymous account, which a
  reinstall can produce, follows the new owner). Answer `{ "stored": n,
  "nextMoment": iso | null }`.
- `DELETE /` (the phone): `requireUser`, delete every row of `userId`.
  Answer `{ "deleted": n }`.
- `POST /tick` (pg_cron only): refuse without `x-sweeper-tick-secret` equal
  to `LHF_SWEEPER_TICK_SECRET` (`403`, counted). Since `verify_jwt = true`
  would reject a request with no JWT at the gateway before the function runs,
  **either** the cron body carries the anon key as the bearer (it passes the
  gateway's check; the function then requires the tick secret on top),
  **or** the function is `verify_jwt = false` and `PUT`/`DELETE` verify the
  bearer in code through `requireUser` as `agent-auth` and `mcp` already do
  (they run with `verify_jwt = false`, `config.toml`). The second is cleaner
  and is the recommendation; `requireUser` already calls GoTrue's `getUser`
  on the bearer, so a forged JWT is refused either way.

### 3.2 The tick

1. If `LHF_SWEEPER_WAKE_DISABLED=1`, answer `200 {"disabled": true}` and do
   nothing (§3.6).
2. Compute `m = date_trunc('minute', now())`. Select rows where
   `m = any(moments)` (or the minute just before, to forgive a late tick) and
   `last_sent_for is distinct from m`, at most 2,000 rows, with a conditional
   `update … set last_sent_for = m` in the same statement (`update … returning`),
   so the claim and the read are one operation.
3. Answer `202 {"claimed": n}` immediately, then do the sends inside
   `EdgeRuntime.waitUntil(...)` (Supabase: "The Function instance continues to
   run until the promise provided to waitUntil completes",
   supabase.com/docs/guides/functions/background-tasks). This keeps the tick
   under pg_net's timeout and under the function's 2 s CPU limit ("Maximum
   CPU Time: 2s … does not include async I/O"); the sends are I/O.
4. For each claimed row, one APNs request (§3.3), with a concurrency of 32.
5. Prune: drop from every claimed row the moments more than 5 minutes past.
6. Log one line: `tick <m>: claimed n, sent s, by status {200: a, 400: b, 410: c, 429: d, 5xx: e}, took t ms`.

### 3.3 The APNs request, as Apple documents it

```
POST https://api.push.apple.com/3/device/<token>          (production)
POST https://api.sandbox.push.apple.com/3/device/<token>  (development)
authorization:   bearer <ES256 JWT>
apns-push-type:  background
apns-priority:   5
apns-topic:      com.lhf.lowhangingfruit
apns-expiration: <unix seconds, now + 120>
content-type:    application/json

{"aps":{"content-available":1}}
```

Every line above is from "Sending notification requests to APNs"
(developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
and "Pushing background updates to your app" (…/pushing-background-updates-to-your-app),
re-read 2026-11-17:

- Background type: "Always use priority 5. Using priority 10 is an error."
  and "If you set this push type, the apns-topic header field must use your
  app's bundle ID as the topic."
- Payload: "create a remote notification with an aps dictionary that includes
  only the content-available key"; "the aps dictionary must not contain any
  keys that would trigger user interactions." Size is irrelevant at 30 bytes
  against "a maximum size of 4 KB (4096 bytes)".
- Expiration: "If the value is nonzero, APNs stores the notification and
  tries to deliver it at least once, repeating the attempt as needed until
  the specified date. If the value is 0, APNs attempts to deliver the
  notification only once and doesn't store it." Two minutes: a phone that
  reconnects within two minutes still gets the nudge, after that the moment
  has passed and the next nudge (3 minutes before) is the one that matters.
  Note the storage rule: "APNs stores only one notification per bundle ID.
  When you send multiple notifications to the same device for a bundle ID,
  APNs selects only one notification to store. In most cases, the latest
  notification is stored." Our two nudges are twelve minutes apart, so the
  first has expired before the second arrives.
- Transport: "Use HTTP/2 and TLS 1.2 or later"; ports 443 or 2197.
  **Whether the Edge runtime's `fetch` negotiates HTTP/2 to Apple is not
  stated in Supabase's or Deno's documentation** (checked 2026-11-17:
  supabase.com/docs/guides/functions, docs.deno.com/api/web/~/fetch and the
  HTTP server page say nothing about outbound ALPN). Deno's `fetch` is built
  on a client that speaks HTTP/2 when the server offers it, so it very likely
  works, but the first probe (§8) settles it: a connection-level failure, not
  a 4xx, is the sign it does not, and then the send moves to a tiny route on
  the Vercel front (Node's `http2` module), with the tick posting it the
  claimed tokens over the front's existing shared secret.
- Auth token: "APNs supports only the ES256 algorithm"; headers `kid` (the
  10-character Key ID) and claims `iss` (the Team ID, `24A3TDB277`) and
  `iat`; "Refresh your token no more than once every 20 minutes and no less
  than once every 60 minutes"; "APNs rejects any request whose token contains
  a timestamp that's more than one hour old"
  (…/establishing-a-token-based-connection-to-apns). The function mints one
  per isolate, reuses it for 50 minutes, and remints on `403 ExpiredProviderToken`.
  Signing with the `.p8` is a `crypto.subtle.sign` with `ECDSA` / `SHA-256`
  over the PEM imported as PKCS#8; no library needed.

### 3.4 Reading Apple's answers

From "Handling notification responses from APNs"
(…/handling-notification-responses-from-apns), re-read 2026-11-17:

| Status, reason | Apple's words | What the tick does |
|---|---|---|
| 200 | "Success." | nothing; it means accepted, not delivered |
| 400 `BadDeviceToken` | "The specified device token is invalid. Verify that the request contains a valid token and that the token matches the environment." | `failures + 1`; a Debug token sent to production is the usual cause |
| 403 `ExpiredProviderToken` / `InvalidProviderToken` | "The provider token is stale and a new token should be generated." / "…the token signature can't be verified." | remint the JWT once and retry that send; a second 403 fails the whole tick loudly (the key is wrong) |
| 410 `Unregistered` | "The device token is inactive for the specified topic. There is no need to send further pushes to the same device token…"; the body's timestamp is "in milliseconds since Epoch" | delete the row now |
| 429 `TooManyRequests` | "Too many requests were made consecutively to the same device token." | stop this row for the tick; nothing to retry |
| 429 `TooManyProviderTokenUpdates` | "Update the authentication token no more than once every 20 minutes." | the remint logic is wrong; fail loudly |
| 5xx | "After 15 minutes, you can retry JSON payloads that receive response status codes that begin with 5XX." | no retry inside the tick (the moment would be over); `failures + 1` |

Apple also says: "Don't retry notification responses with the error code
BadDeviceToken, DeviceTokenNotForTopic, Forbidden, ExpiredToken, Unregistered,
or PayloadTooLarge." A row with `failures >= 3` is deleted and counted; the
phone's next foreground re-registers and PUTs.

**Logged, never logged.** Per tick: the counts of §3.2 step 6. Per failed
send: status and `reason`, the row's `failures`, never the token, never the
user id, never a moment's timestamp (which says when a student's work is
due). The phone's PUT logs `stored n` and nothing of the moments.

### 3.5 The honest delivery odds, from Apple

For a background push Apple promises nothing beyond trying:

- "the system doesn't guarantee their delivery."
- "the system may throttle the delivery of background notifications if the
  total number becomes excessive"; "don't try to send more than two or three
  per hour."
- "When a device receives a background notification, the system may hold and
  delay the delivery of the notification".
- "When the system receives a new background notification, it discards the
  older notification and only holds the newest one."
- "If something force quits or kills the app, the system discards the held
  notification." And from the handler's page: "the system does not
  automatically launch your app if the user has force-quit it. In that
  situation, the user must relaunch your app or restart the device before the
  system attempts to launch your app automatically again."
- "If the user launches the app, the system immediately delivers the held
  notification."

(All from …/pushing-background-updates-to-your-app and
…/uikit/uiapplicationdelegate/application(_:didreceiveremotenotification:fetchcompletionhandler:),
read 2026-11-17.) Low Power Mode is not mentioned on either page; the
background-refresh page says Background App Refresh is off in it, and whether
that covers pushes is undocumented. **Apple publishes no percentage.** What we
can say: two nudges per alarm, at most a handful per student per evening, is
inside the "two or three per hour" envelope by a wide margin; a suspended app
on a charged, online phone will usually be woken within seconds; a force-quit
app will never be; and the only honest number will be the one the phone
counts (§9: `wakes.push` against the moments sent).

### 3.6 Kill switches

Server: `LHF_SWEEPER_WAKE_DISABLED=1` makes `/tick` a no-op that answers 200
and makes `PUT` answer `{ "stored": 0 }` without writing, so nothing
accumulates and an older build keeps working. Phone: `FeatureFlags.sweeperWake
= false` registers nothing, sends nothing, and sends one `DELETE` at the next
foreground if `sweeperWakeEverSentV1` is set. Neither switch touches an alarm.

## 4. The phone's wake path

### 4.1 Two wakes, one handler

| | `BGAppRefreshTask` (today) | Push wake (new) |
|---|---|---|
| Who chooses the time | iOS, from the student's habits; `earliestBeginDate` is a floor | our server, to the minute; Apple, best effort |
| Budget | "up to 30 seconds" | "up to 30 seconds of wall-clock time to process the notification and call the specified completion handler block" |
| After a force-quit | no (DTS forum claim) | no (Apple documentation, quoted above) |
| Low Power Mode | off (documented) | undocumented |
| What it runs today | keepalive probe, feed sync, Gradescope sync, `refreshCanvasGrades` (and its chain), replan, renewal wait, turned-in notices | nothing yet |

Both land in one new `@MainActor` entry, `LHFBackgroundRefresh.runWake(kind:)`,
so `run()` becomes `runWake(.refresh)` and the push handler calls
`runWake(.push)`. The `kind` decides the budget's spending:

- `.refresh` keeps today's chain unchanged (Olisa's sync and Ed ride it; not
  touched), plus Release 1's last-hour poll after `refreshCanvasGrades` when
  inside the hour (plan §1, Phase 4).
- `.push` runs **only** the submission read and the cancel, because its whole
  purpose is a cancel inside a minute, and because `refreshCanvasGrades` is
  the wrong tool for 30 seconds: it is throttled to once per 15 minutes
  (`canvasGradesMinInterval`), it fetches `assignment_groups` per course, and
  it chains into `refreshCourseIntel` and `refreshCourseKnowledge`, the
  course-material manifest exchange and Ed launch that can take tens of
  seconds and is off limits here anyway. The task brief named it; this is
  where the design departs from the brief (§11).

### 4.2 What a push wake does, in order

```
application(_:didReceiveRemoteNotification:fetchCompletionHandler:)
  1. wake = LiveAppStateRegistry.shared.beginWake()        -- RenewalContext.background: latches nothing, no Duo
  2. guard !state.isUsingFixtureData, FeatureFlags.sweeperWake
  3. guard a Canvas session is saved and not clock-expired  -- SessionCookieStore; a dead session: count, complete(.noData)
  4. window = [now - 1 h, now + 2 h]
  5. planner = CanvasStructuredSourcesClient.fetchPlannerWindow(window)   -- one GET, every course, cookies, no CSRF
  6. reads = SubmissionRead.from(planner)                    -- .submitted / .unsubmitted / .unknown per Canvas assignment id
  7. if any armed item in the window is Gradescope-only:
        for each such course (at most 3): GradescopeClient course table   -- the scrape the sync already does, one page
        reads += SubmissionRead.from(table)
  8. state.applySubmissionReads(reads)                       -- writes canvasSubmitted / structuredCompletedItemIDs as today's paths do
  9. scheduler.cancelForSubmitted(ids)                      -- Release 1 Phase 1: pending request ids + alarm ids for every (minutes, sound)
 10. replan(scheduler:state:) with rescheduleWithoutPrompting -- the backstop diff; never prompts
 11. DebugWakeLog line tagged "push"; counts (§9)
 12. completionHandler(.newData or .noData); wake.end()
```

Steps 5 to 10 are what Release 1 builds (`fetchPlannerWindow`,
`applyPlannerWindow`, `cancelForSubmitted`, the `SubmissionRead` verdicts);
the push wake adds no new reader, it only adds a time at which the existing
ones run. Step 7 is new relative to the plan (§11): the plan's R2 read the
planner alone, and a Gradescope-only item (no Canvas assignment id) can
then never be cancelled by a wake. The scrape is the one `syncGradescope`
already performs, called for the few courses that matter, through a
`GradescopeClient` entry point that takes a course list; `syncGradescope`
itself is not changed. If Gradescope's cookies are over a day old they
are useless (CLAUDE.md → Traps) and step 7 is skipped and counted.

**What never runs in a push wake:** the feed sync, `refreshCanvasGrades`, the
course-material or Ed sync, the device sync, the agent passes, the turned-in
notice drain (it stays in the foreground and the `.refresh` wake, for the
reasons `BackgroundRefresh.swift` gives), a silent renewal with the saved
password, a Duo push, the AlarmKit permission prompt.

**The rule that cannot bend:** only `.submitted` cancels. `.unknown` (a 401,
a 403, a timeout, an item absent from a partial page) and `.unsubmitted`
change nothing, and the alarm armed on Monday stands. A test with a fake
planner answer of each kind pins it, and a test pins that a wake with no
session cancels nothing.

### 4.3 Threading and crash safety

The push handler is called by UIKit on the main thread, so the trap that
killed every `BGAppRefreshTask` for six weeks (a `@MainActor`-inferred
closure entered on a system queue, CLAUDE.md → Traps) does not apply to it;
but the completion handler **must be called within the budget** ("your app
will be terminated"), so the wake wraps its work in a `Task` with a 25-second
`withTimeout` and calls the handler from the timeout path too, exactly once
(the `OSAllocatedUnfairLock` once-guard `handle(_:)` already uses). The
completion-handler form is used, not the `async` delegate form: the latter
calls iOS's completion on the cooperative thread, which is the
notification-tap crash of 2026-10-27 (CLAUDE.md → Traps).

### 4.4 The fallback when no push arrives

Nothing. The alarm was armed on Monday and stays armed; the three buzzes
likewise. The `.refresh` wake, when iOS grants one, runs the same poll
inside the hour. A foreground open runs it every minute inside the hour
(Release 1 Phase 2). A website submission inside the last hour on a
force-quit phone rings once; "turned in" on the alarm silences it and marks
the card done; stop opens the page. This is the floor Marco accepted and it
is not a bug.

## 5. Privacy: `docs/PRIVACY.md` changes

Three edits, in the page's own voice (the plan's §2.5 draft, tightened to the
copy rule), to land **in the same commit** as the phone's registration code:

Under "What is sent to our server (and why)", a new bullet after the agent
connection:

> - **A wake-up call for the Sweeper (optional, follows your reminder
>   settings).** The Smooth Sweeper is an alarm your iPhone rings even when
>   Smooth is closed, so Smooth has to cancel it beforehand once your work is
>   in. To give it a chance to check close to the deadline while it is
>   closed, your phone sends our server two things: the device token Apple
>   issues this install for push notifications (it identifies the install to
>   Apple, not you to us), and a short list of minutes at which the phone
>   would like to be woken, at most twenty-four over two days. At those
>   minutes our server sends your phone a silent push with nothing in it;
>   your phone wakes for a few seconds, asks Canvas or Gradescope with your
>   own login whether the work is in, and cancels the alarm only if it is.
>   The server never learns which class, which assignment, when it is due or
>   whether you submitted: the minutes are just minutes, and we do not log
>   them. Apple may deliver these pushes late or not at all, and never after
>   you force-quit the app, so they help the alarm; they never control it.

Under "What we keep and for how long":

> - **Your wake-up schedule**, if reminders and the Sweeper are on: one row
>   per install holding the push token and the next minutes to wake you,
>   replaced on every refresh, deleted when you turn reminders off,
>   disconnect Canvas or delete your account, and deleted by us when Apple
>   says the token is no longer valid.

Under "Deleting your data", add "your Sweeper wake-up schedule" to the list
of what disconnecting Canvas removes.

App Store privacy label (App Store Connect, Marco): under Identifiers →
Device ID, "App Functionality", "Linked to the user" (the token sits beside
the anonymous account id), "not used for tracking". `docs/appstore/REVIEW_NOTES.md`
gains two sentences: the app registers for silent pushes that carry no
content and wake it to check submission status; no user-facing notification
is sent from the server.

## 6. `backend/PROTOCOL.md` additions

A new top-level section after "The agent connection", titled
"The Sweeper wake (`sweeper-wake`)", holding: the three routes of §3.1 with
their bodies and answers; the validation rules and the `forbidden_field`
refusal; the table of §2.2 with the sentence "No column may hold a course,
assignment, title, URL, grade, completion or submission state; the moments
are the only per-student fact, and they are never logged"; the APNs request
of §3.3 verbatim; the response handling of §3.4; the tick's claim rule and
idempotency; the kill switch; and under "Limitations recorded on purpose":
delivery is Apple's best effort and the server never knows whether a push
woke the phone (there is no acknowledgement; a 200 is acceptance). Principle
2 gains one clause: "…**or the Sweeper wake schedule** (`sweeper_wakes`: a
device token and a list of minutes, nothing else), kept while reminders and
the Sweeper are on." The "Tables" count of service-role-only tables goes from
six to seven.

## 7. Can Canvas push to a student? Closed, with evidence

Re-read on 2026-11-17 from Instructure's own pages and source. The answer is
**no**: Canvas offers nothing a student's own login can turn on that tells an
outside app when that student's submission lands.

- **Live Events / Data Services** deliver `submission_created` ("The event is
  emitted anytime an end user or API request submits or re-submits an
  assignment", canvas.instructure.com/doc/api/file.data_service_canvas_submission.html)
  to "either an AWS SQS queue or an HTTPS Webhook"
  (developerdocs.instructure.com/services/canvas/data-services/live-events/overview/file.data_service_introduction.md).
  The same introduction says the service "should not be used for applications
  that need their data immediately and as up-to-date as possible". The
  subscriber is the *customer* (the institution): the page names no student
  path, and the community admin guide for subscribing could not be read
  (the page returned only its title). Penn subscribing and relaying our
  students' events to our server would put per-student submission events on
  the server, which Principle 2 forbids; it is listed to be named, not pursued.
- **Push channels** (`POST /api/v1/users/:user_id/communication_channels`
  with type `push`): "In order to enable push notification support, the
  server must be properly configured" and "the developer key used to create
  the access token from this request must have an SNS ARN configured on it"
  (canvas.instructure.com/doc/api/communication_channels.html). That is the
  Canvas Student app's route under Instructure's own developer key; a cookie
  session has no developer key, and Penn restricts student access tokens
  (CLAUDE.md → Traps, "Penn restricts student Canvas access tokens").
- **Developer keys**: "For Canvas Cloud (hosted by Instructure), developer
  keys are issued by the admin of the institution" and "developer keys are
  scoped to the institution they are issued from"
  (canvas.instructure.com/doc/api/file.oauth.html). The same page: "asking
  any other user to manually generate a token and enter it into your
  application is a violation of" the terms. So a Smooth developer key at Penn
  is a request to Penn's Canvas admins, not something Smooth can obtain.
- **Canvas's own notifications** have no "your submission was received"
  category for a student. In `app/models/notification.rb` (canvas-lms, master,
  read 2026-11-17): "All Submissions" is described "*(Instructor and Admin
  only)* Assignment submission/resubmission, except quizzes", "Late Grading"
  likewise "*(Instructor and Admin only)*", and the relevance filter for
  both is `user.teacher_enrollments.count > 0 || user.ta_enrollments.count > 0`.
  "Submission Comment" is "Assignment submission comment" and "Grading" is
  "Assignment/submission grade entered/changed": a comment or a grade, not a
  receipt. The notification-preferences API lets a user set frequency
  (`immediately`, `daily`, `weekly`, `never`) on existing channels only
  (canvas.instructure.com/doc/api/notification_preferences.html).
- **The one thing a student's session does get**: `GET /api/v1/planner/items`,
  "Retrieve the paginated list of objects to be shown on the planner for the
  current user", with a per-item `submissions` object ("The status as it
  pertains to the current user") and `filter=complete_items`: "Only return
  items that are completed (includes items with planner_override.marked_complete
  = true or submitted assignments)" (canvas.instructure.com/doc/api/planner.html).
  Note for the implementer: the documented example shows `excused, graded,
  late, missing, needs_grading, with_feedback`; the `submitted` field the
  phone reads comes from the source (`lib/api/v1/planner_item.rb`,
  `submitted: submission&.has_submission?`, as the 2026-11-16 research read
  twice). If a Canvas release ever drops it, `complete_items` is the
  documented fallback. This is a pull, not a push, and it is the call the
  wake makes.

So the server's role is confined to being a clock. Nothing in Canvas's
student-facing surface changes that, and this question does not need asking
again unless Penn's admins offer Smooth a developer key or a Live Events
relay, both of which would be privacy decisions before they were technical
ones.

## 8. The end-to-end probe

`backend/scripts/sweeper-wake-e2e.mjs`, the `agent-e2e.mjs` pattern, Node 22
with the Management token (Marco's, `~/lhf-bench/supabase.token`, never
printed): (1) a throwaway anonymous user PUTs a syntactically valid fake
token with one moment one minute ahead; (2) wait for the tick, then read
`function_edge_logs` (the query shape in CLAUDE.md → Traps, "the Management
API's logs moved") for `claimed 1, sent 1` and the APNs status: against a fake
token Apple answers `400 BadDeviceToken`, which proves the request reached
Apple over HTTP/2 with a valid provider JWT (a connection-level error instead
is the HTTP/2 question of §3.3, answered "no"); (3) a PUT with 25 moments is
400, with a moment 3 days out is 400, with an `assignment_id` key is 400
`forbidden_field`; (4) DELETE, row gone; (5) `cron.job_run_details` shows the
tick running once a minute. Then the real run: Marco's Debug build registers
(`environment: development`), the Sweeper page shows an alarm 20 minutes out,
and `debugWakeLogV1` on the plist (CLAUDE.md → Commands) gains a `push` line
within a minute of each of the two moments, or does not, which is also the
measurement. Then the submit-from-laptop case: submit on canvas.upenn.edu
with Smooth closed (not force-quit) 20 minutes before an alarm, and watch
whether the alarm rings.

## 9. How it is measured

The counts the plan defines (§3 there, `sweeperCountsV1` in `UserDefaults.lhf`,
never a title, id or URL), with two added here: `moments.sent` (how many the
phone asked for) and `wakes.push` (how many pushes woke it), whose ratio over
two weeks on Marco's and Olisa's phones is the only honest delivery figure we
will ever have; and `cancelledAtObservation.push`, the number this whole
design exists to raise. Success is the plan's: `rangSubmitted` zero or every
case the §4.4 floor, `rang` not zero.

## 10. Phased build order, with hours

Prerequisite: Release 1 of the 2026-11-16 plan (cancel at observation, the
last-hour poll, confirmed-read-only cancels, the background wake measured) is
on the App Store first; the push wake only adds a time at which those reads
run. Each phase below compiles and tests alone (`swift test --no-parallel`,
the unsigned iOS `xcodebuild` for anything behind `#if os(iOS)`, `deno task
test` and `deno task check`, `backend/scripts/sql-check.sh` for the
migration), and nothing is "done" before that.

| Phase | What | Hours | Needs |
|---|---|---|---|
| S0 | Olisa: APNs key (Production; a second Sandbox key for Debug builds, since Apple now scopes team keys to one environment, §11) in the portal, Key ID, `.p8` into Supabase secrets `APNS_KEY_P8_PROD` / `_SANDBOX`, `APNS_KEY_ID_*`, `APNS_TEAM_ID`; Push Notifications on the App ID. Marco or Olisa: enable `pg_cron` and `pg_net`, create the two Vault secrets. | 1 (owners' time) | Olisa's account |
| S1 | Kit: `SweeperWakePlan.moments`, the plan hash, `SubmissionRead` verdicts if Release 1 did not already add them; tests (two alarms one minute → one pair; 48 h cut; 24 cut; past dropped; nothing but timestamps in the output). | 4 | nothing |
| S2 | Backend: migration, `sweeper-wake` function (PUT/DELETE/tick, validation, APNs client with ES256 signing and the JWT cache, response table), Deno tests with a fake APNs, `rls.test.sql` column pin, `sql-check.sh`, PROTOCOL.md section. | 12 | S0 for the live probe only |
| S3 | Probe script and the first production run against a fake token (HTTP/2 answered); if "no", the Vercel-front send route. | 4 (+6 if the front is needed) | S2 deployed at Marco's go |
| S4 | Phone: delegate adaptor, registration, `noteDeviceToken`, `sweeperWakePass` with the 10-minute/changed rule, DELETE on every opt-out path, `aps-environment`, `remote-notification` in both plists, `FeatureFlags.sweeperWake`; tests (gates, the changed-schedule rule, the DELETE paths, a source scan that the token is written to no log). | 8 | S1 |
| S5 | Phone: the push handler → `runWake(.push)`, the 25-second timeout and once-guard, the planner window read and the Gradescope-only leg, `cancelForSubmitted`, the `DebugWakeLog` `push` tag and counts; tests (each verdict's effect; no session → nothing; timeout → handler called once). | 8 | S4, Release 1 |
| S6 | PRIVACY.md bullets, REVIEW_NOTES.md sentences, CLAUDE.md (What the app does → Background and Profile → reminders; Commands; Known gaps), ROADMAP Done recently; same commit as S4. | 2 | S4 |
| S7 | Device: Debug build on Marco's phone, the real-token probe, the laptop-submit case, 48 hours of counts read off the plist; then the Release archive's entitlement check. | 4 (+48 h elapsed) | S3, S5, the phone |
| S8 | Ship: `FeatureFlags.sweeperWake = true`, the privacy label edit, the deploy of `sweeper-wake` and the migration at Marco's go, the floor automation as usual. | 2 | Marco |

Total: about 45 engineering hours (roughly six working days), plus the
owners' hour and two days of elapsed measurement, which matches the plan's
"5 to 7 days". The optional service-extension downgrade for the three-buzz
fallback (plan §2.10) is not in this table; build it only if `wakes.push`
over `moments.sent` proves poor over two weeks, and only with the
title-to-server disclosure approved first.

## 11. Where this differs from the 2026-11-16 plan's Release 2, and why

The plan's §2 holds in its shape (moments not offsets, two moments per alarm,
the table, pg_cron, the kill switches, the degradation table, the privacy
paragraph). Six differences, each from re-reading Apple's pages or the code:

1. **Two APNs keys, not one.** The plan said one key serves both the sandbox
   and production hosts. Apple's page now says team-scoped keys "restrict
   usage to either Sandbox or Production, enhancing security … Each
   environment can have a maximum of two keys", with older dual-environment
   keys still honoured but environment-specific ones recommended. So Olisa
   makes a Production key and, for Debug builds, a Sandbox key; the function
   picks by the row's `environment`.
2. **The push wake reads the planner and, when needed, Gradescope; the plan
   read the planner alone.** A Gradescope-only item has no Canvas assignment
   id and could never be cancelled by a wake under the plan. The scrape the
   sync already does, for the few courses with such an item in the window,
   fits the budget and the privacy rule (the cookies stay on the phone).
3. **The brief's `refreshCanvasGrades` is not what the push wake runs.** It is
   15-minute-throttled, per-course, and chains into the course-material and
   Ed sync (§4.1). The `.refresh` wake keeps it; the `.push` wake runs the
   one-call planner read instead. Same reads, same verdicts, right budget.
4. **The tick authenticates with its own secret, answers before it sends, and
   claims rows in one statement.** The plan said "service role only, from
   pg_cron"; Supabase's own example warns that any database role can read a
   key sitting in a pending `pg_net` request, and pg_net's 2-second default
   timeout plus the 2-second CPU limit mean a tick that sends before
   answering fails under load. Hence the dedicated tick secret, the `202`
   then `waitUntil`, and `update … returning` as the claim.
5. **`verify_jwt = false` with `requireUser` in code is the recommended
   shape** (the `agent-auth` / `mcp` pattern), because the cron's POST carries
   no student JWT and would otherwise die at the gateway. The plan said
   `verify_jwt = true`; either works if the cron sends the anon key as
   bearer, but one auth path is simpler than two.
6. **The 410 timestamp is milliseconds**, and the `apns-expiration` is unix
   seconds; the plan did not say. Also recorded for the implementer: APNs
   stores one notification per bundle id per device, so two nudges closer
   than the expiry would collapse into one; at twelve minutes apart with a
   two-minute expiry they do not.

One thing the plan had that this document keeps unchanged on purpose: the
optional notification-service-extension route for the three-buzz fallback
stays optional and last, because it moves a title to the server and puts
Canvas cookies in a second process.

## 12. Open questions, for the owners

1. **Olisa**: make the APNs key(s) and enable Push Notifications on the App ID
   (S0); read §5's privacy bullets and say yes or change them.
2. **Marco**: approve the deploy of a new function and migration when S2 is
   green; edit the App Store privacy label at S8; lend the phone for S7.
3. **Both**: whether the 15/3-minute offsets are right, or whether a class
   with a 60-minute Sweeper lead should get a third nudge at 30 minutes (the
   rule is one line; the cost is one more push).
