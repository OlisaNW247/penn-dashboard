# How saving works, and how to add more

_Written 2026-08-23 for v4. Describes the persistence layer as it stands on
`v4`. If you are reading this because you want to store one more thing and
don't want to re-derive the design, skip to §4 — but §1 is why §4 looks the way
it does._

---

## 1. What the app used to do, and why it lost your work

`AppState.canvasItems` and `gradescopeItems` were ordinary in-memory arrays.
They started **empty on every launch**. `init()` restored your name, the Canvas
feed URL, your completions, your hidden courses — but never the assignments
themselves. Then `sync()` did this:

```swift
canvasItems = fetched
```

A wholesale replace. Which means the app's idea of "what I owe" was never
anything more durable than a snapshot of the single most recent network fetch.

Three completely ordinary events broke that:

- **Canvas's calendar feed is a rolling window.** Old items and prior-term items
  drop out of it on Canvas's schedule, not yours. Gone from the feed meant gone
  from the app — *including things you had already ticked off*, so the Done tab
  emptied itself over time.
- **A professor moves or briefly unpublishes an assignment.** It's missing from
  one fetch. The replace takes it from there.
- **One flaky fetch.** An expired session, a 401 on a single concluded course, a
  dropped connection — any of these could return few or zero items, and the
  replace wrote that nothing over everything.

The empty class list was the same disease wearing a different hat:
`allCourseCodes()` derived live from those same empty-at-launch pools, so until
the first sync came back you had no classes at all.

The fix is not "fetch more carefully." No amount of careful fetching helps,
because the architecture had no memory to be careful *with*. It needed a
database that fetches **edit** rather than replace.

---

## 2. What replaced it: the ledger

Two types, both in
`LowHangingFruitKit/Sources/LowHangingFruitKit/Persistence/`:

- **`StoredAssignment`** — a SwiftData `@Model` class. One row per assignment
  the app has ever seen from a feed, keyed by `id` in the form
  `"source:sourceID"`, which is byte-identical to `Assignment.id`. That 1:1
  mapping is deliberate: everything downstream (dashboard buckets, dedup,
  notifications, Grade Watcher) keeps consuming the plain value-type
  `Assignment`, so the ledger is the only new seam in the app.
- **`AssignmentStore`** — the class that owns the container, and the only thing
  allowed to read or write rows.

The row carries three groups of fields beyond the display ones. The
**lifecycle** group (`firstSeen`, `lastSeenInFeed`, `isGoneFromFeed`) is the
whole point of the exercise: an item leaving the feed gets *recorded as having
left*, never silently dropped. The **completion** group (`userCompleted`,
`completedAt`, `isCompletionOnly`) makes the ledger the authoritative record of
what you finished rather than a mirror of some other record. And the
**submission/grade** group (`canvasSubmitted`, `gradescopeSubmitted`,
`scoreEarned`, `scoreMax`) persists what Grade Watcher learns, so the app knows
what you turned in even on a launch with no Canvas session.

### 2.1 `reconcile()` — the core algorithm

`AssignmentStore.reconcile(_:source:now:)` replaces `canvasItems = fetched`. It
runs after each Canvas or Gradescope fetch and does three things.

**It upserts what came back.** For every item in the fetch, if a row with that
id exists, `refresh(from:now:)` copies the feed-supplied fields onto it —
title, due date, URL, term — sets `lastSeenInFeed = now`, and clears
`isGoneFromFeed`. Everything the *ledger* owns survives untouched: `firstSeen`,
the completion, the submission flags, a confirmed cross-platform pairing. If no
row exists, it inserts a fresh one via `StoredAssignment.make(from:now:)`.

**It flags what didn't come back, and deletes nothing.** Every existing row for
that source whose id wasn't in the fetch gets `isGoneFromFeed = true`. That is
the entire deletion policy: there isn't one. A professor hiding an item for an
afternoon, a feed reshuffle, a course rolling off — all of it is recorded, none
of it destroys anything.

**It refuses a suspiciously empty fetch.** Before doing any of the above:

```
if fetched.isEmpty && the ledger already holds real rows for this source:
    keep everything, return the prior data, set wasSuspectedPartial = true
```

A source that had thirty assignments yesterday and returns zero today is
overwhelmingly more likely to be a network blip or a dead session than every
assignment on earth being cancelled. The caller gets `wasSuspectedPartial` back
in the `ReconcileResult` and can show a soft "couldn't refresh" notice instead
of a wiped dashboard. Note the exact condition — *empty*, not *small*. A fetch
that returns three of thirty items still flags the other twenty-seven as gone,
and that is fine, because flagging gone doesn't lose anything.

One subtlety in that guard: completion-only rows (§2.3) don't count as "this
source previously had items." They're bookkeeping. Letting them arm the guard
would refuse a legitimately empty first sync for someone who just upgraded.

### 2.2 Aging — deliberate removal, replacing accidental loss

Nothing is ever deleted, so something has to stop abandoned rows piling up
forever. That's `isAgedOut`, and it is deliberately hard to trigger. A row ages
out only when **all** of these hold:

| Clause | Why it's there |
|---|---|
| **Not finished.** `isFinished` — ticked off, or reported submitted by Canvas or Gradescope — is exempt outright. | Aging exists to clear *abandoned* work, and finished work is the opposite of abandoned. It's the archive the Done tab is built from. Without this clause, something you turned in would silently vanish from your own record two weeks after it rolled off the Canvas feed. |
| **Gone from the feed.** `isGoneFromFeed` must be true. | Anything the feed is still publishing is, by definition, still live. |
| **Has a due date.** `dueAt != nil`. | An undated item has no clock to be overdue against, so there is no honest moment to declare it stale. Undated items never age out, ever. |
| **Overdue past the grace period.** `due < now - goneGracePeriod`, where `goneGracePeriod` is **14 days**. | Being overdue isn't enough — you might be about to turn it in late. Two weeks past due *and* gone from the feed is the point where "this no longer exists" becomes a safer bet than "this is still owed." |

`goneGracePeriod` is `nonisolated` on `AssignmentStore` specifically so the
widget's off-main-actor read (`LedgerWidgetReader.isAgedOut`) applies the
identical number instead of hardcoding its own copy. The two implementations
are duplicated because one is main-actor-isolated and the other can't be; they
must stay in step.

The generosity is a design choice, not sloppiness: a stale item lingering on
your dashboard for an extra fortnight is a mild annoyance. Losing real work is
the one failure this app cannot have.

### 2.3 Two things that will confuse you later

**Uniqueness is a code invariant, not a database constraint.** `id` used to
carry `@Attribute(.unique)`. It doesn't any more, because CloudKit doesn't
support unique constraints and keeping it would make sync impossible to ever
enable. Uniqueness now lives in `AssignmentStore.rowsByID()`, which every read
and every write goes through: it builds an id-keyed map of the whole table, and
when it finds two rows for one id it merges them via
`StoredAssignment.absorb(_:)` and deletes the loser. Removing the attribute
also fixed a quieter bug — SwiftData enforced `.unique` as a last-write-wins
overwrite, so a collapsed duplicate silently threw away the older row's
`firstSeen`, `completedAt` and pairing. `absorb` keeps them. Every rule in it
resolves toward retention: earliest `firstSeen`, latest `lastSeenInFeed`,
`isGoneFromFeed` only if both copies agree, any evidence of completion wins, a
known score beats no score.

**Completion-only rows.** `isCompletionOnly` marks a row that exists *only* to
remember that you ticked something off. Two paths need it: manual and recurring
tasks, which no feed ever reconciles into the ledger so there's no row to write
onto; and completions migrated out of the old UserDefaults set for an
assignment whose feed hasn't synced yet. Nothing but the identity on such a row
is trustworthy, so it's hidden from every read of "assignments the app knows
about" — dashboard, Done, widget, Settings stats. The instant a real feed item
with that id arrives, `refresh(from:now:)` clears the flag and promotes the row
in place, and the completion that was waiting on it rides along. That promotion
is what lets someone upgrading from a pre-ledger build keep work they'd already
finished.

---

## 3. Three tiers of storage, and how to pick one

The app stores things in three places, on purpose. They are not
interchangeable.

**Tier 1 — the SwiftData ledger.** `AssignmentStore` (`Assignments.store`) and
`GradeHistoryStore` (`GradeHistory.store`), both in the App Group container.
This is for **data the student created, or that is their own record of
something**: completions, observed grade readings, manual assignments,
submission and score truth. It's queryable, it survives a reinstall through the
container, and it's the only tier that could ever ride an iCloud sync.

**Tier 2 — the App Group `UserDefaults` suite**, reached through
`UserDefaults.lhf` in `Persistence/SharedDefaults.swift`. This is for
**preferences**: your name, the captured Canvas feed URL, hidden and deleted
course keys, appearance mode, reminder lead times, the digest hour, watched
courses, course-name overrides. The defining property is that every one of them
is cheap to re-enter and meaningless off-device. Losing your reminder lead
times is a thirty-second annoyance; losing your completions rewrites your own
history.

**Tier 3 — the Keychain**, via `LowHangingFruitUI/SessionCookieStore.swift`.
This is for **live credentials and nothing else**: the Canvas and Gradescope
session cookies captured from the in-app WebView. They're written with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — encrypted at rest,
readable after first unlock so the launch-time auto-sync can replay the
session, and never migrated off the device.

### The test

Ask, in this order:

1. **Is it a live credential or token?** → Keychain. No exceptions, and don't
   let it near a `@Model` or a defaults key.
2. **If the student lost it, could they get it back by tapping a few things?**
   → preferences, tier 2. A URL, a name, a toggle, a set of hidden courses all
   pass this test.
3. **Otherwise it's a record — of what they did, or of what was true at a moment
   in time — and nothing can re-derive it.** → the ledger, tier 1.

Grade history is the clarifying example. It looks like a settings blob, and it
used to be one (`gradeWatcherHistory`, a JSON dictionary in UserDefaults). But
`GradeEngine.trajectory` can replay today's items against their due dates and
tell you how the term built up; it *cannot* tell you what changed since you
last looked, because a regrade, a late posting or a dropped-lowest kicking in
all move the current number without moving any due date. Those `(day, percent)`
readings are the only thing in the app that can answer that question, and
nothing can reconstruct them. That makes them tier 1, which is exactly why
`LegacyStateMigration` drags them out of UserDefaults and onto
`StoredGradeObservation` rows.

---

## 4. How to add a new persisted thing

The recipe, in order.

### Step 1 — add the property, optional or defaulted. Always.

```swift
/// One sentence on what it means, and one on why the default is that value.
public var isArchived: Bool = false          // defaulted
public var archivedAt: Date?                 // or optional
```

Never a bare non-optional with no default. This single rule buys two separate
things:

- **It keeps the change a lightweight migration.** SwiftData can add a column to
  a store that already exists on disk *provided it knows what to put in the rows
  already there*. An optional gets `nil`; a defaulted property gets the default.
  A non-optional with no default has no answer, and you are suddenly writing a
  versioned schema and a migration plan for what should have been a one-line
  change.
- **It keeps the schema CloudKit-eligible.** CloudKit requires every property on
  a synced model to be optional or defaulted. Sync is not on today (see
  `docs/database-explained.md` §5), but every property that violates the rule is
  one more thing to fix before it ever can be.

`StoredGradeObservation` is the model to copy: every property is defaulted,
including `courseID = ""` and `observedAt = .distantPast`, which look silly in
isolation and are exactly right.

Then decide what the new field does in each of the three lifecycle hooks on
`StoredAssignment` — skipping one of these is the usual way a new field ends up
half-working:

- **`make(from:now:)`** — what does a brand-new row get? Usually the default,
  but if the feed supplies it, read it here.
- **`refresh(from:now:)`** — does the *feed* own this field, or does the
  *ledger*? Feed-owned fields get overwritten on every sync. Ledger-owned fields
  must not appear in this method at all. Getting this backwards is how you write
  a field that silently resets itself every fifteen minutes.
- **`absorb(_:)`** — when two rows for one id collapse, which value survives?
  Resolve toward whatever the student would notice missing. Every existing rule
  in that method does.

### Step 2 — thread it through `AssignmentStore`

Nothing outside `AssignmentStore` touches rows, so the new field needs a way in
and a way out. Follow the shape already there:

- A **write** method that takes value types rather than rows, resolves through
  `rowsByID()`, mutates, and calls `try? context.save()` exactly once at the end
  — see `setCompleted(ids:at:clearing:prototypes:now:)`.
- A **read** method returning plain `Sendable` values, not `StoredAssignment`
  instances — see `completionRecord()` and `submittedCanvasAssignmentIDs()`.
  Handing a `@Model` object out of the store is how the uniqueness invariant
  leaks.
- If the field changes what should be *shown*, it belongs in `isVisible` or
  `isAgedOut`, and the widget's mirror of `isAgedOut` in
  `Widget/LedgerWidgetReader.swift` has to change with it.
- If it's a diagnostic worth seeing, add it to `LedgerStats` and to the
  Settings → Storage section.

Be careful about replace-versus-merge semantics. `applySubmissionState` is a
deliberate **full replace** so that a retracted submission can go back to
unsubmitted — and that design is exactly what made the partial-refresh bug so
destructive when a caller handed it a partial set (see `docs/v4-changes.md`).
If your new field is a replace, say so in a comment at the method.

### Step 3 — write the migration, if existing rows need one

Only needed if the correct value for an existing row is something other than the
default. The pattern is `LowHangingFruitUI/LegacyStateMigration.swift`:

- Bump `currentVersion` and add your step. `runIfNeeded` runs every step the
  stored version hasn't reached; the version lives under `ledgerMigrationVersion`
  in `UserDefaults.lhf`.
- **Version-gate it, and still write it to be safe to re-run.** These are not
  redundant. The gate makes it one-time in the ordinary case. But the version key
  is itself just a UserDefaults value, and a device restored from backup can
  present a stale one — so every step underneath is independently idempotent as
  well. An already-completed row is left alone; a course that already has
  observations is skipped entirely. Assume your step *will* run twice, and make
  sure that's harmless.
- **Only bump the version once every store that had somewhere to write got its
  turn.** `runIfNeeded` bumps only when both stores were non-nil, because a
  launch where one store failed to construct would otherwise mark the whole
  migration done and strand the other's data permanently.
- **Read from `UserDefaults.lhf`, never `.standard`.** `UserDefaults.lhf` is a
  lazy `static let` whose initializer runs `SharedDefaultsMigration`, so merely
  touching it guarantees the legacy blobs have already been copied out of the
  app's private domain into the shared suite. Point a migration at `.standard`
  instead and an upgrading user's data sits in the shared suite with nothing
  looking for it.
- **Don't delete the legacy keys.** They cost a few kilobytes. Leaving them means
  someone who downgrades to an older build — or a migration that has to be re-run
  after a bug — still has the original data to read. They simply stop being
  written. The same reasoning applies to `SharedDefaultsMigration.legacyKeys`,
  which is a deliberately **frozen** list: keys added after the App Group move
  are born in the shared suite and have nothing to migrate, so a new key missing
  from that list is correct rather than an omission.

### Step 4 — test it against a store a previous build created

Unit-testing the new field in isolation proves almost nothing. The failure you
care about is the upgrade. Two suites show the pattern:

- **`Tests/LowHangingFruitKitTests/MigrationChainTests.swift`** runs *both*
  migrations in the order `AppState.init` runs them, on one simulated launch,
  against scratch defaults suites — never `.standard`, because a test that leaked
  state would fail the *next* suite rather than itself. It exists to catch
  failures in the seam between migrations, not in either one alone.
- **`Tests/LowHangingFruitKitTests/AssignmentStoreTests.swift`** and
  `AssignmentLedgerScenarioTests.swift` replay multi-sync, multi-launch sequences
  and assert the invariants: vanished item survives, empty fetch keeps data,
  completed stays in Done, moved date stays one card.

Minimum bar for a new persisted field: construct a store with rows written
*without* the field, open it with the new code, and assert nothing was lost and
that running the migration twice changes nothing.

---

## 5. The failure modes that are easy to reintroduce

**No App Group entitlement means the app silently stops saving.**
`AssignmentStore.makeDefault()` asks `FileManager` for the App Group container;
if it isn't there, it falls through to `try? AssignmentStore(inMemory: true)`.
That fallback is correct — it's what lets unit tests and SwiftUI previews run
hermetically, and it means a broken entitlement degrades instead of crashing. It
is also *completely invisible from inside the app*. Everything works. The
dashboard populates, ticking things off works, the sync spinner spins. Then you
relaunch and it's all gone.

This is the entire reason Settings has a **Storage** section. `LedgerStats`
carries `isPersistent`, and the panel says either "Saved on this device." or
"Not saving — assignments will be lost when the app quits." If you ever touch
entitlements, provisioning, or the widget target, that line is the first thing to
check on device.

**`UserDefaults(suiteName:)` lies.** It returns a perfectly usable object for
almost any string you hand it, entitled or not. So this is not a test:

```swift
if let suite = UserDefaults(suiteName: appGroupID) { /* proves nothing */ }
```

The real test — the one `SharedDefaults.sharedSuite()`,
`AssignmentStore.makeDefault()` and `WidgetSnapshotStore` all use, so that all
three agree about when the group is available — is asking the file system:

```swift
FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
```

If you add a fourth thing that needs the container, use the same test.

**Writing a preference to the wrong domain.** Every LHF preference read and write
goes through `UserDefaults.lhf`. Reach for `UserDefaults.standard` directly and
you've written into the app's private domain, where the widget extension — a
separate process with its own private `.standard` — physically cannot see it.
The bug shows up as "the widget disagrees with the app," which is a long way from
the line that caused it.

**Running the shared-defaults migration from inside the extension.**
`SharedDefaults.isAppExtension` guards against exactly this. An extension's
`.standard` never held the app's preferences, so migrating from it would copy
nothing, plant the "already migrated" marker in the shared suite, and strand the
app's real data in a domain nothing reads any more.
