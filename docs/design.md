# LHF — Design System

**App name:** LHF (Low Hanging Fruit)
**Tagline:** *Pick what's ripe.*

LHF surfaces the next due thing first. The design language is calm, paper-like,
and chronological — the UI should feel like a single well-laid-out page rather
than an app with chrome.

## Color palette

All four state colors are picked against the Eggshell background and against
Graphite text. Urgency reads at a glance from color alone.

| Token             | Hex       | Use                                        |
|-------------------|-----------|--------------------------------------------|
| Eggshell          | `#E6E4CE` | App background, card surface               |
| Ruby Red          | `#A4031F` | Past-due assignments                       |
| Amber Earth       | `#E28413` | Urgent (due today / within ~24h)           |
| Cornflower Ocean  | `#3A6EA5` | Upcoming (this week)                       |
| Seagrass          | `#439A86` | Future (beyond this week)                  |
| Graphite          | `#30323D` | Primary text, icons, dividers              |

State is derived from due date, not set manually. An assignment moves
through Seagrass → Cornflower Ocean → Amber Earth → Ruby Red as its
deadline approaches and passes.

## Typography

- **Headers:** Instrument Serif — section titles, the LHF wordmark,
  assignment titles in the detail view.
- **Everything else:** Geist — list rows, metadata, buttons, sheet content.

Use weight and size for hierarchy; avoid all-caps and avoid color for
typographic emphasis (color is reserved for urgency).

## Layout principles

- **Generous whitespace.** Padding is the primary structural tool; borders
  and dividers are used sparingly.
- **Sectioned chronological list.** One vertical list, grouped by
  Past Due / Today / This Week / Later. Sections are headers in the same
  scroll view — not tabs, not separate screens.
- **Custom toggle**, not the system toggle, for the "show completed"
  control and similar binary states. The toggle uses the urgency palette
  on its active side.
- **No tab bar.** Navigation depth is shallow: list → detail/edit sheet.
- **Edge-to-edge surfaces.** Cards sit directly on Eggshell with no
  containing card stroke; whitespace separates them.

## Interaction principles

- **Single tap** on a row toggles complete. Completing an item plays a
  short, soft haptic and the row settles into a "done" treatment in place
  before the next refresh moves it.
- **Double tap** on a row opens the edit sheet (title, due date,
  recurrence, notes).
- **Haptics tied to urgency.** The completion haptic is heavier for
  Ruby Red items (you just cleared something overdue) and lightest for
  Seagrass items. This makes urgency tactile, not just visual.
- **Swipe is reserved** for destructive actions (delete) and is never the
  primary path for completion.
- **Long press** previews the source link (Canvas / Gradescope URL) without
  navigating away.

## What this design is *not*
- Not a kanban board. There are no columns to drag between.
- Not a calendar. Dates are shown inline; there is no month grid.
- Not configurable. The four states and their colors are fixed.
