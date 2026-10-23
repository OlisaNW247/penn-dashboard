# Merging Marco's branches into `v8` (plan, 2026-10-23)

Written for Olisa after about ten minutes of research: a `merge-tree` dry
run of every remote branch against `origin/v8` at `2f207e3`, and two
read-throughs of the commit messages and diffs (sign-in cluster;
submissions-and-exams cluster) checking each hunk against the code as it
stands on `v8` today. Nothing was compiled. The mechanics copy the
2026-10-20 merge (`v8-merge-loud-alert`): one integration branch, merges
in order, Olisa's Mac compiles, the phone confirms, then fast-forward.

## 1. What Marco has that `v8` does not

Fourteen remote branches hold commits `v8` lacks. Seven are live; the rest
are stale copies of work `v8` already carries in fuller form.

| Branch | Commits | What | Dry merge into `v8` | Risk |
|---|---|---|---|---|
| `codex/automatic-canvas-login` | 2 (today, on `a480eb1`) | Saves the PennKey username and password automatically from the login WebView after a verified Canvas sign-in; the vault sheet becomes a repair tool only; `docs/PRIVACY.md` rewritten | clean | **high** (decision) |
| `fix/submission-status` | 1 (10-19) | Two "turned in" misreads: a module row and a Canvas row with different assignment ids are never collapsed; Gradescope's keyword scan blanks the assignment's own title first | CLAUDE.md, ROADMAP.md only | low |
| `v8-server-exam-dates` | 1 (10-18) | Server sends `examDates` from the course profile; dated server exams replace the phone's syllabus rows under the same id; weekday-confirmed phone reading wins | CLAUDE.md, ROADMAP.md only; `BackendWire.swift`, `db.ts`, `profile.ts` auto-merge soundly | medium (needs a `sync` deploy) |
| `parked/missing-login-banner` | 1 (10-18) | "needs a refresh" banner and renew-on-open fire when the Canvas cookie item was deleted (one new flag `canvasLoginCapturedV1`); Marco: "for Olisa to review, his sign-in code" | CLAUDE.md only; `AppState.swift` anchors all exist | medium |
| `parked/gradescope-unverified-submission` | 1 (10-18) | A Gradescope row whose detail page could not be read keeps its previous "submitted" instead of flipping to unsubmitted and re-arming the sweeper; touches `syncGradescope` (owner-gated) | clean | medium |
| `parked/launch-submission-refresh` | 1 (10-18) | Runs the Canvas/Gradescope chain once at cold launch instead of after the 5-minute sleep | clean, **but** on `v8` the refactored function now also runs `deviceSyncPass`, the badge refresh and the turned-in/grade announcements at launch | medium-high |
| `fix/canvas-signin-bulletproof` | 1 (10-08) | Diagnosis of the 3.0.0 (11) refresh banner (analytics cookies with real expiries keep `isExpired` false) plus DEBUG-only `-LHFSessionDiagnostics`; no behaviour change | CLAUDE.md, ROADMAP.md only | low |
| `parked/ask-course-sync-fixes` | 1 (10-10) | Partial-course semantics (a half-failed sync keeps a course's documents), 403 per course instead of "signed out", 120 page bodies, front page as `.home`; Marco: "do not merge as is" | **conflicts in `CourseKnowledgeCollector.swift`** with the 2026-10-23 announcement window | high |
| `v8-launch-prep` | 1 (10-14) | `docs/LAUNCH_PREP_HANDOFF.md`, absent on `v8` | clean | none |

**Superseded, safe to delete:** `v8-ann-rules` (an older snapshot: 516
lines `v8` lacks against 7,794 it has; its content was applied as a patch
on 2026-10-18), `codex/redesign-v5` and `codex/assignment-pop-empty-celebration`
(the completion-animation polish's every identifier exists on `v8`),
`v8-announcements`, `v8-loud-alert-actions`, `v8-merge-loud-alert`,
`v8-features`, `V7-polish`, and the August `claude/*` branches.

## 2. Decisions only Olisa can make

1. **Automatic PennKey capture** (`codex/automatic-canvas-login`). The
   code is careful: origin and path checks, main frame only, Keychain
   this-device-only, held in memory at most 10 minutes, saved only after
   `connectCanvas` succeeds, never leaves the phone. But it reverses the
   recorded rule that reading the password out of the login DOM is
   "rejected outright" (`PennKeyLoginForm` doc, `docs/PRIVACY.md`), and it
   removes the consent tap: the vault's "not now" is gone, the disclosure
   is one 12pt line above the WebView. `docs/appstore/REVIEW_NOTES.md`
   and `docs/appstore/DEMO_VIDEO.md` ("We never see your password") would
   be false, and the App Store privacy label needs re-reading. Three
   options:
   - (a) merge as written, then rewrite REVIEW_NOTES, DEMO_VIDEO, the
     label, and tell App Review in the next submission;
   - (b) **recommended**: merge the capture but keep the vault as the
     consent step, pre-filled with the captured pair, so the student
     never retypes and still taps "save" (keeps every shipped promise
     true; a small follow-up patch on top of Marco's branch);
   - (c) do not merge.
2. **The two parked sign-in and sync patches Marco marked for you**
   (`missing-login-banner`, `gradescope-unverified-submission`). Both read
   as correct and small. The banner one makes the silent renewer fire in a
   new case (cookie item deleted), which is a new automatic use of the
   saved password. The Gradescope one changes `syncGradescope`.
3. **Launch refresh.** The launch gap is real: today the new build sat
   silent for twenty minutes because nothing runs the Canvas chain until
   the first 5-minute sleep or a return to the foreground. Marco's branch
   fixes that but, merged onto `v8`, would also post turned-in and grade
   notifications at launch. Options: rework it to run only the sync chain
   (no announcements) at launch, or cut the first sleep to ~20 s. Not a
   straight merge.
4. **Course-sync fixes.** Still real on `v8`: one failed endpoint still
   counts a course as fully synced (so `merge(resyncedCourseIDs:)` drops
   its other documents and the upload retires them for classmates), and a
   403 on one course still aborts the whole run before `store.save`. The
   server-side prerequisite Marco listed (paginating the live-documents
   read) was done on 2026-10-23 (`sync` v12). The branch itself cannot be
   merged: it carries its own 200-day announcement window and its own
   `announcementsFailed`. Salvage the two fixes as fresh patches on `v8`;
   decide the 120-page cap separately now that the extension collects
   pages.

## 3. Order of work

Integration branch `v8-merge-marco` from `origin/v8`. Each step is one
`git merge --no-ff origin/<branch>`, then read the merged file around
every hunk (the 2026-10-20 trap: a clean merge put rows in the wrong
place), then grep both sides' diffs for the same noun.

| Step | Branch | Expected Swift tests | Conflicts to resolve | Gate |
|---|---|---|---|---|
| 1 | `fix/submission-status` | 2606 → 2641 (+35: `AssignmentDeduplicatorTests` 36→42, `GradescopeTests` 32→35, `GradescopeTitleStatusTests` 21, `SectionOverrideCompletionTests` 5) | CLAUDE.md, ROADMAP.md: keep both, Marco's entries dated 10-19 | `swift test --no-parallel` |
| 2 | `fix/canvas-signin-bulletproof` | 2641 (no tests) | CLAUDE.md, ROADMAP.md: his Known-gaps entry is dated 10-08; keep the diagnosis, note the analytics-cookie trap is still unfixed on `v8` | compile |
| 3 | `v8-launch-prep` | 2641 | none | none |
| 4 (if approved) | `parked/missing-login-banner` | +19 → 2660 | CLAUDE.md only. Note: its legacy inference reads `hasOfferedStayLoggedIn`, which the automatic-login branch stops setting | `swift test`, then on the phone: delete the cookie item with the DEBUG "simulate a Canvas logout" and see the banner |
| 5 (if approved) | `parked/gradescope-unverified-submission` | +10 → 2670 | none; `AppState.swift:4054` anchor exists | `swift test`; a device check with Gradescope reachable |
| 6 (if approved) | `v8-server-exam-dates` | +40 → 2710; Deno 419 → 428 | CLAUDE.md, ROADMAP.md; re-read `backend/PROTOCOL.md` beside the pairing sections | run the Deno suite here under real Deno (Marco never did), `swift test`, then deploy `sync` as v13 with Olisa's go; an old server is safe (app falls back to on-device parsing) |
| 7 (decision) | `codex/automatic-canvas-login` (+ the consent patch if option b) | +13 → 2723 | none in code; `docs/appstore/REVIEW_NOTES.md`, `DEMO_VIDEO.md` and the privacy label must change in the same commit | `swift test`, then an interactive PennKey + Duo login on the phone, then "stay signed in" verified with `-LHFAgeCanvasSession` |
| 8 (rework, not merge) | launch refresh; course-sync salvage | separate briefs | n/a | n/a |

After each green compile on Olisa's Mac: iOS Debug build to the phone,
then fast-forward `v8`. The counts above are predictions from `@Test`
counts; trust the Mac's number. A count below the prediction has lost
work.

## 4. What this does not cover

- Nothing here has been compiled; the dry merges are textual.
- Deno tests on `v8-server-exam-dates` have never run under Deno.
- Marco has not been told that the course-material sync was touched on
  2026-10-23 at Olisa's direction, and this plan salvages his parked sync
  fixes onto that; he should hear both at once.
