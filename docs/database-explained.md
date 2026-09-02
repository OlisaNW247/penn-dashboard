# What the database is, per user

_Written 2026-08-23 for v4. Companion to `docs/persistence-explained.md`, which
covers how the ledger works and how to extend it. This one answers the more
basic question: when the app says "your data is saved," what is actually on
disk, whose disk, and what happens to it._

---

## 1. What SwiftData actually is here

SwiftData is an Apple framework that sits on top of SQLite. You declare a Swift
class with `@Model` — `StoredAssignment`, `StoredGradeObservation` — and each
instance becomes a row in a table. `ModelContainer` opens the file,
`ModelContext` reads and writes it, `context.save()` commits.

That is the whole of it. There is **no server, no account, and no network**.
Nothing about SwiftData involves iCloud unless you explicitly ask for it, and
this app doesn't (§5). When `AssignmentStore.reconcile()` runs, the only thing
that leaves the process is a write to a local file.

The word "database" is doing less work than it usually does. It is not a
service. It's a file.

---

## 2. What one student's database physically is

Two files, in a directory on that student's phone:

```
<App Group container>/
    Assignments.store      ← AssignmentStore   (StoredAssignment rows)
    GradeHistory.store     ← GradeHistoryStore (StoredGradeObservation rows)
    widget-snapshot.json   ← WidgetSnapshotStore (the widget's "next due" cache)
```

The App Group container is identified by **`group.com.lhf.lowhangingfruit`**,
declared in three places that must agree: `App/LHFApp.entitlements`,
`LHFWidget/LHFWidget.entitlements`, and `WidgetSharing.appGroupID` in
`Widget/WidgetSnapshot.swift`. `AssignmentStore.appGroupID` hardcodes the same
string; `SharedDefaults.appGroupID` and `GradeHistoryStore.appGroupID` both
forward to `WidgetSharing`.

Alongside those files, the same container holds the shared `UserDefaults` suite
— the same identifier, used as a suite name — which is where every LHF
preference lives (`UserDefaults.lhf`).

That's it. One student, one phone, three files and a plist. There is no row
anywhere that belongs to two students, because there is nowhere for such a row
to be.

Each store also carries a second, invisible piece of state worth knowing about:
`isPersistent`. If the App Group container isn't reachable, both stores fall
back to an in-memory store and `isPersistent` goes false — the app keeps
working perfectly and saves nothing. See `docs/persistence-explained.md` §5;
it's the failure mode most worth remembering.

### Why grade history is a separate file

The widget extension opens `Assignments.store` with a `ModelContainer` declaring
exactly one entity (`LedgerWidgetReader`). If the app added a second entity to
that same container, the two processes would hold different ideas about the
schema of one file. Grade history is of no use to a widget, so it gets its own
file in the same directory and the widget's read stays trivially safe.

---

## 3. Why the App Group container, and not the app's own sandbox

By default an iOS app writes to its own private sandbox, which nothing else can
read — including its own widget. **A widget extension is a separate process with
its own sandbox.** It cannot open the app's private Documents directory, and it
cannot read the app's private `UserDefaults.standard` domain either.

An App Group is the mechanism Apple provides for exactly this: a container that
every process holding the same entitlement can open. So the ledger lives there,
because the widget needs to read assignments.

This is also the entire reason `Persistence/SharedDefaults.swift` exists.
Preferences used to sit in `UserDefaults.standard`, and the widget physically
could not see completions, hidden and deleted courses, or manual assignments.
Moving the same keys into the App Group suite — without renaming a single one —
put them somewhere both processes can reach.

You can still see the seam that predates it: `LedgerWidgetReader` derives
"finished" from the ledger's own `isFinished` / `completedAt` fields rather than
from the real completion set, because at the time it was written the real
completion set was in a domain the widget couldn't open.

---

## 4. Lifecycle — the questions you will actually ask

**What survives an app update?** Everything. An update replaces the app binary;
it doesn't touch the container. New `@Model` properties added as optional or
defaulted are applied as a lightweight migration by SwiftData, and the
one-time migrations in `LegacyStateMigration` and `SharedDefaultsMigration` run
on the first launch that needs them. Completions, grade history, class
selection, syllabus schemes and manual weights all carry across — that path is
exercised by `MigrationChainTests`.

**What happens on delete-and-reinstall?** **Everything is gone.** Deleting the
app removes the App Group container along with it, and the Keychain items with
it. Both `.store` files, the shared defaults, the widget snapshot, the session
cookies — all of it. A reinstall starts from a genuinely empty database and the
student signs in to Canvas again from scratch. There is no server-side copy to
restore from, because there is no server. `docs/PRIVACY.md` states this to the
user in the same terms, and it is accurate.

This is the one lifecycle answer people find surprising, so don't soften it. An
uninstall is a full data loss, by design.

**Device backup and restore?** Nothing in the codebase marks any of these files
as excluded from backup — there is no `isExcludedFromBackup` anywhere — so they
follow iOS's default and are included in an encrypted device backup along with
the rest of the app's data. Restoring that backup onto a phone should therefore
bring the ledger with it.

The Keychain half is different and is verifiable from the code: session cookies
are written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they do
**not** travel to a different device and are not in an unencrypted backup. The
practical consequence is that a restored install should have its assignment
history but will need a fresh Canvas login.

> **Not verified.** I have not actually performed a backup-and-restore of this
> app. The above follows from the documented iOS defaults plus the absence of any
> backup-exclusion code, not from an observed test. If it matters, test it before
> relying on it.

**What would iCloud sync change?** See §5 — it is not enabled.

---

## 5. CloudKit: prepared for, deliberately not on

**Sync is not enabled.** `ModelConfiguration(cloudKitDatabase:)` is set nowhere
in the codebase. Every mention of CloudKit in the source is a comment
explaining a decision made *in anticipation* of it. If someone asks whether LHF
syncs between their iPhone and iPad, the answer today is a flat no.

What has been done is keep the schema *eligible*, so that turning it on later
is a configuration change and not a rewrite. Two rules:

- **`@Attribute(.unique)` was removed from `StoredAssignment.id`.** CloudKit
  does not support unique constraints. Uniqueness moved into code, in
  `AssignmentStore.rowsByID()`, and `absorb(_:)` defines what a collision
  resolves to — which is also what a merge between two devices would need.
- **Every property added since is optional or defaulted.** CloudKit requires
  this of every property on a synced model, since it must be able to
  materialize a record that a peer wrote without the field.

If sync is ever switched on, the merge semantics are already written down:
`absorb(_:)` resolves toward retention on every field — earliest `firstSeen`,
latest `lastSeenInFeed`, gone-from-feed only if both copies agree, any evidence
of completion wins, a known score beats no score. That is deliberate. Two
devices disagreeing is already a surprise; it must not also be the thing that
loses a completion tick.

> **Gap to close before enabling sync.** "Every *new* property is
> optional-or-defaulted" is true, but it is not the same as the schema being
> fully eligible. `StoredAssignment` still has eleven properties that are
> non-optional with no default, all predating the CloudKit decision: `id`,
> `sourceRaw`, `sourceID`, `kindRaw`, `course`, `title`, `firstSeen`,
> `lastSeenInFeed`, `isGoneFromFeed`, `canvasSubmitted`, `gradescopeSubmitted`.
> Each would need a default before `cloudKitDatabase:` could be set.
> `StoredGradeObservation` is already clean — every property on it is defaulted.
> This is a real, small piece of work, not a blocker; it just hasn't been done,
> and no comment in the code says so.

---

## 6. What is deliberately *not* in the database

**Live session cookies.** Canvas and Penn SSO session cookies live in the
Keychain (`LowHangingFruitUI/SessionCookieStore.swift`), under the service name
`com.lhf.lowhangingfruit.session`. They are there rather than in the ledger for
two reasons. They're live authentication tokens, so they need to be encrypted at
rest and kept out of unencrypted backups — which the Keychain gives you and a
SQLite file does not. And they are pinned to this device with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which is a deliberate
security decision: syncing a live Penn SSO session to a second device is not a
convenience feature, it's a way to have one stolen phone hand over an active
university session. If CloudKit is ever enabled, cookies must stay out of it.

`WKWebsiteDataStore` drops session cookies (the kind with no expiry, which is
exactly what Gradescope and Penn SSO use) when the app quits, which is why the
Keychain copy exists at all — without it, you'd be silently logged out on every
relaunch.

**Preferences.** Everything in tier 2 of `docs/persistence-explained.md` §3.
They live in the shared `UserDefaults` suite because they're cheap to re-enter
and meaningless off-device, and putting them in a queryable database would buy
nothing.

---

## 7. Is my data private?

Short version, suitable for adapting into the App Store listing. Every claim
below is checkable against the repo, and I checked them:

- **No server, no account.** There is no LHF backend, so there is nothing for
  your data to be uploaded to. The app never creates an account.
- **No analytics, no tracking, no advertising.** `App/PrivacyInfo.xcprivacy` and
  `LHFWidget/PrivacyInfo.xcprivacy` both declare `NSPrivacyTracking` false, an
  empty `NSPrivacyTrackingDomains`, and an empty `NSPrivacyCollectedDataTypes`.
- **No third-party SDKs.** `LowHangingFruitKit/Package.swift` declares no
  external package dependencies at all. The only code in the app is the app's
  own and Apple's frameworks.
- **The only network requests are to the student's own school services** —
  Canvas at `canvas.upenn.edu`, and Gradescope if they connect it — using their
  own logged-in session. The app never sees or stores a password; sign-in
  happens on the service's own web page inside a WebView.
- **Reminders are local.** They're scheduled and delivered on-device via
  `UNUserNotificationCenter`. There is no push service and no notification data
  leaves the phone.
- **Syllabus documents are read on-device** and only the grading section is
  extracted. Neither the document nor its text is uploaded.
- **Deleting the app removes everything**, including the Keychain sessions.

The user-facing version of all of this is `docs/PRIVACY.md`, which is consistent
with what's in the code. If you change what the app stores or where it sends a
request, that file and the two privacy manifests are what have to change with
it.
