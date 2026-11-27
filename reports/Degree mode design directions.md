# Degree mode should answer one question first

Degree mode feels dense because its first screen answers five questions at once, at equal weight, in five units and three vocabularies, mostly in 10 to 13 pt type. On the two-degree view a student meets **roughly 25 to 30 labels and numbers before the semester table even starts** (an estimate from the view code, not a device count; `current_degree_mode_inventory.md` §3). The apps that feel simple do the opposite: they open on one position or one state, show about zero to three numbers, and attach a single next step to it. This report offers three directions that each pick a different first question: **the road** (where am I and what's next, organised by time), **the finish line** (when would I finish and what could move that, organised by the outcome), and **the stamp card** (what is left, organised by requirements). All three keep the rules already decided, and each says plainly where a rule would have to bend. I would build the road first and put the finish line's two-line sentence on top of it; the stamp card is the weakest front door. One caution up front: most outside sources were read only as search excerpts, no study compares these layouts for degree planning, and nothing here has been tested with students.

## Today's screen asks five questions at once; the simple apps ask one

### Why it feels dense

The inventory describes three layers stacked on one page: Penn's audit, the student's own sketch of semesters, and the app's estimates about that sketch. Each of the owner's asks over three weeks was added on top; nothing was replaced. The tally is **3 tabs, 6 sheets or covers, 5 chip rows, 5 state colours plus 6 class colours, and 5 units** (percent, cu, rule counts, course counts, percentage points), with three vocabularies for the same state ("done / left", "met / open", "n of N"). The same semester table appears in all three tabs. "What is left" sits below a sideways-scrolling table, and no single element answers "what do I do next" (`current_degree_mode_inventory.md` §1, §3, §7).

Outside evidence says this is a known failure, not a styling problem. NN/g's point about progressive disclosure is that whatever is on the first display tells the user it is important, so a screen with everything at the top says everything matters equally (search excerpt; [NN/g](https://www.nngroup.com/articles/progressive-disclosure/)). Degree Works shows two headline wheels, requirements and credits, that often disagree, and schools have to publish a sentence explaining why ([Farmingdale guide](https://www.farmingdale.edu/registrar/degree-works/pdf/fsc-degreeworks-student-manual.pdf)). A Brilliant user read the same progress showing as different amounts in different places as a bug ([Ben Wheatley](https://benwheatley.github.io/blog/2024/03/11-12.00.16.html)). Degree mode currently carries Penn's percent, an estimate with the plan, a by-target figure and an if-approved figure for each degree: four headlines per ring.

The student-side research is thin but points one way. A preliminary ACM study of a planning tool concluded that current systems fail because they do not match how students organise planning, not because they lack features ([CourseFix](https://dl.acm.org/doi/10.1145/3764687.3769937)). The questions students actually bring are "what is left", "why isn't this counting", and "what do I take next semester" ([Stellic](https://www.stellic.com/resources/reduce-degree-audit-support-tickets); [Penn State case study, abstract only](https://library.iated.org/view/WIJEKUMAR2014DES)). None of those is a percentage.

### What the simple apps share

Across Duolingo, Apple's rings, training plans, delivery trackers and maps, the first thing seen is a position or a state, never a table. Duolingo replaced its branching tree with one line because learners were unsure whether they were using it the right way; its CEO told NBC that engagement was equivalent and the change would stay ([Duolingo shareholder letter](https://investors.duolingo.com/static-files/d667f9d1-8f7f-418c-b116-e699a30a9826); [NBC News](https://www.nbcnews.com/tech/tech-news/duolingos-update-redesign-luis-von-ahn-interview-rcna44655); both search excerpts). Apple's fitness lead said the rings were built around a visual on purpose, where other trackers led with numbers; the numbers live one tap in ([MobiHealthNews](https://www.mobihealthnews.com/content/jay-blahnik-what-separates-apple-watch-other-fitness-trackers)). Couch to 5K states a whole plan in two numbers: nine weeks, three runs a week ([NHS](https://www.nhs.uk/better-health/get-active/get-running-with-couch-to-5k/couch-to-5k-running-plan)).

Maps and trackers add the part degree mode needs most. A navigation app shows one highlighted route and one arrival time; every alternative is quieter and is stated as a difference with its condition ([Android Central](https://androidcentral.com/apps-software/google-maps-faster-route-available-sucks); [Apple iPhone User Guide](https://support.apple.com/en-asia/guide/iphone/iphcc4416141/14.0/ios)). A good tracker has a small fixed set of named stages, one "you are here", and one predicted end; NN/g warns that a tracker people find wrong loses their trust ([NN/g](https://www.nngroup.com/articles/status-tracker-progress-update/), search excerpt).

Apple's own guidance, which was read in full, says the same thing in platform terms: "Summarize the main message of your chart," and "don't require interaction to reveal critical information" ([Apple HIG, Charts](https://developer.apple.com/design/human-interface-guidelines/charts)).

### What does not transfer

Streaks and daily goals get their pull from a daily reset. A degree moves a few times a semester, so there is nothing truthful for a streak to count. The closest classroom evidence, a semester-long study of badges and a leaderboard, found lower motivation and exam scores in the gamified class ([Hanus and Fox, via abstract](https://www.researchgate.net/publication/265644737_Assessing_the_effects_of_gamification_in_the_classroom_A_longitudinal_study_on_intrinsic_motivation_social_comparison_satisfaction_effort_and_academic_performance)). The transferable parts of Duolingo are the single next step and the tick on a finished unit. In all three directions below, the only things that get a celebration are verified facts: a semester that is over, a requirement Penn marks met, an advisor answer recorded.

One more limit shapes everything: the designers of the saga map themselves say a single line of levels only works when the content really is a sequence ([Game Developer](https://www.gamedeveloper.com/design/rethinking-progression-in-mobile-puzzle-games), search excerpt). A degree is ordered in time (semesters) and unordered in content (buckets of requirements with choices). So a line is honest for semesters and dishonest for courses.

### How far to trust this

Only Apple's design pages and a few GitHub pages were read in full. Everything else, including the Duolingo, NN/g, GOV.UK, maps and audit-tool findings, comes from search-result excerpts, so wording attributed to those pages is paraphrase. The count of numbers on each app's first screen is a researcher's judgment, not a sourced fact. Where a choice below is my own judgment, it says so.

### A fourth direction I dropped

A chat-first or one-card-at-a-time degree mode ("what should I do now") is the most radical option, and I do not offer it as a front door. A draft study of Khan Academy's AI tutor found students barely used it ([Chalkbeat](https://www.chalkbeat.org/2026/08/25/ai-tutoring-students-khanmigo-khan-academy-engagement-study/)); Jakob Nielsen argues most people cannot put what they want into a prompt ([Nielsen](https://jakobnielsenphd.substack.com/p/prompt-driven-ai-ux-hurts-usability), his estimate, not a measurement); and NN/g documents how laborious it is to adjust a structured result through text alone ([NN/g](https://www.nngroup.com/articles/accordion-editing-apple-picking/), search excerpt). The notes' own rule is that "how am I doing" must never depend on starting a conversation. Its two good ideas survive in all three directions: the app proposes first, and advisor questions are asked one per screen, which is the structure the UK government's design team recommends starting from after its own user research ([GOV.UK Service Manual](https://www.gov.uk/service-manual/design/form-structure)).

## Direction 1, the road: one vertical line of semesters with you on it

**The idea in one sentence:** your degree is one vertical line of semesters, you are standing on one of them, the finish is the last stop, and the next thing to do sits on the stop you are at.

Organising principle: time. First question: where am I and what's next. Primary interaction: scroll the line and tap a stop.

### First screen

All numbers and course codes in this report are invented.

```
degree                  read today

5 semesters · would finish
spring 2029

history      ▓▓▓▓▓▓▒▒░░░░ 58%
engineering  ▓▓▓▓▒▒▒░░░░░ 44%

 ✓ 3 semesters done          ›
 ● fall 2026 · now           5
 ◐ spring 2027 · registered  4
     room for 1 more   + add
 ? ask your advisor · 2      ›
 ○ fall 2027 · planned       5
 ○ spring 2028 · planned     5
 ○ fall 2028 · planned       4
 ⚑ spring 2029 · finish      3
     fall 2028 if 2 answers
     are yes                 ›

path@penn's reading ·
official audit ↗
```

Top to bottom. The title and status line stay as they are. Under them is one sentence in the largest type on the screen: how many semesters are left and the term the plan would finish. Then one thin bar per degree on a shared left edge: teal is Penn's reading, marigold is this semester, cobalt is planned, and the percent at the end is Penn's own number, untouched. The app's estimate with the plan is one tap in, still marked "≈".

Then the road. Each semester is a full-width row with a shape and a word (done, now, registered, planned, finish), so state never rests on colour alone. Finished semesters fold into one row. The number at the right is classes that term. Exactly one row carries a raised callout, the single next step: here, `room for 1 more` with `+ add`. The advisor is a stop on the road, placed before the semester its answers affect. The last stop is the finish, and under it, in words, the earlier finish and what it depends on.

With no plan, the road simply ends after the last registered semester with one row: `nothing planned after spring 2027` and two choices, `plan the rest ✦` and `add by hand`. The sentence at the top reads `no finish yet`.

Figures on the first screen: four (semesters to go, the finish term, two Penn percents), plus one class count per visible stop.

### How each job works

| job | how |
|---|---|
| progress, one degree | the bar is Penn's number; tap it for Penn's requirement cards |
| progress, two degrees | two aligned bars, each Penn's own; one shared road, because the semesters are shared; no combined percent |
| semesters ahead | the road itself; scroll |
| plan by hand | tap a stop; a sheet lists its classes with one "fits" line each, `+ course` (today's add sheet), `move to…` (a menu of terms; drag stays as an extra), and remove |
| plan with ai | `plan the rest ✦` on the first empty stop; edits land on the road at once with `undo` |
| no approval vs sooner | the road only ever holds the plan nobody has to approve; the sooner finish is one worded line under the last stop |
| advisor | tap the advisor stop; one question per screen, `yes` / `no`, each with what a yes changes; `copy` for all open ones; then `update plan`, and the road shows one line saying what moved |
| what-if | `try another major` in a top-right menu; bars and "fits" lines redraw under a grape banner `what if · finance · not declared`, with `back to my degree` |
| Penn's detail | tap a bar for today's block cards; the footer link stays |

One honesty note on what-if: a what-if returns Penn's audit for the other program, not a schedule. The bars and the "fits" lines can follow it at once; the finish term only changes after the planner runs again, and the screen should say `finish not checked` until then.

### What it removes or demotes

The three tabs go: the plan tab adds one sentence to a table the others already show (`current_degree_mode_inventory.md` §2). The sideways strip and the "full view" cover go, because the road is the full view. The rings become bars. The legend goes, because each row says its state in a word. The "+N%" badges leave the first screen and stay inside the add sheet. The "≈ NN% by…" lines under the rings are replaced by the finish sentence. Requirement cards move one tap down, behind each bar.

### Evidence for and against

For: this is the Duolingo move applied where it is honest. Duolingo's stated reason for the path was doubt about the "right" next step, which is the same doubt as ten open requirement cards. Training-plan apps show a long goal as a row of small containers with the current one open, and a semester is the degree's week. On phones, design-system guidance favours a single-column vertical timeline with a full-width row per period ([SAP Fiori](https://www.sap.com/design-system/fiori-design-web/v1-120/ui-elements/timeline/usage); [Flourish](https://helpcenter.flourish.studio/hc/en-us/articles/8761591366031-How-to-adjust-your-horizontal-timeline-for-mobile)), and NN/g reports that horizontal scrolling draws consistently negative reactions and that swipes inside a page are ambiguous ([NN/g](https://www.nngroup.com/articles/horizontal-scrolling/); [NN/g](https://www.nngroup.com/articles/mobile-carousels/); search excerpts, the first mostly about desktop). Apple's rule to offer alternatives to gestures is why moving a class gets a menu, not only a drag ([Apple HIG, Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). It also matches what students build for themselves: every well-liked student planner in the notes is a grid of terms first and a requirement checker second ([CourseRoad](https://github.com/sipb/courseroad2); [MIT Admissions blog](https://mitadmissions.org/?p=55679)). And it is closest to the owner's own words: a table in every view, the whole table on one page, progress rising as he plans.

Against: no study compares a vertical and a horizontal timeline on a phone; the support is vendor and design-system guidance. A road implies one correct order, and a degree has many valid ones. Duolingo's existing users petitioned against losing choice ([Change.org](https://www.change.org/p/reverse-duolingo-s-path-update)), and later reported feeling stranded when course updates moved their position ([Android Authority](https://androidauthority.com/duolingo-broken-updated-courses-why-i-quit-3686405)). And "what is left", the question students ask most, is again one tap down. The advisor-as-a-stop idea and the order in which the app picks the next step are my own judgment, not sourced.

### Risks and where it could mislead

A planned stop looks like a commitment. In a small prototype test at Texas Law, planned courses were the part only half of students fully understood ([Texas Law](https://law.utexas.edu/ux-case-studies/degree-audit/)). The word "planned" on every such row, and "registered" as a separate word, has to carry that.

The line under the finish could be read as available today. It must always name its condition in the same line, in countable words ("if 2 answers are yes"), never as a second flag.

The road will change when Penn's audit is re-read or a what-if is on screen. Without a visible "changed because…" line, that reads as a bug, which is the Duolingo "stranded" complaint.

The next-step callout is the app choosing for the student. To stay inside the "never a verdict" rule it must state a fact ("room for 1 more"), not advice.

### Reuse and build size

**Medium.** The road is a third layout of a table that already has two (strip and page), built on the same pure column model; the add sheet, advisor questions, chat, block cards and projection are reused as they are. New work: the vertical layout, the semester sheet, a small pure rule that picks the next step, turning what-if into a banner mode, and re-pinning the copy tests that hold today's strings ("full view", the tab names, the legend words). No backend change, and nothing new leaves the phone.

## Direction 2, the finish line: one date, and what would move it

**The idea in one sentence:** degree mode opens on a single sentence saying when you would finish with nothing to ask anyone, and a quieter card showing how much sooner if your advisor says yes, like a route and its faster alternative.

Organising principle: the outcome. First question: when do I finish and what could change that. Primary interaction: answering conditions and watching the date.

### First screen

```
degree                  read today

would finish
spring 2029
no approval needed

┌────────────────────────────┐
│ one semester sooner        │
│ fall 2028 if 2 answers     │
│ are yes                    │
│ 0 of 2 answered          › │
└────────────────────────────┘

history      ▓▓▓▓▓▓░░░░ 58% ›
engineering  ▓▓▓▓░░░░░░ 44% ›

semesters                    ›

┌────────────────────────────┐
│ change the plan…         ✦ │
└────────────────────────────┘
finish sooner · lighter
spring · try another major

path@penn's reading ·
official audit ↗
```

Top to bottom. Title and status. Then the headline, very large: the term, with `would finish` above it and `no approval needed` below. Then one card for the alternative, drawn quieter than the headline: its difference ("one semester sooner"), its term, its condition, and a count of answers. Then one row per degree with Penn's percent and a thin bar. Then one row that opens the semesters. Then a field that opens the planner, with three ready-made asks so nobody faces a blank box. Last, the link to Penn's official audit, as today.

The headline has three states, and all three must exist. With no plan: `no plan yet` and `plan it for me ✦`. With the planner's plan: the term. After a hand edit: `you changed the plan · finish not checked` and `check ✦`. The third state is needed because today the plan's summary is dropped by any hand edit (`current_degree_mode_inventory.md` §1).

The card has states in words too: `0 of 2 answered`, `1 yes · 1 to ask`, `all yes · update plan`, or `not possible · 1 answer was no`. After an update the headline moves and one line under it says why: `was spring 2029 · 2 answers were yes`.

Figures on the first screen: five (two terms, one answer count, two Penn percents).

### How each job works

| job | how |
|---|---|
| progress, one degree | its row shows Penn's percent; tap for Penn's requirement cards |
| progress, two degrees | two rows on a shared edge, each Penn's own; the headline is about time, which the degrees share; no combined percent |
| semesters ahead | `semesters ›` opens a plain vertical list of terms |
| plan by hand | inside that list, as in direction 1; back on the first screen the headline reads `finish not checked` until `check ✦` |
| plan with ai | `change the plan…` or a ready-made ask; the answer comes back as a new headline with one line saying what changed, and `undo` |
| no approval vs sooner | this is the first screen: the headline is the plan nobody has to approve, the card is the earlier finish and its conditions |
| advisor | tap the card; one row per question with its state, what a yes changes, `yes` / `no`, and `copy`; then `update plan` |
| what-if | `try another major`; the result comes back as a second quiet card, for example `with finance · fall 2029 · one semester later`, with `open` to see its requirements |
| Penn's detail | tap a degree row for today's block cards; the footer link stays on both screens |

### What it removes or demotes

Everything except the answer. The semester table leaves the first screen. The rings, the legend, the tabs, the chips and the "+N%" badges leave it too. Most notably, the faded "if approved" arc and the two "≈" lines under each ring are replaced by two dated lines in words.

That last change needs the owner's say. He asked for best and worst case "in the same ring" on 2026-11-27. This direction keeps the idea, both cases together, and changes the form.

### Evidence for and against

For: this is the structure the notes find wherever a product has a sure answer and a conditional one. Maps lead with one arrival time and state alternatives as a difference plus a reason. When a toll-avoiding preference is on in Apple Maps, the toll-free route comes first and the tolled ones stay listed below ([SlashGear](https://www.slashgear.com/1823784/how-to-avoid-toll-roads-apple-maps/)), which is the granted plan first and the if-approved plan below. GitHub's merge box puts a counted list of requirements ("1 review is required") in front of the outcome, in words and counts, not a lighter tint ([GitHub changelog, Dec 2024](https://github.blog/changelog/2024-12-03-improved-pull-request-merge-experience-now-in-public-preview), search excerpt). The case against the faded arc comes from hurricane maps: in a survey of 2,847 Florida residents, almost half read the area outside the forecast cone as safe ([University of Miami](https://news.miami.edu/stories/2022/11/that-uncanny-coneresearchers-want-to-erase-the-uncertainty.html), a news release). Shaded regions get read as promises. A large study found that stating uncertainty in specific terms costs little trust, and less than vague wording ([van der Bles et al.](https://pubmed.ncbi.nlm.nih.gov/32205438/)). Of the four framings the notes weighed, a words-first headline with detail on request has the most direct platform guidance behind it ([Apple HIG, Charts](https://developer.apple.com/design/human-interface-guidelines/charts)).

Against: the hurricane evidence applies to a faded arc only by analogy; nobody has tested a solid-plus-faded ring. No audit tool in the notes leads with a finish term, so there is no evidence on how students read one. No consumer app was found in which the user records someone else's spoken yes or no; DocuSign's forums show what goes wrong when an answer given outside the system has nowhere to go ([DocuSign Community](https://community.docusign.com/esignature-171/how-to-remove-envelope-from-waiting-for-others-after-one-party-signed-outside-of-docusign-19943)). And the most glanceable number is the first to be wrong: UBC removed Workday's progress wheel because it was inaccurate, and student government called the errors a major source of anxiety ([The Ubyssey](https://ubyssey.ca/news/workday-academic-progress-wheel/)).

### Risks and where it could mislead

The headline is only as good as the planner. The project's own notes record that prerequisite order rests on a few written rules, and that the first plan a real student saw leaned on things nobody had granted. A wrong term in the biggest type on the screen is worse than a wrong arc. Google Maps users complained loudly when the time saved on an alternate route turned out not to be real ([PiunikaWeb](https://piunikaweb.com/blog/google-maps-showing-misleading-times-on-alternate-routes)).

The headline needs the planner to have run. The planner is a server round trip that the student starts. A student who never asks sees `no plan yet` forever, and the notes warn that if a headline's truth depends on a chat having run, the design is assistant-led in practice.

The guidance on calculators says a result should move the moment the control does ([NN/g](https://www.nngroup.com/articles/sliders-knobs/), search excerpt). Here that would mean sending the audit to the server when an answer is tapped. The privacy promise says it is sent only when the student sends a message. I would keep the explicit `update plan` tap. Making it instant is a rule to bend, and that is the owner's decision.

A date reads as a promise from Penn. "would" helps; so does keeping Penn's link one tap away.

### Reuse and build size

**Small to medium.** Almost everything behind the first screen exists: the planner already returns the chosen finish, the best case, the approvals it leans on and up to twelve advisor questions; the advisor sheet, the chat and the block cards are built. A first cut is one new thin screen on top of existing sheets. It grows to medium with the plain vertical semester list, the `finish not checked` state and what-if cards that carry a term. It becomes large only if answers must move the date instantly, because that needs the server to work out each case ahead of time.

## Direction 3, the stamp card: every class left is an empty stamp

**The idea in one sentence:** each degree is a card of stamps, one per class Penn asks for; done ones are filled, and every empty one is something you can tap to fill.

Organising principle: requirements. First question: what is left. Primary interaction: tap an empty stamp and choose what goes in it.

### First screen

```
degree                  read today

≈ 14 classes left

┌ history ────┐┌ engineering ┐
│ ●●●●●●●●●●  ││ ●●●●●●●●●●  │
│ ●●●●◐◐◎◎○○  ││ ●●◐◐◐◎◎◎◎○  │
│ ○○          ││ ○○○○        │
│ penn 58%    ││ penn 44%    │
└─────────────┘└─────────────┘
● done ◐ now ◎ planned ○ left

left
history major          3 left
 ◎ HIST 2100 · fall 2027
 ○ seminar · pick 1 of 9    +
 ○ elective · pick 1 of 14  +
writing                1 left
 ○ pick 1 of 6              +
engineering electives  4 left
 ◎ MEAM 3020 · spring 2028
 …
fill the rest ✦

done                         ›
would finish spring 2029     ›
path@penn's reading ·
official audit ↗
```

Top to bottom. Title and status. One sentence: how many classes are left, marked "≈" because the count is the app's reading of Penn's rules. Then one card per degree: a grid of stamps with four shapes (filled, half, ringed, empty), and Penn's own percent under it. In the example the two cards show 15 stamps left between them and the sentence says 14 classes, because one class fits a stamp on both cards. Then a four-word key.

Then the list of what is left and nothing else, grouped by requirement with a count per group. A planned stamp shows its class and its semester. An empty one shows how many of Penn's options would fit and a `+`. Below the list: one button that asks the planner to fill the rest, a folded row for everything done, a row for the finish term and the semesters, and the footer.

Figures on the first screen: three (classes left, two Penn percents), plus one "left" count per group.

### How each job works

| job | how |
|---|---|
| progress, one degree | its card; Penn's percent under the stamps; tap a group title for Penn's own rules |
| progress, two degrees | two cards side by side; tap one to filter the list; a class that fits both carries a small mark on both; no combined percent |
| semesters ahead | each planned stamp names its semester; the full list is one tap away on the finish row |
| plan by hand | tap an empty stamp; a sheet lists the courses Penn accepts for it, with `fits both degrees` where true; pick one, then pick a semester from a short list showing each term's load |
| plan with ai | `fill the rest ✦`; stamps turn to planned rings, with `undo` |
| no approval vs sooner | stamps turn to rings only for the plan nobody has to approve; the finish row reads `would finish spring 2029 · fall 2028 if 2 answers are yes` |
| advisor | a question sits on the stamp it is about: `could MATH 2400 fit here too? ask your advisor`, with `yes` / `no` in place; a question about load sits on the finish row; `copy` gathers them all |
| what-if | `try another major` adds a third card with a grape `what if` tag and a line such as `≈ 5 more classes · 3 of yours count`; its empty stamps join the list |
| Penn's detail | this screen is the closest of the three to Penn's audit; a group title opens Penn's rules word for word, and the footer link stays |

### What it removes or demotes

The semester table leaves the first screen; time becomes a label on each stamp and one row at the bottom. Rings and bars become grids of stamps. Tabs go. Finished work folds away, which answers the owner's complaint about a row of chips for classes he already knew he had taken. "+N%" becomes `fits both degrees` or nothing.

### Evidence for and against

For: it answers the question students are documented to ask. Texas Tech's audit offers a condensed view of only what is still needed ([Texas Tech](https://www.depts.ttu.edu/degreeworks/Training/DWAuditGuide.pdf)); Stellic's planner leads with showing what a course would fill at the moment of choosing it ([JHU](https://info.stellic.jhu.edu/student-resources/)); Khan Academy's newer experience dropped the course-wide percent for a count of skills inside each unit ([Khan Academy](https://support.khanacademy.org/hc/en-us/articles/48431088309645-Update-How-mastery-percentage-is-calculated-on-Khan-Academy)). Counts are often easier than percentages ([review](https://pmc.ncbi.nlm.nih.gov/articles/PMC4475789)), and in one study grids of icons beat both ([Tubau et al.](https://diposit.ub.edu/dspace/bitstream/2445/162287/1/681165.pdf)). Motivation research says to point people at whichever is smaller, what is done or what is left, and to give them near sub-goals early on ([Koo and Fishbach, via review](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2019.02353/full); [Huang et al., via Stanford](https://www.gsb.stanford.edu/insights/focus-small-steps-first-then-shift-larger-goal)). "1 left in writing" is a near finish line. A stamp card is literally the object the best-known field study of this effect used: café customers bought more often as their card filled ([Kivetz et al.](https://business.columbia.edu/faculty/research/goal-gradient-hypothesis-resurrected-purchase-acceleration-illusionary-goal)).

Against: that evidence comes from coffee cards and car washes; carrying it to a four-year degree is an inference. The benefit of counts was strongest for people who are already good with numbers ([Cambridge](https://www.cambridge.org/core/product/7197DAAA5CC39185A3E4E02FD36A6FD0/core-reader)). The tools students find hard to read are the ones that put the rule list first and the plan second; this direction is on that side of the line. And the owner has asked for the semester table to be more present over time, not less.

### Risks and where it could mislead

The stamp count is partly the app's own reading. Penn states some rules in credits, some in courses, and some only in words. The app would be deciding how many stamps a rule gets. Penn Labs found exactly this class of error in its own planner this month: a "pick N" rule summed every option and pushed a section past 100% while a requirement was still open ([Penn Labs PR #821](https://github.com/pennlabs/penn-courses/pull/821)).

The stamps and Penn's percent will not agree. Penn's percent counts rules; the stamps count classes. Two figures on one card that disagree is the Degree Works two-wheel problem again.

A card full of ringed stamps looks finished. The planned shape has to be an outline, never a fill, and the word "planned" has to be on the list rows.

The effect that makes stamp cards motivating, the same distance looking shorter, is the one that must not be manufactured here. Real credit already earned is fair to show. Anything that makes the remaining distance look shorter than it is can send a student to register wrongly.

Hiding time hides impossible schedules. A full card says nothing about seven classes in one semester.

### Reuse and build size

**Large.** The block cards, rule lists and add-sheet suggestions exist, but the unit this direction is built on, one slot per class, lives today in the server's planner, not on the phone; the phone knows a remaining need per rule. New work: a slot model on the phone with honest handling of word-only and "pick N" rules, a slot-first add flow with a semester step, one merged list for two degrees, and a mapping from each advisor question to its stamp. Nothing new leaves the phone.

## Side by side: three first screens, three weak points

| | 1 · the road | 2 · the finish line | 3 · the stamp card |
|---|---|---|---|
| organised by | time | the outcome | requirements |
| first thing seen | a line of semesters with "now" on it | one finish term and the sooner one | stamps left, per degree |
| main interaction | scroll, tap a semester | answer a condition, watch the term | tap an empty stamp, fill it |
| figures on first screen | 4, plus a class count per stop | 5 | 3, plus a "left" count per group |
| best for | a student arranging semesters, most of all around registration; anyone with no plan yet | a student whose plan is made and who wants the answer and the advisor's part in it | a student near the end counting down, or one asking "why isn't this counting" |
| weakest point | implies one right order; "what is left" is a tap away | empty until the planner runs; the planner's term becomes the biggest thing on screen | the app decides how many stamps a rule gets; closest to the audit students find hard |
| rule under pressure | none; the next-step callout must stay a fact | replaces the two-case ring the owner asked for; instant updates would bend the privacy promise | the stamp total is an estimate and will not match Penn's percent |
| build size | medium | small to medium | large |

For scale, today's two-degree view has about 25 to 30 text items above the table. The figure counts in this table are for my sketches and can be cut further.

## Build the road first and put the finish sentence on top

I would build direction 1, and I would give it direction 2's two lines as its header and its last stop. The sketch above already does this: the sentence at the top and the worded line under the finish are the finish line's whole idea in two rows.

Four reasons, in order of weight. First, it is the only one that works on day one for every student. The road exists from Penn's record and the registered semester even when nothing is planned; the finish line shows `no plan yet` until the planner runs, and the stamp card needs a slot model that does not exist on the phone. Second, it fixes the most concrete problems in today's screen in one move: the sideways strip, the separate full view, the table repeated in three tabs, and drag as the only way to move a class. The guidance against sideways scrolling on a phone is the firmest layout evidence in the notes, even though it is guidance and not a controlled test. Third, it is what the owner has been asking for in his own words since 2026-11-11, and it is the honest version of the Duolingo idea he named: a line for time, where a degree really is ordered. Fourth, it carries the least risk of a wrong number in big type, because its headline is one sentence the planner already produces and the road beneath it shows what that sentence rests on.

What to fold in from the others. From the finish line: the two-line statement of the plan that needs no approval and the sooner one, in words and counts, replacing the two "≈" lines under each ring. I would make that change even if nothing else were built, with the owner's agreement, since it reverses the form of something he asked for. From the stamp card: only two pieces, and later. Show "left" as a count on the requirement screen behind each bar, and let a student tap an open requirement there to add a class for it. I would not build the stamp card as a front door.

A sensible order of work: the header sentence and the worded sooner line first (small, visible at once); then the vertical road replacing the strip, the full view and the tabs; then the requirement screen's "left" counts. Before the second step, put paper sketches of directions 1 and 2 in front of a handful of students for five seconds each and ask three things: how much is left, when they would finish, and whether anything needs them. That is the cheapest way to replace my inference with evidence.

## Seven questions only the owner can answer

Is the finish term trusted enough to be the biggest thing on the screen? Both the road's header and the finish line rest on the planner's term, and the project's notes list known limits in it. If the answer is "not yet", the header should lead with semesters left and keep the term smaller.

Does the two-case ring stay? The owner asked for it on 2026-11-27. The evidence against a faded arc is by analogy only. The choice is his: keep the ring one tap in, or replace it everywhere with two dated lines.

Which unit is "left"? Classes, cu, or Penn's open requirements. And is one combined "≈ cu left" across both degrees acceptable? It is not a percent, so the written rule does not forbid it, but it is the app's figure about two degrees at once.

Should recording an advisor's answer update the plan by itself? That means sending the audit to the server without a typed message, which bends the current privacy wording. Keeping the `update plan` tap bends nothing.

May the app pick the next step? A callout such as `room for 1 more` is a fact, but choosing which fact to raise is a judgment. If that sits wrong with "never a verdict", the road still works without the callout.

Who is this for first? The owner has two degrees; most students have one. Every sketch here was drawn for two. If one-degree students are the first audience, the first screen gets simpler still, and the dual-degree parts can follow.

Does Penn's percent have to be on the first screen? The rule says it must never be altered, not where it must sit. All three sketches keep it on the first screen. Moving it one tap in would cut two figures from each.

## Conclusion

The real decision is not which metaphor looks best. It is which unit leads: a position in time, a date, or a count of what is left. The percent that leads today is the one unit no simple app in this research leads with; in maps terms it is the odometer, not the arrival time. Once a different unit leads, the decided rules stop fighting simplicity, because the simple apps already do what those rules ask: one sure answer in plain words, the conditional one stated as a difference with its condition named, and the official source one tap away.

The second thing this research changes is where the risk sits. Any of these directions makes the planner's finish term more prominent than it is now. That raises the cost of it being wrong, and it makes the planner's accuracy, more than any drawing, the thing that decides whether degree mode feels smooth or feels like a broken promise.
