# Synthetic extract-facts corpus (36 documents)

Hand-labelled, invented courses and instructors; Penn flavoured but not real. Index and meeting pattern are shared per course (CIS 2400, PHYS 0151, ECON 0100, WRIT 0020). Times are America/New_York (EDT to 2026-10-31, EST from 2026-11-01).

Labelling decisions:
- "made optional" (05) is labelled `needs_review`, not `cancel`: `cancel` would hide a card the student may still want to do (the post says it can replace a lower score), and the ledger never loses work the student might choose to do. The extractor should flag it.
- Relative days resolve from postedAt and the meeting pattern; `due_tolerance` is `day` unless the post names a class start (`exact`). No-time dates default to 23:59.
- A moved/cancelled class meeting that is not an index item (the 10:15 slot in 36) is deliberately left unlabelled.
- An undated, soft reading ask ("if you've got a free hour", no due date) is not a task (17 is labelled empty, round 1): a card with no date and no obligation is noise on the dashboard.
- Ed documents (23, 36) put the thread in `text` as plain text, replies included.

| file | course | kind | case | expected fact types |
|---|---|---|---|---|
| 01-cis-hw3-cancelled.json | CIS 2400 | announcement | assignment cancelled | cancel |
| 02-phys-lab6-cancelled.json | PHYS 0151 | announcement | lab meeting (event) cancelled; its report explicitly stays | cancel |
| 03-econ-midterm-dropped.json | ECON 0100 | announcement | exam cancelled | cancel |
| 04-cis-recitation7-cancelled.json | CIS 2400 | announcement | recitation (event) cancelled | cancel |
| 05-writ-rr4-optional.json | WRIT 0020 | announcement | made optional | needs_review |
| 06-econ-ps5-extended.json | ECON 0100 | announcement | due date moved, explicit date | reschedule |
| 07-phys-ps7-pushed.json | PHYS 0151 | announcement | moved, relative day ('Monday') | reschedule |
| 08-cis-hw5-section205.json | CIS 2400 | announcement | moved for one section only | needs_review |
| 09-econ-ps4-correction.json | ECON 0100 | announcement | correction supersedes an earlier move | reschedule |
| 10-cis-milestone1-before-lecture.json | CIS 2400 | announcement | 'before Tuesday's lecture' (exact start) | reschedule |
| 11-phys-ps5-only-1-4.json | PHYS 0151 | announcement | scope: only problems 1-4 | scope_change |
| 12-cis-hw4-gradescope.json | CIS 2400 | announcement | submission venue: Gradescope, not Canvas | note |
| 13-econ-quiz4-covers.json | ECON 0100 | announcement | note: quiz covers chapters 5-6 | note |
| 14-cis-hw6-dated.json | CIS 2400 | announcement | date given for an index item that is undated | reschedule |
| 15-cis-read-before-tuesday.json | CIS 2400 | announcement | prep task before Tuesday (class start) | new_task |
| 16-writ-feedback-survey.json | WRIT 0020 | announcement | survey by a date, 23:59 | new_task |
| 17-econ-undated-reading.json | ECON 0100 | announcement | undated, soft reading ask (not a task) | none |
| 18-cis-module7.json | CIS 2400 | module | module page: 2 items not in index, 3 already indexed | new_task, new_task |
| 19-phys-hw-slides-posted.json | PHYS 0151 | announcement | none: slides posted | none |
| 20-cis-recording-uploaded.json | CIS 2400 | announcement | none: recording uploaded | none |
| 21-econ-office-hours.json | ECON 0100 | announcement | none: office hours reminder | none |
| 22-writ-grades-out.json | WRIT 0020 | announcement | none: grades out | none |
| 23-cis-ed-hw3-fsm-question.json | CIS 2400 | ed | none: Ed question, staff reply changes nothing | none |
| 24-econ-syllabus.json | ECON 0100 | syllabus | none: syllabus late-policy paragraph (mentions indexed midterm date) | none |
| 25-phys-office-hours-room.json | PHYS 0151 | announcement | none: office hours room change | none |
| 26-econ-ps3-graded.json | ECON 0100 | announcement | none: indexed item named only to say it is graded | none |
| 27-wr-peer-review-new-task.json | WRIT 0020 | announcement | distractor: indexed item restated unchanged + one NEW task | new_task |
| 28-cis-last-years-template.json | CIS 2400 | announcement | distractor: quoted 2025 dates must not become facts | none |
| 29-phys-instructor-will-post.json | PHYS 0151 | announcement | distractor: instructor's own future action | none |
| 30-econ-review-session-moved.json | ECON 0100 | announcement | event (index) rescheduled, explicit date/time | reschedule |
| 31-writ-peer-review-start-of-class.json | WRIT 0020 | announcement | moved to 'start of class on Thursday' (exact) | reschedule |
| 32-cis-hw5-skip-conditional.json | CIS 2400 | announcement | conditional skip | needs_review |
| 33-phys-midterm-maybe-moved.json | PHYS 0151 | announcement | ambiguous 'may move the midterm' | needs_review |
| 34-econ-memo-page.json | ECON 0100 | page | page: project milestones, one new (outline), two indexed | new_task |
| 35-writ-portfolio-page.json | WRIT 0020 | page | page: date for undated index item | reschedule |
| 36-phys-ed-midterm-time.json | PHYS 0151 | ed | ed: staff-pinned exam moved (also says that day's 10:15 lecture slot is cancelled; not labelled, no index item) | reschedule |
| 38-phys-quiz5-stale-conflict.json | PHYS 0140 | announcement | stale (Sep 10 vs now Nov 5): stated Quiz 5 date superseded by index; coverage note still valid | note |
| 39-biol-hw4-cancel-stale.json | BIOL 0200 | announcement | stale: HW4 cancel still valid, HW5 date superseded | cancel |
| 40-chem-midterm-note-stale.json | CHEM 1010 | announcement | stale: coverage/materials note valid, Oct 10 date superseded | note |
| 41-hist-quiz2-past-unindexed.json | HIST 0150 | announcement | stale: past-dated unindexed quiz reschedule | none |
| 42-math-lab7-fresh-reschedule.json | MATH 1400 | announcement | control: fresh reschedule | reschedule |
| 43-stat-syllabus-old-final.json | STAT 1020 | syllabus | control: old syllabus, unindexed dated final | new_task |
