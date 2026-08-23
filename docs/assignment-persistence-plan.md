# Plan: Bulletproofing assignments, classes, submission state & duplicates

_Status: **BUILT** (proposed 2026-08-02, shipped on `v3`; hardened 2026-08-20)._
_This document is kept as the design record. Do not re-implement it — read
`AssignmentStore.swift` first._

| Plan section | Where it lives now |
| --- | --- |
| §3 durable ledger, `StoredAssignment` | `LowHangingFruitKit/Persistence/StoredAssignment.swift` |
| §3 `firstSeen` / `lastSeenInFeed` / `isGoneFromFeed` | same file — all three, same names |
| §3 App Group placement | `AssignmentStore.appGroupID`, read by `LedgerWidgetReader` |
| §3 reconciliation that unions | `AssignmentStore.reconcile(_:source:)` |
| §3 partial-fetch guard | same method, surfaced as `wasSuspectedPartial` |
| §5 persisted Canvas↔Gradescope pairings | `confirmedPairings()` / `recordPairings()` |
| §5 relaxed gap for exact-title matches | `AssignmentDeduplicator.sameTitleMaxDueGap` (21d) vs `similarTitleDueDateTolerance` (26h) |
| §7 feed-simulation harness | `AssignmentLedgerScenarioTests.swift` |
| §9 open question: deployment target | resolved — iOS 17, SwiftData |

A follow-up pass on 2026-08-20 closed six gaps the original plan didn't cover:
versioned schema + migration plan (`LedgerSchema.swift`), honest reporting of
storage and write failures, pruning of aged-out rows, user-created work moved
onto the ledger, completion made ledger-authoritative rather than a parallel
UserDefaults copy, and preferences moved to the App Group suite
(`SharedDefaults.swift`) so the widget can see them.

This is the design plan for making LHF's core data — "what classwork is due" —
durable and trustworthy. It addresses four reported problems that all trace to a
single architectural gap.

---

## 1. The problems

1. **Lost assignments.** Previously-seen assignments disappear.
2. **Class bugs.** The class list is unreliable — empty or missing classes.
3. **No submission state.** The app doesn't know which assignments are already
   submitted.
4. **Duplicates.** An assignment posted on both Canvas and Gradescope sometimes
   shows twice.

## 2. Root cause: there is no assignment database

`AppState.canvasItems` / `gradescopeItems` are in-memory `@Published` arrays,
empty on every launch and rebuilt **only** from live network fetches. `init()`
restores completions, hidden/deleted courses, names, and the course-id cache
from `UserDefaults` — but **never the assignments**. The only thing persisted is
the widget's top-5 snapshot (`WidgetSnapshot`).

Worse, `sync()` does `canvasItems = fetched` — a **wholesale replace**. The list
is only ever as good as the single most recent fetch.

That one gap produces all four symptoms:

| Symptom | Mechanism |
|---|---|
| Lost assignments | Canvas's ICS feed is a rolling window; past / prior-term items age out. Gone from the feed → gone from the app (incl. completed items, so Done empties). One flaky partial fetch overwrites everything. |
| Class bugs | `allCourseCodes()` derives live from the (often-empty) in-memory pools. Before first sync, or with an expired session, the class list is empty. A class with nothing currently due drops off. |
| No submission state | Canvas submission truth flows only through Grade Watcher snapshots (`submittedCanvasAssignmentIDs`), which needs a live **cookie** session (separate from ICS) and is **derived, never persisted** — blank until a grade refresh finishes each launch. |
| Duplicates | `AssignmentDeduplicator`'s fuzzy tier needs both due dates within ~26h. When a professor **moves a date** on one platform only, the gap exceeds tolerance and the merge silently fails. |

## 3. Target architecture: a durable assignment ledger (SwiftData)

Introduce a persistent store that becomes the **source of truth** the dashboard
reads from. Live fetches **reconcile into** it; they never replace it.

### 3.1 Model

```swift
@Model
final class StoredAssignment {
    @Attribute(.unique) var id: String        // "source:sourceID" — matches Assignment.id
    var source: String                        // Assignment.Source.rawValue
    var sourceID: String
    var kind: String
    var course: String
    var title: String
    var dueAt: Date?
    var urlString: String?
    var termRaw: String?

    // Lifecycle — the heart of "don't lose things"
    var firstSeen: Date
    var lastSeenInFeed: Date                   // updated every sync the item is present
    var isGoneFromFeed: Bool                   // true once a sync no longer returns it

    // Submission / grade truth (persisted, not re-derived from scratch)
    var canvasSubmitted: Bool                  // from Grade Watcher workflow_state
    var gradescopeSubmitted: Bool
    var scoreEarned: Double?
    var scoreMax: Double?

    // Cross-platform pairing (persisted so it survives a later date move)
    var linkedID: String?
    var pairingConfirmedAt: Date?
}
```

A thin mapping layer converts `StoredAssignment` ⇄ the existing value-type
`Assignment`, so the rest of the app (dashboard buckets, dedup, notifications,
Grade Watcher) keeps consuming `Assignment` and changes very little.

### 3.2 Storage location & the widget

Put the SwiftData store in the **App Group container** so the widget extension
can read it directly — replacing the hand-rolled `WidgetSnapshot` bridge with a
single shared store. `ModelConfiguration(groupContainer:)` handles this. iOS 17+
(the app already targets recent iOS; confirm the deployment target before
committing to SwiftData vs. the Codable-in-App-Group fallback).

### 3.3 Reconciliation (the core algorithm)

Replaces `canvasItems = fetched`. Runs after each Canvas / Gradescope fetch:

```
reconcile(fetched: [Assignment], source: Source):
  seen = Set(fetched.ids)
  for item in fetched:
      upsert by id — refresh title/dueAt/url/term, set lastSeenInFeed = now,
      isGoneFromFeed = false. Preserve firstSeen, submission flags, linkedID.
  for stored where stored.source == source and stored.id not in seen:
      stored.isGoneFromFeed = true          // DO NOT delete
```

Then the dashboard reads the store, applying **deliberate** visibility rules
(§3.4) — never "absent from the latest fetch."

Guard rail: if a fetch returns **zero** items for a source that previously had
many, treat it as a suspect/partial fetch — log it, keep the prior data, and
surface a soft "couldn't refresh" notice rather than marking everything gone.

### 3.4 Deliberate aging (replaces accidental loss)

An item is hidden from the active dashboard only when a rule says so, e.g.:
- completed (existing `isCompleted`), or
- past-term (`withinTermCap`), or
- `isGoneFromFeed` **and** past its due date **and** gone > N days (default 14).

Undated items and anything still in the feed are never auto-hidden. Everything
stays queryable for Done / history regardless.

## 4. Per-problem outcomes

- **Lost assignments** → union-based reconciliation + no-delete lifecycle.
  Completed items and prior weeks persist; Done never empties on relaunch.
- **Class bugs** → `allCourseCodes()` reads the persistent store, so the class
  list is populated at launch (pre-sync) and classes with nothing currently due
  don't vanish. Hidden/deleted keys keep working against a stable course set.
- **Submission state** → persist `canvasSubmitted` / `gradescopeSubmitted` on the
  ledger; a fresh Grade Watcher refresh still corrects it (self-heals a retracted
  submission), but it's no longer blank between launches. Keep nudging
  "Reconnect Canvas," since the cookie session is what unlocks real Canvas
  submission truth.
- **Duplicates** → §5.

## 5. Dedup hardening (moved-date resilience)

Keep `AssignmentDeduplicator`'s conservative default, add two upgrades:

1. **Persisted pairings.** Once a Canvas↔Gradescope pair is confirmed, store the
   `linkedID` + `pairingConfirmedAt` on both ledger rows. A later sync that moves
   a date on one side keeps the merge — the pairing survives the date change
   instead of being re-decided from scratch each rebuild.
2. **Relax the gap for exact-title matches.** When two titles normalize
   **identically** in the same course, widen the allowed due-date gap (the
   current 21-day same-title cap is the lever) or drop the gap requirement when
   one side has no date — a professor moving "HW 3" a week later is still "HW 3."
   Keep the tight ~26h tolerance only for the *fuzzy* (non-identical) title tier,
   where false merges are the real risk.

## 6. Migration / backfill

- First launch after the change: seed the store from the current live fetch;
  nothing to migrate (assignments were never persisted before).
- Completions (`completedAssignmentIDs`), hidden/deleted courses, names, and the
  course-id cache stay in `UserDefaults` and continue to key by `Assignment.id` /
  course code — unchanged, so no data loss on upgrade.

## 7. Bulletproof testing (the "how do we know it's solid" piece)

The failure modes are **multi-sync sequences** you can't reproduce by hand, so
we encode them as deterministic fixtures. Extends existing patterns in
`HardeningTests`, `CanvasICSTests`, `SubmissionDetectionTests`,
`AssignmentDeduplicatorTests`.

### 7.1 Feed-simulation harness
Drive `AppState` (or a testable `AssignmentStore`) through an ordered list of
`(ICS payload, Gradescope payload)` snapshots and assert invariants **across**
the sequence.

### 7.2 Scenario tests (each a named multi-sync case)
- Item present in sync 1, absent in sync 2 → **still present** (not lost).
- Completed item that leaves the feed → **still in Done**.
- Same assignment, date moved on Gradescope between syncs → **stays one merged
  item**, not two.
- Empty/partial fetch after a full one → **prior data retained**, soft notice.
- Prior-term item → aged out; current-term item with nothing due → retained.
- Submission reported in sync 1, session expired in sync 2 → **submitted state
  persists**; a later real refute (retracted) clears it.

### 7.3 Invariant / property tests
- No **incomplete, in-term, selected** assignment is ever silently dropped
  across any sync sequence (extends the near/later "whole-pool" guarantee to the
  persistence layer).
- Reconciliation is idempotent: replaying the same fetch twice changes nothing.

### 7.4 Recorded real feeds
Capture 1–2 anonymized real ICS payloads from the account as fixtures, so tests
run against Canvas's actual quirks (calendar-style `include_contexts` URLs, term
descriptors), not idealized data.

## 8. Suggested build sequence (when we implement)

1. `AssignmentStore` (SwiftData) + `StoredAssignment` ⇄ `Assignment` mapping,
   behind the current API so nothing else changes yet.
2. Reconciliation + partial-fetch guard; point `rebuildDashboardItems` at the
   store. Ship "lost assignments" + "class list" fixes.
3. Persist submission/grade flags on the ledger.
4. Dedup hardening (persisted pairings + relaxed exact-title gap).
5. Feed-simulation harness + scenario/invariant tests throughout (write the
   failing test first for each fix).
6. Move the widget onto the shared store; retire `WidgetSnapshot` bridge.

## 9. Open questions

- **Deployment target** — is it iOS 17+ (SwiftData) or lower (fall back to a
  Codable snapshot in the App Group)? Confirm before step 1.
- **Aging window** — 14 days gone-from-feed-and-overdue before hiding: right
  default, or configurable?
- **Store vs. AppState boundary** — does `AssignmentStore` own reconciliation and
  `AppState` observe it (cleaner, testable), or does `AppState` keep the logic
  and just gain a persistence sidecar? Leaning the former.
