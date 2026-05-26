# Decision Log

Newest entries at top. One entry per significant decision — what was decided, why, and what was rejected.

---

## 2026-05-26 — iOS UI rework branched off main

**Decision:** Created `marco/ios-ui-rework` to adapt the Mac-first UI for iPhone, rather than patching the existing Mac layout.

**Why:** The original layout had a hardcoded `minWidth: 720` on the root view, an overflowing horizontal toolbar, and card sizing optimised for a wide window. These weren't fixable with small tweaks — the layout assumptions were fundamentally Mac-first.

**What changed:** ContentView split into `#if os(iOS)` / `#if os(macOS)` branches. Setup/connection controls moved to a `SettingsSheet` accessed via a gear icon on iPhone. Header redesigned for portrait. Cards made full-width. DEBUG sample data added so the UI is reviewable without real credentials.

**Rejected:** Patching the existing layout with `GeometryReader` conditionals. Too fragile and hard to maintain as the two platforms diverge further.

---

## 2026-05-22 — Four-state urgency color system

**Decision:** Replaced the earlier three-state color system (green / blue / default) with four named urgency states: Ruby Red (past), Amber Earth (urgent <24 h), Cornflower Ocean (upcoming 2–3 days), Seagrass (future 4+ days).

**Why:** The three-state system had no distinction between "due in 2 hours" and "due in 20 hours." The four-state system gives students an immediate visual read on how much time they have — the card color alone communicates urgency before they read the text.

**Rejected:** Using a continuous color gradient. Too subtle to read at a glance; named states are more scannable.

---

## 2026-05-22 — SwiftUI / Swift for both platforms

**Decision:** Converged on Swift + SwiftUI for the full stack (UI and data layer), targeting iOS and macOS from a single Swift Package Manager project.

**Why:** Olisa's scrapers were already built in Swift. SwiftUI's multiplatform support means one codebase covers both targets with `#if os(iOS)` / `#if os(macOS)` conditionals where needed. Swift 6 strict concurrency catches data-race bugs at compile time.

**Rejected:** React Native front-end with a shared Swift backend. Would have required a native module bridge for every scraper, added a JavaScript runtime dependency, and split the team across two languages with no benefit — the scrapers can't run in JS anyway.
