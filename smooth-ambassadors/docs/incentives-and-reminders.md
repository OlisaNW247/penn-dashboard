# incentives without money, and reminders that don't nag

One page. What's recommended, and why, for a handful of friends at five
schools.

## what the research says, briefly

Sustained volunteer effort comes from three things: **autonomy** (they
choose how), **competence** (they can see it working), and **relatedness**
(they're doing it with people they like). Student ambassador programs that
last combine two or three light incentives (recognition + real influence +
a bit of friendly competition) and lose people to **isolation** mid-semester
more than to lack of rewards. Unpaid programs that feel like free labour
burn goodwill; programs that feel like being early to something keep it.
(Sources: Unibuddy and Makai ambassador guides; Self-Determination Theory
as applied in those; Notion's volunteer Campus Leaders model.)

## the short list (recommended)

1. **Founding ambassador, then campus lead.** Title on their page from day
   one. "campus lead" when they bring a second person at their school or
   hold it a semester. Costs nothing, goes on linkedin.
2. **A real recommendation.** After one semester, a linkedin
   recommendation or short reference letter from olisa and marco, naming
   what they actually did (numbers from the founder view).
3. **Their numbers, live.** The page shows link opens and poster scans
   that are *theirs*. Competence, instantly, without anyone telling them.
4. **A say.** Feedback goes straight to the founders and gets a reply.
   Early TestFlight builds. Once a semester, their school's top request
   gets built or explicitly declined with a reason.
5. **School vs school, never person vs person.** Public leaderboard by
   school only (`/api/leaderboard`, and the digest's "uva is #2, 13 behind
   umiami"). Per-person numbers stay on their own page unless they opt in.
   Among friends, public personal rankings become pressure fast.
6. **Milestones that are concrete.**
   - their school passes 100 attributed opens → a custom poster for that
     school, their idea, printed at every school.
   - 10,000 downloads → the merch already promised, made specific (one
     item, named now, pictured on the page).
7. **Make it theirs.** The messages are editable on the page by design
   ("change the words to sound like you"). Once a semester, a 20-minute
   call where ambassadors share what worked; the best line gets added to
   `messages.json` with their name in the commit.
8. **Shout-outs with substance.** When a school moves up, a text from a
   founder that says what specifically moved it ("your clemons posters did
   it"). Not a generic "great job".

Not recommended: anything tied to reviews or ratings (Apple ban), cash or
gift cards (no money, and it reframes friendship as work), per-person
public leaderboards, points systems or badges (overhead the founders won't
keep up).

## reminders

**Rhythm.** One digest every two weeks, plus six campus moments a year
(welcome-back, week 1, add/drop, midterms, registration, finals). Nothing
else. That is roughly 15 texts per semester, each one short.

**From a person.** Every reminder is sent by olisa or marco from their own
phone. The founder view generates the text; "text it" opens messages
pre-filled; "mark sent" records it. Under five minutes for all
ambassadors. No automated texting service unless Olisa decides so later
(it costs money and needs TCPA-grade consent and opt-out).

**Built from real numbers.** The digest says what their links did, where
their school stands, and what's new, then one 30-second action. See
`worker/digest.js`. Example:

> hey maya, quick smooth update, no reply needed. your links got 13 opens
> in the last 2 weeks. uva posters: 4 scans in 2 weeks (16 all-time). on
> the 2-week board uva is #1, 13 ahead of upenn. if you have 30 seconds:
> paste the group chat message into one new chat. everything's here:
> https://…/a/… reply "pause" and i'll stop these for a while.

**Easy to stop.** "pause" in a reply, or the pause buttons on their page
(4 weeks, the semester). Two unanswered digests in a row → the founder
view marks them quiet and skips them until the next campus moment, which
goes out to everyone not paused. Paused people get nothing.

**Tone.** lowercase, short, no hype words, always "no pressure" and
always true. It's friends telling friends how it's going.
