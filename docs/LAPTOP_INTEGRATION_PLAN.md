# Laptop integration — the Mac as LHF's always-on half

_Written 2026-08-24. Prompted by: "having LHF open on your laptop
frequently can help with some of the force-quitting stuff."_

## Why the Mac changes the game

macOS has none of iOS's background-execution restrictions. A Mac app —
especially a menu-bar app set to launch at login — may simply run a
5-minute sync loop forever. The "guaranteed every 5 minutes" that iOS
structurally forbids (docs/BACKGROUND_REFRESH_PLAN.md) is trivially legal
on the laptop. The design question is only how the phone benefits from
what the Mac learns.

Head starts already in the codebase:
- The app already builds for macOS (one codebase, project.yml both
  destinations; macOS representables exist).
- `StoredAssignment` was deliberately stripped of `@Attribute(.unique)`
  BECAUSE CloudKit doesn't support it — the ledger schema is
  CloudKit-ready by prior design, with `absorb(_:)` as the merge story.
- All preferences flow through `UserDefaults.lhf`, one choke point to
  mirror into key-value sync.

## Tier 1 — make the Mac app a daily driver (quick, ~1–2 days)

No sync yet; just make running LHF on the laptop worth it.

1. **Menu-bar presence** (`MenuBarExtra`): next-due item + count in the
   bar, popover with the near list; closing the window doesn't quit.
2. **Launch at login** (`SMAppService.mainApp`, a Settings toggle).
3. **Persistent foreground loop**: the existing 5-min feed / 15-min
   grades cadence, running indefinitely because macOS allows it.
4. Native Mac notifications already work (`UNUserNotificationCenter` is
   cross-platform; reminders, turned-in, grade alerts all fire on the
   laptop where the student is actually working).

Payoff: whoever keeps a laptop open gets the real 5-minute experience
there, today, with zero architecture change. Limits: helps the phone
not at all — two devices, two separate worlds.

## Tier 2 — CloudKit private-database sync (the real system, ~1–2 weeks)

The Mac becomes the always-on poller; the phone becomes its beneficiary.
No LHF server — the relay is the USER'S OWN iCloud private database,
which the developer cannot read. The privacy pitch survives with one
honest amendment: "syncs between your devices through your iCloud;
still nothing goes to us."

Architecture:
1. **Ledger sync**: SwiftData `ModelConfiguration(cloudKitDatabase:
   .private(...))` for the assignment store (schema already compliant).
   Rows carry `lastSeenInFeed`/`firstSeen`; `absorb(_:)` is the merge
   precedent for conflicts.
2. **Decisions/preferences sync**: course-content decisions, selections,
   renames via `NSUbiquitousKeyValueStore` mirroring the `UserDefaults
   .lhf` keys (small, whole-map values — same shapes already used).
3. **Credentials do NOT sync.** Cookies and the ICS token stay in each
   device's local Keychain; each device logs in on its own. (The feed
   URL could sync via iCloud Keychain later — separate decision.)
4. **The force-quit killer**: the Mac, on its 5-minute loop, detects a
   change (new assignment, moved date, turned-in, grade) and writes it
   to CloudKit. A `CKQuerySubscription` with a VISIBLE notification
   payload makes APPLE's infrastructure push an alert to the iPhone —
   and visible pushes are delivered even to a force-quit app. The
   phone's reminder schedule refreshes next open; the alert itself no
   longer depends on the phone running anything.
5. Both devices keep their own pollers (phone: foreground +
   BGAppRefresh; Mac: persistent loop) — whoever fetches first writes;
   idempotent upserts by the existing `source:sourceID` identity make
   double-fetch harmless.

Costs and cautions:
- iCloud capability + container entitlements (app + widget), Apple
  Developer config, and the App Group interplay — device-matrix testing
  only; none of it reachable by `swift test` (same class as the ledger
  migrations).
- Conflict semantics need one careful design pass (completion ticks and
  decisions are last-writer-wins by timestamp; ledger rows merge like
  `absorb`).
- Privacy policy + App Store notes gain an iCloud sentence; the label
  can remain "Data Not Collected" (private-database iCloud storage is
  the user's own, not developer collection) — verify against current
  App Store guidance at submission time.
- CloudKit sync bugs are the ecosystem's most notorious time sinks:
  budget real soak time, ship behind a Settings toggle ("Sync between
  my devices"), default off for one release.

## Tier 3 — garnish (cheap, after Tier 2)

- Handoff (`NSUserActivity`): open the assignment you were viewing on
  the other device.
- macOS widget (WidgetKit is cross-platform; snapshot store already
  feeds it).
- Menu-bar quick-complete: tick off work from the laptop without
  opening anything.

## What stays declined

A developer-run server (docs/BACKGROUND_REFRESH_PLAN.md Option B).
Tier 2 delivers most of its value — including push-while-force-quit —
with Apple as the only intermediary and zero credential custody.

## Recommended sequence

Tier 1 first: small, independently shippable, immediately useful, and
it seeds the habit ("LHF lives in the menu bar") that makes Tier 2's
always-on poller real. Tier 2 as the v4 headline feature after Marco
review of both this plan and the v3.5 branch. Tier 3 opportunistically.
