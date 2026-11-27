# current_degree_mode_inventory

Source key (all paths relative to the repo root `/home/user/penn-dashboard`, branch `degree-progress`, read 2026-11-27). UI files live in `LowHangingFruitKit/Sources/LowHangingFruitUI/`, Kit files in `LowHangingFruitKit/Sources/LowHangingFruitKit/Degree/`, tests in `LowHangingFruitKit/Tests/LowHangingFruitKitTests/`. Abbreviations: **PV** = `DegreeProgressView.swift`, **ST** = `DegreeSemesterTable.swift` (also holds `DegreeSemesterPage`), **PL** = `DegreePlanView.swift` (also holds `DegreePlanAddSheet`), **WS** = `DegreeWhatIfSheet.swift`, **AV** = `DegreeAdvisorView.swift`, **AQ** = `DegreeAdvisorQuestionsSheet.swift`, **SI** = `PathSignInSheet.swift`, **AS** = `AppState+Degree.swift`, **ASA** = `AppState+DegreeAdvisor.swift`, **RT** = `RedesignTokens.swift`, **CL** = `CLAUDE.md`, **RM** = `ROADMAP.md`, **PR** = `docs/PRIVACY.md`, **CT** = `DegreeCopyTests.swift`. CLAUDE.md line numbers are from the checked-out file; a few quotes wrap across lines and are cited with "≈". No student data is reproduced here; example figures ("67%", "27 of 73") are the ones CLAUDE.md itself records as illustrations.

## 1. Every piece of information degree mode presents today (where, and how it is drawn)

### Takeaway
Degree mode shows three layers stacked on one screen: Penn's own audit (percent or cu, requirement blocks, rules, courses), the student's own sketch (semester table of planned courses), and the app's estimates about that sketch (cobalt "≈" figures, "+N%" badges, "fits" lines, a plan summary line, advisor questions). Almost every item is small text (10–13 pt) or a thin coloured arc/bar; the same facts recur in several places (ring, bar, table, block cards).

### Cited Findings

**Penn's facts (the audit)**
- **Per-degree progress number in the ring's centre.** Three fallbacks: "31" over caption "of 40 cu" when Penn's sentence in the DEGREE block gives credit totals; else "NN%" from Penn's `percentComplete` with no caption; else met-rule count over "of N met". Drawn in Satoshi Bold 22 with a Space Mono 10 caption inside a 96 pt ring (80 pt in the "both" view), 9 pt stroke, teal arc with round cap. — PV:76-99, PV:898-972, PV:532-534
- On the owner's phone the ring has read as a percent ("53%", "67%"), not cu, because the credit sentence was not found in his DEGREE block. — CL:7088 onward (Known gaps: "The ring read '53%' rather than 'x of y cu' on both audits")
- **Program headline beside the ring** (single-degree view): the degree's title from goals, lowercase, Satoshi 17 semibold ("computer science, bse"); never the catalog term. — PV:444-451, PV:778-782
- **Requirement block cards** ("major in …", "general electives", …; the DEGREE block is retitled "everything else" and placed last): title (Satoshi 15 semibold), right-hand count in Space Mono 12 ("3 of 4 cu", "10 of 23", or "NN%"), chevron, and a 6 pt segmented bar (teal met, marigold in progress, cobalt planned, rule-grey track). White card, 16 pt continuous corner radius, 1 pt rule stroke, 16 pt padding. Empty synthetic blocks are skipped. — PV:101-108, PV:121-132, PV:181-196, PV:976-1050
- **Rules inside an expanded block**: label (lowercase, Satoshi 14 medium), optional "n of N" count (Space Mono 11), a status word in Space Mono 11 semibold: "met" (teal ink), "in progress" (marigold ink), "open" (muted). Children indent 12 pt per depth. `.info` rules with nothing under them are drawn as quiet 12 pt muted notes. — PV:1054-1123, PV:110-118
- **Course chips inside a rule**: taken/registered courses as capsule chips in the class's own accent colour (code in Space Mono 11; "· now" suffix while in progress); Penn's still-open options as dashed-outline muted "ghost" chips (max 6 shown per rule); planned courses as cobalt-tinted chips. Chips wrap (flow layout), never scroll. — PV:1125-1207, PV:1211-1245
- **Legend** under the ring(s): 8 pt dots + 12 pt words "done", "in progress", ["planned"], ["if approved"], "left". "planned" shows only while something is planned; "if approved" only while a ring draws a best case. — PV:862-891
- **"both degrees" bar** (dual-degree only): label "both degrees", count "27 of 73" or "27 of 73 · 9 planned" (Penn's rule counts summed across audits), same segmented bar. — PV:564-584
- **Semesters and courses by term** (semester table): past columns (fixed chips), the current one (chips + "· now"; a teal "now" tag on the header in full view), future ones (registered chips + "· registered", then planned rows). Column header = term label ("spring 2027", Satoshi 14 semibold) + total cu (Space Mono 12). Strip columns are 168 pt wide, cards with 16 pt radius. — ST:1-37, ST:111, ST:312-376, ST:400-432
- **Status words** (one muted 13 pt line under the title "degree"): "reading path@penn…", "approve the duo push on this phone", "sign in to canvas", "tap to sign in to path@penn", "finish signing in", a failure message ("couldn't read path@penn · retry"), "read today" / "read yesterday" / "read nov 7". — AS:36-87, PV:315-349
- **Footer link** on every tab: "path@penn's reading · official audit ↗" in teal ink, 13 pt. — PV:849-855
- **Profile row** (entry point): "degree" with a graduation-cap icon and, right-aligned in Space Mono 12, the same text the ring carries ("31 of 40 cu" / "NN%") or the status line. — `ProfileClassesSection.swift`:118-132, PV:198-204

**The student's sketch (the plan)**
- **Planned course rows** in future columns: class-coloured chip (muted grey when it counts nowhere), optional "+N%" badge (Space Mono 10 semibold, cobalt ink; hidden under half a point), an xmark remove button (28 pt hit area), then up to two 11 pt muted lines: either the planner's own "counts toward" labels, or "fits · <degree> · <requirement>", or "your pick · <requirement>", or "not on an open requirement". A small grape tag "ask advisor" (petition) or "check" sits on its own line when the course needs approval. — ST:434-541, ST:76-93, PV:51-55
- **Over-limit load**: a future column's cu figure turns tomato ink when above 6.5 cu (fall/spring) or 4 cu (summer); VoiceOver value "over the limit". No other warning. — ST:95-99, ST:369-374, `DegreeTimeline.swift`:126-141
- **Plan tab summary** (plan tab only): "N cu planned · X of Y open requirements have a planned course", 13 pt muted. — PL:36-63

**The app's estimates about the plan**
- **Planned arc and "≈" line(s)** under each ring: a cobalt arc after the teal arc; text in Space Mono 10 semibold cobalt ink. Without target data: "≈ NN% with plan". With a named finish term: "≈ 92% by spring 2028" and, only when the best case is at least half a point higher, a second line "≈ 100% if approved" with a matching arc in cobalt at 0.35 opacity. — PV:153-178, PV:496-512, PV:764-768, PV:931-942, `DegreePlanCoverage.swift`:143-170
- **Plan summary line** above every semester table when the plan is exactly what the planner wrote: "plan · would finish spring 2028 · 19 cu to go · needs approval" (or "no finish semester"), 12 pt muted. Dropped by any hand edit. — `DegreePlan.swift`:140-146, 216-233; ST:120-125
- **Advisor-questions row** under the summary line: grape 12 pt semibold "ask your advisor · N" (N = questions still open), or "advisor answers · update plan", or "advisor answers". — ST:143-165, AQ:27-33
- **Block and rule planned counts**: "· n planned" appended to Penn's count; rule count turns cobalt ink when anything is planned. — PV:134-151, PV:1104-1108
- **Add-sheet suggestion rows** ("counts toward your degree"): course code (mono 12), lowercase title, cu, "+N%" capsule badge (filled cobalt when the course counts toward two degrees, tinted otherwise), and up to two 11 pt lines "<degree> · <requirement>"; grouped "both degrees" first, then per degree. — PL:250-322, CL:1261-1291, CL≈1563-1568
- **Chat plan card** (inside "plan with ai"): one row per scenario ("6.5 cu · summer → spring 2028", chosen one bold, teal checkmark if it meets the target; best case reads "6.5 cu · 4 cu summers · approvals → …"), a totals line "21.5 cu left · 28 without double counting", up to 4 "not planned: <requirement> · <reason>" lines, up to 3 "ask your advisor: <course> for <slots>" lines. — AV:21-37, AV:83-125, AV:336-372
- **Chat change card**: "added CIS 4710, CIS 4010 · fall 2027" / "moved … · a → b" / "removed …", with "undo" (grape) on the latest, "undone" after. — `DegreeAdvisor.swift`:923-944, AV:404-431
- **Chat notices and stages**: "read path@penn's audit for finance", "using path@penn's audit for finance from today", "planning…", "still working…", "filling what's left…", "reading path@penn for <program>…". — ASA:151-229, ASA:287, ASA:377-393
- **Advisor email draft**: a collapsed "advisor email" disclosure with "copy". — AV:374-393

**What-if information**
- **What-if result**: the same ring + block list as progress, with a grape "what if" capsule tag under the ring, a grape continuation arc for in-progress work, a headline ("switch to economics, ba" / "+ math minor") and a summary line "N met · N in progress · N open · N of your courses count". — PV:588-613, PV:739-741, PV:752-776, PV:943-948; `DegreeWhatIf.swift`:49-81
- **Recent what-ifs** as grape-selected capsule chips (up to eight kept). — PV:714-737, AS:95-96
- **Option scores**: sibling programs already tried (heading "concentrations" for Wharton, "majors" otherwise) as chips with their ring percent: "finance · 58%". The same percent replaces the program code at the right of a row in the search sheet. — PV:615-690, WS:266-287, `DegreeOptions.swift`:112-115
- **Search rows**: program name, a 6 pt kind dot (grape concentration, cobalt major, teal minor, grey other) and an action line ("concentration · wharton", "major · instead of computer science", "minor", "program · <code>"); sections "concentrations / majors / minors / other programs", plus "related" (with a sparkle when it came from the on-device model) and "no match". — WS:176-264, `DegreeProgramSearch.swift`:638-656

**Advisor questions**
- Each question is a white card (14 pt radius): the sentence to ask (15 pt), an optional detail line saying what a yes changes (12 pt muted), and "yes" (teal fill when chosen) / "no" (tomato 30% fill when chosen) capsules. Unanswered first. Kinds: doubleCount, placement, load. At most 12 questions kept. — AQ:35-40, AQ:99-146; `DegreeAdvisorQuestions.swift`:21-36, 90-94

### Inferences
- The essentials a redesign must still carry, in priority order as the code weights them: (a) Penn's number per degree, (b) what is left (open requirements), (c) what the student is taking now, (d) the plan's finish term and "cu to go", (e) the two cases by target term (granted vs if approved), (f) the advisor's open questions, (g) per-course "does it count, toward what".
- Units are mixed on one screen: percent (ring), cu (ring alternative, columns, summary), rule counts ("27 of 73"), course counts ("9 planned"), percentage points ("+2%").
- The same state has three vocabularies: legend "done / in progress / left", rule words "met / in progress / open", and block counts "n of N".

### Gaps
- No screenshot of the current build is in the repo for this inventory; everything above is read from source, not from a running device.
- CLAUDE.md says "+ semester" goes "up to ten" (CL≈1146); the code's cap is `maxTerms = 14` (`DegreePlan.swift`:285). The code wins; the doc line appears stale.

## 2. Every task the student can do

### Takeaway
There are roughly twenty distinct actions, spread over three tabs, five sheets/covers and one floating button; most planning actions live in the semester table, which is repeated in all three tabs.

### Cited Findings
- **Open degree mode**: Profile → classes → "degree" row (Penn installs only; preview/demo show sample data). — `ProfileClassesSection.swift`:118-132; CL:1062-1068
- **Switch tab**: segmented "progress · what if · plan". — PV:6-19, PV:235
- **Switch degree** (dual-degree only): capsule chips "both" + one per degree; tapping a ring in "both" also opens that degree. — PV:368-418, PV:522-525
- **View both degrees**: the "both" chip. — PV:403-418, PV:460-494
- **Expand / collapse a requirement block**: tap the card. — PV:803-815, PV:984-996
- **Pull to refresh** (forces a Path@Penn read): on the screen's scroll view. — PV:249
- **Retry / sign in by tapping the status line** (only on failure or "tap to sign in to path@penn"); "read path@penn" button on the empty state. — PV:327-349, PV:427-442
- **Finish sign-in by hand** in `PathSignInSheet` ("finish signing in", xmark cancels; cannot be swiped away). — SI:17-53
- **Try a what-if**: tap the search pill "search concentrations, majors, minors" → sheet; a sibling row runs in one tap, any other row opens buttons "switch to <name>" / "add major" / "add minor" / "add concentration". — PV:692-712, WS:231-264, WS:313-360, WS:414-445
- **Search programs** with typed words, scope chips "all · concentrations · majors · minors", clear button, "retry" when the list fails to load. — WS:103-174, WS:289-311
- **Re-open a tried option or recent what-if**: option chips and what-if chips. — PV:646-690, PV:714-737
- **Add a planned course**: "+ course" in a future column → add sheet: type a code, set credits with a stepper (0.5–4), "add"; or tap a suggestion. Max 8 courses per term. — ST:543-552, PL:180-218, PL:287-328; `DegreePlan.swift`:285-286
- **Remove a planned course**: xmark on its row. — ST:471-479
- **Move a planned course**: drag its chip onto another future column (appends) or onto a planned row (inserts before). Past/current columns accept nothing. — ST:18-23, ST:294-310, ST:463, ST:523-525, ST:576-581
- **Add a semester**: dashed "+ semester" cell; **remove** an empty last semester ("remove" in its header). — ST:336-367, ST:554-569
- **Open full view**: "full view" button above the strip → `DegreeSemesterPage` ("semesters", xmark), all semesters in rows on one page with the same edit actions. — ST:169-198, ST:599-643
- **Ask the AI**: floating grape sparkle button (bottom-right, 52 pt) → "plan with ai" chat; three starter questions; free text "ask about your degree"; send. — PV:250-263, AV:63-73, AV:254-274, AV:435-465
- **Undo the AI's latest edit**: "undo" on the change card. — AV:415-421, AV:510-515
- **Try again** after a failed answer; **copy** the drafted advisor email. — AV:306-313, AV:374-393
- **Answer advisor questions**: "ask your advisor · N" row (table) or link under the chat's plan card → sheet; tap yes / no (tap again to clear). — ST:149-165, AV:316-324, AQ:126-146
- **Copy the open questions** as a numbered list: toolbar "copy". — AQ:87-92; CL≈1620-1626
- **Update plan** with the answers: grape "update plan" bar appears once an answer changed; sends the fixed prompt "update my plan with my advisor's answers" through the chat. — AQ:19-20, AQ:59-78, PV:275-285
- **Open Penn's official audit** in the browser: footer link. — PV:849-855

### Inferences
- Three of the tasks are only discoverable by small muted text: retry/sign-in (the status line), remove-semester ("remove", 11 pt) and drag-to-move (no affordance at all).
- "Plan" as a tab adds only one summary sentence over a table the other two tabs already show (PL:29-34), so the tab count could shrink without losing a task.

### Gaps
- Drag-and-drop inside the sideways strip has not been confirmed on a device (CL Known gaps ≈7170-7180: "whether drag works inside the sideways scroll on a real touch screen").

## 3. Screen structure today

### Takeaway
One pushed page with a title, a status line, a three-way segmented switch and a scrolling body, plus six modal presentations. The semester table is hosted in all three tabs. On the "both" view with a plan, a student meets on the order of 25–30 separate labels/numbers before reaching the table, and roughly 90 or more before the footer (estimate from code).

### Cited Findings
- **Page frame, top to bottom**: title "degree" (Satoshi Bold 32) → status line → segmented picker → scroll body (tab content + footer link) → floating sparkle button overlay. — PV:232-264, PV:315-325
- **progress tab, single degree**: [degree chips if >1 degree] → ring (+ "≈" lines) beside headline → legend → semester table (summary line, advisor row, "full view", strip) → block cards → footer. — PV:353-366, PV:745-800
- **progress tab, "both"**: chips → two 80 pt rings side by side, each with degree label and "≈" lines → legend → "both degrees" bar → semester table → for each degree: its name as a header + its block cards → footer. — PV:460-494, PV:514-562
- **what if tab**: search pill → tried-options row (heading + chips) → what-if chips (with a second search pill at the end) → ring with "what if" tag + headline + summary → legend → semester table → block cards → footer. With no what-if yet: search pill, options row, table. — PV:588-613
- **plan tab**: summary sentence → semester table → footer. — PL:29-34
- **Sheets and covers**: (1) what-if search sheet, (2) "plan with ai" chat sheet, (3) add-course sheet (medium/large detents) presented from each table, (4) advisor-questions sheet presented from each table and from the chat, (5) full-view cover "semesters", (6) Path@Penn sign-in sheet attached separately to the screen, the chat and the what-if sheet because "a sheet cannot present over another presenter's sheet". — PV:293-310, ST:135-138, ST:158-164, ST:185-197, AV:169-174, SI:88-116
- **Semester strip**: horizontal scroll of 168 pt cards with 10 pt gaps, opens scrolled to the current semester; full view tries the fewest columns first and adds columns until the page fits, cells never under 112 pt. — ST:111, ST:273-292, ST:202-226; `DegreeTimeline.swift`:143-145
- **Closing the chat after it read a what-if jumps the screen to the what-if tab.** — PV:297-304
- **Count of what a student sees on "both" with a planner-made plan (estimate from the view code, not a device)**: title + status (2); tab labels (3); chips (3); per ring: centre number, optional caption, degree label, up to two "≈" lines (3–5 each, so 6–10); legend words (up to 5); bar label + "n of N · k planned" (2 labels, 3 numbers); summary line (1 line, 4 parts: "plan", finish term, cu to go, "needs approval"); advisor row (1); "full view" (1). That is about 25–30 text items above the table. Each visible future column then adds a term label, a cu figure, and per course a code chip, a "+N%" badge, an xmark and up to two "fits" lines; with about two columns visible at 168 pt and five or six courses each, roughly 40–50 more. Below: 2 degree headers and (per the first real audit, six blocks per degree) about 12 cards × (title + count) ≈ 26 more, then the footer. Distinct coloured marks on the first screenful: teal, cobalt, faded cobalt and track arcs on two rings, three bar segments, five legend dots, plus per-class chip colours. — PV:460-584, ST:115-139, ST:312-376, ST:440-521; block count from CL≈7095 ("major, general electives, SEAS writing, free electives, elective coursework, everything else")

### Inferences
- A phone 402 pt wide with 20 pt side padding shows a little over two 168 pt columns, so a full degree (8–10 semesters) is never visible in the strip; the owner's "full view" request was the response to that (see section 6).
- Requirements ("what is left") sit below the table in every view; in "both" the first requirement card is several screens down.

### Gaps
- The exact number of items on the owner's phone depends on his audit and plan, which are not in the repo; the counts above are structural estimates.

## 4. Hard rules already decided that a redesign must keep

### Takeaway
The rules are of four kinds: honesty about whose number is whose (Penn's vs the app's "≈"), a short list of forbidden words and required strings enforced by source-scanning tests, the "least text that works" lowercase copy rule, and privacy limits on what leaves the phone. Several were stated or approved by the owner in his own words.

### Cited Findings
- **Penn's number is never changed by the plan.** "**Penn's number in the middle of the ring never changes, and nothing planned is called met.**" — CL:1249-1250. Code comments say the same: "It is this app's estimate, not Penn's, which is why it carries "≈" and its own colour and never replaces the number in the middle of the ring." — PV:153-159; "Penn's number in the middle never changes." — `DegreePlanCoverage.swift`:143-148; CL≈1662
- **Planned work has its own word and colour, never "met".** "The screen draws the result as its own cobalt layer under its own word, "planned"" — CL≈1244-1246. The plan view's doc comment: "The screen never says a requirement is satisfied by a plan" — PL:8-10. The word under a course is ""fits", never "satisfies"" — CL:1154. The chat prompt says a planned course ""would count toward" a requirement, never that it is met" — CL:1326. The summary line says "would finish … It says "would", because whether anything counts is Penn's word" — `DegreePlan.swift`:216-220.
- **No combined percent across two degrees.** "**There is no combined percent, on purpose**: Penn publishes one audit per degree, and a figure made from two would be this app's opinion shown as Penn's; a test keeps the word "average" out of the screen." — CL:1216-1219; test: `#expect(!progress.lowercased().contains("average"))` — CT:108-116. The combined element allowed is the summed rule-count bar ("both degrees · x of y"). — CL≈1208-1210
- **"≈" on every app estimate**: "The percent is this app's estimate, which is why it carries "≈"" — CL≈1250-1252; strings "≈ NN% with plan", "≈ NN% by <term>", "≈ NN% if approved" — PV:156-178.
- **Only a granted plan is drawn; the best case is listed, not drawn into the table.** Section title "A plan nobody granted is not drawn; the advisor is asked" — CL:1575; "`best` is chosen only when the student asks … otherwise the first scenario that leans on nothing ungranted" — CL≈1602-1608; trap: "A planner's output is what the student will try to register for: draw only what is granted, list the rest as questions for the advisor, and let the answers come back as facts." — CL (Traps, ""Best case" written into the student's table read as the plan"). The best case may appear on the ring as a faded arc with "if approved" (owner's request, section 6). — CL:1638-1664
- **Words the degree views must never contain** (lowercased substring scan of PV, WS, PL, ST, AV): "graduate", "on track", "eligible" — CT:22-30. Note this is a substring test: a code comment containing "undergraduate" failed it once. — CL (Test baseline, run 42653623893)
- **Other forbidden strings**: "recommend" anywhere in PV and AV — CT:172, CT:227; the literal `"recommended` in the table and add sheet — CT:205-214 ("the screen never says "recommended" (a test holds that)" — CL:1287); "counts in both" in PV — CT:114; `catalogYearLabel` in PV (no catalog term beside the ring) — CT:32-36.
- **Strings the tests require to exist today**: legend words "done", "in progress", "left" — CT:38-45; footer "path@penn's reading · official audit ↗" with `PathPage.officialAuditURL` — CT:47-52; plan phrases "+ course", "+ semester", "fits · ", "counts toward your degree" — CT:88-96; "full view" and "semesters" — CT:98-106; "both" / accessibility "both degrees" — CT:108-112; "planned" and "with plan" — CT:163-172; "not on an open requirement" — CT:205-209; chat title "plan with ai" and the sentence "sends your audit and plan to smooth's server to answer. nothing is stored." — CT:217-221.
- **Lowercase copy**: "no capitalised literal in a visible string" (regex over Text/Button/Link/TextField/Label literals) — CT:54-62. Status sentences come only from `DegreeStatus.line`, never from the view — CT:64-71, AS:48.
- **Copy rule**: "**Copy rule (2026-10-10, Marco): the least text that works.** No explanatory sentences, no captions restating a control, no raw system errors, no developer diagnostics on a normal screen." — CL:2413-2416. The view's own comment: "Copy is the status words … and a handful of fixed lowercase labels, never a sentence, and never a verdict" — PV:207-213.
- **The audit is Penn's; the screen only draws it and always links the official audit.** "Code decides nothing here: the audit is Penn's and the screen only draws it." — CL (Degree → status words, ≈1770); "It is Penn's reading, shown Smooth's way. Smooth does not decide what counts; Penn's audit does … the screen always links to Path@Penn." — PR:229-231
- **Every suggested course is one Penn lists for an open requirement; typed codes are still allowed.** — PL:81-87; CL:1283-1287
- **AI edits apply at once with undo; no confirmation step.** "The wrong fix would be a confirmation step on every edit, which undoes the ask that it add courses for you." — AV:39-48
- **Privacy limits** (must change `docs/PRIVACY.md` in the same commit as any behaviour change — CL top section): grades and GPA are never read; the sign-in token, Penn's id, name and pronoun never leave Penn's page — PR:174-178; the audit stays on the phone, nothing to laptop, iCloud or "the tree" — PR:179-182; the only path to the server is a "plan with ai" message, sent only when the student sends it, stored by nobody, "and the chat says so before your first one" — PR:183-201; program search runs on the phone, the on-device model only supplies subject names checked against Penn's list — PR:224-228, WS:11-16; advisor answers are kept on the phone and travel only inside the next planning message — PR:216-223; the plan is the student's own file and is sent nowhere on its own — PR:232-238.
- **No real names in owner-visible labels the app invents** is not a rule, but two presentation decisions are: no six-digit catalog code beside the ring ("tacky") and degrees named by code ("computer science, bse") with chips showing the major alone. — PV:447-450; CL≈7110-7118

### Inferences
- The copy tests scan five named source files for literal strings. A redesign that renames files or changes strings ("full view", "+ course", the legend words) will fail those tests until they are deliberately re-pinned; the forbidden-word and privacy rules are the substantive ones, the required-string pins are records of the current design.
- "Never a verdict" plus the three banned words means a redesign cannot use phrases like "on track to graduate"; a Duolingo-style encouragement line would need wording that states a fact ("3 left") and not a judgement.
- The one sanctioned place for a two-case picture is the ring-level figure (granted solid, best faded); the table itself must hold only the granted schedule.

### Gaps
- The build spec the copy tests cite (`docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md`) was not read for this note; rules above come from CLAUDE.md, the tests, PRIVACY.md and code comments.
- Whether the owner would relax "no combined percent" for a simpler dual-degree summary is not recorded anywhere; it is stated as deliberate.

## 5. Visual language

### Takeaway
Degree mode uses the app's Smooth palette with fixed meanings: teal = done/met (Penn), marigold = in progress, cobalt = planned (the app's estimate; faded cobalt = if approved), grape = AI / advisor / what-if, tomato = over the limit (and "no"), rule-grey = left. Type is Satoshi for titles and labels and Space Mono for numbers and codes; shapes are capsule chips and white cards with 12–16 pt continuous corners on a white "paper" ground.

### Cited Findings
- **Palette values**: paper `#FFFFFF` (dark `#0B1020`), surface `#F2E5C9`, rule `#D9C9A6`, ink `#1B1714`, muted `#7C7060`; tomato `#F07256`, marigold `#F7A844`, lemon `#F5D353`, teal `#40B3A5`, cobalt `#699AE7`, grape `#AF85F0`; each accent has a darker "…Ink" partner for text (e.g. teal ink `#176D65`, cobalt ink `#345EA8`, grape ink `#7044A6`, tomato ink `#B63B23`, marigold ink `#985700`). Card `#FFFFFF` (dark `#151B2D`), ring track `#D9C9A6` (dark `#27304B`). — RT:37-61, RT:64, RT:87
- **Design description**: "a white paper ground with tomato/marigold/lemon/teal/cobalt/grape accents, an "after sunset" dark mode" — CL:260-262
- **Meanings in degree mode**: teal arc/segment and "met" word, selected degree chip (teal 22% fill, teal ink), "+ course", footer link, "now" tag, "yes" answer, drop-target outline — PV:391, PV:949-951, PV:1042, PV:1070, ST:332, ST:354-357, ST:547, AQ:111-112; marigold in-progress segment and word — PV:1040, PV:1071; cobalt planned arc, segment, chips, "≈" lines, "+N%" badges — PV:553, PV:937-941, PV:1037, PV:1195-1205, ST:464-468; cobalt at 0.35 = "if approved" — PV:875, PV:934; grape = what-if tag and chips, AI button, chat bubble (28% fill), send button, advisor row, "ask advisor"/"check" tags, "update plan", "undo", "try again" — PV:257, PV:683, PV:769-775, ST:153, ST:486-489, AV:286, AV:457, AQ:70; tomato ink = over-limit cu, tomato 30% = "no" answer — ST:372, AQ:113-114.
- **Class identity colours**: course chips take one of the six accents by a stable hash of the course code (28% fill, ink partner for text), so a chip's colour means "this class", not a state. — RT:529-564, PV:1161-1173, ST:380-394
- **Fonts**: `lhfSerif` is Satoshi Bold (titles: "degree" 32, sheet titles 28, ring centre 22); `lhfSans` is Satoshi (Inter fallback) for labels 10–17 pt; `lhfMono` is Space Mono for numbers, counts, codes, "≈" lines (10–12 pt). — RT:305-311, RT:330-348, RT:403-410; PV:318, PV:955, ST:624
- **Shapes**: capsule chips (9×4 pt padding for course chips; 12×7 for selector chips, 1 pt rule outline when unselected, tinted fill when selected); cards = rounded rectangle 16 pt continuous radius with 1 pt rule stroke (block cards, semester cards), 14 pt (question cards), 12 pt (chat cards); dashed outlines for "ghost" options and "+ semester"; search and text fields are capsules with a translucent surface fill; primary sheet action is a 48 pt-tall 15 pt-radius grape bar. — PV:389-392, PV:997-999, PV:1186-1188, ST:329-333, ST:561-564, AQ:66-71, AQ:119-123, AV:367-371, PV:704-707
- **Motion**: spring animations on ring fractions, bar planned share, block expansion and what-if chip selection (response 0.3–0.5, damping 0.85). — PV:720, PV:808, PV:967-968, PV:1047
- **Shared controls**: tabs use `SmoothSegmentPicker`, the same capsule switch the dashboard's "todo · all · prev" uses. — PV:235; `DashboardControls.swift`:21; CL (Dashboard → control row)
- **Accessibility already present**: combined legend, ring label including the "≈" lines, chip labels ("CIS 1200, planned", ", could count", ", in progress"), column value "over the limit", selected traits on chips. — PV:880, PV:922-926, PV:1171, PV:1189, PV:1205, ST:373-374

### Inferences
- The accent set is doing double duty: state (teal/marigold/cobalt/grape/tomato) and class identity (the same six hues on chips). A course chip can be teal or cobalt by hash while sitting next to a teal "done" arc or cobalt "planned" badge; in a redesign that leans harder on colour-as-state, class colours on course chips would compete with it.
- Lemon is the one accent with no meaning in degree mode today (it appears only via class-colour hashing).

### Gaps
- Dark-mode appearance of the degree screens is unverified on a device (Known gaps: "the faded arc readable against the track in light and dark" — CL:6583 onward).

## 6. The owner's own words over time

### Takeaway
Olisa (the owner driving degree mode; a dual-degree student) has asked, in order, for: a simple progress picture and hypotheticals; a semester table everywhere that fits on one page; one view of both degrees; progress visibly rising as he plans; guidance on which courses count; an AI that fills the plan for him; a plan the visuals actually reflect; awareness of his advisor; best and worst case in one ring; fewer sign-in chores. His complaints are about clutter that tells him what he already knows, visuals that do not match the plan, and tasks he cannot act on. The newest brief asks for the simplest, most intuitive presentation, citing Duolingo.

### Cited Findings (dated, quoted from CLAUDE.md unless noted)
- 2026-11-09/10, the founding ask: ""see your degree progress, see what would hypothetically be your course of action if you switched degrees", no course recommendations" — CL:1062-1064
- 2026-11-10, on the catalog code beside the ring: he "called it tacky"; and "he asked what orange against green meant" (which produced the three-word legend). — PV:447-450, PV:858-861; CL:7114-7118
- 2026-11-10: ""a table feature where you can build a sample course load for the next semester or rest of your time at Penn"" — CL:1143-1145
- 2026-11-11: ""a table in every tab with each potential semester and classes you take. and you be able to drag and switch classes around"" — CL:1164-1166
- 2026-11-12: ""fit the entire class table on one page maybe with multiple rows. there should be a button"" — CL:1191-1192
- 2026-11-12: ""It should not need to re-read as often as it does. classes selected do not change every couple of minutes"" — CL:1667-1668
- 2026-11-12 (dual degree): ""There should be a way for me to see my overall progress as a dual degree and plan towards that"" — CL:1203-1205
- 2026-11-12, on the 27-chip "counts in both" row: ""I don't think the counts in both section in necessary either"" (it listed classes "he already knew he had taken") — CL:1211-1215
- 2026-11-12 (undeclared in Wharton): ""the hypotheticals should factor in the fact that I have to pick a concentration … and allow me to look at different possibilities"" — CL:1087-1089
- 2026-11-12: ""It should show the progress towards my degree going up as I pick potential new classes as I try to fill the rest of my calendar table"" — CL:1234-1236
- 2026-11-12: switching the feature off on `v12`: ""remove the degree progress thing temporarily because I don't think it is ready"" — CL:1045-1047
- 2026-11-13: ""I should be able to search the concentration I want to add within search instead of swiping left with so many options. There should be a way to distinguish within search adding/switching concentrations vs switching majors. Incorporate AI to make this as smooth as possible"" — CL:1103-1107
- 2026-11-13: ""When you are adding courses to your plan it should guide you and only recommend courses that contribute to your degree. classes that contribute to a higher percentage of completion to your degrees should be highlighted differently compared to classes that don't"" — CL:1261-1265 (this reversed the original "no recommendations" rule: CL:1266-1268)
- 2026-11-14: ""The recommender seems to be only recommending courses for cis even though I have two degrees. Additionally I want to use a better model for these recommendations and don't mind saving user degree data to the server. I currently don't see where the AI aspect comes in. There should be a chatbot to ask questions and have it add courses for you"" — CL:1293-1298
- 2026-11-14, after the first AI answer placed two courses: ""It should be able to do this."" — CL:1336; 2026-11-15, after the second: ""Still not working."" — CL:1365
- 2026-11-27, after his first drawn plan: ""Still visually does not reflect completion after implementing its own plan. I am approved for 6.5 cu semesters. Do you think the plan itself makes sense?"", then ""identify why the app made all the mistakes you pointed out and fix them"", then ""the smooth app should also be cognizant of the fact that you have an advisor and give you questions to ask them and then give the user an easy way of inputting their advisors answers back into the app"" — CL:1577-1583
- 2026-11-27, on rings reading 84% and 73% under a plan that filled everything: ""Still not 100 percent on either"", then ""maybe there can be a best case and worst case depending on approvals in the same ring"" — CL:1638-1645 (quotes wrap within that paragraph)
- 2026-11-26, sign-in: ""that duo push going unanswered thing shouldn't happen"", ""I want to have to enter my own password and manually deal with duo as little as possible"" — CL≈1677-1681; 2026-11-27: ""when it says approve duo push on the phone theres nothing I can really do"" — CL:1702-1703
- Related taste signals from the co-owner (Marco), whose copy rule governs the whole app: "the least text that works" (2026-10-10) — CL:2413; "remove all of the little bullshit text" (2026-11-11) — CL:1796; "a lot of needless text in the submission" — CL:2650. An in-code note records the owner's complaint about "seventeen chips in a sideways row". — PV:615-621
- The roadmap's own summary of the arc: he "asked to see his progress as a dual degree and plan toward it", "asked for the progress to go up as he plans classes, and for the "counts in both" row to go", and "asked for the add sheet to guide him … which reverses the "no recommendations" rule this feature started under". — RM:87-107

### Inferences
- What he values, read across the quotes: (1) one glance that answers "how far am I, in each degree"; (2) the picture must move when he acts (plan a class → progress rises; plan everything → it reads complete); (3) the whole path visible at once ("entire class table on one page"); (4) the app does the work (AI fills the plan, search instead of swiping, as little sign-in as possible); (5) nothing on screen that he already knows or cannot act on (27 chips, catalog code, a Duo line with no push).
- Every one of his additions was layered onto the original ring-and-cards screen rather than replacing anything, which is how the current density accumulated.
- He accepts the app's own estimates beside Penn's number as long as they are visibly distinct; he asked for the two-case ring himself.

### Gaps
- The latest request quoted in the assignment ("the most simple intuitive way of displaying this information … take inspiration from duolingo") does not appear in CLAUDE.md, ROADMAP.md or `docs/` (grep for "duolingo", "most simple", "intuitive way" found nothing on 2026-11-27); it is known only from the task brief and has no recorded date in the repo.
- No recorded reaction from the owner to: the full view, drag-to-move, the guided add sheet's ranking, the advisor-questions sheet or the two-case ring on a device (CL Known gaps, lines 6568-6640 and 7088 onward, list these as unreported).

## 7. Pain points and density problems in the current design (observations from the code)

### Takeaway
The screen is a stack of five feature layers added over three weeks, each with its own vocabulary, colour and unit, expressed mostly in 10–13 pt text. The same table is shown in three tabs, six modal presentations hang off it, and the "what is left" answer sits below a sideways-scrolling table. The notes file itself already records several known disagreements between what different parts of the screen say.

### Cited Findings
- **Many layers on one ring**: a ring can carry a teal arc, a grape in-progress arc (what-if), a cobalt planned arc, a faded-cobalt best-case arc and the track, with a number, a caption and up to two 10 pt mono lines beneath, plus a "what if" tag. — PV:898-972, PV:757-777
- **Small type everywhere**: the "≈" lines and "+N%" badges are Space Mono 10; course codes and rule counts 11; "fits" lines 11; summary line, advisor row, legend and "full view" 12; status line and chips 13. The largest body text on the page is 15–17 pt (block titles, headline). — PV:552, PV:766, PV:887, PV:1106, PV:1166; ST:122, ST:152, ST:176, ST:385, ST:466, ST:495
- **The table is in all three tabs** and the plan tab adds one sentence to it. — ST:4-16, PL:29-34, PV:481, PV:595, PV:793-797
- **Up to four horizontal scrollers on one tab** (what-if): tried-options chips, what-if chips, the semester strip, and in the sheet the scope chips; the progress tab has degree chips and the strip. — PV:375, PV:635, PV:715, ST:275, WS:146
- **Six modal presentations** and presenter workarounds: each table instance presents its own add sheet and advisor sheet; the sign-in sheet is attached in three places; "update plan" from the full view must close the cover, wait half a second, then open the chat. — ST:143-165, PV:275-285, PV:308-310, SI:88-97
- **Mixed units and vocabularies** (see section 1): percent, cu, rule counts, course counts and percentage points; "done/left" vs "met/open"; "planned" vs "with plan" vs "by spring 2028" vs "if approved" vs "needs approval" vs "ask advisor" vs "check". — PV:869-877, PV:1060-1066, PV:156-178; `DegreePlan.swift`:221-233; ST:535-541
- **"What is left" is far down**: block cards come after the ring, legend, (bar,) and the whole table; in "both" they are repeated per degree with collapsed cards showing only a title, a count and a 6 pt bar. — PV:475-492, PV:1002-1022
- **Opaque labels**: the DEGREE block is titled "everything else"; Penn's rule labels are shown verbatim in lowercase; the second degree's chip was Penn's own description of the major and "runs off the edge" ("wharton ung prgm - undeclared"). — PV:194-196, PV:1099; CL≈7150-7156
- **Colour collisions**: class-hash colours on course chips use the same hues as the state colours (section 5). — RT:529-564
- **Known disagreements recorded in the notes**: the single-degree tab does not take the planner's coverage for a degree planned against a what-if, so "it will read lower than "both", which may look like a disagreement"; "the "· n planned" count on the bars still counts placed courses and chips, so it can sit beside a whole bar"; "the percent text can read 100 while the arc stops short of the in-progress share, by design". — CL:6583-6597, CL:6568-6582
- **Known confusing navigation**: "closing the chat still lands on the what-if tab under "switch to management, bs", which read as confusing in the recording and is not changed". — CL:6568-6582; PV:297-304
- **Floating button overlap**: "the sparkle button floats over the bottom of every tab". — CL (Known gaps, Plan with AI limits ≈7215)
- **Courses that count nowhere read as a verdict**: a free elective whose requirement Penn describes in words shows greyed with "not on an open requirement", which "would then read as a wrong verdict". — CL≈7200-7206; ST:514-519
- **Ties in the guidance**: on his phone five planned classes all read "+2%" ("as feared, they tie"). — CL≈7190-7196
- **Sign-in is a status word**: the only affordances for a stalled or needed sign-in are a 13 pt muted line that is sometimes tappable and a sheet that appears after 6–10 s. — PV:327-349; CL≈1700-1725
- **Hidden gestures**: drag-to-move has no visible handle; the last empty semester's "remove" is 11 pt muted text. — ST:361-366, ST:463

### Inferences
- Rough complexity tally for a writer: 3 tabs, 6 modals, 5 chip rows, 5 colours with state meanings plus 6 class colours, 5 units, about 9 distinct recurring text styles at or under 13 pt.
- The information a student most likely wants first (how far, what is left, what next, when done, what to ask the advisor) is present but spread across the ring, the bar, the table header lines and collapsed cards; no single element answers "what do I do next".
- Because the table is the editing surface and is replicated, any redesign that gives the plan one home can drop a tab and the per-tab duplication without removing a capability, provided "fits"/"+N%" judgement still follows whichever audit (declared or what-if) is on screen (ST:9-16).
- The honesty rules (section 4) constrain simplification: a single big "you are N% done" number for a dual-degree student is not available, and a completed-looking state may only be drawn in the app's own colour with "≈", never as Penn's.

### Gaps
- None of these observations has been checked against real usage data or a usability test; they are read from code and from the notes' own Known gaps. Whether the owner experiences each as a problem is unknown except where section 6 quotes him.
