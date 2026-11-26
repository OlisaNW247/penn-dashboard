# A Sweeper that belongs to a server: what it means, in plain words

Written 2026-11-17 for Marco. Nothing here is built. It explains the idea
before the design in `docs/SERVER_SWEEPER_DESIGN_2026-11-17.md`, which is
for whoever builds it. The two documents from 2026-11-16
(`docs/SWEEPER_STATUS_RESEARCH_2026-11-16.md` and
`docs/SWEEPER_ACCURACY_PLAN_2026-11-16.md`) are where every fact about
iPhones, Apple's push service and Canvas was first read and sourced. This
one repeats only what is needed to follow the story.

Marco's question: "help me understand how we can do a smooth sweeper and
have it belong to a server. That way, we can research the missing status
and, I guess, integrate servers into the app and research submission
status before we send out the smooth sweeper."

Marco's rule, which this whole design obeys: "no dont want no alarm option
as this cd lead to someone missing an assignemnt." The alarm is always set
ahead of time. Only a confirmed "it's in" from Canvas or Gradescope takes
it away. A failed check never takes it away.

## 1. The problem in one paragraph

The Sweeper is set days ahead. Every time Smooth refreshes, it looks at your
unfinished work and tells the iPhone: ring an alarm ten minutes before each
one is due. The iPhone keeps those alarms itself and rings them even if
Smooth is closed. That is good: nothing can stop the ring. It is also the
problem: when you hand something in on the Canvas website, Smooth has to
notice and tell the iPhone to drop that alarm. If Smooth is closed, it
cannot notice. So the alarm rings for work you already turned in. That is
what happened on 2026-11-03.

## 2. What the phone can and cannot do while Smooth is closed

Think of a closed app as asleep. iOS decides when it wakes.

What iOS does for us without waking Smooth:
- Rings the alarm at the exact minute we asked for. No Smooth code runs.
- Shows a reminder notification at the exact minute. No Smooth code runs.

What iOS will not do:
- Run our code at a minute we choose. There is no "wake me at 11:49 PM"
  for an app. The one thing that comes close is a push from our own server
  (section 4), and even that is a request, not an order.
- Run our code when the alarm fires. The alarm is the iPhone's, not ours.
  Our code runs only if you tap one of its buttons.

What iOS sometimes does:
- Wakes Smooth for about thirty seconds, at times it picks based on how
  often you open the app. This is "background refresh". Smooth has asked for
  it since August, but no wake has ever been seen on a real phone, and Apple
  says it is switched off in Low Power Mode and never happens after you
  swipe the app away in the app switcher.

So "check Canvas right before the alarm rings" cannot be built on an
iPhone. What can be built is: give Smooth as many chances as possible to
check in the last hour, and make every check that says "it's in" cancel the
alarm on the spot.

## 3. What "belonging to a server" means here

Today the Sweeper lives entirely on the phone. The phone decides, the phone
sets the alarms, the phone is the only thing that can cancel them.

"Belonging to a server" means the server keeps a second copy of one thing:
**the schedule of when each phone wants to be woken.** The server then acts
as an alarm clock for the phone: at each of those minutes it sends the
phone a silent nudge. The phone wakes for a few seconds, asks Canvas and
Gradescope "is this in yet?" with its own login, cancels the alarm if the
answer is yes, and goes back to sleep.

What the server holds, per student:
- A **device token**. A long code Apple gives each install of Smooth so a
  server can send it pushes. It identifies the install to Apple, not the
  student to us.
- A **list of minutes**, at most a couple of dozen over two days. "Wake me
  at 11:44 PM and 11:56 PM." Just times.

What the server never holds:
- Your Canvas or Gradescope login. The server never talks to Canvas as you.
  That rule stands.
- Which class or which assignment each minute is for.
- Whether you submitted. The phone finds that out and keeps it to itself.
- Your name, grades or work list (the work list is only on the server if you
  turned on the AI assistant connection, as today).

This is the same answer the research asked you on 2026-11-16 and you gave:
"Yes, plan it." It is the first thing the server would keep whose only
purpose is to reach your phone, so it gets a paragraph in the privacy
policy and a line on the App Store privacy label (a "device ID" used for
app functionality).

## 4. One alarm, start to finish

Take a problem set due at 11:59 PM on Thursday. Your Sweeper lead time is
ten minutes.

1. **Arming (days before, unchanged).** You open Smooth on Monday. It sees
   the problem set is not done and tells the iPhone: ring at 11:49 PM
   Thursday. The iPhone now owns that alarm.
2. **Telling the server (new).** In the same refresh, Smooth works out when
   it would like to be woken to check: 15 and 3 minutes before each alarm,
   so 11:34 PM and 11:46 PM. It sends the server its device token and that
   list of minutes. Nothing else.
3. **Thursday evening.** You submit the problem set on the Canvas website at
   11:20 PM from your laptop. Smooth is closed on your phone.
4. **11:34 PM, the server's clock ticks.** A small job runs every minute on
   the server and finds your phone's 11:34 entry. It sends Apple one silent
   push for your device token. The push carries nothing but "wake up".
5. **Apple delivers it, usually within seconds.** Your phone wakes Smooth in
   the background for up to thirty seconds. Smooth asks Canvas, with your
   own saved login, for everything due in the next couple of hours and
   whether each is submitted. Canvas says the problem set is in.
6. **The cancel.** Smooth tells the iPhone to drop the 11:49 alarm and the
   backup buzzes, marks the card as turned in, and goes back to sleep.
7. **11:46 PM, the second nudge** arrives. Smooth wakes, finds nothing left
   to check, sleeps again.
8. **11:49 PM.** Silence. The card is in "prev" when you next open Smooth.

If instead you had not submitted, step 5 finds the work still out, Smooth
changes nothing, and the alarm rings at 11:49 exactly as today.

## 5. Where it can fail, and what happens then

Every failure below ends the same way: **the alarm rings as it was set.**
Nothing in this design can make an alarm disappear without a confirmed
"it's in". That is your rule, and it is also what Apple's weaknesses push us
toward anyway.

- **Apple delivers the push late or not at all.** Apple's own words: "the
  system doesn't guarantee their delivery", and "don't try to send more than
  two or three per hour". Two nudges per alarm is well inside that. If both
  are dropped, the alarm rings for work already in. That is the one case
  this design cannot close.
- **You swiped Smooth away in the app switcher (force-quit).** Apple: "If
  something force quits or kills the app, the system discards the held
  notification." No wake until you open Smooth again. The alarm rings as set.
- **Low Power Mode.** Background refresh is off; whether silent pushes still
  arrive is not documented. The alarm rings as set.
- **Your phone is offline at that minute.** Apple holds the push for two
  minutes (we set that limit), then drops it. The alarm rings as set.
- **Your Canvas login on the phone has lapsed.** The wake cannot ask Canvas,
  changes nothing, and never starts a Duo push from the background. The
  alarm rings as set; the next time you open Smooth it signs in silently as
  today.
- **Canvas is slow or answers with an error.** An error is not "submitted".
  Nothing is cancelled. The alarm rings as set.
- **Our server or Apple's service is down.** No push. The alarm rings as set.
- **You reinstalled Smooth.** Apple gives the new install a new token and
  tells our server the old one is dead. The server deletes it. The new
  install registers on its first open.

The reverse failure, an alarm that should ring and does not, cannot come
from this design: the server never tells the phone to cancel anything, and
the phone cancels only on a confirmed read.

## 6. What the student sees

Almost nothing new. There is no permission prompt for silent pushes
(Apple's own rule: pushes an app has not asked to show arrive silently).
There is no new switch: the server copy follows the Sweeper. Turn reminders
off, exclude every class, disconnect Canvas or delete your account, and the
phone tells the server to forget its token and minutes.

What changes is what does not happen: the alarm for work you handed in from
your laptop while Smooth was closed stays quiet, most of the time. The
Sweeper page's countdown card drops the item the next time you open Smooth.

A DEBUG build will show, for the people building it, one line per wake:
when it came, whether it was a push or an iOS background refresh, how long
the check took, and what it cancelled. Never a title.

## 7. What it costs

**To build.** The phone half (register for pushes, send the minutes, handle
the wake, cancel on a confirmed read) and the server half (one table, one
small function, one job that ticks every minute) together are about five to
seven working days, after the phone-only fixes in the 2026-11-16 plan's
Release 1 are done. The design document has the hour-by-hour estimates.

**To run.** Nothing new to pay for. Apple's push service is free with the
developer membership we already have. The server job runs inside the
Supabase project we already pay for; one push is one tiny web request, and
even a few thousand students would mean a few thousand requests a night.

**From Olisa, once.** As the Apple Developer account holder, he creates one
push "key" in the Apple Developer portal (a small file downloaded once), and
turns on "Push Notifications" for the app's identifier. The key goes into
the server's secret store and nowhere else. He also signs off the privacy
paragraph.

**From Marco.** The deploy go, the one-line change to the App Store privacy
label, and the phone for the end-to-end check.

**From students.** Nothing. No prompt, no setting.

## 8. What this does not do, said once

- It does not let the server decide whether to ring. The server knows no
  submission state and never will under the privacy rule.
- It does not reach a force-quit app. Nothing on iOS does, except a visible
  notification handled by a small helper process, which the plan keeps as an
  optional later step for the three-buzz fallback only.
- It does not make Canvas tell us when you submit. Canvas offers no push,
  webhook or email that a student's own login can turn on. The design
  document closes that question with Canvas's own documentation, so nobody
  has to ask it again.
- It does not replace the phone-only fixes. Cancel-the-moment-we-see-it, the
  once-a-minute check in the last hour while Smooth is open, and the quiet
  rules for things that never ring come first. The server nudge is one more
  chance for those checks to run while Smooth is closed; without them it
  cancels nothing.

## 9. The one sentence

The iPhone keeps the alarm; the server keeps the alarm clock that wakes the
phone to check; the phone alone asks Canvas and alone decides to cancel; and
when anything in that chain breaks, the alarm rings, which is the side you
chose.
