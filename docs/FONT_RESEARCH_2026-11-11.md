# The class-code font: what it is, why it reads as "Claude", and five alternatives

2026-11-11, research only. No font in the app was changed. Marco asked which
face draws "PHYS 0151", said someone told him it looks like Claude, and asked
for a few options. The images are in `docs/font-research/`. They are a
faithful re-draw of `AssignmentCardView`'s numbers (sizes, tracking, padding,
the 18pt corner, the teal "due in two days" tint) made with CoreText on the
Mac by `docs/font-research/render.swift`. They are **not simulator
screenshots**, and no build was run. The downloaded font files were kept in a
scratch folder and are not in the repo.

## 1. What draws the class code today

Every class code in the app goes through `Font.lhfMono` (`RedesignTokens.swift`).
It maps `.semibold` and heavier to the file `SpaceMono-Bold`. **Space Mono has
no SemiBold**, so "semibold" in the code is really Space Mono Bold.

| Where | Face | Size / tracking | Colour |
|---|---|---|---|
| Collapsed card (`AssignmentCardView.content`, line 241) | Space Mono Bold, uppercased | 9.5pt, +1.1 | the urgency ink (`smoothTaskTextAccent`: tomato, marigold, lemon, teal, cobalt or grape ink); exam cards use `smoothExamTextSecondary` |
| Opened card | the same line: the opened card is the same view with `expandedDetail` appended, not a separate header | 9.5pt, +1.1 | same |
| Draft review sheet (`AgentDraftReviewSheet.header`, line 181) | Space Mono Bold, uppercased | 10.5pt, +1.1 | `courseAccentInk(for:)`, the class's stable colour |
| "NEW" tag beside it | Space Mono Bold | 8pt, +0.8 | paper on tomato |

The other faces on those screens:

- **Assignment title:** Familjen Grotesk Medium, 20pt on the card and 24pt on the sheet (`lhfAssignmentTitle`).
- **Due value in the corner** ("Thu", "5h"): Space Mono at 18pt. The code asks for `.medium`, which maps to Space Mono **Regular**.
- **"late" / "in class" under it:** Space Mono Bold 8.5pt.
- **Caveat line** (cancelled / moved / changed / drafted by claude): Inter SemiBold 9pt (`lhfSecondary`).
- **Opened card:** the full date is Familjen 12.5pt, "from syllabus" is Inter SemiBold 9pt, and "edit date" / "open in canvas" are Familjen 12pt.
- **Sheet:** "drafted by claude" is Inter SemiBold 13pt, and the draft body is Inter 16pt.
- **Header:** the "Smooth" wordmark is Roobert SemiBold Italic (`lhfWordmark`), and the weekday is Roobert SemiBold (`lhfHeaderTitle`).
- **Screen titles and other primary text:** Satoshi Bold (`lhfSerif`), with Satoshi for the other primary interface text (`lhfSans`).

### Why it reads as "like Claude"

Anthropic does not publish its type, so the claims below come from third-party
write-ups and a foundry case study. Treat them as well-attested, not official.

- **Marketing site:** Anthropic's 2024 redesign set headlines in Styrene
  (Commercial Type) and body text in Tiempos (Klim), per the foundry case
  study at type.today. Later extractions of anthropic.com describe custom
  Anthropic Sans, Serif and Mono families. The Mono is used **uppercase, small
  and tracked, as an "eyebrow" label above a heading**.
- **The Claude app:** a serif for answers (Copernicus / Tiempos-like), a
  Styrene-style sans for the interface, and a mono for code. The accent is a
  clay orange on a warm off-white.

Our class code is that same move: a small, uppercase, widely tracked mono
label sitting above a grotesk title. It sits on a paper ground with a tomato
accent and cream surfaces (`smoothSurface` F2E5C9). Space Mono adds to it:
its uppercase is wide and geometric, close to Styrene's flat, square-shouldered
capitals, and it has a retro "terminal" voice that also recalls Claude Code.

So the likeness is the **role** (a mono eyebrow) plus the **palette**, more
than the exact letterforms. The single-storey "a" doesn't come into it, because
the code is always uppercase. That also means a different mono only softens the
read. Leaving the mono for a word face removes it.

## 2. Five alternatives, each shippable

Each candidate below has an image beside it in `docs/font-research/`. Every
image shows the collapsed card, the opened card and the code enlarged, in light
and dark. `contact-sheet.png` puts all six side by side.

Size and tracking are proposals, tuned so every candidate's cap height lands
near Space Mono's at 9.5pt.

### A. Mono, kept but quieter: IBM Plex Mono SemiBold, 9.5pt, +0.8

Image: `1-ibm-plex-mono.png`.

- **Why it fits:** it is a humanist mono with softer, narrower capitals than
  Space Mono, so it drops the retro-terminal voice while keeping the "data
  label" role. It is the smallest change.
- **Pairing:** it sits under Familjen without competing, and its real SemiBold
  weight sits between Inter's 600 and Roobert.
- **Licence and file:** SIL OFL. `IBMPlexMono-SemiBold.ttf` from
  `github.com/google/fonts/ofl/ibmplexmono`, 140 KB (one static weight).
- **Risk:** it is still an uppercase mono eyebrow, which is half of the Claude
  read. JetBrains Mono, the usual stand-in for Anthropic Mono, is a close
  cousin.

### B. Humanist grotesk: Atkinson Hyperlegible Next SemiBold, 10pt, +0.9

Image: `2-atkinson-next.png`.

- **Why it fits:** it was designed by the Braille Institute for telling
  characters apart at small sizes. That is exactly the 9 to 10pt job here, and
  it holds up best on the 26% tint. It reads friendly, not technical.
- **Pairing:** its humanist forms sit between Inter and Familjen, and it is
  clearly a different voice from Roobert's geometric title.
- **Licence and file:** SIL OFL.
  `AtkinsonHyperlegibleNext[wght].ttf` from
  `github.com/google/fonts/ofl/atkinsonhyperlegiblenext`. That is the whole
  weight range in 115 KB, and a static SemiBold would be smaller.
- **Risk:** its zero is slashed ("0151" shows a slash). That is good for
  telling 0 from O, but it is a visible quirk. Check the variable font's named
  instance (`AtkinsonHyperlegibleNext-SemiBold`) resolves in `.custom`, the
  way `FamiljenGroteskRoman-Medium` does.

### C. Condensed, from Apple: SF Pro Condensed Semibold, 11pt, +0.5

Image: `3-sf-pro-condensed.png`.

- **Why it fits:** tall, compact capitals give the code the look of a sticker
  or label rather than a terminal readout. Condensing lets it run a point
  larger at the same width, so it is the most legible at a glance.
- **Pairing:** it sits neutrally under Familjen, and its narrow, upright
  rhythm contrasts with Roobert's round title.
- **Licence and file:** Apple's system font, reached through
  `Font.system(size:weight:).width(.condensed)` (iOS 16+). There is **no file
  and 0 KB**, and Dynamic Type comes for free. Do not bundle the SF file
  itself.
- **Risk:** it is the iPhone's own face, so it is the least "Smooth-specific".
  The rest of the app does not use SF, so it must look deliberate and not like
  a fallback.

### D. Serif: Gambetta Semibold, 10.5pt, +0.7

Image: `4-gambetta.png`.

- **Why it fits:** a sturdy text serif turns the code into something like a
  catalogue or course-listing line: bookish and warm on the paper ground. It
  is the most distinct from every face in the app.
- **Pairing:** it is the only serif, so it carries contrast against
  Inter, Familjen and Roobert, and does not fight any of them.
- **Licence and file:** Fontshare (Indian Type Foundry) Free Font License, the
  same licence as Satoshi. It explicitly allows "Mobile or Desktop
  Applications". `Gambetta-Semibold.otf` comes from
  `api.fontshare.com/v2/fonts/download/gambetta` and is 44 KB. The FFL counts
  subsetting as a derivative work, so ship the file whole.
- **Risk:** the hairlines thin out at 10.5pt, most of all as light ink on the
  dark-mode tint (compare the two columns). It may need Bold. There is also
  irony here: Anthropic's answers are set in a serif too, though uppercase
  serif caps read nothing like that.

### E. Display, commercial: Roobert SemiBold, 10pt, +0.8 (Displaay)

Image: `5-roobert.png`.

- **Why it fits:** it is the face that already draws the wordmark and weekday,
  so the class code would join the header's voice. It is geometric, but
  proportional and not mono, so the "eyebrow" cue is gone. It has tabular
  figures (`zero.tf` and friends) if they are ever wanted.
- **Pairing:** title and code would share one family. Familjen still carries
  the assignment name, and Inter the small print.
- **Licence and file:** commercial. Displaay prices a single style at **55 €**,
  perpetual, sized by company headcount (minimum tier 3 people). Its app
  usage covers "any Application", with iOS and Android counting as one app
  (displaay.net/typeface/roobert, displaay.net/info/license). The file is
  already in the bundle, so it costs **0 extra bytes**. If Marco would rather
  keep a mono, Roobert Mono and Roobert Semimono exist in the same six
  weights at the same price list.
- **Risk:** see the licence note below. Using it in more places widens the
  exposure. And with the wordmark and every card in one family, the header
  loses some of its standing.

### Licence note found along the way (not about the choice)

The bundled `Resources/Roobert-SemiBold.otf` (and the italic) is **Displaay's
trial build**. Its PostScript name is `RoobertTRIAL-SemiBold`, its full name is
"Roobert TRIAL SemiBold", and `RedesignTokens.swift` asks for
`"RoobertTRIAL-SemiBold"` by name.

Displaay's licence says trial fonts are "Not for commercial or public-facing
projects" and are "Limited to non-published materials". This file has been in
App Store builds. CLAUDE.md records a personal agreement Olisa holds for
Roobert. If that agreement covers this file, nothing is wrong. If it was a
licence for the full font, the licensed (non-TRIAL) file should replace this
one, and `lhfWordmark` / `lhfHeaderTitle` would need the new PostScript name.
This is Olisa's to confirm, whatever happens with the class code.

## 3. Images

| File | What |
|---|---|
| `font-research/contact-sheet.png` | all six faces: the collapsed card plus the code at 2x, light and dark |
| `font-research/0-current-space-mono.png` | today |
| `font-research/1-ibm-plex-mono.png` | A |
| `font-research/2-atkinson-next.png` | B |
| `font-research/3-sf-pro-condensed.png` | C |
| `font-research/4-gambetta.png` | D |
| `font-research/5-roobert.png` | E |
| `font-research/render.swift` | the renderer: `swift render.swift <Resources dir> <downloaded fonts dir> <out dir>` |

Each PNG is about 130 KB, and the contact sheet is 214 KB.

## 4. My ranking

1. **C, SF Pro Condensed Semibold.** It removes the Claude read outright, costs
   nothing, has no licence question, scales with Dynamic Type, and is the most
   legible at card size. The change is one function (`lhfMono` callers that draw
   a course code would switch to a new `lhfCourseCode`).
2. **E, Roobert SemiBold.** It is the most "Smooth" of the five, because it is
   the header's own voice. It ranks second only because the bundled file is the
   trial build: settle that first.
3. **B, Atkinson Hyperlegible Next SemiBold.** It is the best pure legibility
   pick and is free. The slashed zero is its one quirk.

If the mono role matters to Marco, A (IBM Plex Mono) is the gentle fix, but it
only halves the resemblance.

**The one question for Marco:** should the class code stay a mono "data label"
(A), or become a word face like the title above it (C, E or B)? The Claude
likeness comes from the mono-eyebrow role itself, so only the second choice
removes it.

## Sources

- [Styrene in use: ANTHROP\C (type.today)](https://type.today/en/journal/anthropic): Styrene for headlines, Tiempos for body.
- [rar.design: Claude interface design](https://rar.design/posts/claude-interface-design-philosophy) and [shadcn.io: Claude design extraction](https://www.shadcn.io/design/claude/raw): third-party reads of the app's serif, sans and mono. They are unofficial.
- [webdesignhot: claude-ai design.md](https://www.webdesignhot.com/design.md/claude-ai/): Anthropic Mono as uppercase eyebrow metadata. This is a third-party extraction.
- [Displaay: Roobert](https://displaay.net/typeface/roobert) and [Displaay licence](https://displaay.net/info/license): prices, app usage and trial terms.
- `LowHangingFruitUI/Resources/Satoshi-FFL.txt`: the Fontshare Free Font License text, which allows "Mobile or Desktop Applications".
