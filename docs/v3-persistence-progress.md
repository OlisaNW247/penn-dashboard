# v3-persistence — progress & handoff

_Branch: `v3-persistence` (off `v3`). Written 2026-08-02. All work below is
committed; `swift test` = **256 tests / 22 suites green**._

This branch tackles the four data-trust problems you raised — lost assignments,
class bugs, unknown submission state, Canvas/Gradescope duplicates — plus the
highest-severity items from the improvement audit.

## What shipped

### 1. Durable assignment ledger (the root-cause fix)
Commits `c152cac` (feat) + `7bd2d41` (tests).

The app never persisted assignments: `canvasItems`/`gradescopeItems` started
empty every launch and `sync()` did `canvasItems = fetched` — a wholesale
replace. So a rolling Canvas feed, a moved assignment, or one flaky fetch could
erase previously-seen work. Now:

- **`StoredAssignment`** (`@Model`) + **`AssignmentStore`** live in
  `LowHangingFruitKit/Sources/.../Persistence/`. SwiftData, App Group container
  (`group.com.lhf.lowhangingfruit`) so a future widget can share it.
- **`reconcile()`** upserts fetched items, flags vanished ones `isGoneFromFeed`
  (never deletes), and **refuses a suspiciously empty fetch** (partial-fetch
  guard) so a blip can't wipe the list.
- **Deliberate aging**: a gone item is dropped only once it's *also* overdue past
  a 14-day grace window; undated / still-in-feed items never age out.
- **`AppState`** seeds its pools from the ledger at `init` (class list populated
  before the first network call — fixes the empty-class-list bug) and reconciles
  on sync instead of replacing.
- The store is **injectable** and falls back to a fresh in-memory store when the
  App Group isn't entitled (tests/previews), so there's no disk touch or
  cross-test leakage. A nil store => the old non-persistent behavior (safe
  degrade, never a crash).

### 2. Honest dashboard states — improvement #1 & #2
Commit `c4ba41f`. The timeline showed the "Go enjoy Life" empty state whenever a
tab had no sections, including on cold launch and after a failed sync — so you
could open the app mid-sync and be told you were done. Now it resolves to a
loading spinner / a full error state (with Try again) / the caught-up art only
when we truly have data. Plus a slim dismissible **sync-error banner** so failed
refreshes are visible on the dashboard, not just Settings.

### 3. All-day assignments due at local end-of-day — improvement #4
Commit `6d4f96f`. Date-only ICS events were pinned to 23:59:59 **UTC** (~7:59pm
Eastern), firing countdowns and reminders ~4h early. Now 23:59:59 **local**,
DST-safe.

### 4. Disconnect actually signs out — improvement #3
Commit `d128c7e`. Disconnect only cleared the Keychain cookie copy; the live
login persisted in `WKWebsiteDataStore` and was folded right back in — and the
App Review "erases the stored session" claim was untrue. Disconnect is now async
and awaits `AutoSyncCoordinator.purgeWebSession(...)`, which deletes the matching
cookies + cached website data.

## Verification
- `cd LowHangingFruitKit && swift test` → 256 tests / 22 suites, green.
- The two new suites — `AssignmentStoreTests`, `AssignmentLedgerScenarioTests` —
  are the "bulletproofing": they replay multi-sync/multi-launch sequences and
  assert vanished-item-survives, empty-fetch-keeps-data, survives-relaunch,
  completed-stays-in-Done, moved-date-stays-one-card.

## Not done (deliberate follow-ups, ranked)
These were scoped out to keep the branch solid and tested rather than sprawling:

1. **Persisted Canvas submission state.** The ledger has `canvasSubmitted` /
   `scoreEarned` fields ready, but `submittedCanvasAssignmentIDs` is still
   derived per-launch and not yet written to the ledger. Wiring
   `updateSubmissionState()` to persist onto rows (and seed from them at init)
   would make submission state survive launches — the remaining piece of "it
   doesn't know the submission state." Small, isolated.
2. **Persisted dedup pairings (moved-date resilience).** `linkedID` /
   `pairingConfirmedAt` fields exist but aren't populated. Dedup still runs live
   each rebuild (so same-date duplicates collapse), but a professor moving a date
   >26h on only one platform can still split a pair. Persisting confirmed
   pairings closes that. See `docs/assignment-persistence-plan.md` §5.
3. **Widget → shared ledger.** The widget still reads the hand-rolled
   `WidgetSnapshot`; it could read `AssignmentStore` directly.
4. **Dynamic Type** (improvement audit High #5) and the Med items in
   `docs/improvement-backlog.md` (Gradescope serial GETs, `.timeSensitive`
   entitlement, sticky preview mode, etc.).

## Also on this branch
- `docs/assignment-persistence-plan.md` — the design (SwiftData confirmed viable;
  the §9 iOS-17 open question is resolved — see `docs/persistence-feasibility.md`).
- `docs/improvement-backlog.md` — the full audit, Top-10 table + `file:line`.
