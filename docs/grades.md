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
