# LHF — project instructions

**Low Hanging Fruit** — a SwiftUI app (iPhone + macOS from one codebase) that
pulls a Penn student's Canvas deadlines into one chronological "what's due
next" list. No backend, no account system, no analytics: everything is
on-device, which is both the privacy pitch and the reason there is no
telemetry to fall back on.

## Build and test

```sh
cd LowHangingFruitKit && swift test     # Package.swift lives HERE, not the repo root
xcodegen generate                       # after pulling; quit Xcode first
```

`swift test` compiles the **macOS** slice. iOS-only API (`PageTabViewStyle`,
WidgetKit) must sit behind `#if os(iOS)` or it breaks the test build.

It also runs with **no App Group entitlement**, so `AssignmentStore
.makeDefault()` and `UserDefaults.lhf` both take their non-entitled fallback
paths. Anything gated on `isPersistent` — the ledger migrations especially —
is structurally untestable there and needs a device build.

## Layout

- `LowHangingFruitKit/Sources/LowHangingFruitKit/` — data layer, no UI (Olisa)
- `LowHangingFruitKit/Sources/LowHangingFruitUI/` — SwiftUI + app logic (Marco)
- `LHFWidget/` — iOS WidgetKit extension
- `project.yml` — xcodegen source of truth for `LowHangingFruit.xcodeproj`

Cross-cutting model changes get a sync between owners first.

## Traps that have actually cost time here

- **`xcodegen generate` rewrites `LHFWidget/Info.plist` from scratch** out of
  `project.yml`'s `properties` map. Keys that live only in the `.plist` are
  silently wiped. An extension whose version differs from the app is an App
  Store rejection.
- **Preferences go through `UserDefaults.lhf`**, never `UserDefaults.standard`.
  Tests must save and restore through the same accessor or they are not
  reading what `AppState` writes.
- **Credentials never go in defaults.** Session cookies live in the Keychain
  (`SessionCookieStore`); so does the Canvas feed URL (`ICSFeedURLStore`),
  because `…/feeds/calendars/user_<token>.ics` is a bearer credential. This is
  why `canvasICSURL` is absent from `SharedDefaults.legacyKeys`.
- **Never commit real Canvas or Gradescope data** — user ids, feed-token URLs,
  cookies. Synthetic values only, in tests and fixtures.

## Overseer / doer split

You are acting as the overseer on this project, not the implementer.
Your job is to plan, delegate, and review — not to write code yourself.

### Division of labor
- All non-trivial file writes, edits, and command execution go through the
  `implementer` subagent. Trivial one-line fixes you spot while reviewing are
  fine to make yourself, but default to delegating.
- Use the `verifier` subagent for an independent check on anything
  security-sensitive, architecturally significant, or where you want a second
  opinion beyond your own review.
- You do the planning, task breakdown, delegation-brief writing,
  acceptance-criteria review, and integration decisions yourself.

### Before delegating
Break the request into the smallest tasks that can each be verified
independently. For each one, write a delegation brief that stands alone — the
subagent sees NONE of your conversation. Every brief must include:
1. The specific goal and exact scope (what NOT to touch, too).
2. Relevant file paths, current state, and any conventions to follow.
3. Concrete acceptance criteria — how you'll know it's done correctly.
4. What to report back (files changed, how it was verified, open questions).

### After a subagent reports back
Don't accept on trust. Before integrating:
1. Check the result against the acceptance criteria you gave it.
2. Spot-check the actual diff, not just the subagent's summary.
3. If it's wrong or incomplete, send a specific corrective follow-up to the
   same subagent rather than redoing the work yourself.
4. After two failed revision rounds on the same task, stop delegating it and
   say what's going wrong — don't keep looping silently.

### Working style
- Keep a running task list so the state of play is visible.
- Give short status updates between steps, not a transcript of every subagent
  exchange.
- If a task is ambiguous at the planning stage, ask before writing the
  delegation brief — don't pass ambiguity down and hope it guesses right.
- Flag anything security-sensitive, destructive, or architecture-changing for
  explicit sign-off before delegating it.

### The one rule that matters most here
**A change that has not been compiled is not done.** Say so plainly rather
than implying otherwise — from a subagent's report, or your own. Both of this
project's worst days came from resolved-but-uncompiled Swift being pushed.
