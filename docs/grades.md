# Grade Watcher — Spec

_Feature branch: `v2.5`. Last updated: 2026-07-19._

**Grade Watcher** is a per-class grade calculator for LHF. For each selected
class it shows two numbers:

1. **Current grade** — your grade in the class *right now*, computed only from
   work that has actually been scored.
2. **% of final grade already decided** — how much of the term's graded weight
   has been locked in, so a big-looking current grade off two quizzes reads as
   provisional, not final.

Data comes from **Canvas** (the backbone) with a **Gradescope early-score
overlay** (a fallback that only fills gaps, never adds work). Reachable **only**
from Settings → Grade Watcher. No tab, no dashboard surface, in this version.

---

## 1. Data architecture — Canvas backbone + Gradescope overlay

### Canvas is the source of truth
Canvas defines the entire structure: the assignment list, the categories
(Canvas "assignment groups"), the weights, and the point totals. We never invent
an assignment or a category that Canvas doesn't have.

**Endpoint (cookie session auth, same door as `CanvasDiscoveryClient`):**
```
GET /api/v1/courses/:id/assignment_groups?include[]=assignments&include[]=submission&per_page=100
```
- Returns each assignment group with `id`, `name`, `group_weight`, and its
  nested `assignments[]`.
- Each assignment carries `id`, `name`, `points_possible`, `omit_from_final_grade`,
  and (via `include[]=submission`) a `submission` object with `score`,
  `workflow_state`, `excused`, `missing`, `late`, `submitted_at`.
- GETs need no CSRF token. Strip any leading `while(1);` XSSI prefix before
  JSON decode (Canvas prepends it on some JSON endpoints).
- Paginate via the `Link` header `rel="next"` if present (large courses).

### The weights flag lives on the COURSE, not the groups — this is the crux
`group_weight` is **present but garbage** when the course isn't in weighted
mode. Whether weights apply is a **course-level** flag:
```
GET /api/v1/courses/:id?include[]=... (read apply_assignment_group_weights)
```
or read it off the courses list we already fetch:
```
GET /api/v1/users/self/courses?include[]=total_scores  (also gives the cross-check score)
```
Branch on `apply_assignment_group_weights`:

- **Weighted mode (flag true):** use `group_weight` per category.
- **Points mode (flag false):** ignore `group_weight` entirely; one implicit
  bucket, straight points.

### Gradescope overlay — double-counting is designed out
Gradescope is a **fallback score source only**. Hard rules:

1. **Gradescope NEVER adds an assignment to the math.** The Canvas assignment
   list is the universe. Gradescope can only supply a *score* for an assignment
   that already exists in Canvas.
2. It may only fill an assignment that has **no Canvas score yet**
   (`submission.score == nil`). Priority: **Canvas score > Gradescope early
   score > none.**
3. Matching is fuzzy (see §5). An unmatched Gradescope item — or one that maps
   to a Canvas assignment that already has a Canvas score — goes to a visible
   **"unmatched" review list**. It is **never silently counted**.
4. Mapping is **user-confirmable**: a low-confidence fuzzy match is proposed,
   not auto-applied, and the user can correct it.

### Canvas's own computed score is a CROSS-CHECK, not a source
`computed_current_score` (from `?include[]=total_scores`) is used only to
sanity-check our number. It is **nil when the professor hides totals**, so it
can't be the source. If our number and Canvas's disagree materially (threshold
TBD, e.g. > 1.0 percentage point), surface a subtle **"differs from Canvas"**
note rather than silently diverging or silently overwriting ours.

---

## 2. Math — the two modes

Notation: for an assignment `i`, `earned_i` = `submission.score`,
`poss_i` = `points_possible`. "Scored" means `score != nil` **and** not excused
(see edge cases). A category `c` has items; `S(c)` = its scored items,
`A(c)` = all its (gradeable, non-excused-doesn't-apply-here) items.

### Points mode (`apply_assignment_group_weights == false`)
Single implicit bucket. Only scored items participate.
```
current grade =  Σ_{i ∈ scored}  earned_i   /   Σ_{i ∈ scored}  poss_i
```
```
% decided     =  Σ_{i ∈ scored}  poss_i     /   Σ_{i ∈ all}     poss_i
```
Both denominators guard against zero (empty → grade is "no scores yet",
% decided = 0).

### Weighted mode (`apply_assignment_group_weights == true`)
Per category `c` with weight `w_c`:
```
categoryPct_c = Σ_{i ∈ S(c)} earned_i  /  Σ_{i ∈ S(c)} poss_i      (only scored items)
```
Current grade is a **renormalized** weighted average over **only the categories
that have scored work** (`S(c)` non-empty and `Σposs > 0`):
```
current grade = ( Σ_{c ∈ scoredCats} w_c · categoryPct_c )  /  ( Σ_{c ∈ scoredCats} w_c )
```
Renormalizing by the participating weights is what makes "92% off one graded
category" honest — we don't dilute by categories that haven't happened yet.

% decided is computed over **all** categories, each contributing the fraction of
its own points that are already scored, scaled by its weight:
```
% decided = Σ_c  w_c · ( Σ_{i ∈ S(c)} poss_i  /  Σ_{i ∈ A(c)} poss_i )
```
(with `w_c` normalized to sum to 1 across non-zero-weight categories; a category
with `Σ_{i∈A(c)} poss == 0` contributes 0, no divide-by-zero.)

**Do NOT** count a whole category as "decided" just because one item in it is
graded — % decided is per-item within the category, exactly as written above.

---

## 3. Edge-case table (must be encoded in the engine AND unit-tested)

| Case | Rule | Rationale |
|---|---|---|
| **Excused** (`submission.excused == true`) | Exclude from BOTH earned and possible, everywhere. | Excused work is removed from the class, not zeroed. |
| **`score == nil`** (even if submitted) | Exclude. Key off **score presence**, not submission state. | Submitted-but-ungraded isn't decided yet. |
| **Missing / past-due, unscored** | **Default: exclude** from the math (match "not yet graded"). BUT surface a count: "N items pending grading." | Keeps the number from looking silently rosy; final policy must MATCH Canvas late policy (Canvas may auto-zero — if observed, revisit). |
| **Extra credit / `points_possible == 0`** | Never divide by zero. A 0-possible item can add to `earned` (bonus) but adds 0 to any `possible` denominator. Guard every division. | Extra credit legitimately pushes grade > 100%. |
| **`omit_from_final_grade == true`** | Exclude the assignment entirely (both earned and possible). | Canvas explicitly flags these as non-counting. |
| **Drop-lowest** (per-category toggle) | Suppress until the category has **≥ 2 scored items**. When active, drop the single lowest `earned/poss` ratio from `S(c)` before computing `categoryPct_c`. | Avoids NaN / wild swings on 0–1 items. |
| **Zero-weight category** (weighted mode) | Excluded from current grade AND from % decided. | Weight 0 means it doesn't count. |
| **Weighted category with no scored items** | Excluded from current grade (renormalize around it); contributes **0** to % decided. | Hasn't happened yet — shouldn't drag the grade. |
| **All categories empty / no scores anywhere** | Current grade = `nil` ("no scores yet"), % decided = 0%. | Honest empty state, not "0%". |
| **Weighted-mode weights don't sum to 100** | Normalize by the actual sum of participating weights. | Canvas doesn't force 100; extra-credit categories can push it over. |

---

## 4. Overlay / dedup rules (restated as an algorithm)

For each Canvas assignment `a`:
1. If `a.submission.score != nil` → **Canvas score wins.** Source badge = Canvas.
   Any Gradescope match is ignored (not even shown as unmatched — it agreed).
2. Else if a Gradescope item `g` fuzzy-matches `a` (§5) → fill `a`'s score with
   `g`'s. Source badge = **Gradescope early**. Mark as an overlay so staleness /
   cross-check treat it as provisional.
3. Else → `a` stays unscored (excluded from math per §3).

Every Gradescope item that matched **nothing**, or matched an assignment that
already had a Canvas score, lands in the **unmatched review list**. Manual user
mapping can promote an unmatched item into an overlay (step 2).

---

## 5. Matching heuristics (Gradescope → Canvas)

Goal: map `g.title` to a Canvas assignment robustly across naming drift.

1. **Normalize both titles:** lowercase; strip punctuation; expand/collapse
   `HW`, `Homework`, `PSet`, `Problem Set`, `Lab`, `Quiz` to a canonical token +
   number (`"HW3"`, `"Homework 3"`, `"Problem Set 3"` → `hw 3`). Reuse the
   number-extraction style already in `CourseCode` / Gradescope parsing.
2. **Scope by course first** — only match within the same class (Canvas course
   ↔ Gradescope course).
3. **Exact normalized match** → confidence high, auto-apply.
4. **Token / fuzzy match** (e.g. Jaccard on normalized tokens or edit distance)
   above a threshold → propose, **user-confirmable**, not auto-applied.
5. **Max-points tiebreaker:** when two candidates tie on name, prefer the one
   whose `points_possible` equals Gradescope's max points.
6. No acceptable match → unmatched review list.

Confirmed mappings persist (UserDefaults, same pattern as
`completedAssignmentIDs` / `manualAssignments`) keyed by course + normalized
title so the user isn't re-asked each sync.

---

## 6. UI

### Entry point (hard requirement)
Grade Watcher is reachable **only** from `SettingsSheet.swift`: add a
**"Grade Watcher"** row (its own Section or inside an existing one) that
pushes/presents the grades view via the sheet's `NavigationStack`. **No tab, no
dashboard card, no header button** in this version.

### Grades view — per-class cards
Each selected class renders a card:
- **Current grade, large** (e.g. `91.4%` / letter if we add one later). If no
  scores yet: "No scores yet."
- **"Decided vs still open" bar** — a horizontal progress bar showing % decided,
  labelled (e.g. "38% of your grade is decided").
- **Expandable category breakdown** — per category: name, weight, category %,
  scored/total item counts. Points mode shows the single implicit bucket.
- **Per-number source badges:** `Canvas` / `Gradescope early` / `manual`.
- **"N items pending grading"** chip when past-due-unscored items exist.
- **"Differs from Canvas"** subtle note when the cross-check disagrees.
- **Last refreshed** timestamp + a stale treatment (see §7).

### Manual weight editing (always available)
- Users can edit category weights manually. This is **always** available, and is
  the **only** fallback when Canvas has no weights (points mode / weights hidden).
- Manual weights override Canvas weights for the grade math; source badge for a
  manually-weighted breakdown reflects `manual`.
- Persisted per course in UserDefaults.

---

## 7. Session staleness

Grades refresh **only while the Canvas session cookie is alive** — the same
ceiling as the rest of the cookie-authed features (`SessionCookieStore`). When
the cookie lapses:
- We keep showing the **last computed grades** but mark them **stale**.
- Show a **"Last refreshed <time>"** line; a stale grade must *look* stale
  (dimmed / badge), not silently pretend to be live.
- Canvas doesn't push; refresh happens on each sync while logged in (polling),
  never real-time.

---

## 8. Explicitly cut (out of scope, on purpose)

- **Syllabus auto-parsing of weights.** Deliberately NOT built. Manual weight
  editing is the only fallback. (No fragile NL/PDF syllabus scraping.)
- **Gradescope as a source of *assignments*.** Gradescope only overlays scores
  onto existing Canvas assignments; it can never introduce an assignment into
  the math. (Consistent with HANDOFF: Gradescope-as-assignment-source was
  removed in `a5141e2`; we are not reintroducing it.)
- **Projected / "what-if" grades** (enter a hypothetical score to see the
  effect). Not in this version.
- **Letter-grade cutoffs / GPA.** Percentages only for now.
- **A dashboard/tab surface.** Settings-only entry by user decision.

---

## 9. Architecture placement

- **Grade engine (pure math, no I/O):** `Sources/LowHangingFruitKit/Grades/`
  (e.g. `GradeEngine.swift`). Deterministic, fully unit-testable, no network.
- **Models:** `Sources/LowHangingFruitKit/Models/` —
  `GradeCategory`, `GradeItem`, `CourseGrade` / `GradeBreakdown`, and a source
  enum (`canvas` / `gradescopeEarly` / `manual`).
- **Canvas grades fetch:** new client in `Sources/LowHangingFruitKit/Canvas/`
  (or `CanvasDiscovery/`), following `CanvasDiscoveryClient`'s cookie pattern
  (`HTTPCookie.requestHeaderFields`, `URLSession`, XSSI strip).
  **One client for two concerns:** the `include[]=submission` payload also
  carries `workflow_state` / `submitted_at`, which the in-flight submission-
  detection work (see HANDOFF) needs — expose submission state from this same
  client rather than building a second one that hits the same endpoint.
- **UI:** `Sources/LowHangingFruitUI/`, entered from `SettingsSheet.swift`.

---

## 10. Phase plan (checkpoints)

1. **CP1 — this spec.** Branch `v2.5`, `docs/grades.md`. ← you are here.
2. **CP2 — Models + `GradeEngine` + exhaustive unit tests** (every §3 edge case,
   both modes, the % decided formula). All 47 existing tests stay green.
3. **CP3 — Canvas grades client:** fetch groups + assignments + submissions +
   the course weights flag; decode into models; wire into AppState/sync. Expose
   submission state for the paused submission-detection work. No network in tests.
4. **CP4 — Grade Watcher UI** behind Settings, with manual-weight editing. iOS +
   macOS both build.
5. **CP5 (after feedback) — Gradescope score extraction** + overlay matching +
   unmatched review list.

---

## Decisions (CP1 review, 2026-07-19)

1. **Past-due-unscored:** exclude from the math + surface "N pending grading."
   **No auto-zero.** The cross-check note covers the case where a course's
   Canvas late policy auto-zeroes missing work and the numbers diverge.
2. **"Differs from Canvas" threshold: 1.0 percentage point.** Below that, stay
   silent (rounding noise). Compare only when `computed_current_score` is
   non-nil.
3. **Letter grades: confirmed cut.** Percentages only this version.
4. **Courses shown:** the **selected-course set from the class picker.** A class
   hidden from the dashboard is also hidden from Grade Watcher (consistent
   mental model; no fetching for deselected courses).
5. **Drop rules:** auto-read `rules.drop_lowest` (and `drop_highest`) from the
   `assignment_groups` payload when present; the manual per-category toggle
   remains as override/fallback. The **≥ 2-scored-items suppression applies
   regardless of source.** `rules.never_drop` ids are honored — items pinned
   by the professor are never dropped.

## Decisions (CP2 review, 2026-07-19)

6. **% decided ignores drop rules.** It's computed over each category's raw
   scored-possible points *before* drop-lowest/drop-highest are applied, so it
   stays monotonic with grading progress (rises only as items get scored) and
   never swings because a drop policy removed an item from the math.
7. **Pending-grading count excludes zero-weight categories** (weighted mode
   only). A category with `effectiveWeight == 0` doesn't count toward the
   current grade or % decided (Decision above the fold), so its unscored
   past-due items don't inflate the "N items pending grading" chip either —
   consistent with "weight 0 means it doesn't count."
8. **Pure-extra-credit category yields `nil`, not `0%`.** When every scored
   item in a category has `points_possible == 0` (all extra credit, no real
   denominator), `CategoryResult.percent` is `nil` — an undefined ratio, not a
   zero grade — matching the "no scores yet" honesty rule elsewhere in the
   spec.
</content>

---

## 11. Trajectory, week delta & term summary (addendum, 2026-07-20)

Three read-only additions on top of CP1–CP5. No new endpoints, no new modes;
what-if / projections remain cut (§8) — everything here describes scores that
already exist.

- **Trajectory (grade over time).** `GradeEngine.trajectory(_:)` replays the
  course's scored items in due-date order: one point per scored due date
  (scores due later are masked), plus a final unmasked point at `now`, so the
  line's endpoint always equals the headline grade. Undated scores count from
  the first point (they can't be placed in time); a score due in the future —
  a Gradescope early fill, say — appears only in the final point; "no scores
  yet" points are skipped, never rendered as 0. This is *reconstruction*, not
  history: the chart is complete from the first sync, and every point inherits
  §2–3 (drops, excused, extra credit, both modes) because each point is a full
  `compute` call. Rendered as a 64×26pt hand-rolled sparkline trailing the big
  number (index-spaced — a trend glyph, not an axis chart); endpoint dot
  green/red/neutral by direction.
- **Week delta.** `GradeWatcherStore` persists one observed (day, percent)
  entry per course per refresh day (UserDefaults, same pattern as
  `manualWeights`; pruned to 180 entries per course). The card's chip shows
  current minus the observation closest to 7 days back — a real "since you
  last looked" number, unlike the reconstructed trajectory. It needs a
  baseline ≥ 24h old (a refresh can't compare against itself) and hides while
  |Δ| < 0.1 pt. The chip carries arrow + number, so color is never the only
  signal.
- **Term summary (revised 2026-07-20, owner decision).** Atop the course list,
  an **estimated GPA**: each class's percent stepped through `GradeScale`
  (standard cutoffs mapped to Penn's 4.0 scale — A/A+ 4.0, A− 3.7 … D 1.0, no
  D−), then averaged unweighted (credit hours aren't in the data). Always
  labeled "estimated · standard cutoffs" — professors' real cutoffs are
  unknowable, so the number is honest about being an approximation. Shown once
  ≥ 2 classes have a grade. This narrows §8's letter/GPA cut: the term
  headline converts to the 4.0 scale, but per-class numbers stay percentages
  and no per-class letters are shown.

## 12. Submission detection (addendum)

The submission side-channel `CanvasGradesClient` already fetches alongside
grades (§1, §9) now drives the dashboard, not just Grade Watcher: it decides
which items auto-file under Done without the user tapping anything.

- **The rule (`AssignmentSubmissionInfo.indicatesSubmitted`).** Conservative by
  design — only a positive signal flips an item to submitted, so real work
  never gets auto-marked incomplete by accident. `isMissing` is excluded up
  front (a professor-entered score on missing work arrives as `graded` with no
  `submittedAt`), then either a real `submittedAt` or `workflowState` of
  `submitted`/`pending_review` counts.
- **The join (`Assignment.canvasAssignmentID`).** Canvas's ICS feed embeds the
  numeric assignment id in both the event URL (`/assignments/12345`) and the
  UID (`event-assignment-12345@…`); the URL is preferred, the UID is the
  fallback. Scoped to `.canvas`-sourced true assignments only — quizzes,
  discussions, and events use a different id space in their URLs, so the join
  key comes back nil for them rather than mis-joining.
- **Derived, not persisted.** `AppState.submittedCanvasAssignmentIDs` is
  recomputed from the latest grade snapshots on every refresh
  (`updateSubmissionState()`) and never written to disk — a Canvas correction
  (a retracted submission) self-heals on the next sync instead of sticking.
  `isCompleted(_:)` consults it alongside the existing manual-completion set.
- **Refresh timing.** Grades otherwise only refresh when the user opens Grade
  Watcher (§6, §8). `AutoSyncCoordinator.refreshCanvasGrades` now also runs at
  launch/activation off `ContentView`'s existing refresh loop, throttled to
  once per 15 minutes (mirroring the Gradescope throttle), so submission
  detection works on the dashboard without a Grade Watcher visit.

---

## 13. The grade report & syllabus ingestion (addendum, 2026-07-26)

This section **reverses two of §8's cuts** — deliberately, and narrowly.
Syllabus parsing is back, but only as a *proposal* the user confirms; and
projections are back, but only as read-only arithmetic over scores that already
exist (no user-entered hypotheticals).

The reason for the reversal is a gap Canvas cannot close: Canvas knows what has
been graded, not what it is worth, and not what hasn't been created yet.
Professors routinely publish assignments a week before they're due, so
"what's left" computed from Canvas alone is an undercount for most of the term.
The syllabus is the only place that knows the shape of the whole course.

### 13.1 Watching

Watching a class is opt-in (`GradeWatcherStore.watchedCourseIDs`, persisted).
Every selected class still gets a card and a grade — watching doesn't gate the
numbers. It marks the classes the student is actively managing and is where a
syllabus gets attached. Attaching a syllabus starts watching implicitly.

### 13.2 Projection math (`GradeProjection`, pure)

Per counting category: `w` = normalized weight, `f` = fraction of the
category's points already scored (**pre-drop**, per Decision 6), `p` = the
ratio in the scored, post-drop part.

```
E     = Σ w·f·p           earned share — the floor
open  = 1 − Σ w·f         still up for grabs (= 1 − decidedFraction)
floor   = E                    score 0 on everything left
ceiling = E + open             score 100% on everything left
pace    = E + open · current   the rest goes like the work so far
needed(T) = (T − E) / open     required average on the rest to hit T
```

`needed` returns one of four states, not a bare number: `alreadyReached`,
`need(percent)`, `unreachable(shortfall)`, `nothingLeft`. Points mode is the
same formulas with a single implicit category (`w = 1`).

The drop-rule asymmetry (`f` pre-drop, `p` post-drop) is intentional and
matches Decision 6: dropped points are still decided — they're never coming
back — while the grade itself correctly ignores them.

### 13.3 Syllabus ingestion

**Sources, best first** (`CanvasSyllabusClient`): `?include[]=syllabus_body`,
course pages matching "syllabus", course files matching "syllabus" (PDF via
PDFKit). Paste and file import are always available and are the only route for
a syllabus hosted off Canvas. Finding nothing is a normal outcome, not an error.

**Parsing is deterministic — no model, no network** (`SyllabusParser`). The app
has no backend and a privacy manifest that says nothing leaves the device;
both would have to change to send a student's syllabus somewhere to be read.
Regex suffices because of one property of the domain:

> **A grading scheme's weights sum to 100.** Accept only 90–110 (normalize to
> 100); `|sum − 100| ≤ 0.5` with ≥ 2 categories is high confidence, the rest
> medium, everything else is rejected outright and falls back to manual weights.

That gate is what makes a cheap parser trustworthy: a misread essentially never
adds up. Two specific traps are handled explicitly because they'd otherwise
pass it — a `Total 100%` table row (doubles the sum) and comparison phrasing
("attendance below 80% …", which reads as a category named "attendance below").

Also extracted: drop-lowest counts from prose, **expected item counts**
("there will be 10 problem sets" — the field Canvas can't provide), letter
cutoffs (rejected unless ≥ 3 bands and monotonic with letter rank), and curve
language (narrow markers only; "subject to change" is boilerplate and would
flag every course).

### 13.4 Mapping to Canvas (`SyllabusMatcher`)

Same three tiers as the Gradescope overlay, sharing one normalizer
(`TitleNormalizer`, extracted from `GradescopeOverlay` so the two matchers
can't drift): exact → confirmed → fuzzy (proposed, never auto-applied) →
unmatched. Ambiguous ties are left unmatched rather than guessed. Heavier
categories win the greedy assignment.

**Coverage is all-or-nothing.** Syllabus weights reach the engine only when
every weight-bearing Canvas group is covered, because `GradeEngine`'s manual
weights are all-or-nothing — a partial set would silently zero the categories
it doesn't cover. Half a syllabus is worse than none.

### 13.5 Provenance

Syllabus weights flow in through the existing `manualWeights` channel plus
`Input.syllabusWeightedCategoryIDs`, which changes only the reported
`weightSource` (new `ScoreSource.syllabus`), never the arithmetic. A
hand-typed weight always overrides a syllabus weight — the edit is the more
recent, more deliberate statement of intent.

### 13.6 Honesty rules (encoded, not aspirational)

- Nothing parsed is applied without confirmation; every weight is shown next to
  the line it was read from.
- Every projection is labeled a projection.
- A failed parse says so and hands off to manual weights — it never guesses.
- Detected curve language is surfaced: cutoffs may not hold.
- Letter grades say whether they came from the syllabus's cutoffs or the
  standard estimate.

### 13.7 Placement

```
Sources/LowHangingFruitKit/Syllabus/
  SyllabusModels.swift        scheme, category, attached syllabus, candidate
  SyllabusParser.swift        pure text → scheme; the 90–110 gate lives here
  SyllabusTextExtractor.swift HTML (structure-preserving) + PDFKit + paste
  SyllabusMatcher.swift       scheme categories ↔ Canvas groups, 3 tiers
  SyllabusReconciler.swift    expected-count vs Canvas-listed gaps
  CanvasSyllabusClient.swift  cookie-authed discovery of syllabus documents
Sources/LowHangingFruitKit/Grades/
  GradeProjection.swift       floor/pace/ceiling + needed-for-target
  GradeCutoffs.swift          bands, standard table, custom (syllabus) tables
  TitleNormalizer.swift       shared with the Gradescope overlay
Sources/LowHangingFruitUI/
  GradeReportView.swift       the report
  SyllabusSetupView.swift     import → review → map → confirm
```

Tests: `GradeProjectionTests` (14), `SyllabusParserTests` (20),
`SyllabusMatcherTests` + `SyllabusReconcilerTests` (14). All syllabus fixtures
are **synthetic** — the rule against committing real Canvas/Gradescope data
covers course documents too.
