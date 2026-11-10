# The quiz of 2026-11-09, and "in class" on Project 2

Written 2026-11-10 (early morning US Eastern) from Marco's two bug reports of
the night before. Marco's iPhone was **unavailable** to `devicectl` for the
whole session (listed, state `unavailable`), so nothing here was read off the
phone itself: no App Group plist, no `course-knowledge.json`, no ledger, no
notification log. The evidence is the work list and course material the phone
uploaded through the agent connection (`agent-snapshot`, last upload about
05:00 UTC on 2026-11-10), read with the connector's own tools
(`list_work`, `get_assignment`, `search_course_material`), plus the code on
`agent/connection-v11`.

## 1. "It didn't tell me I had a quiz today"

**What the quiz was.** PHYS 0151 (lecture site 1949400) "Quiz 7", Canvas
assignment 15139531, calendar uid `event-assignment-15139531`, due
`2026-11-09T18:59:00Z` = Monday 1:59 PM Eastern, 10 points, description "Chap
27. HW6, WS8.1-8.2." The syllabus puts Monday's meeting at 1:45 to 2:44 PM
("Lectures (including quizzes)"), so the quiz is sat at the start of class
and Canvas's due time is fourteen minutes after it starts. It is a Canvas
assignment that takes no submission (`submission_types` of `none` or
`on_paper`; the snapshot says "nothing to submit"; which of the two is not
visible from the snapshot). Quizzes 4, 5, 8 and 9 are the same shape. It is
not missing from any source: the calendar feed carried it, the phone held it,
and the snapshot uploaded at 05:00 UTC lists it among finished work.

**What the dashboard did with it, by the code.** Nothing hid it early:

- `AppState.isExpired` is the `.event` rule; Quiz 7 is `.assignment`, so it
  does not apply.
- The per-class "items with nothing to submit" switch hides no-submission
  assignments when off, but Quiz 8 and Quiz 9 (the same kind, same class)
  show, so it is on.
- The sign-up backlog rule only withholds work already a week overdue at the
  first sync; the same-day class-reminder rule is for announcement tasks;
  neither touches a feed assignment.
- A Planner dismissal (`structuredDismissedItemIDsV1`) could hide it and
  cannot be ruled out without the plist; nothing suggests Marco dismissed it
  in Canvas.

So Quiz 7 was in **todo** from Saturday 1:59 PM ("next two days") and under
"today" from Sunday 1:59 PM, until Monday 1:59 PM. At that moment
`isAutoFiledNoSubmission` made it count as completed (a no-submission
assignment past its due time "belongs with finished work", owner's rule of
2026-08-27), and it moved to **prev**, where the snapshot found it. A look at
the app on Monday afternoon or evening shows Quiz 8 next week and no trace of
today's quiz, which matches the report.

**Why nothing rang.** The Smooth Sweeper never rings for "nothing to submit"
(`NotificationScheduler.loudAlerts`, `showsNothingToSubmit`): it is an alarm
for work not handed in, and Smooth cannot know whether an in-class quiz was
taken. The ordinary lead-time reminders do apply to it: with the default
lead times (1 day, 1 hour) they were planned for Sunday 1:59 PM and Monday
12:59 PM, each "PHYS 0151 / Quiz 7. Due in …". Whether those were delivered,
and which lead times Marco has set, needs the plist (`notif.leadOffsets`,
`notif.enabled`, per-class `coursePreferences`) and is the first thing to
read when the phone is back:

```bash
xcrun devicectl device copy from --device 8A287085-9C88-5A87-816B-1A8EF80D67AD --domain-type appGroupDataContainer --domain-identifier group.com.lhf.lowhangingfruit --source Library/Preferences/group.com.lhf.lowhangingfruit.plist --destination /tmp/lhf.plist
```

then `plutil -p /tmp/lhf.plist | grep -E "notif\.|structuredDismissed|onPaper|noSubmission"`.

**Verdict.** No rule is wrong in the sense of losing or hiding the quiz too
early: the app had it, showed it in todo for two days, and filed it at its
due time. What Marco did not get is a *loud* warning on the day, because an
in-class quiz is "nothing to submit" and the only same-day alert for that kind
is the 1-hour lead-time reminder (if his lead times include it). No code was
changed for this half. Options for Marco to choose from, not built:

1. A morning-of notice for no-submission items whose title names a quiz or
   exam ("PHYS 0151 · Quiz 7 today, 1:59 PM"), outside the Sweeper.
2. Treat a Canvas no-submission quiz like a found exam (grey exam card, never
   aged by the switch), which makes it louder on the dashboard but adds no
   notification.
3. Leave it, and make sure the 1-hour reminder is on.

## 2. "Project 2: Feature Extension: not in class"

**What it is.** CIS 3990 assignment 15013598, due Tue 2026-11-10 10:00 PM
Eastern, 100 points, handed in on the course's git server (a tagged PR),
so Canvas takes no submission. Grade Watcher's `submission_types` puts it in
`noSubmissionCanvasAssignmentIDsV1` (`GradeItem.requiresNoSubmission`:
every type is `none`, `on_paper` or `not_graded`; `external_tool` is not one
of them, so it is `none` or `on_paper`, almost certainly `none`).

**Why the card said "in class".** `SmoothDueValue.secondaryLabel` printed
"in class" for every card with `showsNothingToSubmit`, whatever Canvas's type.
The cache kept only "takes no submission", not which kind.

**Fix (committed with this doc).** A second persisted set,
`onPaperCanvasAssignmentIDsV1` (`AppState.onPaperCanvasAssignmentIDs`,
`GradeItem.submitsOnPaper`, same per-item replace as the first set), and
`NothingToSubmitLabel.text`: "in class" for `on_paper`, for an `.event`, and
for a no-submission item whose title names a quiz or exam (in-class quizzes
set to "No Submission" are common); "off canvas" for everything else. Only the
word changed: reminders, the Sweeper's silence and the auto-file at the due
time still read the wider set. The opposite risk was checked in code: a
`none` assignment with a due date is still a card (only the per-class switch
hides it), and it still gets its lead-time reminders.

Until the first grade refresh after the update, `onPaperCanvasAssignmentIDs`
is empty, so an on-paper item without "quiz" or "exam" in its title reads
"off canvas" for that first minute.
