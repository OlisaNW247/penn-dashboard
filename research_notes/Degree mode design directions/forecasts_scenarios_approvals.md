# forecasts_scenarios_approvals

> Method note for the report writer. `WebFetch` was blocked in this session (the three hosts tried, `github.blog`, `mucollective.northwestern.edu` and `news.miami.edu`, all failed DNS resolution because they are outside the session's allowed network domains). Everything below therefore comes from web-search result summaries, not from reading the full pages. Wording in quotation marks is as the search tool returned it and should be treated as close paraphrase unless checked against the page. Where the search summary did not say which of several URLs a statement came from, that is flagged. Nothing here was observed first-hand in the apps.

## 1. Route alternatives and ETAs (Google Maps, Apple Maps, Citymapper, Waze)

### Takeaway
Navigation apps show exactly one primary answer (one highlighted route and one arrival time) and demote every alternative to a visually quieter secondary that carries only its difference from the primary ("N minutes slower/faster") plus a short condition label (tolls, eco). The recurring complaints are about alternatives that are surfaced unprompted, that are not actually better, or whose time deltas turn out to be wrong.

### Cited Findings
- Google Maps highlights the chosen/fastest route (usually blue) and draws alternatives in gray with their slightly longer durations; "current routes are blue, others are gray". The search summary did not pin this to a single URL; the candidates returned were a how-to guide and a Google support thread — [Alphr](https://www.alphr.com/google-maps-how-to-change-route/); [Google Maps Help thread](https://support.google.com/maps/thread/18183457/alternate-routes-limited-to-1-or-2-the-route-option-i-used-to-have-is-no-longer?hl=en)
- During navigation Google Maps shows alternatives that are marginally slower or faster than the current route. Users object to seeing slower ones: one commenter has no interest in a route that is "18 minutes slower" mid-route, and another asks for alternatives only when they save time — [Android Central](https://androidcentral.com/apps-software/google-maps-faster-route-available-sucks)
- Users reported misleading time deltas on alternates, for example alternatives claimed to be 20 to 30 minutes faster when the driver was 10 minutes from the destination — [PiunikaWeb](https://piunikaweb.com/blog/google-maps-showing-misleading-times-on-alternate-routes)
- A 2025 report says the in-drive alternate-route suggestions had stopped appearing for some users, and it was treated as a regression worth reporting (i.e. users rely on them) — [9to5Google](https://9to5google.com/2025/05/16/google-maps-alternate-routes-broken/); [Android Authority](https://www.androidauthority.com/google-maps-alternate-route-suggestions-missing-3558948)
- Google Maps has made an eco-friendly route the default in some cases, which drew criticism that the default is no longer the fastest — [Tom's Guide](https://www.tomsguide.com/computing/why-google-maps-keeps-sending-you-the-long-way-and-how-to-stop-it)
- A design critique of the eco default argues the user should set how many extra minutes they accept, and that the design "won't be misleading as the fastest option is always there as a secondary" — [Medium, Gergo Kondor](https://medium.com/@gergokondor/ecofriendly-case-in-google-maps-915d73987e47)
- A former Google Maps UX researcher publicly explained why a highly requested routing feature "doesn't make sense"; the search result did not include the argument itself — [autoevolution](https://autoevolution.com/news/google-maps-researcher-explains-why-a-highly-requested-feature-doesn-t-make-sense-235615.html)
- Google Maps adds up estimated toll totals for a route so the cost of the condition is a number, not just a flag — [MacRumors](https://www.macrumors.com/2022/06/14/google-maps-now-estimates-toll-charges/)
- Apple Maps: "If alternate routes appear, you can tap one on the map to take it (or tap Go next to its description in the route card)" — each alternative is a card with its own Go button — [Apple iPhone User Guide](https://support.apple.com/en-asia/guide/iphone/iphcc4416141/14.0/ios)
- Apple Maps with "avoid tolls" on: "The first route that Maps offers will now avoid tolls. It will likely still give you options for routes with tolls below that." The preference reorders the list; it does not remove the conditional options — [SlashGear](https://www.slashgear.com/1823784/how-to-avoid-toll-roads-apple-maps/)
- Apple's App Store copy: Maps "automatically offer[s] the fastest route" and lets users avoid highways or tolls — [App Store listing](https://apps.apple.com/ae/app/apple-maps/id915056765)
- Users complain that Apple Maps does not show toll cost ("Total toll costs, even rough estimations, aren't represented transparently in the ways they are within competing mapping apps") — [Apple Support Communities](https://discussions.apple.com/thread/256147966)
- Citymapper shows several route options side by side "with clear information about travel time, transport mode, ease, and total cost", and marks which option is fastest — [Pratt IXD design critique](https://ixd.prattsi.org/2026/09/design-critique-citymapper/)
- Citymapper "improved the app to show you all the departure & arrival times in the next hour for each trip you picked", so the user compares concrete arrival times, not durations — [Citymapper news](https://citymapper.com/news/2571/)
- Citymapper ranks results with a model and personalises the order over time; priorities can be changed in Preferences — [Citymapper news](https://citymapper.com/news/2838/citymapper-now-uses-ai-powers-to-help-you-choose-the-best-route)
- A review notes Citymapper's live arrival time for one connection was wrong, i.e. the comparison is only as good as the estimates — [Econsultancy](https://econsultancy.com/six-features-to-appreciate-about-citymappers-ux/)

### Inferences
- The shared grammar is: one headline time; alternatives expressed as a delta against it; a one- or two-word reason for the difference (tolls, eco, traffic); a single tap to switch. Nobody shows two equal-weight routes.
- The primary is the route the user is on or can take with no further decision. A conditional alternative ("faster, but tolls") sits below or beside it and names its cost in the same breath as its benefit.
- User anger concentrates on three things: alternatives that are worse being offered anyway, a default that is not what the user believes it is (eco instead of fastest), and deltas that prove wrong. All three are trust failures of the secondary option, not of the primary.
- A preference (avoid tolls) changes which route is first, and the others stay visible lower down. That is a close analogue of "granted plan first, if-approved plan below".

### Gaps
- No first-party Google, Apple or Citymapper design write-up was found that explains the primary/secondary decision or the exact label wording ("fastest", "tolls", "similar ETA"). The label wording on route cards is unverified.
- Nothing usable was found on Waze.
- The blue/gray convention is well known, but the search did not return an official Google page stating it.

## 2. Live timelines of a multi-step journey (Flighty, package tracking, Uber/Lyft, Domino's)

### Takeaway
A linear tracker with a "you are here" marker works because it answers the anxious question ("where is it and what happens next?") at a glance, shows that work is being done, and reduces the urge to ask a human. Its value collapses when the stages shown do not match reality.

### Cited Findings
- Domino's built its tracker around 2008 because customers found waiting stressful after the 30-minute guarantee ended; NPR describes it as a status page meant to ease anxiety — [NPR Planet Money transcript](https://www.npr.org/transcripts/nx-s1-5896338)
- Domino's was already tracking order status internally, so it could expose that progress to customers without changing operations — [The Hustle](https://thehustle.co/originals/how-the-dominos-pizza-tracker-conquered-the-business-world)
- The psychology is called the "labor illusion": seeing evidence of work in progress makes people trust and value the wait — [Entrepreneur](https://www.entrepreneur.com/buying-a-franchise/how-dominos-20-year-old-pizza-tracker-shaped-nearly-every-delivery-app-you-use-today)
- Buell's research (secondary description): a progress display that simulated effort on a search that actually returned instantly raised perceived value; a 2017 Management Science follow-up by Buell, Tsay and Joachimsthaler extended operational transparency to restaurants. This is from a non-academic essay and the figures were not checked against the papers — [Atticus Li blog](https://atticusli.com/blog/posts/labor-illusion-operational-transparency-ryan-buell-behavioral-economics/)
- NPR's 2026 reporting says many such trackers are now not accurate — [NPR](https://www.npr.org/2026/09/18/nx-s1-5896338/how-a-pizza-app-changed-our-relationship-with-waiting)
- NN/g, "Status Trackers and Progress Updates: 16 Design Guidelines": status trackers are pull, progress updates are push; offer both, because a tracker alone makes users keep refreshing; the tracker should prioritise information related to the latest update; and "users lose trust in your status tracker, especially if your employees tell them the status tracker is wrong" — [NN/g](https://www.nngroup.com/articles/status-tracker-progress-update/)
- NN/g has a companion video, "Status Trackers: 6 Guidelines for Discoverability and Clarity" — [NN/g video](https://www.nngroup.com/videos/status-trackers/)
- For multi-day or multi-week processes NN/g says organisations use status trackers together with progress updates by email or SMS — [NN/g, virtual queues](https://www.nngroup.com/articles/virtual-queue-best-practices/)
- Uber's Live Activity: the team ranked what a rider needs; first the driver's name and photo, second overall trip progress drawn as a bar "whose final stretch covers the last two minutes of the wait, so the bar stays readable whatever the total wait is". The surface is glanced at for a few seconds, and the Dynamic Island forced an even more concise design. The information priority was "the main anchor point when evaluating and justifying the scope of a change" — [Uber Engineering blog](https://www.uber.com/blog/live-activity-on-ios/)
- Uber on the Lock Screen shows vehicle details, the latest ETA and trip status; the Apple Watch version later added a progress circle and drop-off time — [MacRumors](https://www.macrumors.com/2023/02/22/uber-live-activities-support-worldwide/)
- Flighty: founder Ryan Jones's stated goal, quoted by Apple, is "We want Flighty to work so well that it feels almost boringly obvious". The app puts key information first, borrows airport design conventions, was conceived during a long flight delay, and has to shine "when things go awry". The team makes 20 concept ideas per feature to avoid falling back on old ones — [Apple Developer, Behind the Design: Flighty](https://developer.apple.com/news/?id=970ncww4); [App Store, Apple Design Award winners](https://apps.apple.com/in/story/id1687371285)
- Flighty's design is built on the airport departure board as a real-world analogy (third-party guide, unofficial) — [Blake Crosley design guide](https://blakecrosley.com/guides/design/flighty)
- Flighty predicts delays from late-arriving aircraft, by its own claim up to 6 hours before the airline says anything; MacRumors reports the 2024 update predicts delays "hours in advance" — [Flighty](https://flighty.com/); [MacRumors](https://www.macrumors.com/2024/08/06/flighty-update-flight-delays/)
- Lemonade's claim view shows "when we received your claim, whether more information is needed, and when your claim is being reviewed" — a three-state tracker in plain words — [Lemonade](https://www.lemonade.com/renters/explained/how-to-file-a-renters-insurance-claim)

### Inferences
- The trackers that people praise share four properties: a fixed, small number of named stages; one marked current position; one predicted end time that updates; and a statement of what is needed next (and from whom).
- Uber's "last stretch is always the final two minutes" is a deliberate distortion of scale to keep the end of the journey legible. Time-proportional accuracy was given up for readability.
- Flighty's contribution is forecasting the change before the official source does, and saying so in the same row as the official time. That is "scheduled 14:05, now expected 14:50" — two times, one primary, one crossed out or secondary.
- Trackers reduce support contact only when accurate; an inaccurate tracker is worse than none (NN/g; NPR).

### Gaps
- No design write-ups were found for the Shop app, UPS, FedEx or Amazon tracking, or for Lyft.
- The Buell papers themselves were not read; the findings above are second-hand.
- Flighty's own timeline screen (the vertical gate-to-gate timeline) was not documented by any source returned; the description of its layout here is limited to Apple's and a third party's words.

## 3. Money goals and projections (Monzo, YNAB, Copilot, Wealthfront, Betterment, Schwab, Ally)

### Takeaway
Consumer finance apps reduce a simulation to a binary status ("on track" / "off track") anchored on the median outcome, add one sentence of advice for getting back on track, and offer the range or probability only as a second layer. The research on ranges is cautionary: cones and bands are widely misread as hard boundaries.

### Cited Findings
- Betterment tells the user whether they will reach the goal's target amount "if there is average market performance", and "If a goal is off track, we'll provide advice for bringing the goal back on track" — [Betterment help](https://www.betterment.com/help/off-track-goal)
- Betterment's disclosure has a section titled "Savings Goal Status: On Track Or Off Track" and describes the forecaster graph (net of fees; grouped goals get one combined projection) — [Betterment legal](https://betterment.com/legal/goal-projection)
- Ally's goal tracker: the goal is "off track when the final projected value for the 50th percentile is less than the goal target" — the status is a rule on the median of a Monte Carlo run — [Ally Invest methodology](https://www.ally.com/docs/invest/monte-carlo-methodology)
- Schwab's Goal Tracker runs many simulations and expresses the result as a likelihood, for example a 50% likelihood of outperforming the average-market projection — [Schwab](https://www.schwab.com/automated-investing/goal-tracker)
- YNAB: the product "will prompt you to assign a certain amount each month to stay on track to meet the target amount"; progress bars are segmented by the target's cadence (four or more sections for a weekly target); red in a bar means act now ("anytime you see red in your progress bar, it's time to move money accordingly"); the Home tab sums everything not yet funded into a single "Underfunded" figure — [YNAB progress bars guide](https://support.ynab.com/en_us/progress-bars-a-guide-SkDEhot09.md); [YNAB targets guide](https://support.ynab.com/en_us/how-to-use-targets-rk5kkI9ks.md); [YNAB At Home](https://support.ynab.com/en_us/spotlight-BkdHBZUokg.md)
- YNAB shipped progress bars turned off by default for existing users, as a deliberate response to how people react to design change — [YNAB what's new](https://ynab.com/whats-new/noticed-a-change-to-your-progress-bars)
- Wealthfront Path was "designed specifically for use on a mobile touchscreen", with retirement age, savings and spending adjustable by sliders; it is meant "to allow you to explore what's possible and dream up many different scenarios to find the best path for you" — [Wealthfront, Introducing Path](https://blog.wealthfront.com/introducing-path/)
- Wealthfront: "move your slider to save more for retirement and you immediately see the impact on your ability to afford a new home"; Social Security is a three-way toggle (100%, 50% or 0% of estimated benefits) — [Wealthfront calculator comparison](https://www.wealthfront.com/blog/comparing-wealthfront-personal-finance-calculator/); [Wealthfront support](https://support.wealthfront.com/hc/en-us/articles/115000627263-What-inputs-can-I-change-for-my-retirement-goal)
- Hurricane cone: a University of Miami survey of 2,847 Florida residents found almost half presumed regions outside the cone were out of harm's way, and 40% believed the cone showed where damage would occur — [University of Miami News](https://news.miami.edu/stories/2022/11/that-uncanny-coneresearchers-want-to-erase-the-uncertainty.html)
- A NOAA-commissioned literature review lists the standard misreadings of the cone: reading it as the storm's size or intensity, treating its edge as the boundary of the impact zone, and believing it conveys certainty rather than uncertainty — [NOAA repository](https://repository.library.noaa.gov/view/noaa/29111/noaa_29111_DS1.pdf); [NHC library literature review](https://www.aoml.noaa.gov/general/lib/lib1/nhclib/Bibliographies/Cone%20of%20Uncertainty%20Literature%20Review_4_10_19%20%281%29%20%281%29.pdf)
- The same misreadings were documented after the 2004 Florida hurricanes — [Yale Program on Climate Change Communication (2007 paper)](https://climatecommunication.yale.edu/wp-content/uploads/2016/02/2007_05_Misinterpretations-of-the-%E2%80%9CCone-of-Uncertainty%E2%80%9D-in-Florida.pdf)
- Explaining the cone's conventions (a wider cone means more uncertainty about the track) changed viewers' stated beliefs, but a minority still gave estimates consistent with the misconceptions. The search summary attributed this to Hegarty and Boone and did not say which returned URL carried it; the likeliest is the APA spotlight — [APA journals spotlight](https://www.apa.org/pubs/highlights/spotlight/issue-155)
- Colorado State psychology researchers proposed replacing the cone with a different tool for visualising hurricane danger — [Colorado State University](https://natsci.source.colostate.edu/2021/07/12/)
- Fan charts draw ranges of possible future values around a central line, widening with the horizon; the Bank of England's version uses 30, 60 and 90 percent intervals — [Wikipedia, Fan chart](https://en.wikipedia.org/wiki/Fan_chart_(time_series))
- Spiegelhalter reports that a Bank-style fan adapted as "fuzzy fans" for migration statistics is "one which we have found to be comprehensible and attractive" (a practitioner's observation, not a controlled study) — [Understanding Uncertainty](https://understandinguncertainty.org/visualising-uncertainty)
- Spiegelhalter, Pearson and Short's 2011 Science review covers icon arrays, fan charts and related forms for lay audiences — [PubMed](https://pubmed.ncbi.nlm.nih.gov/21903802/); [PDF copy](https://www.stat.berkeley.edu/~aldous/157/Papers/spiegelhalter_visualizing.pdf)

### Inferences
- The finance pattern has three layers, in this order: a word (on track / off track), a single number with a date, and only then a chart or range. The word is computed from the median; the range exists but is not the headline.
- "Off track" is always paired with what to do about it. A status with no next action is not used.
- The cone evidence says that a shaded region invites a boundary reading: people take "inside the shape" as "will happen" and "outside" as "won't". A faded arc on a ring is the same kind of object: a region whose edge can be read as a promise.
- A ring or band cannot say why the second outcome is conditional. The finance apps that handle conditions well (Wealthfront's Social Security toggle) make the condition an explicit, named control with discrete states, not a shade of colour.

### Gaps
- Nothing was found on Monzo pots/goals, Copilot or Robinhood.
- No source confirmed whether Wealthfront Path draws a range or confidence band; the sources describe point projections that update as sliders move.
- No controlled study of lay comprehension of fan charts specifically was retrieved; the fan-chart evidence here is descriptive plus Spiegelhalter's practitioner remark.
- The Miami survey figures come from a university news release, not the paper.

## 4. Timelines and roadmaps on narrow screens (Linear, TripIt, calendars, Notion, Things/Todoist)

### Takeaway
On a phone the evidence, such as it is, favours a vertical, single-column timeline that scrolls in the natural direction and gives each period a full-width row; horizontal timelines are kept for wide screens. The sources are vendor documentation and design-system guidance, not comparative research.

### Cited Findings
- Flourish: "With long horizontal timelines, you may notice that your events stretch too much, which makes the content harder to read on smaller screens" — [Flourish help](https://helpcenter.flourish.studio/hc/en-us/articles/8761591366031-How-to-adjust-your-horizontal-timeline-for-mobile)
- SAP Fiori: "For size S (smartphone), we highly recommend using the single-sided layout combined with narrow containers"; the double-sided layout is for when there is room — [SAP Fiori design guidelines](https://www.sap.com/design-system/fiori-design-web/v1-120/ui-elements/timeline/usage)
- Office Timeline (vendor blog, opinion): vertical timelines "feel right at home on phones and tablets. Think about how you use your phone - you scroll up and down, not sideways"; each event gets its own horizontal space so descriptions do not crowd neighbours — [Office Timeline](https://www.officetimeline.com/timeline/types/vertical)
- Syncfusion's timeline component defaults to vertical and says "The horizontal layout works particularly well on desktop screens and wide containers" — [Syncfusion docs](https://ej2.syncfusion.com/react/documentation/timeline/orientations)
- A container-query demo shows the common responsive pattern: "A timeline component that shifts from compact vertical to a fully horizontal layout based on the container width" — [Ahmad Shadeed lab](https://lab.ishadeed.com/container-queries/timeline/)
- A user report of the failure mode: "In the mobile device the horizontal layout for the timeline is very small" — [ActivityWatch forum](https://forum.activitywatch.net/t/vertical-view-for-timeline/2594)

### Inferences
- The existing degree screen's sideways-scrolling column table and its "full view" grid are both horizontal-first layouts; the guidance above is uniformly that a phone timeline should be a vertical list of periods, each a full-width row.
- A vertical list also gives each semester room for a status word and a condition ("needs approval"), which a 168-point column does not.

### Gaps
- No sources were found for Linear's roadmap, TripIt's itinerary, Apple Calendar, Fantastical, Notion's timeline, Things or Todoist's "Upcoming" view. Their layouts are not documented here and should not be asserted from these notes.
- No study comparing comprehension or task completion between vertical and horizontal timelines on phones was found.

## 5. Approval, dependency and "blocked on someone else" states (GitHub, Lemonade, TurboTax, DocuSign, application trackers)

### Takeaway
Products that depend on another person's decision show the blocked state as a short, countable requirement list next to the outcome it blocks ("1 review required"), name who is being waited on, and keep "waiting on them" visibly separate from "waiting on you". The most-requested improvement in these products is naming the specific person or item that is holding things up.

### Cited Findings
- GitHub's redesigned pull-request merge box (public preview December 2024, default February 2025, generally available March 2025) was meant to help users "understand the state of your pull request and get it merged faster"; the announcement's own screenshot shows "1 review is required" above a list of status checks, some failing — [GitHub changelog, Dec 2024](https://github.blog/changelog/2024-12-03-improved-pull-request-merge-experience-now-in-public-preview); [GitHub changelog, GA](https://github.blog/changelog/2025-03-04-improved-pull-request-merge-experience-is-now-generally-available/)
- A later GitHub post describes a new pull-request overview that moves the merge box higher, shrinks it to show the same information "in less than half the space", and adds a compact readiness summary highlighting checks and the next available actions. The URL of this post carries a date (2026-12-05) later than the day of this research (2026-11-27), so the date is suspect and the post should be verified before being cited — [GitHub changelog](https://github.blog/changelog/2026-12-05-new-pull-request-overview-page-in-public-preview/)
- GitHub semantics: by default a pull request can merge unless it conflicts; admins can require at least one approving review and required status checks — the "merge" button is the outcome and the requirements are a list in front of it — [GitHub Docs](https://docs.github.com/enterprise/2.9/user/articles/defining-the-mergeability-of-pull-requests)
- DocuSign's "Waiting for Others" bucket means the envelope has at least one recipient who has not completed their action; the recipient details show whether each outstanding person "Needs to Sign" or "Needs to View" — [DocuSign Community](https://community.docusign.com/esignature-171/my-documents-are-waiting-for-others-56)
- DocuSign users are confused when the bucket's label does not match reality (an envelope that was "completed and signed but status is waiting on others", caused by copy-only recipients being counted) — [DocuSign Community](https://community.docusign.com/esignature-171/completed-and-signed-but-status-is-waiting-on-others-5606)
- A DocuSign feature request asks for the agreement activity to show the name of the person whose signature is pending — [DocuSign Community ideas](https://community.docusign.com/ideas/agreement-activity-unable-to-show-the-name-of-the-person-whoses-signature-is-pending-25012)
- When someone signs outside DocuSign the envelope stays stuck in "waiting for others"; there is no clean way to record an answer given out of band — [DocuSign Community](https://community.docusign.com/esignature-171/how-to-remove-envelope-from-waiting-for-others-after-one-party-signed-outside-of-docusign-19943)
- Lemonade's claim status distinguishes "whether more information is needed" (your move) from "when your claim is being reviewed" (their move) — [Lemonade](https://www.lemonade.com/renters/explained/how-to-file-a-renters-insurance-claim)
- A vendor guide on approval UI: never leave a requester wondering where a submission stands; use a step-by-step progress bar for linear approvals and individual status cards per approver for parallel ones; use an inline pill such as "Awaiting: Jenna's approval" for lightweight cases; allow drill-down to see which sub-item is stalling. It claims a stage-based tracker cut "where's my approval?" queries by 40% in its first month (single vendor anecdote, unverified) — [ONES blog](https://ones.com/blog/?p=1123684); [ONES blog](https://ones.com/blog/?p=1130422)
- Enterprise precedent: PeopleSoft's Pending Approvals page lists requests needing attention oldest first, and a separate View Approval Status page lets the requester follow their own — [Oracle PeopleSoft docs](https://docs.oracle.com/en/applications/peoplesoft/human-capital-management/9.2.055/application-fundamentals/pending-approvals-page.html)

### Inferences
- GitHub's pattern is the closest structural match to "a better outcome is available if N things are approved": the outcome (merge) is one control; in front of it is a short list of requirements, each with its own state (passed, failed, pending, required); and a one-line summary counts them. The outcome is not drawn as partly achieved.
- The approval-pending state is expressed with words and counts ("1 review required"), not with a lighter tint of the success colour.
- Parallel, independent approvals (which is what several advisor questions are) are shown as one row per approval, each with its own state, not as a single progress bar.
- DocuSign shows the cost of having no way to record an answer that arrived outside the system: the item sits in "waiting" forever. An approval that is given in a conversation needs a place where the user records it themselves.
- Mislabelled waiting states (DocuSign's copy-only recipients) produce support questions. The label has to be literally true.

### Gaps
- Nothing was found on TurboTax's "needs attention" state, on mortgage or visa application trackers, or on how any consumer app lets a user self-record a third party's verbal yes/no. That last pattern (the user as the recorder of someone else's decision) appears to be uncommon; no direct precedent was found.
- The GitHub posts were not read in full (host blocked), so the grouping and ordering of checks inside the new merge box is not confirmed here.

## 6. "What if" toggles in consumer products (calculators, fare calendars, configurators, trade-in)

### Takeaway
The usability guidance is consistent: when users are exploring rather than committing, a control should change the headline result immediately with no submit step, and the control should be discrete and named when the choice is discrete. Defaults matter, because a misleading default reads as the product's claim.

### Cited Findings
- NN/g on sliders and knobs: "Critical to the usability of this control is that the system responds immediately with feedback"; sliders are a poor fit when results are slow to compute or load — [NN/g, sliders and knobs](https://www.nngroup.com/articles/sliders-knobs/)
- NN/g on calculators and estimators: show results immediately, because "when they are using a calculator, they are just exploring, not committing"; the article names "a mortgage calculator with a misleading default amount" as a pitfall, and treats trustworthiness as one of three criteria alongside usability and usefulness — [NN/g, recommendations calculator](https://www.nngroup.com/articles/recommendations-calculator/)
- Immediate updates remove the need for a separate "Submit" or "Apply" button — [Uxcel lesson on sliders](https://app.uxcel.com/lessons/sliders-best-practices-918/immediate-changes-8900)
- Wealthfront: moving a slider immediately shows the effect on a different goal ("you immediately see the impact on your ability to afford a new home"), and a discrete assumption (Social Security at 100%, 50% or 0%) is a toggle, not a slider — [Wealthfront blog](https://www.wealthfront.com/blog/comparing-wealthfront-personal-finance-calculator/); [Wealthfront support](https://support.wealthfront.com/hc/en-us/articles/115000627263-What-inputs-can-I-change-for-my-retirement-goal)
- Apple Maps' "avoid tolls" is a switch that reorders the route list, with the tolled routes still listed below — [SlashGear](https://www.slashgear.com/1823784/how-to-avoid-toll-roads-apple-maps/)
- A complaint about that switch: it is "all or nothing when it comes to highway and tolls", with no partial option — [Apple Support Communities](https://discussions.apple.com/thread/256147966)
- Citymapper lets the user compare departure and arrival times across the next hour for a chosen trip, i.e. a what-if on leaving time with concrete arrival times as the output — [Citymapper news](https://citymapper.com/news/2571/)

### Inferences
- A yes/no advisor answer is a discrete condition. The precedents treat discrete conditions as switches or segmented choices whose effect on one headline number is shown at once.
- The existing flow (answer, then tap "update plan", which opens a chat and makes a server request) is the opposite of the "no submit step" guidance. Whether instant recomputation is feasible is an engineering question outside these notes; the evidence only says users expect the number to move when the switch does.
- A what-if preview and a recorded fact are different things. None of the sources address a control that is both "try this assumption" and "record that it was granted"; conflating them is a risk the precedents do not resolve.

### Gaps
- Nothing was found on flight fare calendars, Tesla or other EV configurators, or Apple Trade In.
- No source addressed how to distinguish visually between a hypothetical toggle (exploration) and a confirmed fact (record).

## 7. Communicating uncertainty honestly to lay users

### Takeaway
Stating uncertainty plainly costs little trust, and a specific numeric or dated statement costs less than a vague verbal hedge. For conditional outcomes the research favours discrete, countable representations and explicit statements over shaded regions, which people read as boundaries.

### Cited Findings
- van der Bles, van der Linden, Freeman and Spiegelhalter (PNAS 2020; five experiments, total n = 5,780, including a preregistered national replication and a field experiment on BBC News): "whereas people do perceive greater uncertainty when it is communicated, we observed only a small decrease in trust in numbers and trustworthiness of the source, and mostly for verbal uncertainty communication" — [University of Groningen record](https://research.rug.nl/en/publications/the-effects-of-communicating-uncertainty-on-public-trust-in-facts/); [Cambridge repository](https://www.repository.cam.ac.uk/handle/1810/304699)
- Secondary summary of the same paper: a numeric range produced a small drop in trust in the number and no significant change in trust in the source; a verbal statement of uncertainty produced a larger drop in trust in the number and a small drop in trust in the source — [AI Impacts paper summary](https://blog.aiimpacts.org/p/paper-summary-the-effects-of-communicating)
- Kay, Kola, Hullman and Munson, "When(ish) is My Bus?" (CHI 2016): proposes quantile dotplots, a discrete representation of a continuous outcome built for small phone screens; in a controlled experiment they reduced the variance of probability estimates by about 1.15 times compared with density plots and helped users estimate more confidently — [MU Collective](https://mucollective.northwestern.edu/project/when-ish-is-my-bus); [UW Interactive Data Lab](https://idl.uw.edu/papers/when-ish-is-my-bus)
- Fernandes, Walls, Munson, Hullman and Kay (CHI 2018, best paper honourable mention): quantile dotplots and CDF plots both produced better transit decisions than textual uncertainty; decisions with 50-outcome quantile dotplots earned about 97% of optimal expected payoff — [MU Collective](https://mucollective.northwestern.edu/project/uncertainty-bus); [paper PDF](https://mucollective.northwestern.edu/files/2018-UncertainBusDecisions-CHI.pdf)
- Hurricane cone evidence (see section 3): nearly half of 2,847 surveyed Floridians read the outside of the cone as safe and 40% read the cone as the damage area — [University of Miami News](https://news.miami.edu/stories/2022/11/that-uncanny-coneresearchers-want-to-erase-the-uncertainty.html)
- Explaining a graphic's conventions shifts stated beliefs but does not eliminate the misreading for everyone — [APA journals spotlight](https://www.apa.org/pubs/highlights/spotlight/issue-155) (attribution to this URL unconfirmed, see section 3)
- NN/g: an inaccurate status tracker loses users' trust — [NN/g](https://www.nngroup.com/articles/status-tracker-progress-update/)
- Reported downside of over-eager forecasting: Google Maps alternates that claimed large savings which did not materialise drew complaints — [PiunikaWeb](https://piunikaweb.com/blog/google-maps-showing-misleading-times-on-alternate-routes)

### Inferences
- The degree case is not probabilistic uncertainty (a distribution); it is a small number of discrete conditional outcomes that depend on named decisions. The dotplot and fan-chart literature therefore applies only by analogy. Its transferable lesson is that discrete, countable marks are read more reliably than continuous shaded regions.
- The van der Bles result supports saying the condition out loud in specific terms: "Spring 2028 if the 6.5 cu load is approved" is a specific conditional statement, and that kind of statement costs less trust than a vague "possibly earlier".
- Legends and explanations help but do not fix a form that invites a wrong reading. If a faded arc is being misread as progress, adding a legend swatch ("if approved") is the weaker remedy; changing the form is the stronger one.
- The honest unit for a conditional outcome is the date plus its conditions in the same line, with the conditions countable ("needs 2 approvals").

### Gaps
- No NN/g article specifically on communicating uncertainty or conditional outcomes was retrieved.
- No study was found on lay comprehension of two-tone ("solid plus faded") progress rings or bars specifically. The claim that a faded arc is misread is an inference from the cone literature, not a measured result.
- No source addressed plain-language conditional phrasing ("X if Y") experimentally; the phrasing guidance is inferred from van der Bles (specific beats vague) and from the route-app convention.
- The Kay and Fernandes papers were not read in full (host blocked); figures are from the labs' own project pages as returned by search.

## Implications for showing a granted plan versus an if-approved plan

### Takeaway
Across maps, trackers, finance, code review and the uncertainty research, the conditional outcome is never drawn as a fainter version of the real one: there is one primary answer in plain words with a date, the alternative is stated as a difference from it together with its named conditions, and the conditions are a short list of items each with its own state and an owner.

### Cited Findings
- One primary route, alternatives as deltas with a condition label, one tap to switch — [Android Central](https://androidcentral.com/apps-software/google-maps-faster-route-available-sucks); [Apple iPhone User Guide](https://support.apple.com/en-asia/guide/iphone/iphcc4416141/14.0/ios); [SlashGear](https://www.slashgear.com/1823784/how-to-avoid-toll-roads-apple-maps/)
- A default that is not what the user assumes it is (eco route instead of fastest) causes distrust; keeping the other option visible as a secondary is the proposed remedy — [Tom's Guide](https://www.tomsguide.com/computing/why-google-maps-keeps-sending-you-the-long-way-and-how-to-stop-it); [Medium, Gergo Kondor](https://medium.com/@gergokondor/ecofriendly-case-in-google-maps-915d73987e47)
- Requirements in front of an outcome are shown as a counted list ("1 review is required") with a compact readiness summary and next actions — [GitHub changelog](https://github.blog/changelog/2024-12-03-improved-pull-request-merge-experience-now-in-public-preview)
- Waiting states name what each outstanding party must do, and users ask for the pending person to be named — [DocuSign Community](https://community.docusign.com/esignature-171/my-documents-are-waiting-for-others-56); [DocuSign Community ideas](https://community.docusign.com/ideas/agreement-activity-unable-to-show-the-name-of-the-person-whoses-signature-is-pending-25012)
- Status is a word computed from the central case, paired with advice ("on track" / "off track" plus how to get back) — [Betterment help](https://www.betterment.com/help/off-track-goal); [Ally Invest methodology](https://www.ally.com/docs/invest/monte-carlo-methodology)
- Shaded regions are read as boundaries by a large share of lay viewers — [University of Miami News](https://news.miami.edu/stories/2022/11/that-uncanny-coneresearchers-want-to-erase-the-uncertainty.html); [NOAA repository](https://repository.library.noaa.gov/view/noaa/29111/noaa_29111_DS1.pdf)
- Specific statements of uncertainty cost less trust than vague verbal ones — [University of Groningen record](https://research.rug.nl/en/publications/the-effects-of-communicating-uncertainty-on-public-trust-in-facts/)
- Results should update immediately when the user changes an assumption, with no submit step — [NN/g, sliders and knobs](https://www.nngroup.com/articles/sliders-knobs/); [NN/g, recommendations calculator](https://www.nngroup.com/articles/recommendations-calculator/)
- Glanceable surfaces are designed from a ranked list of what the user needs, and scale is distorted when that keeps the end state legible — [Uber Engineering blog](https://www.uber.com/blog/live-activity-on-ios/)
- Phone timelines are vertical, one full-width row per period — [SAP Fiori design guidelines](https://www.sap.com/design-system/fiori-design-web/v1-120/ui-elements/timeline/usage); [Flourish help](https://helpcenter.flourish.studio/hc/en-us/articles/8761591366031-How-to-adjust-your-horizontal-timeline-for-mobile)
- An inaccurate tracker or forecast is worse than none — [NN/g](https://www.nngroup.com/articles/status-tracker-progress-update/); [PiunikaWeb](https://piunikaweb.com/blog/google-maps-showing-misleading-times-on-alternate-routes)

### Inferences
- **The headline is a date, not a percentage.** Maps lead with an arrival time; trackers lead with an expected delivery time; Flighty leads with the expected departure. The equivalent of the ring's percent in those products is secondary or absent. "Finish: fall 2028" is the ETA; "67%" is the odometer.
- **The granted plan is the primary route.** It is the one that needs no further decision, so it is the one drawn at full weight and the one the schedule shows. This matches the project's own rule that only a granted plan is drawn in the table.
- **The if-approved plan is an alternative expressed as a delta with its conditions attached**, in the form the route apps use: "one semester sooner · needs 2 approvals". The benefit and the cost appear together. It is not a second arc on the same shape.
- **Do not encode "conditional" as opacity.** The cone literature says shaded regions are read as boundaries or promises, and legends only partly correct that. The products that handle pending approval well (GitHub, DocuSign) use words and counts, not tints.
- **The conditions are a checklist with per-item state and an owner.** Each advisor question is one row with one of three states (not asked / yes / no), and the count of open items is the summary. This is the GitHub merge-box structure applied to an advisor instead of a reviewer.
- **Separate "waiting on you" from "waiting on them".** Lemonade and DocuSign both split these. For the student, "ask your advisor" is their move; "advisor hasn't answered" is the advisor's. The current single row does not distinguish them.
- **Recording an answer should move the date at once.** NN/g's calculator and slider guidance, and Wealthfront's toggles, all have the headline change the moment the control changes. A recorded yes that requires a second "update plan" step breaks the cause-and-effect link.
- **A recorded answer is a fact, not a what-if.** No precedent was found that mixes exploration toggles with recorded decisions in one control. If both are wanted, the evidence gives no guidance on combining them and some reason (Google's eco-default backlash) to keep "what the plan assumes" unambiguous.
- **The schedule is a vertical list of semesters with a "you are here".** That is the tracker pattern (fixed stages, one current marker, one predicted end) and the phone-timeline guidance at once. A semester that depends on an approval can carry that as a word on its row.
- **Accuracy outranks elegance.** Every category has a version of the same failure: a tracker that is wrong, an alternate route whose saving is not real, a waiting label that is not true. An if-approved finish date that later proves unreachable would be this failure, so the conditions it rests on need to be visible wherever the date is.
- **Rank the information before choosing the form.** Uber's team fixed an explicit priority order and used it to judge every change. A plausible order from the evidence is: (1) when I finish with no permission needed; (2) whether sooner is possible and what it takes; (3) what to ask and what has been answered; (4) what I take each semester. The current screen leads with (none of these) a percentage.

### Gaps
- No precedent was found for a consumer app in which the user records a third party's verbal decision and a plan recomputes from it. This is the least-evidenced part of the brief; the nearest analogues are GitHub (the reviewer records it) and DocuSign (the signer records it), where the system, not the user, captures the answer.
- No evidence was found on how many conditional alternatives lay users can hold at once; the route apps typically show two or three, but no source states a limit.
- No direct test of "solid arc plus faded arc" comprehension exists in the sources retrieved; the recommendation against it rests on analogy.
- Because page fetching was blocked, none of the cited pages was read in full. The writer should treat quoted wording as approximate and should not attribute precise UI details (colours, exact labels, layout) to any app on the strength of these notes alone.
- Not covered at all, for lack of sources: Waze, Shop/UPS/FedEx/Amazon tracking, Lyft, Monzo, Copilot, Robinhood, Linear, TripIt, Apple Calendar, Fantastical, Notion, Things, Todoist, TurboTax, mortgage and visa trackers, fare calendars, EV configurators, Apple Trade In.
