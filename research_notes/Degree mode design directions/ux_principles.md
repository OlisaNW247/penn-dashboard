# ux_principles

Research notes for "Degree mode design directions" (2026-11-27). Scope: design principles and evidence for choosing between very different directions for a degree-progress and planning screen on iPhone. Nothing here designs the feature.

How to read the sourcing. `developer.apple.com` pages were fetched in full and are quoted verbatim. `nngroup.com` could not be fetched from this session (the host is outside the session's allowed network domains), so every NN/g claim below comes from search-result excerpts of the NN/g page and is marked "(excerpt)". Academic papers were mostly reached through abstracts, publisher pages or university write-ups, not full text; where a number comes from a secondary summary it says so. Anything I could not source is under Gaps, not in Cited Findings.

## 1. Progressive disclosure and "one primary thing per screen": when do summaries with drill-down beat dashboards?

### Takeaway
The guidance is consistent across NN/g and Apple: show the few things most people need first, state the main message in words, and put the rest one deliberate step away, never hiding anything critical behind an interaction. I found guidance and expert consensus for this, but no controlled experiment that compares a "single headline plus drill-down" screen against a dense dashboard for a planning task.

### Cited Findings
- NN/g describes progressive disclosure as deferring advanced or rarely used features to a secondary screen, which makes applications easier to learn and less error-prone (excerpt). — [NN/g video: Progressive Disclosure](https://www.nngroup.com/videos/progressive-disclosure/)
- NN/g's article says that whatever is on the initial display tells users it is important, i.e. the first screen is itself a prioritisation message (excerpt). — [NN/g: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
- NN/g distinguishes progressive disclosure (core features first, secondary on request; most people never need the second layer) from staged disclosure (a linear sequence, one step's features at a time, everyone passes through every step) (excerpt of NN/g's table, wording of the contrast from a secondary blog). — [NN/g: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/); [Orbix summary](https://www.orbix.studio/blogs/progressive-disclosure-in-ux)
- A secondary blog attributes to NN/g the warning that more than two levels of disclosure usually hurts because users get lost between levels. I could not confirm this wording on NN/g's own page. — [Orbix summary](https://www.orbix.studio/blogs/progressive-disclosure-in-ux)
- Apple: "An effective chart highlights a few key pieces of information in a dataset, helping people gain insights and make decisions." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: "Summarize the main message of your chart to help make it approachable and useful for everyone. Although a primary reason to use a chart is to display the data that supports the main message, it's essential to summarize key information so that people can grasp it quickly." Apple's example is Weather's title and subtitle that "succinctly describe the expected precipitation for the next hour, giving people the most important information without requiring them to examine the details of the chart." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: "Let people interact with the data when it makes sense, but don't require interaction to reveal critical information." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple explicitly sanctions the small-summary-that-opens-detail pattern: a single accessibility label can suffice "when you use a small version of a chart in a button that reveals a more detailed version." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple, cognitive accessibility: "When you minimize complexity in your app or game, all people benefit." For Assistive Access: "Identify the core functionality of your app and consider removing noncritical workflows and UI elements" and "Break up multistep workflows so people can focus on a single interaction per screen." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Apple (watchOS, but stated as a general design benefit): "Consider limiting the content of an individual page to a single screen height. Embracing this constraint encourages each page to serve a clear and distinct purpose and results in a more glanceable design." — [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls)
- Apple (watchOS): "prefer displaying useful information people can get at a glance and supporting simple interactions when they add value," with the phone app as the place for "more details." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)

### Inferences
- The two NN/g forms map onto two of the candidate directions: a headline screen with drill-down is progressive disclosure (most students stop at layer one); a guided path is staged disclosure (everyone walks every step). Staged disclosure suits a task done once in order (building a plan); progressive disclosure suits a state checked often (how am I doing).
- "Anything on the first screen signals importance" is an argument against three tabs, rings, bars, chips and a table all at the top level: the screen currently signals that everything is equally important.
- Apple's rule that interaction must not be required for critical information means the items needing advisor approval, if they change whether the plan works, belong in or next to the headline, not three taps down.
- If the unverified "two levels" limit holds, the structure headline → requirement group → individual course is already at the limit; a what-if layered on top would be a third level.

### Gaps
- No controlled study found comparing a summary-with-drill-down screen with a multi-widget dashboard for comprehension or decision quality on mobile.
- NN/g's own wording on the number of disclosure levels and on its two success criteria (getting the split right; making the path to more obvious) could not be read directly because nngroup.com was unreachable from this session.
- I searched for a "one primary action per screen" source from Apple or Material and did not retrieve one beyond the Assistive Access sentence above.

## 2. Motivation effects in progress displays (goal gradient, endowed progress, small wins, streaks) and making a multi-year goal feel achievable

### Takeaway
Effort rises as a goal feels near, sags in the middle, and responds to which quantity the display draws attention to: early on, sub-goals and "done so far" help because they make the goal feel attainable; late, "what's left" and the end goal help. All of the strongest evidence comes from short, low-stakes tasks (coffee cards, car washes, crowdsourced work), so its transfer to a four-year degree is an inference.

### Cited Findings
- Kivetz, Urminsky and Zheng (2006, Journal of Marketing Research 43, 39–58): members of a real café's buy-ten-get-one-free programme bought coffee more frequently the closer they were to the free coffee; the authors report the gradient is not explained by habituation, expiry concerns, other time trends or heterogeneity bias. — [Columbia Business School research page](https://business.columbia.edu/faculty/research/goal-gradient-hypothesis-resurrected-purchase-acceleration-illusionary-goal); [paper PDF](https://business.columbia.edu/sites/default/files-efs/pubfiles/1200/goalgradient.pdf)
- A Chicago Booth write-up of the same study puts the time between purchases at about 20 percent shorter by the last stamp than at the first. — [Chicago Booth Review: Going for the goal](https://www.chicagobooth.edu/review/going-goal)
- "Illusionary goal progress": customers given a 12-stamp card with two bonus stamps already filled completed the ten required purchases faster than customers with a plain 10-stamp card (same real distance). One secondary summary gives median completion of 10 versus 15 days; I did not verify that figure against the paper. — [Columbia Business School research page](https://business.columbia.edu/faculty/research/goal-gradient-hypothesis-resurrected-purchase-acceleration-illusionary-goal)
- Same paper, online study: people rating songs for reward certificates rated more songs per visit and persisted longer as they neared the reward. — [Columbia Business School research page](https://business.columbia.edu/faculty/research/goal-gradient-hypothesis-resurrected-purchase-acceleration-illusionary-goal)
- Nunes and Drèze (2006, Journal of Consumer Research), endowed progress: a field experiment handed out 300 loyalty cards at a professional car wash; half needed eight stamps, half needed ten with two pre-stamped, so both required eight paid visits. The head-start group completed the card more often and faster. — [paper PDF hosted at USC](https://msbfile03.usc.edu/digitalmeasures/jnunes/intellcont/Endowed%20Progress%20Effect-1.pdf); [summary](https://www.coglode.com/nuggets/endowed-progress-effect)
- Secondary summaries of Nunes and Drèze report that the effect depends on a reason being given for the head start and can fail without one. — [Coglode: Endowed Progress Effect](https://www.coglode.com/nuggets/endowed-progress-effect)
- Bonezzi, Brendl and De Angelis (2011, Psychological Science 22(5), 607–612), "Stuck in the Middle": motivation "can be higher when people are either far from or close to the end state and lower when they are about halfway," a U-shape; the shape depends on whether people monitor progress as distance from the start or distance from the end. — [PubMed](https://pubmed.ncbi.nlm.nih.gov/21474842/); [Kellogg research page](https://www.kellogg.northwestern.edu/faculty/research/detail/2011/stuck-in-the-middle-the-psychophysics-of-goal-pursuit)
- Koo and Fishbach, small-area hypothesis: people are more motivated when attention is directed to whichever is smaller, accumulated or remaining progress, because the small area creates "an illusion of fast progress." A review summarises the pattern as: the accumulated ("to-date") frame motivates more when progress is low, the remaining ("to-go") frame when progress is high. — [Frontiers in Psychology review, 2019](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2019.02353/full); [Kellogg Insight: Mastering Motivation](https://insight.kellogg.northwestern.edu/article/mastering_motivation)
- Koo and Fishbach also report a commitment moderator: emphasising to-date progress raises adherence when commitment is uncertain; emphasising to-go works better when commitment is certain (four studies, per abstract). — [Frontiers in Psychology review, 2019](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2019.02353/full)
- Huang, Jin and Zhang (2017, Organizational Behavior and Human Decision Processes 141, 1–15), "Step by Step: Sub-Goals as a Source of Motivation": sub-goals motivate in the early stage because, while people doubt attainability, signals that the goal is reachable drive motivation; later, focusing on the overall goal keeps the work feeling valuable and avoids coasting. In a field study a hybrid plan (sub-goals first, then the overall goal) did best: 57.1% reached the target versus 33.8% with only the overall goal and 39.1% with only sub-goals. — [Stanford GSB Insights](https://www.gsb.stanford.edu/insights/focus-small-steps-first-then-shift-larger-goal); [journal record](https://ideas.repec.org/a/eee/jobhdp/v141y2017icp1-15.html)
- Amabile and Kramer's "progress principle" comes from an analysis of nearly 12,000 diary entries from working professionals: the strongest daily lift to motivation and mood was making progress in meaningful work, even small progress. "Small wins" as a concept is Weick's (1984). The same secondary source warns that trivial or fake wins can backfire. (Secondary source; I did not reach the original.) — [Cogn-IQ: Psychology of Small Wins](https://www.cogn-iq.org/blog/psychology-of-small-wins/)
- Streaks: a qualitative study of Duolingo (nine years of forum posts plus 15 interviews) documents gamification being "misused," i.e. learners optimising the game elements at the expense of learning. — [arXiv 2203.16175](https://arxiv.org/abs/2203.16175)
- Behavioural-science commentary on "streak creep" argues streaks can turn an activity into an obligation and backfire. Opinion, not an experiment. — [The Decision Lab: Streak Creep](https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification)

### Inferences
- A degree is long enough that most students spend most of their time in Bonezzi's low-motivation middle. The evidence points to re-anchoring on a nearer end point (this semester, this requirement group, "after spring you are done with X") so the student is always near the end of something.
- The small-area and to-date/to-go findings give a concrete, testable rule for the headline number: early students see what they have done; students past roughly half see what is left. A senior with 4 courses left is better served by "4 left" than by "90%".
- Huang et al. supports chunking by stage: semesters or requirement groups as sub-goals early, graduation as the stated goal late.
- Endowed and illusionary progress work by making the same distance look shorter. For a degree, real endowed progress exists (transfer and AP credit, courses in progress this term) and showing it is legitimate. Manufacturing head starts is the part that does not transfer: a student who believes they are closer than they are may register wrongly.
- Streaks reward frequency of opening the app. Degree progress changes a few times a year; there is nothing truthful for a streak to count.

### Gaps
- The 34% versus 19% card-completion figures usually quoted for Nunes and Drèze were in my search query but not confirmed by any retrieved text; verify in the USC-hosted PDF before quoting.
- The 10-versus-15-day median for Kivetz's bonus-stamp card came from an unidentified secondary summary; verify in the Columbia PDF.
- I found no study of goal-gradient or sub-goal effects on a multi-year educational goal, and none on degree-audit displays specifically.
- I did not retrieve Amabile and Kramer's primary source (HBR 2011 or the book); the citation above is secondary.
- No controlled experiment on streak mechanics and long-term persistence was found.

## 3. Showing a part-to-whole: ring/donut versus bar versus plain count versus a sentence; percentages versus counts

### Takeaway
A single ring is not meaningfully harder to read than a bar for one proportion, but bars are read somewhat faster and compare better side by side; neither replaces a number in words, which Apple treats as mandatory. The Gigerenzer literature shows counts are often easier than normalised percentages, with real limits, and it was established on conditional-probability problems, not progress displays.

### Cited Findings
- Skau and Kosara (EuroVis 2016), "Arcs, Angles, or Areas": pie and donut charts encode data three ways (arc length, centre angle, area); their studies indicate angle is the least important cue, and donut charts are about as accurate as pies. In their survey of how people read the charts, 51% reported using arc length, 25% area, 23% angle, 1% chord length. — [Tableau Research: Arcs, Angles, or Areas](https://www.tableau.com/research/publications/arcs-angles-or-areas-individual-data-encodings-pie-and-donut-charts); [paper PDF](https://tableau.com/sites/default/files/2023-01/Skau-EuroVis-2016.pdf)
- Cleveland and McGill's ranking puts position on a common scale first, then length, angle and area, but average accuracy differences are often very small (one or two parts in a hundred), as summarised in the pie/donut literature. — [Skau dissertation, UNC Charlotte](https://ninercommons.charlotte.edu/record/3238/files/Skau_uncc_0694D_11257.pdf)
- A 2024 study in Information Visualization comparing pie and donut charts with bar charts found little difference in cognitive load between chart types, with bar charts consistently faster on average. — [Information Visualization, 2024](https://journals.sagepub.com/doi/10.1177/14738716241259432)
- A study of donut-chart parameters found proportion-reading accuracy insensitive to the inner radius except for the thinnest ring. (Attribution to Cai et al. is from the search summary; I did not open the paper.) — [paper PDF via CORE](https://core.ac.uk/download/518741103.pdf)
- Apple: bar marks "work well in charts that help people compare values in different categories or view the relative proportions of various parts in a whole." Apple's own part-to-whole example is iPhone Storage: "a single bar mark containing several segments," with separators between segments to "help people distinguish individual ones." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: use a fixed axis range when the bounds are meaningful: "people expect a chart that shows a battery's current charge to have a minimum value of 0% (completely empty) and a maximum value of 100% (completely full)." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: summarise the chart's main message in a title and subtitle in plain language so people "grasp it quickly" without examining the chart. — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Gigerenzer and Hoffrage introduced natural frequencies in 1995; the frequency-format hypothesis holds that people handle counts more easily than normalised percentages, in part because percentages require normalising to 100. — [Wikipedia: Frequency format hypothesis](https://en.wikipedia.org/wiki/Frequency_format_hypothesis); [PMC review](https://pmc.ncbi.nlm.nih.gov/articles/PMC4475789)
- Gigerenzer's 2011 BMJ essay argues a Cochrane review favoured natural frequencies and that a contrary 2011 Annals of Internal Medicine result did not actually test natural frequencies. — [Gigerenzer, "What are natural frequencies?" (MPG)](https://pure.mpg.de/pubman/item/item_2099208_9/component/file_3562683/Gigerenzer_What_2011_VerlPDF_final_LS.pdf)
- Limits: a study in Judgment and Decision Making found the benefit of natural frequencies "occurred primarily for participants who scored high in numeracy." — [Numeracy, frequency, and Bayesian reasoning (Cambridge)](https://www.cambridge.org/core/product/7197DAAA5CC39185A3E4E02FD36A6FD0/core-reader)
- Limits: Tubau and colleagues found icon arrays produced more accurate risk estimates than either percentages or natural frequencies, and that natural frequencies can be as hard as percentages when the task needs a ratio judgment. — [Tubau et al. (Universitat de Barcelona repository)](https://diposit.ub.edu/dspace/bitstream/2445/162287/1/681165.pdf)
- A Frontiers in Education paper notes natural frequencies "might not be easy when comparing or computing proportions." — [Frontiers in Education, 2020](https://www.frontiersin.org/articles/10.3389/feduc.2020.00073/pdf)

### Inferences
- For one degree's completion, the chart form matters less than the number and the sentence beside it. The measured ring-versus-bar difference is speed, not accuracy, and is small.
- Two rings side by side ask for a comparison of arc lengths on two separate circles; two bars on a common baseline use the encoding Cleveland and McGill rank highest. For a dual-degree student the evidence leans toward aligned bars or two plain counts over two rings.
- A count answers the question a student actually has ("how many classes are left, and can I fit them?"); a percent answers a question nobody acts on. "9 classes left" is also directly comparable with semesters remaining, which a percent is not. The natural-frequency literature supports this direction but was not tested on this kind of display, so treat it as a strong prior, not a proven result.
- Counts stop helping when the student must compare two wholes of different size (ratio judgment). For "which degree is further along" a percent or aligned bars is the appropriate secondary element.
- A requirement-by-requirement icon array (one mark per course or per requirement, filled or not) is the format with the best comprehension evidence among those tested by Tubau et al., and it is count-preserving.

### Gaps
- No study found that compares a ring, a bar, a bare count and a sentence for a progress-to-goal reading on a phone.
- No evidence found specifically on activity-ring-style displays (Apple Fitness) and comprehension.
- The Cleveland and McGill summary and the donut inner-radius finding are from search excerpts of secondary and thesis sources, not the original papers.

## 4. Chat versus direct manipulation versus hybrid ("generative UI", chat that yields editable cards) for planning tasks

### Takeaway
The consistent expert position is that a blank prompt box is a poor sole interface: many users cannot articulate what they want, and text-only threads make refining a structured result laborious. The direction endorsed by Nielsen, NN/g and the tools themselves is hybrid: intent in words, result as a manipulable object. Evidence that students will voluntarily lean on a chat tutor is weak.

### Cited Findings
- Jakob Nielsen's "articulation barrier": prompt-driven AI requires users to write precise prose; he estimates fewer than 20% of people in the US, Northern Europe and East Asia are articulate enough for advanced use of prompt-driven generative AI. This is his estimate, not a measured result. — [Nielsen: The Articulation Barrier](https://jakobnielsenphd.substack.com/p/prompt-driven-ai-ux-hurts-usability)
- Nielsen expects successful AI interfaces to be hybrid, combining intent-based prompting with GUI elements, and proposes "prompt augmentation" patterns (prompt rewrite, related prompts, prompt builders and others) to lower the barrier. — [Nielsen: Prompt Augmentation](https://jakobnielsenphd.substack.com/p/prompt-augmentation)
- NN/g observed two behaviours it attributes directly to text-only chat interfaces: "accordion editing" (repeatedly asking the AI to shrink or expand its output to reach one goal) and "apple picking" (referencing pieces of earlier responses in a new prompt to assemble the desired output). NN/g calls these behaviours "directly caused by existing generative AI tools and their limitations" (excerpt; article dated 24 September 2023). — [NN/g: Accordion Editing and Apple Picking](https://www.nngroup.com/articles/accordion-editing-apple-picking/)
- NN/g on generative UI: it anticipates interfaces generated in real time per user and "an outcome-oriented design approach where designers prioritize user goals and define constraints" (excerpt). This is a forecast. — [NN/g: Generative UI and Outcome-Oriented Design](https://www.nngroup.com/articles/generative-ui/)
- A 2026 UXmatters article reports that an NN/g diary study of three chatbots found participants often carried their search-engine mental model over to the chatbot, and that NN/g's April 2025 evaluation found prompt chips and suggestions help but often sit on top of the deeper issue. (Secondary report of NN/g work.) — [UXmatters, July 2026](https://www.uxmatters.com/mt/archives/2026/07/first-session-trust-in-ai-products-why-code-editors-onboard-users-better-than-chatbots.php)
- A Stanford preprint, "Generative Interfaces for Language Models," has the model produce UI structures in place of chat text and reports that people preferred the generated interfaces over conversational ones in over 70% of cases. Preprint, not peer reviewed. — [arXiv 2508.19227](https://arxiv.org/abs/2508.19227)
- A vendor report claims 77% of participants said a generative UI could save them time compared with a text chatbot. The vendor sells generative-UI tooling. — [Thesys blog](https://www.thesys.dev/blogs/why-generative-uis-outperform-chatbots-for-enterprise-productivity)
- OpenAI's canvas (launched 3 October 2024 as an early beta) opens a separate workspace beside the chat where users can directly edit the text or code; the model was trained to make targeted edits when the user selects a passage and to rewrite otherwise. Reviewers compared it to a document editor and to Claude's Artifacts. — [OpenAI: Introducing canvas](https://openai.com/index/introducing-canvas/); [Fast Company](https://www.fastcompany.com/91202944/open-ai-canvas-word-doc)
- Khanmigo: a draft NBER paper by Oreopoulos and Low is quoted as finding "We observe how students actually used the AI tutor, and the answer is: not much"; students used it on about a third of the days they worked in Khan Academy, many messages were off-topic or attempts to extract answers, and gains were modest and no larger than earlier Khan Academy practice without an assistant. Khan Academy has since moved Khanmigo into the main product instead of a separate tab. — [Chalkbeat, 25 August 2026](https://www.chalkbeat.org/2026/08/25/ai-tutoring-students-khanmigo-khan-academy-engagement-study/); [KQED MindShift](https://www.kqed.org/mindshift/66662/students-didnt-get-answers-from-khanmigo-they-didnt-want-its-questions-either)
- Apple, cognitive accessibility: "Prefer system gestures and behaviors people are already familiar with over creating custom gestures people must learn and retain." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### Inferences
- Chat fits the part of degree planning that is a constraint statement: "graduate by spring 2028, no more than 5.5 units, I'm approved for 6.5." Those are easy to say and tedious to click. Chat fits badly for the part that is inspection and adjustment of a structured object (move this course to fall), which is the accordion-editing and apple-picking trap.
- The pattern the evidence supports is: words in, object out. The plan is the durable artefact; the conversation is one way to change it, and every change it makes should be visible and reversible on the object itself (the canvas pattern).
- The articulation barrier predicts that an assistant-first screen with an empty text field will strand many students. Suggested prompts reduce this but, per the NN/g evaluation as reported, do not remove it. A design where the system proposes a plan first and the student reacts needs no articulation at all.
- The Khanmigo result is a warning about assuming students will come to a chat because it exists; moving it "into" the product, where the content is, is what Khan Academy did next. The analogy to degree planning is indirect (tutoring is not planning).
- If a headline's truth depends on a chat having been run, the chat is not optional and the design is assistant-led in practice whatever the layout says.

### Gaps
- I found no NN/g or peer-reviewed study that compares chat, direct manipulation and a hybrid on a planning or scheduling task with outcome measures.
- I found no reliable sources on the specific interaction patterns of Notion AI, Linear, Arc or Duolingo Max; they are not covered here.
- Shneiderman's direct-manipulation-versus-agents argument (and the Shneiderman and Maes debate) was searched for and not retrieved; it is not cited.
- The UXmatters attribution of the term "articulation barrier" to NN/g in 2023 conflicts with Nielsen presenting it as his own concept on his Substack; Nielsen co-founded NN/g, and I could not resolve which is the original publication.

## 5. Presenting conditional or uncertain outcomes in plain language; framing; avoiding false precision

### Takeaway
Vague probability words are read very differently by different people, most of all in the middle of the range, while stating the uncertainty as a range or a named condition costs little trust. The same fact framed as a gain or as a loss changes choices sharply, so the frame of a "by spring 2028 if approved" line is a design decision, not copy polish.

### Cited Findings
- Verbal probability phrases are interpreted with large variability, especially for phrases meant to convey 20% to 80%; agreement is highest for extreme terms (always, certain, never, impossible). Complementary phrases do not mirror each other: mean values for complementary terms summed to about 90%, not 100%. — [Willems, Albers and Smeets, arXiv 1901.09686](https://arxiv.org/abs/1901.09686)
- Van der Bles et al. (2020, PNAS), five UK surveys, total n = 5,780: stating uncertainty made people perceive the numbers as more uncertain, but trust in the numbers and the source fell only slightly; the drop was mainly associated with verbal uncertainty statements, and numerical uncertainty (a range) had only a minor effect on trust. — [PNAS](https://www.pnas.org/doi/pdf/10.1073/pnas.1913678117); [PubMed](https://pubmed.ncbi.nlm.nih.gov/32205438/)
- A review of crisis communication reports that most work finds numeric ranges around an estimate do not undermine trust, that some work (citing Joslyn and LeClerc 2016 among others) suggests communicating uncertainty can increase trust in some contexts, and that some studies found ranges can undermine trust. The evidence is mixed, leaning benign. — [arXiv 2304.01789](https://arxiv.org/abs/2304.01789)
- Tversky and Kahneman (1981, Science 211, 453–458), Problem 1, N = 152: with outcomes described as lives saved, 72% chose the certain option; with the same outcomes described as deaths, 22% chose the certain option. The only difference was the description. — [paper PDF](https://www.gwern.net/doc/psychology/1981-tversky.pdf)
- Later work questions the robustness of that specific effect; one study found it only with large group sizes (600 or 6,000). — [PMC3191503](https://pmc.ncbi.nlm.nih.gov/articles/PMC3191503)
- Apple, on describing data: "Avoid using subjective terms. Subjective words — like rapidly, gradually, and almost — communicate your interpretation of the data. To help people form their own interpretations, use actual values in your descriptions." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: "Maximize clarity in data descriptions by avoiding potentially ambiguous formats and abbreviations. For example, using 'June 6' is clearer than using '6/6'; similarly, spelling out '60 minutes' or '60 meters' is clearer than using the abbreviation '60m.'" — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Kivetz et al. and Nunes and Drèze both show that a display can change behaviour by changing perceived distance while real distance is unchanged ("illusionary goal progress"). — [Columbia Business School research page](https://business.columbia.edu/faculty/research/goal-gradient-hypothesis-resurrected-purchase-acceleration-illusionary-goal)

### Inferences
- A degree plan's uncertainty is mostly conditional, not probabilistic: the outcome is X if a named person approves a named thing, otherwise Y. The literature on vague probability words says not to compress that into "likely" or "on track"; the low trust cost of stated uncertainty says it is safe to show both outcomes.
- The least ambiguous form the evidence supports is two concrete end points with the condition named: the term the student finishes under what is already granted, and the term under the best case, with the specific approvals that separate them. A blended figure ("≈ 84%") hides which of the two worlds it describes.
- "≈ 92%" carries two digits of precision for an estimate built on unapproved assumptions. Apple's "use actual values" and the count findings in section 3 both point to whole, countable units (courses, semesters, approvals outstanding).
- Framing: "3 approvals from finishing a year early" (gain) and "without 3 approvals you finish a year later" (loss) are the same fact. Loss framing will push harder, and may push students to treat an ungranted petition as a default. For a high-stakes plan the neutral baseline is the granted case, with the best case presented as an addition.
- "Almost done" and "on track" are exactly the subjective terms Apple warns against; they are also the middle-range verbal expressions with the widest interpretation spread.

### Gaps
- I did not retrieve Joslyn and LeClerc's forecast experiments directly; they are cited only through the review.
- I found no research on communicating conditional (if-approved) outcomes specifically, as distinct from probabilistic ones.
- A statement seen in a search excerpt, that a numeric value's "suggested precision may be misleading" and that this is one reason senders prefer verbal phrasing, could not be tied to a specific paper and is not cited.
- No evidence found on how students interpret "≈" or "with plan" style qualifiers.

## 6. Timelines on narrow screens: vertical timeline/stepper, horizontal paging by period, Gantt on mobile; platform guidance

### Takeaway
Platform guidance favours vertical sequences on phones and treats horizontal movement as acceptable only for a short, ordered set of peer pages with visible position and a non-gesture alternative. Sideways-scrolling regions are discoverability and gesture-conflict risks. I found no credible guidance for Gantt-style charts on phones.

### Cited Findings
- Material Design's archived stepper guidance: vertical steppers "are designed for narrow screen sizes" and "are ideal for mobile"; they can be used on mobile as-is provided each step's content is responsive. — [Material Design (archive): Steppers](https://material.io/archive/guidelines/components/steppers.html)
- Steppers have been removed from the current Material Design guidelines; MUI notes they "are no longer documented in the Material Design guidelines" though the library still supports them. For compact mobile progress MUI's mobile stepper suggests dots "when the number of steps is not large." Treat the Material stepper guidance as legacy. — [MUI: Stepper](https://mui.com/material-ui/react-stepper/)
- NN/g, mobile carousels: "swipe ambiguity" means the same swipe can mean different things depending on exactly where it starts; in Safari a horizontal swipe from the left edge means Back. Partial mitigations are a page gutter (white space showing the carousel does not run to the screen edge) and visible arrows as an alternative; avoid carousels with too many items (excerpt). — [NN/g: Mobile Carousels](https://www.nngroup.com/articles/mobile-carousels/)
- NN/g, horizontal scrolling: on desktop it is "one of the few interactions that consistently generate negative responses from users," and even obvious cues for horizontal scrolling have weak information scent (excerpt; the article is mostly about desktop). — [NN/g: Horizontal Scrolling](https://www.nngroup.com/articles/horizontal-scrolling/)
- An accessibility practitioner's critique lists the risk that horizontal swiping triggers navigating away, among other problems with horizontal scrolling containers. — [Adrian Roselli, 2025](https://adrianroselli.com/2025/08/horizontal-scrolling-containers-are-not-a-content-strategy.html)
- A practitioner citing his own research reports users rarely engage with content hidden behind a swipe. Not independently verified. — [Carousels, swipers, sliders and usability](https://bechster.github.io/carousels-swipers-sliders-and-usability)
- Apple: "Use page controls to represent movement between an ordered list of pages. Page controls don't represent hierarchical or nonsequential page relationships." — [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls)
- Apple: "Although page controls can handle any number of pages, don't display too many. More than about 10 dots are hard to count at a glance. If your app needs to display more than 10 pages as peers, consider using a different arrangement, such as a grid, that lets people navigate the content in any order." — [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls)
- Apple allows one page in a page control to carry a distinct indicator (Weather marks the current location) but no more than two indicator images in total. — [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls)
- Apple (watchOS): vertical pagination with one clear purpose per page "is more effective than horizontal pagination or many levels of hierarchical navigation." — [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls)
- Apple: "Offer alternatives to gestures. Make sure your UI's core functionality is accessible through more than one type of physical interaction." and "Support simple gestures for common interactions." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Apple: "In a compact environment, maximize the width of the plot area to give people enough space to comfortably examine a chart." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)

### Inferences
- A degree has about 8 fall and spring semesters, fewer remaining, which sits inside Apple's "about 10" limit. Paging one semester per screen with a page control is within guidance; a free-scrolling strip of narrow columns is the pattern NN/g and Roselli warn about (hidden content, weak scent, edge-swipe conflict with Back).
- A vertical list of semesters (past collapsed, current marked, future expanded) uses the phone's native scroll axis, needs no discovery, works with Dynamic Type because rows can grow downward, and matches the legacy Material advice for narrow screens.
- Drag-and-drop between columns is a custom gesture inside a scroll view. Apple's "offer alternatives to gestures" means any such move needs a tap path as well (for example a "move to…" menu), and the tap path may be sufficient alone.
- Apple's distinct-indicator allowance gives a sanctioned way to mark "now" in a paged semester view.

### Gaps
- No reliable source found on Gantt charts on mobile; I am not citing vendor blog posts on the topic.
- Apple's sheets guidance (detents, when to use a sheet versus a pushed view) was not fetched and is not covered.
- NN/g's mobile carousel and horizontal scrolling findings are from search excerpts; the original articles could not be opened.
- No study found comparing a vertical timeline with horizontal paging for a plan of 6 to 10 periods on a phone.

## 7. Responsible gamification for a high-stakes real-world goal: where streaks, mascots, confetti and levels help or mislead; SDT

### Takeaway
The classroom and lab evidence on points, badges and leaderboards is mixed to negative for intrinsic motivation, with one semester-long study showing harm. What is supported is feedback that conveys real competence and leaves the choice with the student. I found no evidence on gamifying a degree specifically.

### Cited Findings
- Hanus and Fox (2015, Computers & Education), a longitudinal classroom study: students in the gamified course (leaderboard and badges) showed less motivation, satisfaction and empowerment over time than the non-gamified class, and lower final exam scores, which the authors link to reduced intrinsic motivation. — [ResearchGate record of the paper](https://www.researchgate.net/publication/265644737_Assessing_the_effects_of_gamification_in_the_classroom_A_longitudinal_study_on_intrinsic_motivation_social_comparison_satisfaction_effort_and_academic_performance)
- Sailer et al. (2017) is reported as finding that specific elements can satisfy psychological needs: badges, leaderboards and performance graphs positively affected competence-related need satisfaction (and, per one secondary source, autonomy), while avatars, meaningful stories and teammates affected social relatedness. Secondary reporting; direction differs from Hanus and Fox. — [University of Arizona ITLT article summarising the literature](https://journals.librarypublishing.arizona.edu/itlt/article/id/1487/)
- Mekler et al. (2017) is reported as finding that points, levels and leaderboards neither harmed nor enhanced intrinsic motivation, while raising output, i.e. they act as extrinsic incentives. Secondary reporting. — [University of Arizona ITLT article](https://journals.librarypublishing.arizona.edu/itlt/article/id/1487/)
- A 2026 study in BMC Psychology is summarised as noting that points, badges and leaderboards sometimes raise short-term participation but fail to produce stable intrinsic motivation. — [BMC Psychology, 2026](https://link.springer.com/article/10.1186/s40359-026-05046-8)
- "When Gamification Spoils Your Learning": a qualitative case study of Duolingo using nine years of forum posts and 15 interviews documents gamification misuse, where users pursue the game elements in ways that undermine learning. — [arXiv 2203.16175](https://arxiv.org/abs/2203.16175)
- Commentary grounded in self-determination theory argues external rewards can crowd out intrinsic interest and that a streak can shift from by-product to the main reason for opening the app; one essay describes the app as behaving like an anxious partner. Opinion pieces. — [The Decision Lab: Streak Creep](https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification); [Institute of Network Cultures, January 2026](https://networkcultures.org/blog/2026/01/19/baby-please-dont-break-the-streak/)
- A paper applying self-determination theory to gamification analyses leaderboards, badges and experience points in terms of the three needs: autonomy, competence and relatedness. — [DiGRA paper](https://dl.digra.org/index.php/dl/article/download/2773/2757/2817)
- Apple: "Be cautious with fast-moving and blinking animations," and when Reduce Motion is on, reduce "automatic and repetitive animations, including zooming, scaling, and peripheral motion." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Apple: "Minimize use of time-boxed interface elements. Views and controls that auto-dismiss on a timer can be problematic for people who need longer to process information." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- The progress principle's own caveat, per a secondary source: wins must be genuine and on meaningful work; trivial or fake wins can backfire. — [Cogn-IQ: Psychology of Small Wins](https://www.cogn-iq.org/blog/psychology-of-small-wins/)

### Inferences
- Sorting the mechanics by what SDT says they feed:
  - Competence, truthfully: marking a requirement group complete, a finished semester, a recorded advisor approval. These are real events with real meaning; acknowledging them is feedback, not decoration.
  - Autonomy: the student choosing among options, and the plan being theirs to change. A design that auto-builds and locks a plan trades autonomy for convenience.
  - Relatedness: the advisor is the real relationship in this domain; a mascot is a substitute for one.
  - Extrinsic only: streaks, points, levels, leaderboards. A degree offers nothing these can honestly count between registration periods, and Hanus and Fox is the closest evidence (a semester-long course) that they can hurt.
- Celebration is safest when tied to an irreversible, verified fact (a grade posted, a requirement Penn marks met). Confetti on a planned or unapproved state is the illusionary-progress effect applied to a decision where being wrong costs a semester.
- Levels or a path metaphor imply a single correct order. A degree has many valid orders and some hard prerequisites; a level display would be claiming more structure than exists.
- Social comparison (leaderboards) is the element most associated with harm in Hanus and Fox and has no legitimate role where students are on different degrees and timelines.

### Gaps
- No study found on gamification of degree completion, advising or course planning.
- I did not read Hanus and Fox, Sailer et al. or Mekler et al. in full; the three are reported from abstracts and secondary summaries, and their detailed designs and effect sizes are unverified here.
- No rigorous evidence found on mascots or on confetti and celebration animations specifically.
- No controlled evidence found that streaks help or harm long-horizon goals; the Duolingo evidence is qualitative and the rest is commentary.

## 8. Accessibility and legibility: colour not the only signal, Dynamic Type, VoiceOver summaries of charts, Reduce Motion

### Takeaway
Apple's guidance is specific and directly constrains the design choice: every chart needs a words-first summary, colour needs a second cue, text must survive at least 200 percent enlargement, gestures need a button alternative, and animation must degrade to fades. Designs built on small multi-colour rings, dense chips and sideways tables are the hardest to make comply; sentence-first designs comply almost for free.

### Cited Findings
- "Convey information with more than color alone… Offer visual indicators, like distinct shapes or icons, in addition to color to help people perceive differences in function and changes in state." Apple names red-green and blue-orange as especially difficult pairings. — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- In charts: "Avoid relying solely on color to differentiate between different pieces of data or communicate essential information in a chart… One way to supplement color is to use different shapes or patterns." Example: Health's blood-pressure chart uses two shapes as well as two colours. — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- "Aid comprehension by adding visual separation between contiguous areas of color," e.g. separators between segments of a stacked bar. — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- "Support larger text sizes… Ideally, give people the option to enlarge text by at least 200 percent," through Dynamic Type or custom UI. Default and minimum text sizes on iOS are 17 pt and 11 pt. — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Contrast: Accessibility Inspector uses WCAG AA values, 4.5:1 for text up to 17 pt and 3:1 for 18 pt and for bold text; check both light and dark appearances. — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Control size: default 44×44 pt on iOS, minimum 28×28 pt, with about 12 pt of padding around bezelled elements and about 24 pt around unbezelled ones. — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- "Make every chart in your app accessible… it's essential to support VoiceOver." Swift Charts provides a default Audio Graphs implementation and an accessibility element per mark; "If you don't use Audio Graphs, you need to provide an overview of the chart's structure and purpose." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- "Write descriptions that help people understand what a chart does before they view it… especially important for VoiceOver users and those with certain types of cognitive disabilities because they rely on your descriptions to understand the purpose and primary message of your chart before they decide to investigate it further." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- "Write accessibility labels that support the purpose of your chart": Maps summarises elevation over a portion of a route because the purpose is a sense of the terrain; Health labels every bar because the purpose is the actual step count. "It's rarely enough to merely report a data value unless you also include context." "Describe what the chart's details represent, not what they look like." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Audio Graphs lets VoiceOver build an audible representation of a chart from an `AXChartDescriptor`, with a title and summary; users can scrub through the data. — [Apple developer documentation: Audio graphs](https://developer.apple.com/documentation/accessibility/audio-graphs); [WWDC21: Bring accessibility to charts in your app](https://developer.apple.com/videos/play/wwdc2021/10122)
- "Help people notice important changes in a chart… Animating such changes can help people notice them, but you need to highlight the changes in other ways, too, to ensure that VoiceOver users and people who turn off animations know about them." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Reduce Motion: reduce "automatic and repetitive animations, including zooming, scaling, and peripheral motion"; tighten springs, track animations to gestures, avoid z-axis depth animation, replace x/y/z transitions with fades, avoid animating into and out of blurs. — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- "Make it easy for everyone to interact with a chart. Sometimes, chart marks are too small to target with a finger… consider expanding the hit target to include the entire plot area." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- "Offer alternatives to gestures… if you use a swipe gesture to dismiss a view, also make a button available." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- "Minimize use of time-boxed interface elements… Prefer dismissing views with an explicit action." — [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### Inferences
- A sentence that states the result is at once the visible headline, the VoiceOver label and the content that scales with Dynamic Type. A design whose primary element is that sentence satisfies most of this section before any chart work.
- Layered arcs in one ring distinguished by hue and opacity (done, in progress, planned, if-approved) depend on colour and on fine opacity differences; each layer would need a second cue (pattern, position or a labelled legend with counts) to comply.
- Fixed-width columns and chips with 9–11 pt text do not survive 200 percent text; vertical lists do.
- Drag between semesters and swipe actions need tap equivalents; a conversational edit ("move X to fall") is itself a valid non-gesture alternative.
- If a chat changes the plan, the change must be announced in a non-animated, non-visual way as well (Apple's "highlight the changes in other ways").
- Per Apple's Maps-versus-Health distinction, the VoiceOver label for a degree summary should match the screen's purpose: if the purpose is "how much is left and is the plan sound," the label is that summary, not a reading of each arc.

### Gaps
- Apple's Typography page (the Dynamic Type detail moved there in March 2025) and its VoiceOver page were not fetched; only the Accessibility and Charts pages were read in full.
- No independent (non-Apple) study found on VoiceOver users' comprehension of ring or progress charts.

## 9. Reducing a multi-degree, multi-requirement data set to something glanceable: inverted pyramid, headline-first, the 5-second test

### Takeaway
Lead with the conclusion in a few words, then supporting detail in descending importance, so a student who stops at any point still has the main fact. The five-second test is a useful check, but NN/g's own description limits what it shows: five seconds is enough for an impression, not for reading, so the headline has to be very short and visually dominant.

### Cited Findings
- NN/g on the inverted pyramid: the most important information, "or what might even be considered the conclusion," comes first, followed by progressively smaller details; readers "can stop reading at any point on the page and still come away with the main point" (excerpt). — [NN/g: Inverted Pyramid: Writing for Comprehension](https://www.nngroup.com/articles/inverted-pyramid/)
- NN/g's rationale: users do not read carefully online and have little patience for content that does not engage them; the first sentence of every paragraph should be the most important, and headlines and subheadings should be descriptive (excerpt). — [NN/g: Inverted Pyramid](https://www.nngroup.com/articles/inverted-pyramid/)
- NN/g's earlier summary: "start with the conclusion. Many users won't see anything else" (excerpt via NN/g's writing-for-the-web topic listing). — [NN/g: Writing for the Web topic](https://www.nngroup.com/topic/writing-web/?page=7)
- NN/g on the five-second test: a first-impression test in which the stimulus is shown for five seconds (or another short period); that is too short for reading copy but enough to form an impression of the visual style; participants should not be told the exposure is only five seconds, because that prompts memorising (excerpt, partly via a secondary source quoting NN/g). — [NN/g: Testing Visual Design](https://www.nngroup.com/articles/testing-visual-design/)
- Apple: "Establish a consistent visual hierarchy that helps communicate the relative importance of various chart elements." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: an effective chart "highlights a few key pieces of information in a dataset." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple's Weather example: a title and subtitle state the next-hour precipitation in plain language so people get "the most important information without requiring them to examine the details of the chart." — [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts)
- Apple: "More than about 10 dots are hard to count at a glance," a direct statement of a glance limit for discrete items. — [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls)
- NN/g: what is on the initial display signals importance (excerpt). — [NN/g: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)

### Inferences
- The inverted pyramid gives an ordering test for any candidate design: cut the screen at any height and ask whether what remains above the cut is still true and still the most important thing. A screen that opens with tabs or a legend fails at the first cut.
- For a dual-degree student the conclusion is probably one fact about the whole situation (when they finish and what stands in the way), with per-degree detail as the second tier. Two equal rings present two conclusions and leave the synthesis to the student.
- Because five seconds does not allow reading, a practical version of the test for this screen is: after five seconds, can the student say (1) roughly how much is left, (2) when they finish, (3) whether something needs their action. Anything else is second-tier by definition.
- The glance limit of about ten discrete items suggests a requirement-level icon array or list should show groups (fewer than ten) at the top level, not every course.
- The supporting detail should answer the next question the headline provokes, in order: what is left, when it happens, what needs someone's approval. That ordering is also a drill-down path.

### Gaps
- Stephen Few's definition of a dashboard ("at a glance", single screen) and smartwatch glanceability studies were searched for and not retrieved; they are not cited.
- I found no source that applies the inverted pyramid to app screens as opposed to written content; the transfer is an inference, supported only by Apple's "summarize the main message" guidance.
- NN/g's five-second-test sample-size guidance (5–6 participants) appeared only in a vendor guide and was not confirmed on NN/g's page.

## 10. Decision rules for choosing between (a) a guided path, (b) a headline screen with drill-down, (c) a conversational/assistant-led design, (d) a visual map/timeline

### Takeaway
The evidence does not pick one direction outright; it says which user question each direction answers well and what each must not be allowed to do. The strongest and most general support is for a words-first headline with detail on request; the other three are best supported as the second layer or as the way the plan gets made.

### Cited Findings
- Every rule below rests on findings cited in sections 1–9; the principal sources are [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts), [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Apple HIG: Page controls](https://developer.apple.com/design/human-interface-guidelines/page-controls), [NN/g: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/), [NN/g: Inverted Pyramid](https://www.nngroup.com/articles/inverted-pyramid/), [NN/g: Accordion Editing and Apple Picking](https://www.nngroup.com/articles/accordion-editing-apple-picking/), [Nielsen: The Articulation Barrier](https://jakobnielsenphd.substack.com/p/prompt-driven-ai-ux-hurts-usability), [Kivetz et al. 2006](https://business.columbia.edu/faculty/research/goal-gradient-hypothesis-resurrected-purchase-acceleration-illusionary-goal), [Bonezzi et al. 2011](https://pubmed.ncbi.nlm.nih.gov/21474842/), [Huang et al. 2017](https://www.gsb.stanford.edu/insights/focus-small-steps-first-then-shift-larger-goal), [Koo and Fishbach via Frontiers review](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2019.02353/full), [van der Bles et al. 2020](https://pubmed.ncbi.nlm.nih.gov/32205438/), [Tversky and Kahneman 1981](https://www.gwern.net/doc/psychology/1981-tversky.pdf), [Hanus and Fox 2015](https://www.researchgate.net/publication/265644737_Assessing_the_effects_of_gamification_in_the_classroom_A_longitudinal_study_on_intrinsic_motivation_social_comparison_satisfaction_effort_and_academic_performance).

### Inferences
Rules that apply whichever direction is chosen:
1. **Sentence before chart.** The first thing on screen is a short statement of the conclusion in countable units. Any chart supports it and is never the only carrier of a fact. (Apple "summarize the main message"; NN/g inverted pyramid; section 3 on counts.)
2. **Nothing critical behind an interaction.** If unapproved items change the finish date, that fact is on the first screen. (Apple Charts.)
3. **Count what is granted; name what is not.** The baseline is the outcome under what is already approved. The best case is shown as a separate, labelled outcome with its conditions listed. No blended estimate, no "≈" percent. (Sections 5 and 2.)
4. **Flip the frame with progress.** Early: what is done and the next milestone. Past halfway: what is left. Always offer a nearer finish line than graduation. (Koo and Fishbach; Bonezzi; Huang.)
5. **Celebrate only verified facts.** No streaks, points, levels or comparison with other students. (Section 7.)
6. **Every gesture has a tap path; every colour has a second cue; every screen survives 200 percent text.** (Section 8.)

Rules for choosing a direction:
- **Choose (b), headline with drill-down, as the resting state** when the screen is opened more often to check than to change. It is the only direction with direct platform guidance behind it, it complies with accessibility guidance at least cost, and it works when the student's plan is already made. It is weakest for a student who has no plan yet: a headline cannot say when they finish if nothing is planned.
- **Choose (a), a guided path, for the moments that are a sequence done once**: first setup, building a plan, resolving advisor questions. Staged disclosure fits because everyone needs every step and order matters. Do not make it the resting state: a returning student should not walk steps to see a fact, and a path implies one correct order that a degree does not have.
- **Choose (c), assistant-led, only as the way a plan is made or changed, with the plan as a visible, editable object.** Good fit: stating constraints and goals in words. Poor fit: inspecting, comparing and nudging a structured plan through text. Require that the assistant proposes first (no blank prompt), that each change lands on the plan where it can be seen and undone, and that the same change is possible without chat. Do not choose it as the primary surface if the answer to "how am I doing" would then depend on the student starting a conversation.
- **Choose (d), a map or timeline, as the second layer that answers "when,"** and build it on the vertical axis or as one period per page with a position indicator (fewer than about ten periods). Avoid a free sideways-scrolling strip and avoid drag as the only way to move things. A timeline is a poor first screen for a student whose real question is "how much is left" and a good one for a student actively arranging semesters.

A short test to run on any candidate, in order:
1. Cover everything below the first third of the screen. Is what is left true, and is it the most important fact?
2. After five seconds, can a student say how much is left, when they finish, and whether anything needs their action?
3. Read the screen aloud as VoiceOver would. Is the first thing spoken the conclusion?
4. Set text to the largest accessibility size. Does the headline still fit and does anything truncate to meaninglessness?
5. Find every number on the screen. Could each be replaced by a count of real things (courses, semesters, approvals)? If not, why is it there?
6. Find every place the screen shows something not yet granted. Is it visibly different, in a way that does not depend on colour alone, and is the condition named?

### Gaps
- None of these rules has been tested with students on this screen. They are a synthesis of general evidence; the one-screen five-second check and a first-click test on two or three candidates would be the cheapest way to replace inference with evidence.
- The evidence base is thin exactly where the choice is hardest: no comparative study of headline, guided, conversational and timeline designs for long-horizon planning was found.
