# Low Hanging Fruit — Handoff

_Last updated: 2026-06-30_

**LHF (Low Hanging Fruit)** is a personal academic dashboard for Penn students.
It reads the student's own **Canvas** calendar feed and shows assignments and
deadlines as one chronological "what's due next" list, with local reminders.
SwiftUI, iPhone (+ macOS from the same code). **Canvas-only** as of v1.0.0.

---

## ⚠️ Where things stand right now (read this first)

The app is code-complete at **v1.0.0 / build 1** (commit `5c5354b`) with a full
App Store package (see the bottom of this doc). **But active development has
reopened** on two fronts decided this session:

1. **Real Canvas submission detection** — a NEW feature. Feasibility
   investigation is in progress (results below).
2. **Sync-bloat fix** (Priority 1 bug) — **root cause is now identified**
   (details below).

The Priority 1–3 task list (further down) is **PAUSED by user decision:
"submission feasibility first."** Do not resume Priority work until the
submission question below is closed.

> **Core model — corrected this session.** Two framings that were floating
> around are wrong: (a) LHF is **Canvas-only**; Gradescope was deliberately
> removed (commit `a5141e2`). (b) The app does **not** currently know
> "submitted" — the ICS feed carries no submission state
> (`CanvasICSClient.normalize` hardcodes `submitted: false`). Items show until
> the **user taps to mark them done** (`completedAssignmentIDs`), and
> notifications are **due-date reminders**. "Notify when not submitted" was a
> **Gradescope** capability (it scraped submit-vs-submitted from HTML) and left
> with Gradescope.

---

## 🔬 Submission detection — feasibility investigation (NEW, in progress)

**Goal (user):** the app should read real Canvas submission state, drive app
state from it, and send notifications based on whether assignments are submitted.

### Key finding: the self-scoped Canvas session API is OPEN at Penn ✅

Run in the user's **logged-in browser** (their session, not ours):

```
GET https://canvas.upenn.edu/api/v1/users/self/courses?enrollment_state=active&per_page=100
→ returned full JSON (all enrollments). PROVEN reachable with session cookies.
```

This **does not contradict** the "Penn IT denied Canvas API access" constraint.
That denial was of **developer / OAuth keys** (third-party integrations).
Reading *your own* data through *your own* logged-in session is a different door,
and it is open — the **same auth the syllabus scanner already uses**
(`SessionCookieStore` + `CanvasDiscoveryClient`, cookie-authenticated GETs).

### The hard ceiling (tell the user before building)

- Submission state is only knowable **while the Canvas session is alive.** Penn
  SSO cookies expire server-side; when they lapse the app falls back to the
  cookieless ICS feed (no submission field), so submission state **goes stale
  until re-login.** "At all times" is not achievable. Realistic model:
  *refresh on each sync while logged in; degrade gracefully otherwise.*
- Canvas does not push changes, so "notify when it flips to submitted" means
  **polling on each sync**, not real-time.
- **Notifications stay regardless** (user: "a notification about an assignment
  is still helpful, regardless of if you submitted it"). If submission lands,
  submitted items just get their reminder suppressed.

### One confirmation step still open

The submission field itself has **not yet been observed**, only the auth path:

```
GET https://canvas.upenn.edu/api/v1/courses/:id/assignments?include[]=submission&per_page=5
```

Each assignment *should* carry `submission.workflow_state`
(`unsubmitted` / `submitted` / `graded` / `pending_review`) + `submitted_at`.
Tested so far:
- **CIS 3200** (id `1925208`, the only current real course) → returned `[]`
  (Summer 2026 course, no assignments posted yet — not a failure).
- A cohort/diagnostic course → `404 "resource does not exist"` (Assignments tab
  disabled; auth still worked).

**NEXT:** rerun `include[]=submission` against a course that actually **has
assignments** — e.g. **MATH 1400** (id `1830605`, completed Spring 2025). That
single result confirms the `submission` object shape and closes feasibility.

### Build sketch (once confirmed)

- New `CanvasSubmissionClient` in `Sources/LowHangingFruitKit/Canvas/`, mirroring
  `CanvasDiscoveryClient` (cookie auth, `URLSession`). Strip any leading
  `while(1);` XSSI prefix before JSON decode.
- On each sync, fetch submissions per **selected** course, map assignment
  id/URL → `workflow_state`, and set `Assignment.submitted` (today hardcoded
  `false` at `CanvasICSClient.swift:51`).
- Keep notifications as due-date reminders; suppress reminders for submitted items.

---

## 🐛 Priority 1 — Sync bloat: ROOT CAUSE FOUND

**Symptom:** the list gets polluted with assignments from past terms.

**Root cause (empirical, from probe #1):** the user is enrolled in **9 "active"
Canvas courses spanning 4 terms**, but only **CIS 3200-920 (`202620` / Summer
2026)** is a real current class. The rest are **diagnostics, "Class of 2028"
cohort spaces, and old courses Canvas never marked "concluded"** — so they stay
`active` forever and the ICS feed dutifully pulls all their assignments. It is
**not** primarily a parser bug; it's un-scoped course inclusion. The existing
5-month `isTooOld` cutoff (`AppState.isTooOld`) can't catch a never-ending
diagnostic space or a recent past term.

### Chosen fix — Option 3, hybrid class picker (user approved: "I like 3")

- On connect, **auto-detect current-term courses and pre-select them**; also show
  the **full class list** so the user can uncheck junk / add a summer class. Only
  **selected** courses' assignments surface. This is the "guard so stale-term
  items can't reappear."
- **Term detection:** Penn `course_code` suffix is `YYYYTT` where
  `TT = 10 Spring / 20 Summer / 30 Fall` (June 2026 → `202620`). Or use
  `enrollment_term_id` from the courses API.
- **Data source:** `/api/v1/users/self/courses?enrollment_state=active` (proven)
  gives `id`, `name`, `course_code`, `enrollment_term_id` per course. Map each
  ICS assignment → its course via the `/courses/<id>/` segment in the item's URL.
- **Persist** the selected-course set in `AppState` + `UserDefaults` (same pattern
  as `completedAssignmentIDs` / `manualAssignments`).

---

## 📋 Priority 1–3 task list (PAUSED — original brief, resume after submission)

**P1 — Bugs** (drive WITH the user, do not loop autonomously):
- **Sync bloat** — root-caused above; fix = the class picker.
- **Sync + manual-add seamless** — rigorously test the full sync path and the
  add-assignment flow. Edge cases to cover: duplicate items across sources,
  manual item colliding with a synced one, offline add, deleted-on-Canvas item.

**P2 — Defined changes** (may loop against a real test gate; stop after the same
error twice):
- Show item **provenance** on each card (Canvas vs manual).
- Parse the raw course string into a clean **code + number**
  (`FNAR 3230-401 202610 PSYCHEDELIC…` → `FNAR 3230`); build a test table of
  messy strings → expected output and loop until all pass.
- Progress ring **total reflects the active filter** (This Week vs All).
- Remove the "A one-time assignment" helper text, or make it reflect the
  Repeats-weekly toggle (recommend which + why).

**P3 — Quality pass** (run once, findings report only, NO edits): run the UI/UX
frontend skill across the app and surface every improvement with reasoning.

**Backlog (noted, not now):** the app deep-links straight to Penn Canvas —
acceptable for a Penn-first launch, not the long-term answer.

---

## 🔐 How login / session works

**Log in once — they stay logged in.**
- **Onboarding never reappears** (`hasCompletedOnboarding` in `UserDefaults`).
- **Assignments need no re-login.** Onboarding captures the personal Canvas
  **calendar-feed URL** (`…/feeds/calendars/user_<token>.ics`, a self-
  authenticating secret token URL). Every launch + the 5-min auto-refresh fetch
  it with a plain HTTPS GET — no cookies, no session (`CanvasICSClient`,
  `AppState.sync()`).
- **Only the syllabus/announcement "suggestions" scanner uses login cookies**
  (`SessionCookieStore` persists + replays them). Penn SSO cookies expire
  server-side; when they do, only that feature asks to reconnect. **The
  submission-detection feature (above) will ride on this same cookie session.**

---

## 🏗️ Architecture / layout

```text
App/                       # Xcode app target (@main, Info.plist, PrivacyInfo, icon)
LHFWidget/                 # iOS WidgetKit extension (Home + Lock Screen "Next Due")
project.yml                # xcodegen source of truth → LowHangingFruit.xcodeproj
LowHangingFruitKit/
  Sources/
    LowHangingFruitUI/     # SwiftUI: RootView, ContentView, AppState,
                           #   DashboardViewModel, Onboarding, Settings,
                           #   NotificationScheduler, cards, design tokens…
    LowHangingFruitKit/    # data layer (no UI)
      Models/Assignment.swift
      Canvas/{CanvasICSClient,ICSParser}.swift
      CanvasDiscovery/{CanvasDiscoveryClient,CanvasRequirementScanner}.swift
  Tests/LowHangingFruitKitTests/
docs/appstore/             # App Store submission package
```

- **Marco** owns the UI layer; **Olisa** owns the data layer. Cross-cutting
  changes (e.g. the `Assignment` model) get a quick sync first.

## 🧰 Build / run / test

```sh
cd LowHangingFruitKit && swift test        # 13/13 passing as of this session
# Run: open LowHangingFruit.xcodeproj, pick an iPhone SIMULATOR (no signing), ⌘R
xcodegen generate                          # regenerate project after editing project.yml
```

- **Widget (`LHFWidget/`)** — a separate iOS process, so it can't read
  `AppState`. The app writes a small "next due" snapshot to a shared **App
  Group** container (`WidgetSnapshotStore` in `LowHangingFruitKit`) on every
  dashboard rebuild and calls `WidgetCenter.reloadAllTimelines()`; the widget
  reads it. **Manual step before it works:** in Xcode → Signing &
  Capabilities, add the **App Groups** capability `group.com.lhf.lowhangingfruit`
  to *both* the `LowHangingFruit` and `LHFWidgetExtension` targets (entitlements
  files already reference it; this registers the group with your Apple ID).
  Without it the container URL is nil and the widget shows its empty state.
- **DEBUG seam:** launch with `-LHFDemoData` (populated dashboard, skips
  onboarding), plus `-LHFTabAll`, `-LHFTabDone`, `-LHFShowSettings`.

## 📌 Important constraints

- **Canvas developer/OAuth API is denied by Penn IT** → the assignment list comes
  from the user's Canvas **calendar ICS feed** (no submission state in ICS).
  Submission state for true assignments (quizzes excepted, since their ICS URLs
  use a different id space) is now recovered instead from the self-scoped grades
  fetch (`/api/v1/...` with the user's own login cookies, docs/grades.md §12) —
  distinct from the denied developer keys.
- No backend of ours; everything on-device. No analytics/tracking/ads.
  `PrivacyInfo.xcprivacy` declares no collection (UserDefaults reason CA92.1).
- Generated artifacts (`build/`, `LowHangingFruitKit/dist*/`, `.iosbuild/`) are
  gitignored.

## 🔒 Do NOT commit real Canvas data

The feasibility probes returned the user's **real** Canvas data (user id, secret
per-course `…/feeds/calendars/course_<token>.ics` URLs). Keep these out of git,
this handoff, memory, and any fixtures. Use synthetic values in tests.

---

## 🚀 App Store status (still the eventual destination, after the work above)

- Version **1.0.0 / build 1**, commit `5c5354b`. `swift test` passes; iOS
  **Release** builds succeed in the simulator; onboarding → dashboard verified.
- **The one blocker: code signing.** Device/Archive builds fail with _"Signing
  requires a development team"_ — no Apple Developer account is signed into Xcode
  on this Mac. Fix: Xcode → Settings → Accounts → add Apple ID → target
  **LowHangingFruit** → Signing & Capabilities → automatic signing → pick Team,
  then add `DEVELOPMENT_TEAM` to `project.yml` so it survives `xcodegen generate`.
- **Git push:** remote is `OlisaNW247/penn-dashboard`; pushing needs the
  **`Marcomercader`** account (`gh auth switch --user Marcomercader`).
- Full submission runbook: **`docs/appstore/CHECKLIST.md`** (App Store Connect
  record, privacy hosting, listing/assets, review notes + demo video, archive &
  submit). **Review-access decision:** reviewers can't pass Penn SSO → handled
  with review notes + demo video, not an in-app sample-data path.

## 🔭 Known follow-ups

- No in-app "Log out / disconnect" control; sync errors surface in Settings only.
- Sample-data demo path for onboarding (review insurance) — not built.
- macOS ("My Mac") destination not yet exercised post-Gradescope-removal.
</content>
</invoke>
