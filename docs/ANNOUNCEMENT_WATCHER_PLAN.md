# v6: Grade Watcher visibility + Announcement Watcher

Written 2026-08-31 (overnight session; owner asleep — decisions recorded here
for morning review). Branch: `v6`, cut from the head of the PR #8 line.

## 1. Grade Watcher — back in the UI

Done in one line. `FeatureFlags.gradeWatcher` was `false` as a **merge
artifact**: the v3.5 doc comment ("on this branch the entry points are on")
survived the v3.5+v4 merge while v4's `false` value did. The dashboard's
"grades" header button (`ContentView.swift:406`) and the Settings entry were
both gated on it. Now `true`; the runtime gate `canUseGradeWatcher` still
hides the button for calendar-link-only installs with no cookie session.

## 2. Announcement Watcher

Reads professors' Canvas announcements and turns actionable ones ("read
ch. 3 before Friday's class") into dashboard assignments.

### Pipeline

```
selectedCanvasCourseIDs() ──> CanvasAnnouncementsClient (cookie REST, paginated)
        │  new announcements only (processed-ID cache, each parsed exactly once)
        ▼
AnnouncementAssignmentExtractor (protocol)
        ├─ HeuristicAnnouncementExtractor   always available, on-device, free
        └─ ClaudeAnnouncementExtractor      opt-in, claude-haiku-4-5, key in Keychain
        ▼
dedup against existing items (normalized title within course — an announcement
that restates a real Canvas assignment must not create a twin)
        ▼
Assignment(source: .canvasAnnouncement) ──> ledger reconcile ──> dashboard
```

### Decisions and why

- **Extractor is a protocol with two backends.** LHF's shipped privacy story
  is "everything on-device"; the review notes say so. Sending professors'
  announcement text to an API must therefore be **opt-in** (off by default),
  with the heuristic backend doing real work without it. The AI setting is
  labeled with exactly what leaves the device.
- **Model: `claude-haiku-4-5`** — the cheapest Anthropic model ($1/$5 per
  MTok). Owner's explicit constraint. Called directly over REST
  (`POST /v1/messages`, headers `x-api-key` + `anthropic-version:
  2023-06-01`) since Swift has no official SDK. One request per
  announcement: forced tool call (`tool_choice` → `extract_assignments`
  tool), so the answer arrives as schema-shaped `tool_use.input`, not prose.
  `max_tokens` small. No retry loops.
- **Token economy:** HTML stripped to plain text before sending; body capped
  (~4k chars); each announcement parsed once ever (processed-ID set in
  `UserDefaults.lhf`); nothing re-sent on later syncs.
- **API key in the Keychain** (`AnthropicKeyStore`, modeled on
  `ICSFeedURLStore`) — it is a bearer credential; defaults are off-limits per
  CLAUDE.md.
- **New `Assignment.Source` case `.canvasAnnouncement`** rather than reusing
  `.manual`: provenance must be visible and deletable, and dedup/aging rules
  differ. The only exhaustive switch over `Assignment.Source` in the tree
  turned out to be `RecurringTask.isOccurrence` (GradeCourseCardView and
  GradeModels switch over the unrelated grade-provenance `ScoreSource`);
  `StoredAssignment` round-trips the raw string, so persistence needed
  nothing.
- **Created items are real ledger rows** — they survive relaunch, age, and
  archive like everything else, and the card's URL opens the announcement.
- **Dedup before insert:** normalized-title match (AssignmentDeduplicator's
  vocabulary) against current items of the same course; announcements that
  merely restate an existing assignment create nothing.

### Deliberately out of v1

Editing extracted items before insert (they're ordinary items — edit/delete
after); per-course announcement toggles; parsing announcement attachments;
any non-Anthropic model.

### Open questions for the owner

1. Auto-insert vs. suggest-first: v1 auto-inserts (your words: "create it on
   LHF"). If hallucinated deadlines show up in practice, the safer design is
   a confirm sheet — say the word.
2. The AI path needs an Anthropic API key. Fine for you; a shipped student
   product wants either a proxy or on-device Apple Foundation Models
   (iOS 26+). Deferred.

## Status at end of overnight session (2026-08-31, pre-dawn)

Everything above is implemented, on `origin/v6`, and **uncompiled** — no
Swift toolchain where this was built. An independent verifier pass over the
full branch diff found no blockers; its two should-fixes (direct tests for
the pagination security guard; this document's switch claim) are fixed.
Left open as recorded nits: within-one-batch candidate self-duplication
isn't deduped (only against prior state); `refreshedCookieHandler` unwired
on the announcements client (matches CanvasModulesClient precedent).

Morning gate, in order:
1. `git fetch && git checkout v6`, then `cd LowHangingFruitKit && swift test`
   — expect **663 + 30 = 693** tests / 70 suites, all green.
2. `xcodegen` not needed (no project.yml change); build the app, open
   Settings — "announcement watcher" section, watcher on / ai off.
3. The "grades" button is back in the dashboard header (needs a live
   cookie session to appear — `canUseGradeWatcher`).
4. To try the AI path: Settings → announcement watcher → ai assist on →
   paste an Anthropic API key.
