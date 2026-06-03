# LHF — Design System

**App name:** LHF (Low Hanging Fruit)
**Greeting:** the dashboard opens with *"Hello, &lt;name&gt;"* (name captured in onboarding).

LHF surfaces the next due thing first. The design language is calm, warm, and
paper-like — a single well-laid-out page rather than an app with chrome.

> This document describes the **v2 redesign** that shipped to `main`
> (commit `9697e15`+). It supersedes the earlier eggshell/full-bleed concept.

## Color palette

| Token            | Hex       | Use                                              |
|------------------|-----------|--------------------------------------------------|
| Greige           | `#F4F1EC` | App background                                   |
| Card White       | `#FFFFFF` | Active assignment card surface                   |
| Ink              | `#211F1B` | Primary text / titles                            |
| Date / footer    | `#5C574E` | Header date, serif footer                        |
| Course code      | `#A39C8E` | Course code (9pt, uppercase, tracking 1.2)       |
| Spine — overdue  | `#C8443A` | Red spine + due text, past due                   |
| Spine — today    | `#D98C2B` | Amber spine (due text `#C2861A`), due ≤ 24h       |
| Spine — upcoming | `#2E7D6B` | Green spine + due text, 2+ days / later          |
| Ring track       | `#E5DDCE` | Unfilled portion of the weekly ring              |
| Toggle bg        | `#E9E3D8` | Segmented control container                      |
| Divider          | `#E2DBCE` | Section header rules                             |
| Done card        | `#F0EDE6` | Completed (archived) card surface                |
| Done spine       | `#B6B0A2` | Muted grey spine on completed cards              |

Each active card has a **6pt colored spine** on its left edge (clipped to the
card's 13pt corners). Spine color encodes urgency, derived from the due date —
overdue → today (≤24h) → rest-of-week → later.

## Typography

- **Instrument Serif** — the `LHF` label, the "Hello, &lt;name&gt;" greeting,
  the date, the ring number, the Done footer.
- **Geist** — everything else: course codes, titles, due text, toggle labels,
  section headers.
- Custom faces aren't bundled yet, so both fall back to the **system serif /
  system sans** designs — the serif↔sans distinction is preserved either way.

## Layout

- **Header:** `LHF` label · "Hello, &lt;name&gt;" · date + **sync** + **gear**
  on the left; **weekly progress ring** (completed/total this week, green fill)
  top-right. No tab bar, no clutter.
- **Segmented toggle:** a pill with three options — **This week / All / Done** —
  with a sliding active indicator.
- **Timeline list:** sectioned by urgency. Section headers are `LABEL · rule ·
  count`.
  - *This week:* OVERDUE · TODAY · REST OF WEEK
  - *All:* the above plus LATER (8+ days out)
  - *Done:* COMPLETED TODAY · EARLIER THIS WEEK, then a serif footer
    ("N down this week. / nice pace.").

## Interaction

- **Single tap** an active card → complete. Plays an urgency-weighted haptic
  (heavy = overdue, light = future), the card animates up and out, and the
  weekly ring re-fills. The data mutation is deferred until the exit finishes.
- **Calendar button** (right edge of each card) → opens the due-date editor.
  A manually-changed due date shows **"manually adjusted"** under the date.
- **Tap a completed card** (Done tab) → un-complete it.
- **Sync button** (header) → manual refresh; re-syncs Canvas + Gradescope using
  the persisted session.

## What this design is *not*
- Not a kanban board, not a calendar grid.
- Urgency colors are fixed and always due-date-driven (never set by hand).
