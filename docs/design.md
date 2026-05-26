# Penn Dashboard — Design System

## Identity

**App name:** LHF — Low Hanging Fruit
**Tagline:** Low Hanging Fruit
**Voice:** Quiet, functional, no chrome. The data is the design.

## Color Palette

| Role | Name | Hex | Usage |
|------|------|-----|-------|
| Background | Eggshell | `#E6E4CE` | App background, card text |
| Text | Graphite | `#30323D` | All body text, icons, toggles |
| Past due | Ruby Red | `#A4031F` | Card color — overdue assignments |
| Urgent | Amber Earth | `#E28413` | Card color — due within 24 h |
| Upcoming | Cornflower Ocean | `#3A6EA5` | Card color — due in 2–3 days |
| Future | Seagrass | `#439A86` | Card color — due in 4+ days |

Card text is always white on the urgency color. Section labels and UI chrome use Graphite at reduced opacity (40–60%).

### Urgency thresholds

| State | Condition |
|-------|-----------|
| Past | `dueAt < now` |
| Urgent | `now < dueAt < now + 24 h` |
| Upcoming | `now + 24 h ≤ dueAt < now + 3 days` |
| Future | `dueAt ≥ now + 3 days` |

## Typography

| Use | Font | Size / Weight |
|-----|------|---------------|
| App wordmark | Instrument Serif | 34 pt, regular |
| Date header | Instrument Serif | 28 pt, regular |
| Empty state | Instrument Serif | 28 pt, regular |
| Assignment title | Geist | 16 pt, semibold |
| Toggle labels | Geist | 13 pt, regular / semibold |
| Due countdown | Geist | 13 pt, medium |
| Course code | Geist | 11 pt, semibold, +0.7 kerning, uppercase |
| Section headers | Geist | 11 pt, semibold, +0.6 kerning, uppercase |
| Tagline / meta | Geist | 12–13 pt, regular |

## Layout Principles

- **Generous whitespace.** 20 pt horizontal padding on cards, 12–16 pt vertical gaps between cards, 24 pt between sections.
- **Chronological sections.** Assignments grouped into PAST DUE / TODAY / TOMORROW / THIS WEEK / LATER, never a flat unsorted list.
- **Full-width cards.** Cards stretch edge-to-edge within the padded container. No grid, no columns.
- **Card anatomy.** Course code (top-left, uppercase) → Title (below, large) → Due countdown (bottom-left). Completion button top-right. Link button bottom-right.
- **Custom toggle.** Pill-shaped segmented control with a sliding graphite fill. Options expand equally to fill full width. Count badges inside each option.

## Interaction Principles

- **Single tap card body** → opens the due-date edit sheet (session-local override).
- **Tap completion circle** → triggers checkmark draw animation, card fades and slides up, assignment moves to Completed tab.
- **Tap completion circle on a completed card** → moves assignment back to Active.
- **Haptic feedback tied to urgency.** Heavy for past-due, medium for urgent, light for future (iOS only).
- **Pulse animation** on the due countdown text for past-due and sub-hour urgent assignments. Opacity oscillates 0.5–1.0 at 0.7 s period.
- **Critically-damped spring** (`damping 30, stiffness 220`) for sibling cards shifting after a completion — no bounce.

## Platform Adaptations

| Feature | iPhone | macOS |
|---------|--------|-------|
| Settings / connection controls | Gear icon → bottom sheet | Persistent top bar |
| Minimum window size | n/a | 720 × 480 pt |
| WebView login sheets | Full screen | 860 × 620 pt |
| Haptics | Yes | No-op |
