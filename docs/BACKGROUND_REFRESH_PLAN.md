# Background refresh — how close to "every 5 minutes" LHF can get

_Written 2026-08-24, for v3.5+. Prompted by: "I want a guaranteed system
in which the app updates every 5 minutes, regardless of whether it's
open."_

## The constraint that decides everything

iOS does not permit apps to run on their own schedule in the background.
There is no API — public or private — that gives an App Store app a
guaranteed 5-minute background timer. The mechanisms that exist:

| Mechanism | Who decides when it runs | Realistic cadence |
|---|---|---|
| App open in foreground | The app | LHF already does 5 min (feed) / 15 min (grades) |
| `BGAppRefreshTask` | iOS, opportunistically | A few times/hour for a frequently-used app; sparse overnight; ZERO guarantee |
| Silent push (`content-available`) | iOS, throttled | Budgeted to a handful per hour; requires a server anyway |
| Visible push (APNs) | The sender's server | Real-time — but the CHECKING must happen on a server |

The only way to guarantee a 5-minute check is to move the checking off
the phone entirely: a server that polls Canvas around the clock and
pushes results to the device.

## Option A — RECOMMENDED: BGAppRefreshTask (best effort, no backend)

What it is: register a background-refresh task; iOS wakes the app for
~30 seconds at times of its choosing (it learns usage patterns), during
which LHF runs the exact refresh it runs on foregrounding — feed sync,
grades/submission detection, turned-in notifications, widget snapshot.

- Real-world behavior: for a daily-use app, refreshes typically land
  every 15–60 minutes during waking hours. Not 5 minutes, never
  guaranteed, but "Turned in ✓" fires within the hour instead of at next
  open, and the widget stays fresh.
- Privacy: unchanged — everything stays on-device. The pitch survives.
- Cost: ~a day. Implementation shape:
  1. `BGTaskScheduler` registration in `LHFApp` init with a task id
     (`Info.plist`/project.yml: `BGTaskSchedulerPermittedIdentifiers`,
     `UIBackgroundModes: fetch`) — mind the xcodegen plist trap.
  2. Handler: load persisted state, run `syncIfConfigured()` +
     `AutoSyncCoordinator.refreshCanvasGrades` (throttles relaxed for the
     background path or bypassed with a background-specific interval),
     drain `pendingTurnedInNotices` directly (no ContentView in the
     background — the drain needs a background-safe twin), reschedule the
     next task, call the completion before the 30s budget dies.
  3. Re-request on every launch/foreground (tasks don't persist forever).
  4. Device validation only — background tasks cannot run under
     `swift test` and the simulator needs `e -l objc` debugger tricks.
- Trade-off to accept up front: users WILL observe gaps (overnight,
  low-battery, rarely-used phones). That's iOS policy, not a bug.

## Option B — a server: the only true "guaranteed 5 minutes"

What it takes: a backend that stores every user's Canvas calendar-feed
token (a bearer credential) and — for grades/submissions — their session
cookies, polls Canvas every 5 minutes, diffs, and sends APNs pushes.

Why this plan recommends AGAINST it for LHF:
1. **It deletes the product's identity.** "No backend, no account
   system, everything on-device" is the privacy pitch, the App Store
   privacy label ("Data Not Collected"), and the published privacy
   policy. All three become false the moment credentials land on a
   server.
2. **The credential liability is real.** Canvas session cookies = full
   account access. Holding them server-side for classmates is a breach
   waiting to be someone's worst semester.
3. **It half-works anyway.** Penn SSO cookies expire in days and cannot
   be renewed server-side without storing the user's PennKey password
   (absolutely not). Only the ICS feed token is long-lived — so the
   "guaranteed" server could only guarantee calendar-item changes, not
   grades or submission detection.
4. Ongoing cost/ops: hosting, APNs keys, uptime, a privacy policy
   rewrite, and App Store re-review of the data practices.

If a future version ever wants near-real-time anyway, the least-bad
shape is a feed-only relay (server holds ONLY the ICS token, pushes
"something changed — open me" pings, all parsing still on-device) — but
that is a different product decision, made deliberately, not a checkbox.

## Verdict

Take Option A. It converts "updates only when opened" into "updates
several times an hour, hands-off, with notifications that arrive while
the phone is in your pocket" at zero privacy cost. Treat Option B as
documented-and-declined unless the product's privacy stance is being
reconsidered on purpose.
