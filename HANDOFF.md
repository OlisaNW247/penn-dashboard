# Low Hanging Fruit — Handoff

_Last updated: 2026-09-02. This section supersedes everything below the
first "Superseded" marker; read `CLAUDE.md` first for commands, storage
tiers, traps, and the overseer/doer working model._

## ⚠️ Current state: `assistant-ui` is the line

**New work goes on `assistant-ui`** (tracking `origin/assistant-ui`), cut
2026-09-02 from `origin/v6`. Everything is pushed; the tree is clean.

Two commits on top of `v6`:

- `cda2794` — the **ask** screen: a chat over the student's own class
  context, plus the button swap that gave it the bottom-right corner.
- `3c50275` — the **real Claude backend** behind it, keyed off the
  student's own Anthropic API key.

**Verified green baseline (owner's Mac, 2026-09-02): 736 tests / 76
suites**, zero failures, plus a clean iOS simulator build. Both gates were
run on the Mac this session — this is not a predicted number.

**Bonus finding: `v6`'s own baseline is now verified.** `v6` shipped its
Announcement Watcher work uncompiled and predicted 693 tests / 70 suites.
That is exactly what it produces on a real Mac. The v6 patch compiles as
written; the note below claiming it is unverified is now closed out.

## What ask is, and what state it's in

The **UI is a prototype the owner has seen and called "not quite there"**
— they like it and specifically flagged it as a good fit for part of
**onboarding**. Treat the current screen as a design study to be reworked,
not as settled. The backend under it is real and is the part to build on.

Files, all new unless marked:

| Path | What |
|---|---|
| `LowHangingFruitUI/AssistantView.swift` | The screen. Branch backdrop, hanging suggestions, transcript, composer. |
| `LowHangingFruitUI/BranchBackdrop.swift` | The bough as a real Bézier (`BranchGeometry`), queryable by the layout. |
| `LowHangingFruitUI/PersimmonMark.swift` | The app's mark as a vector, 22–60pt, dark-mode aware. |
| `LowHangingFruitUI/AssistantConversation.swift` | Transcript state, streaming, stop/clear. |
| `LowHangingFruitUI/AssistantResponder.swift` | `AssistantResponder` protocol, `AssistantContext`, and the scripted stand-in. |
| `LowHangingFruitUI/ClaudeAssistantResponder.swift` | The real backend. SSE streaming over `URLSession.bytes`. |
| `LowHangingFruitUI/AssistantContextAssembly.swift` | `AppState` → context document. **The disclosure boundary.** |
| `LowHangingFruitKit/Assistant/AssistantContextDocument.swift` | The byte-stable context document builder. |
| `ContentView.swift` (modified) | `.assistant` route; fruit FAB; add-assignment moved to the filter row. |

**No `xcodegen generate` is needed** — the app consumes
`LowHangingFruitKit` as a local SPM package, so new files under `Sources`
are picked up without touching `project.yml`. Do not regenerate.

## The one thing that blocks the flagship demo

The screen's own headline example — *"what's my phys attendance policy"* —
**cannot be answered from real data**, and this is a data problem, not a
model problem.

`SyllabusSetupView` does ingest syllabus text (PDF, Canvas page, pasted).
`SyllabusParser` keeps only the grading section and **discards the prose**.
There is no attendance policy, late-work policy or office-hours text
anywhere on disk to send. Announcement bodies are gone too:
`announcementItems` holds rows the watcher *extracted*, not the
announcements, whose `AnnouncementSourceText` is transient.

So ask can currently answer: what is outstanding, what is due when, what a
class's grade categories weigh, what is done. It cannot answer any policy
question.

The context document says so in its own header and instructs the model to
admit the gap rather than infer — because a page of due dates and
percentages *looks* complete, and a model handed it will otherwise invent
a plausible policy. **Do not remove that line** while the gap exists.

**Retaining syllabus text is the unlock, and it is a real decision, not a
chore**: that same screen currently promises the student "it stays on your
phone." Scope it deliberately.

## Design decisions that must not be accidentally undone

Four things in this work look like they could be simplified and cannot:

1. **The context document never reads a clock** and never emits a relative
   date. It is a prompt-cache prefix, and caching is a *prefix match* — one
   changed byte re-bills the whole document on every question. The
   obvious-looking "put today's date at the top so the model knows what day
   it is" is exactly what guarantees a 0% cache hit rate. The date goes in
   the user message, after the `cache_control` breakpoint.
2. **`assistantSourceLabel` has no `default:` case.** That is deliberate.
   It is a disclosure boundary, so adding a seventh `Assignment.Source`
   should stop the build there and make someone decide what a third party
   gets told about it.
3. **Citations come back through a `<sources>` delimiter, not tool use.**
   Tool use would cost a second round trip and kill the streaming feel. The
   parser buffers on a partial match so `<sou` never flashes on screen and
   gets yanked back.
4. **Refusals arrive as HTTP 200** with `stop_reason == "refusal"`, not as
   an error status. Code that reads `content[0]` blind breaks on them.

Request shape, checked against current API docs this session:
`claude-opus-5`, `max_tokens` 2048, `stream: true`,
`output_config.effort: "low"` (retrieval-style Q&A, latency-sensitive),
`fallbacks: "default"` with header `server-side-fallback-2026-07-01`. **No
`thinking` field** (adaptive is the default on that model and
`budget_tokens` is a 400) and **no `temperature`/`top_p`/`top_k`** (also
400). Do not "helpfully" add them back.

## Never verified

- **No call has ever been made against the live Anthropic API.** Every
  test is offline by construction. The SSE event shapes, the refusal
  payload, and the beta header's real behaviour are unproven against a
  live endpoint. This is the highest-value next check and needs only a real
  key and one question.
- **The ask screen's solid bough is unverified on screen.** A device
  screenshot caught that `Path.addLines` *moves* rather than connects, so
  the branch was rendering as two hairlines with the page showing between
  them. The fix compiles and tests pass, but the simulator stopped
  responding before it could be photographed. Look at this first.
- The API key field itself already exists (Settings, added by `v6` for the
  Announcement Watcher). ask reads that same key — **do not add a second
  key field.**

## Owed before this could ship

1. **`CLAUDE.md` and `docs/PRIVACY.md` overstate the privacy position.**
   `CLAUDE.md` is corrected as of this session; `docs/PRIVACY.md` is **not
   touched** deliberately — it is published App Store material and should
   not be rewritten to describe an unshipped feature. Revisit at ship time.
2. **A pre-existing flake.** `CourseContentDashboardTests` ("flipping a
   content decision never changes `canvasCourseIDsByCode`…") failed once in
   a full run, then passed three consecutive full runs, and passes in
   isolation. It races another suite over shared `UserDefaults` — the trap
   `CLAUDE.md` documents. Untouched by this work. Fix the isolation at the
   source; do not relax the assertion.
3. The device build is signed and ready
   (`Apple Development: Gabriel Nkolisa Nwogugu`, team `24A3TDB277`,
   Developer Mode on) but the owner's iPhone was not connected, so it was
   never installed. `tunnelState: unavailable`, last seen 2026-08-28.

## Next actions, in order

1. Look at the ask screen on a device; confirm the bough fills solid.
2. Paste a real API key and ask one question — the first live call.
3. Decide the syllabus-text question. Without it ask cannot answer policy.
4. Rework the UI, likely toward onboarding, per the owner's read.
5. Fix the `CourseContentDashboardTests` flake.
6. Independent of all of this: the Mac App Store upload, still owed from
   the `v6` session below.

---

# Superseded: state as of 2026-08-31 (the `v6` line)

_Last updated: 2026-08-31, end of an overnight session. This section
supersedes everything below the "superseded" marker; read `CLAUDE.md`
first for commands, storage tiers, traps, and the overseer/doer working
model (which now includes model-tier routing — added this session)._

## ⚠️ Current state: `v6` is the line

**New work goes on `v6`** (tracking `origin/v6`), cut 2026-08-31 from the
head of the PR #8 line, so it already contains everything ever pushed to
`claude/gradescope-term-scope`. That PR (#8 → `v5`) is still open; merging
it and later merging `v6 → v5` are both clean because `v6` is a superset.
`claude/handoff-continuation-bn0e5m` is **dead work from a stale-`main`
mistake — never resume it**, and never start from `main`'s HANDOFF.

Two very different verification states coexist on `v6`:

- **Verified green baseline (owner's Mac, 2026-08-30): 663 tests /
  67 suites**, zero failures — everything up to and including the
  connection-notice banner compiled and passed there.
- **The v6 feature work on top is UNCOMPILED** (written in a Linux
  container with no Swift toolchain): Grade Watcher entry points back on
  + the whole Announcement Watcher (~2,500 lines, ~30 new tests).
  Expected: **693 tests / 70 suites**. Anything else means the patch
  doesn't compile as written — not a flaky count. Gate checklist and the
  full design record: `docs/ANNOUNCEMENT_WATCHER_PLAN.md`. An
  independent source review of the branch diff found no blockers; its
  open nits are listed there.

## What landed this session (2026-08-30 → 31)

Compiled and verified by the owner (in the 663/67 baseline):
1. **Gradescope term scoping** — Gradescope items carry their account-page
   term; archived classes keep undated leftovers filed (the "27 days
   late" user report). PR #8.
2. **GradeHistoryStore test-runner guard** — `swift test` no longer opens
   the real Mac App Group store (the CoreData error wall).
3. **The Mac build lane** — `App/LHFApp-macOS.entitlements` (sandbox,
   network.client, team-prefixed App Group), per-SDK
   `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` in `project.yml`,
   `LSApplicationCategoryType` (education — **must match the ASC
   listing category**). Archive verified: entitlements present, ledger
   survives relaunch (App Group resolves), real Mac UI.
4. **Profile page on macOS** — `.formStyle(.grouped)` + 720pt cap +
   prompt-based placeholder; visually confirmed by the owner.
5. **Connection-notice banner** — one dismissible dashboard card when
   Gradescope was never connected or Canvas is pasted-link-only
   (`needsGradescopeConnection` / `canvasIsLinkOnly`; preview mode
   exempt). Compiled, but **the dismiss X has never been tapped on a
   real device** — the owner's account has both services connected, so
   the banner has never actually rendered for anyone. Still owed.
6. **CLAUDE.md** — model-tier routing for the overseer/doer split
   (doers pinned Sonnet/Haiku in `.claude/agents/`).

Uncompiled on `v6` (overnight, owner asleep):
7. **Grade Watcher visible again** — `FeatureFlags.gradeWatcher = true`.
   The `false` was a **merge artifact** contradicting its own doc
   comment, not a decision. Runtime `canUseGradeWatcher` gate unchanged.
8. **Announcement Watcher** — `CanvasAnnouncementsClient` (cookie REST,
   paginated, mirrors the grades client) → extractor protocol with a
   deterministic heuristic backend (default, on-device) and an opt-in
   `claude-haiku-4-5` backend (raw REST, forced tool call, key in
   `AnthropicKeyStore`/Keychain) → items land as `.canvasAnnouncement`
   ledger rows (upsert, source-partitioned like `.canvasModules`),
   deduped against existing same-course items. Settings section with the
   privacy contract; watcher defaults ON, AI assist OFF. Each
   announcement parsed once ever (persisted ID set — AI re-parse is a
   re-bill).

## Mac App Store — where the submission stands

iOS 2.0.0 (5) is live; **no macOS binary has ever been uploaded** (Macs
currently get "iPhone Apps on Mac"). Owner-side state:
- Upload candidate archive:
  `~/Library/Developer/Xcode/Archives/2026-08-30/LHF-mac-1609.xcarchive`
  (visible in Organizer; contains through the banner commit — **not**
  the v6 features, which is correct: v6 is unreviewed).
- Screenshots resized to 1440×900 in `~/Desktop/lhf-shots/out/`.
  Cosmetic flag: the dashboard shot greets "Hello, There" — a real first
  name would present better.
- Remaining, all in App Store Connect: add the **macOS platform** to the
  app record → Organizer → Distribute App → Upload → per-platform
  description/keywords → review notes pointing at "Preview with sample
  data" (reviewers cannot pass Penn SSO) → submit. After approval:
  Pricing and Availability → uncheck "Make this app available on Apple
  Silicon Macs". Full detail: `docs/appstore/CHECKLIST.md` §macOS.

## Triaged, not bugs — don't "fix" these

- No-submission items flashing OVERDUE for a couple of minutes on a
  fresh install / brand-new items: the designed cold-start window before
  the first grade refresh fills `noSubmissionCanvasAssignmentIDs`. It
  self-corrects; closing the window would hide genuinely late work.
- No Notifications row in iOS Settings until the in-app reminders toggle
  first requests permission: standard iOS behavior.

## Next actions, in order
1. Owner runs the v6 morning gate (`swift test` → 693/70, then build,
   look at Settings → announcement watcher, grades button).
2. Fix anything red — treat as the patch not compiling as written.
3. The Mac upload (independent of v6; the archive predates it).
4. Decide PR #8's fate (merge to `v5`, or retire in favor of `v6`).
5. Open decision recorded in the plan doc: auto-insert vs confirm-first
   for AI-extracted assignments; per-course announcement toggles.

---

# Superseded: state as of 2026-08-29 and earlier

_Last updated: 2026-08-29 (branch `v5` — the current line, cut from the
2.0.0 build 5 head). This section supersedes everything below the
"historical context" marker; read `CLAUDE.md` first for commands, storage
tiers, and the traps._

## ⚠️ Current state: `v5` is the line; 2.0.0 (build 5) is with the owner at ASC

**New work goes on `v5`**, cut 2026-08-29 from `claude/v4-github-repo-kvu0e0`
(the v3.5 + v4 merge) at the exact commit 2.0.0 build 5 is being submitted
from. That merge branch is **frozen** while the upload is in flight: landing
anything on it would mean the binary the owner validates is not the commit
that was tested. Once 2.0.0 is through review, `v5` becomes the de-facto
ship line and the merge branch can be retired.

The submission itself is unchanged and still owner-side: archive → validate →
upload → paste copy → submit, in the order `docs/appstore/CHECKLIST.md`
§"2.0.0 submission" lists. Screenshots are regenerated and committed. Once
the build is uploaded, tag the release commit `v2.0.0-build5` (on the merge
branch — that is the commit that was submitted, not `v5`'s head).

**Verified green baseline (owner's Mac, 2026-08-27): 644 tests / 63 suites**
(plus 4 XCTest scheduler tests), zero failures. A change that lowers either
number has lost work — investigate rather than accept it.

**Unverified on `v5` right now:** the Gradescope term-scope fix
(PR #8 → `v5`) was written in the Linux container with no Swift toolchain and
has never been compiled. It should take the baseline to **654 tests / 65
suites**; if `swift test` reports anything else, read that as the patch not
compiling the way it was written rather than as a flaky count.

**Grade Watcher is HIDDEN this release** (`FeatureFlags.gradeWatcher =
false`, owner's call 2026-08-26). The whole `docs/appstore/` package is
scrubbed to match (2.3.1 accurate metadata): no grades/syllabus claims in
the listing, no grades stops in the review notes, no grades screenshots, and
`capture-screenshots.sh` skips those shots. The v2.5-era grades copy lives
in git history for when the flag flips back.

## What changed 2026-08-27 (all on this branch, all verified on the Mac)

Worked owner-driven, one device-pass finding at a time; each landed with
tests and a `docs/decisions.md` entry (read those entries for the why):

1. **Profile lists Modules-only / not-yet-posting classes** (`39a8aef`) —
   the CIS 2620 fix. `allCourseCodes()` now pools
   `canvasItems + gradescopeItems + moduleReadingItems` and unions the
   cached enrolled courses, re-applying the ingestion filters at read time.
   `CourseListSourcesTests`.
2. **Readings consent popup removed; auto-import** (`1550510`) —
   `CourseNudgeSheet`/`pendingCourseNudge` machinery deleted. Readings
   import the moment a probe finds them; the single gate is
   `AppState.shouldAutoImportReadings(for:)` (blocks only on an explicit
   `.exclude` from Settings → "Courses & content"). `ReadingsAutoImportTests`
   replaced the nudge suite.
3. **"Nothing to submit" caveat + no-submission cache** (`e24be6a`) —
   Canvas no-submission assignment ids (`GradeItem.requiresNoSubmission`)
   are cached in `UserDefaults.lhf` under
   `noSubmissionCanvasAssignmentIDsV1` (self-healing per observed item,
   never iCloud-mirrored), so the card caveat is right on a cold launch.
   `DashItem.showsNothingToSubmit` = `requiresNoSubmission || kind ==
   .event` is the display predicate.
4. **Book icon removed** (`c7baf3b`) — the caveat is the one marker; the
   glyph is gone from the card and the Mac menu-bar row.
5. **Nothing-to-submit items are never "late"** (`51c522e`) —
   `isExpiredEvent` is a hard `due < now` boundary (was calendar-day;
   all-day ICS entries already parse to end-of-day so they still last their
   day), mirrored into `LedgerWidgetReader`; and
   `AppState.isAutoFiledNoSubmission` (cache-backed, offline) is wired into
   `isCompleted` so a past-due no-submission assignment files to Done
   instantly instead of waiting for a grade refresh.
6. **One merged per-class toggle, and off means HIDDEN** (`7bb7cff`) —
   `CoursePreferences.nothingToSubmitEnabled` replaced `recurringEnabled` +
   `noSubmissionRemindersEnabled` (decode fold: new key wins, else the two
   old keys AND together; old CodingKeys are decode-only fossils). Off hides
   the class's `.event` items and cached no-submission assignments from the
   dashboard pools (enforced in `rebuildDashboardItems`); `RecurringTask`
   occurrences stay visible but silent (the one remaining scheduler gate);
   assessments are never hidden. UI routes through
   `AppState.setNothingToSubmitEnabled` — the store setter alone does NOT
   rebuild the pools, and that is load-bearing. Same toggle in the
   onboarding per-course walk.
7. **App Store package rewritten for 2.0.0** (`c78b9fe`) + regenerated
   screenshots (`f100bdf`).

## How to work in this setup (unchanged, and it bit us again today)

- The Claude session runs in a **Linux container with NO Swift toolchain**.
  Make changes, run static checks (greps for dangling symbols, brace
  balance), push, and the owner runs `cd LowHangingFruitKit && swift test`
  and builds on their Mac, pasting results back. Every change today
  compiled first try under this discipline — keep the bar there.
- The owner's zsh chokes on `#` comments in pasted commands. Their local
  checkout drifts branches — have them run `git branch --show-current`
  before anything that matters, and remember relative paths: they usually
  sit inside `LowHangingFruitKit/`, so repo-root scripts need `../`.
- Work happens on `v5` (PRs into it, or fast-forward pushes). `main` is
  frozen at the June 1.0 — do not base work on it, and do not read its
  `HANDOFF.md`: it still describes a Canvas-only 1.0 with no Gradescope, no
  ledger and no widget, and a session that trusted it built a day of work
  against a product that no longer exists. Check
  `git for-each-ref --sort=-committerdate refs/remotes/origin` before
  believing any handoff doc.
- Tests share process-wide `UserDefaults` — every test backs up and
  restores EXACTLY the keys it writes, including the `coursePreferences`
  blob (`CoursePreferencesStore.storageKey`) if it goes through the store
  against `UserDefaults.lhf`. `NoSubmissionCaveatTests` has the current
  helper patterns (`withCachedIDs`, `withCleanCoursePreferences`).
- iOS notification banners always show the installed app icon; there is no
  per-notification logo API. A stale icon there is device cache — restart
  the phone before anything drastic (delete+reinstall wipes on-device data).

## Known gaps / follow-up backlog (deliberate, not forgotten)

- **iOS WidgetKit widget ignores `nothingToSubmitEnabled`** — it reads the
  ledger plus the three legacy per-course keys only, so a hidden class's
  readings still appear in the widget. Needs its own pass (project a fourth
  legacy-style key, or teach `LedgerWidgetReader` the blob).
- **No `-LHFShowProfile` screenshot seam** — the Profile shot is manual.
- `CourseContentDecision.fingerprint` is a decode-kept fossil (its re-ask
  purpose died with the popup).
- Mac icon rounded-rect margin pass (cosmetic, pre-existing).
- iCloud Tier 2 sync is opt-in/default-off with little soak; the
  `LedgerSchemaV1` migration has still never opened a real pre-existing
  on-disk store; the demo screen recording for ASC shows the 1.x flow and
  should be re-recorded or dropped.
- Remaining device-pass items: onboarding walk end-to-end, Mac menu-bar
  build, widget with renamed courses, two-device iCloud toggle.

## After the submission

- App Review feedback lands in ASC; whatever it asks, the package files in
  `docs/appstore/` are the source of truth to amend and re-paste.
- If 2.0.0 is approved: update `CLAUDE.md`'s "Shipped on the App Store as"
  line, tag the submitted commit on the merge branch, and retire that branch
  in favour of `v5` (`main` still needs either a fast-forward decision or
  retirement of its own — it is stuck at the Canvas-only 1.0.0 and its
  `HANDOFF.md` describes a product two years of branches out of date).

Everything below this section is historical context from earlier sessions.

---

_Previous update: 2026-08-20 (branch `claude/lhf-v3-canvas-merge-6msbyo`)_

**LHF (Low Hanging Fruit)** is a personal academic dashboard for Penn students.
It reads the student's own **Canvas** calendar feed (plus **Gradescope**, and
Canvas **grades**) and shows assignments as one chronological "what's due next"
list, with local reminders. SwiftUI, iPhone-first (+ macOS from the same code),
everything on-device.

---

## ⚠️ Read this first

Work is on **`claude/lhf-v3-canvas-merge-6msbyo`** — `v3` (Marco's SwiftData
ledger, grade report, projections, syllabus ingestion, intro flow) with the
**v2.5 Canvas login hardening merged in**, plus a hardening pass on the ledger
itself.

- `cd LowHangingFruitKit && swift test` → **365 tests / 34 suites passing.**
- **`v3` does not have the Canvas login hardening.** The hardening lives on
  `v2.5` and on this branch.
- **This is no longer a fast-forward.** `v3` moved while the branch was in
  flight: PR #5 (`claude/bold-tesla-2142f1`) landed an independent
  implementation of shared preferences and completion-on-the-ledger — the same
  two gaps this branch had already closed. That has been merged here, resolved
  toward `v3` in the overlapping areas because its versions carry
  `MigrationChainTests`, `SharedDefaultsMigrationTests` and the
  `@Attribute(.unique)` removal. `v3` is now fully contained in this branch, so
  `git merge --ff-only` works from `v3`'s side.
- **Coordinate with Marco before landing it.** His `28891ca`
  (`docs/v3-integration-handoff.md`) sequences six parallel branches into `v3`,
  and 30+ commits arriving out of that order is what the document exists to
  prevent. PR #5 is evidence the collision is real, not hypothetical.

**Not yet verified on hardware.** `swift test` runs without an App Group
entitlement, so `AssignmentStore.makeDefault()` and `UserDefaults.lhf` both
take their non-entitled fallback paths. Three things are therefore **untested by
the suite** and need a device build:

1. the manual-assignment migration, which *deletes* the `manualAssignments`
   UserDefaults blob after copying it to the ledger,
2. `SharedDefaultsMigration`'s one-time copy from `.standard` into the suite,
3. the widget reading hidden/renamed/deleted courses out of that suite.

Check Settings → Storage after upgrading an existing install: it should say
**"Saved on this device."**

## 🆕 What changed in this session (2026-08-21)

**The v3 merge is done and green — 365 tests, 34 suites.**

`v3` had moved: PR #5 shipped a second, independent implementation of the same
shared-preferences and completion-on-the-ledger work this branch had. Neither
line contained any of the other's unique work, so it was merged rather than
resolved by picking a side — `v3`'s versions won the overlap (better migration
test coverage, plus the `@Attribute(.unique)` removal), and this branch's
unique work was re-applied on top: the Canvas login hardening, `LedgerSchemaV1`,
`saveChanges()` with `LedgerStats.isHealthy`, `pruneAgedOut()`, and the
manual-work-on-ledger API.

**One security correction the merge itself created.** `canvasICSURL` is off
`SharedDefaultsMigration.legacyKeys`. It belonged there on `v3`, where the feed
URL was an ordinary preference; once the hardening lands it is a Keychain-held
bearer credential, and copying it into the shared suite would put it back into
unencrypted, backed-up storage. Nothing is orphaned — `ICSFeedURLStore.load()`
reads the pre-hardening value from `UserDefaults.standard` and moves it to the
Keychain. `SharedDefaultsMigrationTests` now asserts the key is *absent*, so
re-adding it fails loudly.

**Lesson worth keeping.** Three rounds of compile errors on this merge all had
one shape: a conflict resolved by taking one whole side of a file, dropping the
losing side's unique work while leaving its callers in place. Whole-file
resolution is only safe when one side is strictly newer. Check first.

---

## 🆕 What changed in this session (2026-08-20)

**The v2.5 → v3 merge was broken and is fixed.** A silent git auto-merge left
duplicate `clearAll()` and `loadPreviewSnapshots(_:now:)` in
`GradeWatcherStore.swift`; the branch did not compile. Kept the first of each
(the v3 version, whose comment mentions syllabus schemes). Nothing else in the
merge had the same defect — the compiler was the audit.

**Ledger hardening.** An audit of the SwiftData ledger against the four
symptoms a separate `docs/assignment-persistence-plan.md` proposed fixing found
that plan was written against **`main`**, where no ledger exists at all — on
`v3` almost all of it was already built. Six real gaps remained, and all six are
now closed:

1. **Schema versioning.** `LedgerSchema.swift` adds `LedgerSchemaV1` +
   `LedgerMigrationPlan`, wired into every `ModelContainer`. Without it, the
   first incompatible model change would have thrown on an existing store,
   fallen back to in-memory, and shown the user an empty dashboard with no
   error — the exact data loss the ledger exists to prevent. `stages` is empty
   on purpose; the point is that the *next* change is a migration.
2. **Honest failures.** `makeDefault()` keeps the reason it degraded instead of
   discarding it (`storageFailureReason`).
3. **Checked writes.** `try? context.save()` is gone; `saveChanges()` records
   `lastSaveError` / `failedSaveCount`. Settings → Storage now has three states,
   because a store can be perfectly on-disk and still be failing every write.
4. **Pruning.** `pruneAgedOut()` deletes what `isAgedOut` already hides, bounded
   by the identical predicate, so finished work stays untouchable.
5. **User-created work on the ledger.** Manual assignments and recurring tasks
   were JSON blobs in defaults — the one category of work Canvas cannot
   re-supply had none of the ledger's protection. Migrated, and exempt from the
   feed-gone/aging rules.
6. **Shared preferences.** `SharedDefaults` moves non-credential preferences to
   the App Group suite so the widget can see hidden courses and renames. It
   falls back to `.standard` unless the App Group container actually exists —
   `UserDefaults(suiteName:)` succeeds for *any* string, so without that check
   the "shared" suite is a private domain that only hides values already in
   `.standard`.

Completion is now single-source: the ledger owns `completedAt`, and the old
defaults keys are read once at launch, migrated, and deleted.

**Tests: 239 → 329.** New suites: `LedgerHardeningTests`,
`MergedCompletionWithoutSyncTests`, `RecordedICSFixtureTests` (the recorded-feed
fixtures the old plan asked for), plus additions to `AssignmentStoreTests`,
`LedgerWidgetReaderTests` and `AssignmentDeduplicatorTests`.

---

## 🆕 What changed in this session (2026-07-26)

**Bug fixes**

- **Grade Watcher resolved no courses.** Canvas course ids only ever arrive
  attached to an ICS item's URL, and the parser understood only direct
  `/courses/<id>/assignments/<id>` links. Canvas also emits calendar-style
  `/calendar?include_contexts=course_<id>` URLs, which resolved to nothing — so
  every class vanished and the screen claimed "no classes selected" while the
  picker showed them all switched on. `AppState.courseID(from:)` now reads both
  shapes; resolved ids are cached in `canvasCourseIDsByCode` (persisted) so a
  class stays fetchable in a week when it has nothing due and contributes no URL.
- **Completing a cross-posted assignment produced two Done cards.**
  `DashboardViewModel.reload` rebuilt its completed pool from the **raw**
  `canvasItems + gradescopeItems`, not the deduplicated pool. Since completing a
  merged item marks *both* underlying ids done (via `linkedID`), both originals
  qualified for Done. `AppState` now publishes `mergedCoursework` and Done reads
  that. Covered by `DoneDuplicationTests` — verified to fail (2 cards) without
  the fix.
- **Grade Watcher failed silently.** `GradeWatcherStore.error` was set on every
  non-expiry failure and **never rendered**, so a missing Canvas session looked
  identical to "no grades yet": empty cards, no explanation. Now surfaced as an
  amber banner with **Reconnect Canvas** + **Try again** actions (also on the
  expired-session banner and the "can't match your classes" empty state).

**Features / UI**

- **Edit classes** (Settings → Classes): swipe to **Rename** or **Delete**,
  long-press for a menu that adds "Reset to <code>"; deleted classes still
  collapse into a restore list. Renaming is **cosmetic only** — selection,
  reminders, grades and dedup all still key on the Canvas course code, so a
  re-sync can't undo a rename or orphan a class. Renamed labels show on the
  dashboard and Done cards via `EnvironmentValues.courseNameOverrides`
  (an empty map = old behaviour, so previews stay AppState-free).
- **Settings and Grades are pushed pages, not sheets.** Both hang off the
  dashboard's `NavigationStack` via `ContentView.DashRoute`. `SettingsSheet` was
  renamed to **`SettingsPage`** and no longer owns a `NavigationStack` or a
  modal "Done" button. Both pages carry `.lhfSheetTheme()` so they use the app's
  paper palette instead of the system grouped background.
- **Header redesign.** The weekly progress ring is gone from the top right,
  replaced by two circular icon buttons on one line — Grades, then **Settings in
  the corner**. `ProgressRingView` still exists but is no longer on the
  dashboard.
- **Splash plays 1.4× (40% faster)** via `SplashPlayer.playbackRate`. The
  safety-net timeout (6s → ~4.3s) and the handoff fade (0.45s → 0.32s) are
  scaled to match. Reading "40% faster" as 1.4× speed; if it should mean "40%
  less time" that's 1.667 in one constant.
- Removed the "your archive says otherwise." line from the Done footer and the
  **Debug** section from Settings.

---

### Session 2 (2026-07-26) — App Store prep + the grade report

**App Store blockers cleared** (details in `docs/appstore/CHECKLIST.md`, rewritten):
both widget defects, the dark-mode Info.plist pin, preview mode covering every
screen, **Disconnect Canvas / Disconnect Gradescope** in Settings → Account
(`SessionCookieStore` previously had no UI caller at all), privacy manifests
updated (+ the widget got its first one), `docs/PRIVACY.md` rewritten for
grades/Keychain/syllabus/widget/Gradescope, and all five `docs/appstore/` files
brought up to v2.5. Screenshots regenerated, now including Grades and the report.

**The grade report + syllabus ingestion** (new `docs/grades.md` §13). This
reverses two of §8's cuts on purpose:

- `GradeProjection` / `GradeProjector` — floor / at-this-pace / ceiling, and
  `requiredAverage(for:)` ("you need 94.7% on what's left for an A"). Pure math
  over `GradeBreakdown`, no new fetches.
- `GradeReportView` — pushed from each card's **Full report**; per-class watch
  toggle.
- `SyllabusParser` — deterministic, on-device, no model. Trustworthy because of
  one gate: **weights must sum to 90–110**, and a misread essentially never
  does. Also reads drop rules, expected item counts, letter cutoffs and curve
  language.
- `SyllabusMatcher` — syllabus categories → Canvas groups, exact/confirmed/
  fuzzy/unmatched, sharing `TitleNormalizer` with the Gradescope overlay.
  Coverage is all-or-nothing because the engine's manual weights are.
- `CanvasSyllabusClient` + `SyllabusTextExtractor` — syllabus_body, pages, PDF
  files, plus paste/import.
- `GradeCutoffs` — replaces the old `GradeScale` file (which still exists as a
  thin wrapper), adds custom syllabus cutoffs.

**Engine changes are additive:** `CategoryResult.possibleScoredRaw` is now
exposed (projections need pre-drop decided points), and
`Input.syllabusWeightedCategoryIDs` changes only the reported `weightSource`
(new `ScoreSource.syllabus`), never the arithmetic.

## 🐛 Known bugs — status

**Both v2.5 widget defects are FIXED** (were: the widget was built and thrown
away, and every `xcodegen generate` deleted its `NSExtension` block):

1. The widget dependency now uses **`platformFilter: iOS`** instead of
   `platforms: [iOS]`. xcodegen 2.45.4 doesn't filter a `platforms:` dependency
   per-platform — it discards it entirely (0 dependencies, 0 copy phases).
   `platformFilter` is **case-sensitive**: `iOS` writes Xcode's `platformFilter`
   attribute; lowercase `ios` and plural `platformFilters` are silently ignored.
   Getting this right matters in both directions — without the filter the macOS
   destination fails outright ("contains embedded content built for the iOS
   platform"), which is presumably why the broken `platforms:` line was there.
   After the fix: dependencies 0 → 5, copy-files phases 0 → 3, **iOS Release and
   macOS builds both green**.
2. `NSExtension` / `NSExtensionPointIdentifier` now live in `project.yml`'s
   `info.properties`, so regeneration can't delete them. **The
   `git checkout -- LHFWidget/Info.plist` dance is no longer needed.**

Verified end to end: a Release build produces
`LowHangingFruit.app/PlugIns/LHFWidgetExtension.appex` with the correct
`NSExtensionPointIdentifier`.

**`UIUserInterfaceStyle: Light` is removed** from the app's Info.plist. It
pinned the interface style at the system level, so the in-app Light/Dark setting
could never engage. The app now applies `.preferredColorScheme` from
`AppState.appearanceMode` alone. **Still unverified on a physical device.**

**Preview (demo) mode was broken past the dashboard** and is fixed:
`selectedCanvasCourseIDs()` resolved nothing (sample items carry no Canvas
URLs), so Grade Watcher showed "Can't reach Canvas for your classes" with a
Reconnect button that ejected the tapper out of preview into Penn SSO. Fixtures
now cover the class list, grades, the report, and the widget snapshot; the
Reconnect action is hidden in preview. `PreviewModeTests` also caught that
entering preview only seeded on the *next* launch.

## 🔐 How login / session works (three different auth paths — don't conflate them)

- **Assignments — no login after onboarding.** Onboarding captures the personal
  Canvas **calendar-feed URL** (`…/feeds/calendars/user_<token>.ics`, a
  self-authenticating secret URL). Every sync is a plain cookieless HTTPS GET.
  Because that URL *is* the credential, it lives in the Keychain via
  `ICSFeedURLStore` — **not** UserDefaults, where `v3` still keeps it.
  ICS carries **no submission state** (`CanvasICSClient.normalize` hardcodes
  `submitted: false`).
- **Grades + Canvas submission detection — need a live cookie session.**
  `CanvasGradesClient` replays persisted Canvas cookies
  (`SessionCookieStore`, Keychain; gathered via `AutoSyncCoordinator.canvasCookies()`).
  Penn SSO expires server-side and **cannot be refreshed silently** — the WebView
  login has to run again, which is what the Reconnect button does.
- **Gradescope** — no student API, so login cookies are persisted and replayed
  (`GradescopeClient`), throttled to ≤ 1 sync / 15 min.

### Submission state — what the app does and doesn't know

Three independent notions of "done", and they are **not** interchangeable:

| Signal | Source | Persisted? |
|---|---|---|
| Manual tick | user taps a card → `StoredAssignment.userCompleted` / `completedAt` | **Yes** (ledger) |
| Gradescope submitted | `Assignment.submitted` from the scrape → `gradescopeSubmitted` | **Yes** (ledger) |
| Canvas submitted | Grade Watcher `workflow_state` → `applySubmissionState()` → `canvasSubmitted` | **Yes** (ledger) |

All three are durable now. The Canvas flag is written as a full **replace**
rather than a merge, which is what preserves the self-healing property the old
recompute-every-refresh design had: a retracted or TA-cleared submission goes
back to unsubmitted on the next refresh. `submittedCanvasAssignmentIDs()` seeds
`AppState` at launch, so the app knows what you turned in *before* — or without —
any grade refresh.

Each flag also carries **when it was last observed**
(`canvasSubmissionObservedAt` / `gradescopeSubmissionObservedAt`, newest of the
two via `submissionObservedAt`). The flag alone cannot separate "not submitted,
confirmed a minute ago" from "not submitted, as far as we knew last Tuesday",
and those mean different things to a student deciding what to work on. Nil means
*never observed* — unknown, which is not the same as stale, and must not be
rendered as "last checked ages ago".

Still true: Canvas state is derived from the grades fetch, so **no Canvas
session ⇒ no fresh answer.** Canvas doesn't push, so this is polling while the
session is alive — best-effort, never real-time. What's changed is that a stale
answer now says so instead of disappearing.

Not yet modelled: late / missing / excused / resubmitted (Canvas sends these in
`workflow_state`; we collapse them to a Bool), and a manual student override for
when Canvas is wrong or unreachable.

---

## 🏗️ Architecture / layout

```text
App/                       # Xcode app target (@main, Info.plist, PrivacyInfo, icon)
LHFWidget/                 # iOS WidgetKit extension (Home + Lock Screen "Next Due")
project.yml                # xcodegen source of truth → LowHangingFruit.xcodeproj
LowHangingFruitKit/
  Sources/
    LowHangingFruitUI/     # SwiftUI + app logic (Marco)
      RootView, ContentView, AppState, DashboardViewModel
      OnboardingView, SettingsPage, SplashView
      GradeWatcherView / GradeWatcherStore / GradeCourseCardView
      GradeReportView / SyllabusSetupView
      NotificationScheduler, AutoSyncCoordinator, SessionCookieStore
    LowHangingFruitKit/    # data layer, no UI (Olisa)
      Models/{Assignment, CourseCode, Term, AssignmentDeduplicator}.swift
      Canvas/{CanvasICSClient, ICSParser, CanvasGradesClient}.swift
      Grades/{GradeEngine, GradeProjection, GradeCutoffs, TitleNormalizer,
              GradescopeOverlay}.swift
      Syllabus/{SyllabusParser, SyllabusMatcher, SyllabusReconciler,
                SyllabusTextExtractor, CanvasSyllabusClient, SyllabusModels}.swift
      Gradescope/GradescopeClient.swift
      CanvasDiscovery/{CanvasDiscoveryClient, CanvasRequirementScanner}.swift
  Tests/LowHangingFruitKitTests/   # 365 tests
docs/grades.md             # Grade Watcher design brief (§13 = report + syllabus)
docs/appstore/             # App Store package (current as of 2026-07-26)
```

- **Marco** owns the UI/app layer; **Olisa** owns the data layer. Cross-cutting
  model changes get a quick sync first.
- **Tests share `UserDefaults.lhf`.** `AppState` persists there, so any test
  that toggles selection/completion must normalize on the way **in and out** —
  an interrupted run otherwise leaves state that fails the next one. See
  `GradeWatcherCourseResolutionTests`.
- **Preferences live in the App Group suite, not `.standard`.** Every read and
  write goes through the single `UserDefaults.lhf` accessor
  (`Persistence/SharedDefaults.swift`), which resolves to
  `group.com.lhf.lowhangingfruit` and falls back to `.standard` when there's no
  entitlement. That's what lets the widget see completions, hidden/deleted
  courses and manual assignments at all. `SharedDefaultsMigration` copies the
  pre-existing keys across once per install, guarded by a marker in the
  destination; the list is frozen, so **new keys don't belong on it** — they're
  born in the suite. Session cookies stay in the Keychain
  (`SessionCookieStore`), deliberately device-bound, and do **not** move.
  The **Canvas feed URL** does not move either: it is a bearer credential and
  lives in the Keychain via `ICSFeedURLStore`, which is why `canvasICSURL` was
  taken off `legacyKeys` when the login-hardening line merged in. Save and
  restore through `UserDefaults.lhf` in tests, never `.standard` directly, or
  the values you write are not the ones `AppState` reads — see `IntroFlowTests`.

## 🧰 Build / run / test

```sh
cd LowHangingFruitKit && swift test              # 365 passing
xcodegen generate                                # safe now — Info.plist trap disarmed
bash docs/appstore/capture-screenshots.sh        # regenerate App Store screenshots
```

**Signing is resolved.** `project.yml` carries `DEVELOPMENT_TEAM: 24A3TDB277`
(Olisa's team, "GABRIEL NKOLISA NWOGUGU") on **both** the app and widget targets.
Marco's iPhone (`00008150-000A25D63428401C`) is registered in the provisioning
profile. Xcode has the team signed in, so `-allowProvisioningUpdates` can
register new devices.

**Install to the device** (requires **Developer Mode ON** — Settings → Privacy &
Security → Developer Mode → restart; it cannot be enabled from the Mac, and the
phone must be **unlocked** to launch):

```sh
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates -derivedDataPath /tmp/DD build
xcrun devicectl device install app --device 00008150-000A25D63428401C \
  /tmp/DD/Build/Products/Debug-iphoneos/LowHangingFruit.app
xcrun devicectl device process launch --device 00008150-000A25D63428401C \
  --terminate-existing com.lhf.lowhangingfruit
```

Debug builds are development-signed and **expire in ~7 days** — reinstall to
refresh. `CompileAssetCatalogVariant` has failed transiently once; a straight
retry fixed it.

- **DEBUG launch flags:** `-LHFDemoData` (populated dashboard, skips splash +
  onboarding), `-LHFTabAll`, `-LHFTabDone`, `-LHFShowSettings`,
  `-LHFShowGrades`, `-LHFShowReport`. These are DEBUG-only; the
  **reviewer-facing** demo is preview mode, which ships in Release.
- **Widget App Group:** automatic provisioning registers
  `group.com.lhf.lowhangingfruit` for development, but the **App Store
  distribution profile needs the App Groups capability on both App IDs** or the
  container URL is nil in the shipped build and the widget stays empty.

## 📌 Important constraints

- **Canvas developer/OAuth API is denied by Penn IT** → the assignment list comes
  from the **calendar ICS feed**. The *self-scoped session API* (the user's own
  login cookies) is reachable and is what grades/discovery use — that is a
  different door from the denied developer keys.
- No backend of ours; everything on-device. No analytics/tracking/ads.
  `PrivacyInfo.xcprivacy` declares no collection.
- **Do NOT commit real Canvas/Gradescope data** — user ids, secret feed-token
  URLs, cookies. Use synthetic values in tests and fixtures.
- **Pushing** needs the **`Marcomercader`** gh account
  (`gh auth switch --user Marcomercader`); `marco-opertti-lightfeatherio` has no
  access to `OlisaNW247/penn-dashboard`.

## 🔭 Follow-ups

**Blocking a submission (need a person, not a commit):**

- **Verify the ledger migrations on device** — see "Read this first". The test
  suite structurally cannot reach them.
- **Upload 1.1.1 to App Store Connect.** The version page exists; the build was
  never uploaded, so the Build section is still empty. Independent of all the
  v3 work — it ships from `v2.5`.
- **Fold this branch into Marco's six-branch v3 integration**, rather than
  merging over it.
- **Verify grades + submission detection on device.** Reconnect Canvas on the
  iPhone. This is the headline feature and it has never run against real data.
- **Verify dark mode and the widget on device** — both were unverifiable before
  this session's fixes and remain unverified on hardware.
- **Decide the Gradescope question** (Guideline 5.2.2). The prepared
  justification is in `docs/appstore/REVIEW_NOTES.md`; the alternative is to
  gate Gradescope out of this submission.
- **Host `docs/PRIVACY.md`**, fill its contact email, and get a support URL.
- **Register bundle IDs + the App Group** under team `24A3TDB277`, and settle
  who owns the App Store Connect record.
- **Dark-mode screenshots and the widget screenshot** — the capture script
  can't drive those; it prints a reminder at the end.
- **Re-record the demo video** to the new `DEMO_VIDEO.md` script.

**Code:**

- `.timeSensitive` notifications need the *Time Sensitive Notifications*
  capability enabled in Xcode to break through Focus (harmless without it).
- `ProgressRingView` is still unused by the dashboard — delete it or find it a home.
- The syllabus parser is deliberately conservative. When real syllabi start
  failing the 90–110 gate, add fixtures to `SyllabusParserTests` **first** — the
  gate is what makes the parser trustworthy, so loosen it only against evidence.
- Grade-change notifications are a natural next step: `GradeWatcherStore.history`
  already records one observation per course per day.
