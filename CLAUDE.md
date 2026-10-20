# LHF (Low Hanging Fruit), shipped as **Smooth**

## Start here: every session reads this file, and updates it before it ends

This file and `ROADMAP.md` are the project's memory. Sessions don't remember
each other; these two files are how the next one knows what this one did.

**At the start of a session:** read this file top to bottom, then
`ROADMAP.md`. Treat both as claims to re-check rather than facts: when a
line here disagrees with the code, the code wins, and fixing the line is
part of the job. The release number below has been stale before.

**Before a session ends (or before the last commit of a piece of work),
update them.** What goes where:

| Changed | Update |
|---|---|
| What the app does (a screen, a setting, a feature added or removed) | **What the app does**, below, and **Done recently** in `ROADMAP.md` |
| The test count after a verified run | **Test baseline** (count, date, branch, how it was run) |
| A new or merged branch; a new ship line | **Branches** |
| A bug that looked like something else, or a fix whose wrong version was tempting | a new entry in **Traps that have already bitten** |
| Something still unverified on a device, or known broken | **Known gaps**, and **Now** in `ROADMAP.md` if it blocks a release |
| A privacy-relevant behaviour (what leaves the phone, how to delete it) | the intro below **and** `docs/PRIVACY.md`, in the same commit |
| A plan, idea, or experiment set aside | `ROADMAP.md` (**Next**, **Later**, or **Tried and parked**) |

Keep the register: prose that says *why*, dated when a fact can go stale
(`2026-09-24`, never "yesterday"). Replace a stale line; don't append a
contradiction beside it. Commit these files with the change they describe,
not in a separate "docs" commit later.

---

A personal academic dashboard for college students. It reads the student's
own **Canvas** (calendar feed plus their signed-in session) and
**Gradescope**, merges them into one chronological "what's due" list, and
sends local reminders. (It tracked grades too until the owner took Grade
Watcher out of the app on 2026-10-18; the grade fetch still runs, for the
reasons under "What the app does".) SwiftUI, iPhone-first, and it also builds
for macOS from the same source. The user-facing name is **Smooth** (since
2026-09-12; it was **Locust** from 2026-09-09). Display names and copy only:
bundle ids, module names, App Group names and defaults keys keep their LHF
names.

**Schools.** Built for Penn, and since 2026-09-23 it also signs in to the
Canvas of Brown, Columbia, Cornell, Dartmouth, Harvard, Princeton and Yale,
or any HTTPS Canvas address a student types in
(`CanvasInstallation.verifiedSchools` / `.custom(address:)`). Everything
server-side is Penn-only for now: pooled course materials, the server path
of ask, the announcement AI assist, and "stay signed in" (PennKey).
Non-Penn installs run fully on-device, because the backend keys course
material by numeric Canvas course id, and two schools' ids would collide.

**Privacy posture; say it this way.** "The student's own data stays
on-device; course material is pooled server-side; ask has an on-device
fallback." Grades, completions, submission state, the work list, the
student's name, and Canvas/Gradescope cookies never leave the phone. The
PennKey password, if the student saves it, stays in this phone's Keychain
and only ever goes to Penn's login page. There is no analytics, tracking,
or third-party SDK. Don't say "everything is on-device" (untrue since
`assistant-ui`) or "no server" (untrue since the backend). `docs/PRIVACY.md`
is the student-facing version and must change in the same commit as any
behaviour it describes.

**The backend.** A small Supabase project (Postgres plus Edge Functions;
`backend/PROTOCOL.md` is the contract). Every Penn install talks to it
through an anonymous account created on first launch: no email, no
password, no name. Two things go through it:
- **Course materials.** Syllabus, course pages, modules, assignment
  descriptions and announcements are fetched from Canvas with the student's
  own login, then pooled per Canvas course so classmates share one copy.
  Sync is automatic: after Canvas connects, then on the refresh loop with
  hourly staleness. There is no manual sync. Since 2026-10-02 (`v8`, not
  yet verified on a device) the same sync also reads **Ed Discussion** for
  any class whose Canvas site has an Ed tool: the app performs the tool's
  LTI launch in a hidden WebView (with the Keychain's Canvas cookies
  injected first, or the launch bounces to Penn WebLogin), reads Ed's
  session token out of the landed page's `localStorage` (since
  2026-10-09; Ed keeps no session cookie) into the Keychain
  (`EdSessionTokenStore`, with any Ed cookies in
  `SessionCookieStore.Service.ed` as a fallback), reads the board with
  `EdClient` (`x-token`), and keeps only announcements, pinned threads
  and staff posts (`EdThreadFilter`) as documents of kind `ed`. Student,
  private and anonymous posts never leave the phone; no author is ever
  named. `docs/ED_DISCUSSION.md` is the design record;
  `FeatureFlags.edDiscussion` is the kill switch.
- **ask** ("the tree"). Questions go to the backend with the on-device
  context document and matched excerpts, and are answered by a model via
  OpenRouter under LHF's own key (see the ask section below). The
  Announcement Watcher's AI assist is routed the same way, only for
  announcements that an on-device gate judges could carry a task. Since
  2026-10-18 that covers Ed announcements and pinned posts too (title and
  body, no author, once each, never for a hidden class), under the same
  switch and the same gate; the text is what the pool already holds. (For
  one day, 2026-10-19, the Canvas loop also read plain staff posts; the
  merge of 2026-10-20 kept Marco's Ed pass, which does not.) It is on by
  default, and a student can turn it off under Profile → notifications,
  which `docs/PRIVACY.md` promises. Neither questions nor answers are
  stored, only per-user daily request counts and token totals.

Disconnecting Canvas deletes the student's enrollment/usage rows and
anonymous account from the backend. Since 2026-09-24 there is no separate
delete button; the disconnect confirmation says so. Offline, over quota, or
with the backend unreachable, ask answers on-device:
`OnDeviceAssistantResponder` computes exact answers from the dashboard's
items, retrieves policy and content answers from synced course materials
(`CourseKnowledgeCollector` → `CourseKnowledgeStore`), and on iOS 26 /
macOS 26 Apple Intelligence devices rephrases via Apple's on-device model
(`OnDeviceLanguageModel`). Eight Edge Functions live in
`backend/supabase/functions/`: `ask`, `ask-canary`, `delete-account`,
`discover-websites`, `extract-announcement`, `extract-profile`,
`map-categories`, `sync`.

**Visual language.** Marco's Smooth design: a white paper ground with
tomato/marigold/lemon/teal/cobalt/grape accents, an "after sunset" dark
mode, the S app mark, and bundled type registered at runtime by
`SmoothFontRegistry` (`RedesignTokens.swift`):
- Satoshi (Fontshare FFL).
- Inter, Familjen Grotesk and Space Mono (all SIL OFL, licence files beside
  them in `Resources/`).
- Roobert SemiBold for the dashboard title: a commercial face from
  Displaay, cleared for shipping on 2026-09-15 under a personal agreement
  Olisa holds. There is deliberately no licence file in the repo; the
  agreement is Olisa's to produce if it is ever asked for.

**Release state.** Live on the App Store: **3.0.0 (build 11)** (App Store
id `6783911002`, released about 2026-10-01; confirmed on the store page by
Olisa 2026-10-09, with 1.2.1 live before it from 2026-09-04). This line has
been stale before, so re-check it rather than trust it. `project.yml`
stamps **3.0.1 (build 12)** on `v8` (2026-10-09, the sign-out fix below;
not yet archived). The `update-manifest` floor is still 1.2.1; raising it
to 3.0.0 is Olisa's call. Builds 7–9 of 3.0.0
were uploaded from `v5` and none was released (build 8 was rejected under
2.1(a), see Known gaps). Build 10 was uploaded 2026-09-16 at 9:54 AM,
from before stay-signed-in existed, and attached to that rejected
submission but never resubmitted. Build 11 is the first from `V7`
(uploaded 2026-09-27, with Olisa's session logic restored; see the
24-hour trap). App Store Connect refuses an upload whose build number is
not higher than every build it has seen, so check TestFlight → Builds
there, not this file, before picking the next one.

App Store Connect, as left on 2026-09-27 (re-check it): the app is
"Smooth For Students", team Stem Forward Co., whose Account Holder is
Olisa's Apple ID. The updated Apple Developer Program License Agreement
was accepted that day with Olisa's OK; until the Account Holder accepts a
new one, Apple blocks every submission. The iOS version record was
renamed 2.0.0 → 3.0.0, and its What's New and review notes were saved
(the notes as pasted are at the top of `docs/appstore/REVIEW_NOTES.md`).
Marco was finishing by hand: remove 3.0.0 from the old rejected
submission `067299d2…`, swap build 10 for 11, then Add for Review →
Submit. Whether he submitted is not recorded here. The version is set to
release automatically once approved; raise the `update-manifest` floor
only after 3.0.0 is actually downloadable. macOS 1.0 shows "Ready for
Distribution" there (reviewed 2026-08-30), whatever older docs say. On launch the app fetches a public update-policy file that can
require an update (`Update/`, below).

## What the app does

Screen by screen, as of 2026-10-20 on `v8-merge-loud-alert` (Olisa's `v8` and
Marco's `v8-loud-alert-actions` merged; **not compiled**, see Test baseline).
Keep this current. It is the fastest way for a new session to know what exists.

- **Onboarding.** A three-beat intro (`MissionIntroView`), then
  `OnboardingView`'s walk:
  1. school
  2. Canvas login (WebKit, the school's own SSO; Penn is PennKey + Duo)
  3. Gradescope login (optional)
  4. reminders
  5. a per-course setup walk (`OnboardingCourseSetup`)

  "Just exploring? preview with sample data" on the first pane is preview
  mode, App Review's only way in (see Known gaps). A reconnect from the
  dashboard banner opens the Canvas login directly; the school picker is
  behind the back chevron, and since 2026-10-09 (blind) picking a
  different school there asks "switch school?" first, because it signs
  the student out and forgets the saved password and Duo trust. A student can instead
  paste a Canvas calendar link (`PasteFeedLinkSheet`); that install gets
  the feed but no session. Since 2026-10-18 Profile → accounts shows a
  "sign in to canvas" button under the canvas row for exactly that state
  (connected, no saved login, not preview), because no banner appears
  there and Grade Watcher's reconnect button is gone. At Penn, the PennKey
  sheet offered after the Canvas login is **"the vault"** since 2026-10-18
  (`PennKeyCredentialsSheet`): a vault-door emblem that clunks shut once
  as the sheet opens (drawn already shut under Reduce Motion), the same
  one line about the Keychain, the two fields. It was a lock icon under
  "stay signed in to canvas". Only the look changed.
- **Dashboard** (`ContentView`):
  - **Header.** The "Smooth" wordmark and the weekday. Tapping the wordmark
    ripples its squiggle and sweeps a shine across it. The **megaphone**
    and a profile button sit beside it, both 48pt circles. Since
    2026-10-18 the megaphone is here, where the grades button was, and
    always shows (an empty list says "no announcements"); the grades
    button is gone with Grade Watcher (below).
  - **Banners.** A sync error ("couldn't sync"), a Canvas banner when
    the session is dead ("reconnect canvas", "duo needs you", or "pennkey
    password rejected"), and, since 2026-10-10, "not saving on this
    phone" when the ledger is running in memory or its last save failed
    (`StorageHealth`; never in preview or demo mode).
  - **Control row.** A full-width **todo · all · prev** switch
    (`DashViewPicker`), then a **class filter** menu (narrows all three
    views, with a clearable chip under the row), **+** (the add sheet: a
    one-off or weekly assignment, class picked from a grid of per-class
    coloured chips, `CoursePicker`). The **megaphone** used to be a fourth
    control here and moved to the header on 2026-10-18, where its circle
    is marigold (the class filter beside the switch is cobalt: ink glyph on
    a cobalt fill, like the tomato add button). It opens
    `AnnouncementFindsView`, which since 2026-10-18 is two lists under the
    page header and a class filter (the dashboard's own `ClassFilterMenu`,
    default all classes, not remembered):
    1. **found**: the tasks the Announcement Watcher found in Canvas
       announcements and Ed posts, and the exams the class has found
       (the syllabus's too), that are still ahead: not finished and not
       hidden by the dashboard's own rule (`isHiddenAnnouncementTask`:
       past, undated a week after its post, or a same-day reminder, see
       "Which announcement tasks show"). Drawn as the dashboard's own `AssignmentCardView`
       (exam cards keep the exam look; swipe to finish; "edit date"
       works), soonest first, one card per exam when the syllabus and an
       announcement both name it. A "NEW" tag sits beside the class.
       Hidden when empty.
    2. **announcements**: the Canvas announcements and the Ed
       announcements and pinned posts from the **past 7 days**, newest
       first, across classes; a row is class, date ("ed" beside it for an
       Ed post), title, a one-line preview, an arrow and a "task found"
       tag when a find came from it; the whole row opens the original.
       Empty says "no announcements".

    The dismiss button says "back to assignments". What each list holds
    is decided in `AppState+AnnouncementSheet.swift`
    (`announcementFoundItems(now:)`, `announcementSheetRecords(now:)`),
    read-only over the same rows as before; the 7 days are display only,
    the log still keeps 60. Before 2026-10-10 the sheet listed only
    extracted tasks and hid itself when there were none, which read as
    "announcements are missing".
    The Canvas rows are an on-device cache (`AnnouncementLogStore`,
    `announcement-log.json` beside the course-knowledge file; title,
    class, date, link and a 280-character preview; cleared on
    disconnect), filled by `syncAnnouncements`, which asks Canvas
    for 60 days back *through tomorrow* (see the announcements-window
    trap). The Ed rows are built at display time from `.ed` course
    documents (`EdDocumentHeader`), never written to that file, and the
    list follows `$courseKnowledge` without the sync calling it.
    Extraction, including the AI assist, still only ever sees the last
    14 days. For an Ed post that is 14 days since it was *posted*: the
    posting day its document's header names (`CourseDocument.shownPostedAt`
    through `AppState.edPostDate`, since 2026-10-19, written without a
    compiler), and the thread's last activity only for a document synced
    before that. The badge counts
    exactly what the sheet can show: unread found items plus unread
    posts from the past 7 days, so it never counts a passed task or an
    older post. Rows unread when opened are tagged NEW
    (`AnnouncementReadState`, which marks only the shown rows seen), and
    the first fill of each kind on an install counts as already seen. The
    badge caps at "99+" (VoiceOver still gets the true count).
  - **todo**: overdue plus the next two days. Tasks found in
    announcements are cards here and in all (see the bullet after prev).
    For someone who signed up
    on or after the 2026-10-09 build, unfinished Canvas/Gradescope work
    that was already more than 7 days overdue at their first sync is
    withheld from todo, all, the widget and ask (`SignupBacklog`; a
    set-once cutoff in `UserDefaults.lhf`, `signupBacklogCutoffV1`). The
    decision is taken beside the sync, never inside it: at `init`, an
    install whose ledger already holds feed rows, or that had finished
    onboarding when this build first launched (`signupBacklogSeenV1`),
    records a "hide nothing" sentinel and sees no change; otherwise the
    first `rebuildDashboardItems` that sees real feed items records
    "now minus 7 days". Nothing is deleted, finished work still reaches
    prev, and manual work is never hidden.
  - **all**: future work through the term.
  - **prev** (`DoneView`): leads with "N down this week", shows this week's
    finished work, and opens "earlier this semester" in place. Finished work
    only: a task found in an announcement that went by unfinished is not
    here. (For part of 2026-10-18 prev listed those as "past", and the
    owner's phone filled with tasks already taken; they now leave the
    dashboard entirely, see the tasks bullet below.) A *finished*
    announcement task is ordinary finished work and stays.
    When the sign-up rule above is withholding anything, a quiet last line
    reads "N older hidden" with "show", or "older shown" with "hide"
    (`signupBacklogRevealedV1`).
  - **Tasks found in announcements** (2026-10-18, owner's call; not yet on
    a phone). Canvas announcements (`syncAnnouncements`) and Ed
    announcements and pinned posts (`AppState+EdAnnouncementTasks.swift`,
    triggered after the course knowledge changes and once at launch) are
    read for tasks by the same extractors, the same "ai assist" switch and
    the same on-device gate, once per post (`processedAnnouncementIDs` holds
    both kinds of id). Each task, submission or preparation, dated or not,
    is a card for a class whose per-class "announcements on dashboard"
    switch is on (the default; it now governs Canvas and Ed together). A
    task whose own wording reports something done ("grades posted") stays
    megaphone-only, and a preparation task (`.event`) still answers to the
    class's "items with nothing to submit" switch. An undated task sits
    under "later" in all like any undated item, for seven days after its
    post (next bullet). Rows are `.canvasAnnouncement` ledger rows; an Ed
    one has an `ed-` sourceID (`AnnouncementOrigin`), which gives "from ed"
    and "open in ed" on the card. It is a prefix and not a new
    `Assignment.Source` or a new column on purpose: an older build maps an
    unknown source to `.canvas` (the wrong source, and an id that no longer
    matches the stored one), and a schema change makes an older build fall
    back to an empty in-memory ledger. The same task on Canvas, on Ed, or
    already a Canvas assignment is one card (`resolvingAnnouncementDuplicates`
    with a fixed survivor order: not hidden by a rule, then dated, then Canvas,
    then id). Two announcements are one task only on the same day (dates
    within `AssignmentDeduplicator.similarTitleDueDateTolerance`, about 26
    hours, or one undated): the same title for the 6th and again for the
    20th is two tasks. A tick on the hidden twin carries to the shown one
    only between copies of the same day (`completionFollows`), never across
    a gap, a reschedule included. A Canvas post that stops
    coming back inside the fetched window has its rows flagged
    `isGoneFromFeed` and its cards hidden (`reconcileAnnouncementPresence`;
    evidence is the announcement log's posted date; an empty fetch judges
    nothing, and so does a class the fetch returned no post for; a post
    must be missing from two judged fetches in a row, counted in
    `announcementMissCountsV1`; a finished task stays in prev; a post that
    returns restores them). The flag never deletes: the store's aging rule
    exempts announcement rows (Traps). An edited due date stays while its
    row is hidden. Ed deletions are not detected, see Known gaps.
  - **Which announcement tasks show** (2026-10-18, owner's call, after the
    phone filled with stale ones: "Take quiz covering assignments 1 and 2"
    from a Sept 14 Ed post, "Attend the weekly rotation quiz"; "none of
    these previous ones are honestly helpful"). Visibility rules,
    evaluated at every rebuild by `AppState.isHiddenAnnouncementTask`
    (`AppState+AnnouncementTaskRules.swift`); an unfinished task they hide
    is in todo, all and prev **nowhere**, and the ledger row is never
    deleted or flagged, so it returns the moment a rule stops matching:
    1. **Past.** A dated task whose date (the student's edit, if any) has
       passed. A finished one is finished work and stays in prev. Syllabus
       and announced exams follow the same rule. This is the one rule for
       "an announcement or Ed task vanishes at its due time and is never
       overdue" (the owner's rule of 2026-10-19, whose own implementation,
       `AppState.isExpired` widened to every `.canvasAnnouncement` item, was
       removed in the 2026-10-20 merge: `isExpired` is the `.event` rule
       for feed items alone again, and leaves an `.event` that is itself an
       unlinked announcement task to this rule, so no item is judged by
       both; one linked to a Gradescope twin keeps the event rule). Where
       it is asked: the
       dashboard's coursework and assessments buckets (`live` in
       `rebuildDashboardItems`), the megaphone's found list and badge (at the
       sheet, `announcementFoundItems(now:)`, not in the lists' input: see
       "Where the two announcement lists are judged" below), and
       ask's work pool (`announcementItemsStillOpen`, asked of the *feed*
       date, because the context document keeps it). The one place that
       cannot is the widget's ledger fallback (`LedgerWidgetReader`, another
       process, no post dates): it keeps the dated half, `dueAt < now`, for
       announcement rows, and the app's published snapshot, built with the
       whole rule, wins whenever there is one.
    2. **Undated tasks age out**: shown until 7 days after the post, then
       gone (`undatedAnnouncementTaskLifetime`). The post date is the
       announcement log's `postedAt` for a Canvas post, the Ed post's
       posting day (`edPostDate`) for an Ed post, and, when neither still holds the post, when
       the ledger first saw the row (`AssignmentStore.firstSeenDates`, a
       read, no new column). A syllabus exam has none and is never aged.
    3. **Same-day class reminders are not cards**: a title that opens with
       attend / come to / come in / bring / join us (after "please",
       "remember to", "don't forget to"), or says "in class/lecture today",
       and is due within 12 hours of the post or on its calendar day
       (`AnnouncementClassReminder`). "HW 3 due tonight" stays, and so does
       a found exam. This one needs the post's *own* date: the first-seen
       fallback is not the post's time.
    **Where the two announcement lists are judged.** `announcementPageItems`
    and `announcementFinds` are the megaphone's *input* and are deliberately
    not filtered by this rule in `isVisibleAnnouncement`: the sheet judges
    them at display time (`announcementFoundItems(now:)`, the badge), so the
    page keeps a past row the sheet will not show (`AnnouncementSheetTests`;
    the merge briefly filtered one level too early, which that test caught).
    Feed items (Canvas, Gradescope, manual) are never judged by any of it.
    The Ed pass reads only posts dated within the 14 days the Canvas pass
    uses, and skips a post with no date (`edDocumentsEligibleForTasks`); the
    date is the header's posting day (`edPostDate`), so a thread bumped by a
    reply yesterday is not "recent". The megaphone's found list and its
    badge ask the same rule, so what the dashboard keeps off itself is not
    listed there either, and neither is ask (since the 2026-10-20 merge,
    blind; before it ask still called them outstanding).
  - **How the posts are read, and what stops them being read forever**
    (merged 2026-10-20; the limits written 2026-10-19 without a compiler).
    Two passes, one ratchet. Canvas announcements go through
    `syncAnnouncements`, Ed announcements and pinned posts through
    `syncEdAnnouncementTasks`; both pick their extractor with
    `announcementExtractor(for:courseCode:)`, share the informational gate
    and the "ai assist" switch, and record what they read in
    `processedAnnouncementIDs`. The limits protect the quota `ask` shares (on
    2026-10-19 one failing extractor re-sent the same 13 posts every 15
    minutes and emptied it): a post that fails extraction three times is
    marked read with no find (`announcementExtractionAttemptsV1`, "gave up
    N"), a quota refusal ends the run touching no counter, and a run in
    which every backend extraction failed backs the extractor off for an
    hour (`announcementExtractionBackoffUntilV1`; in the Canvas loop the
    list is still refreshed). **Both passes obey all three, on the same two
    keys** (the Ed pass since the review of 2026-10-20, blind; Ed ids are
    `ed:…` and Canvas ids digits, so the counters cannot meet, and one
    back-off serves one quota). The Ed pass also keeps Marco's own six-hour
    wait (`edTaskRetryAfterV1`) for a failed post under the cap. Both keys
    clear with the processed ids, on disconnect and in the extraction repair.
    **Twins are dropped at write time by both passes**
    (`droppingAnnouncementTwins`; the post still counts as read): an Ed task
    that restates a task on the ledger or earlier in the run, and a Canvas
    task that restates an Ed find already on the ledger (the Canvas loop
    compares only against Ed finds, not against other Canvas posts). A
    syllabus exam row is never in the comparison pool, so an Ed or Canvas
    post that *moves* an exam is filed, not dropped as the syllabus's twin;
    the dashboard then shows the announced date (`announcementDedupOrder`
    offers the syllabus last). Staff posts that are neither
    announcements nor pinned are no longer read for tasks (the Canvas loop
    read them for one day).
  - **Exam cards** (2026-10-18, owner's call; not yet on a phone). "If
    you ever have a midterm, the class finds it from the syllabus or from
    an announcement. Either way, if a midterm is found, don't duplicate
    it." An exam card is black with white type in light mode and white
    with black type in dark (`SmoothExamPalette`, drawn when the title is
    an exam by `ExamDetection.isExam`, or when the dashboard says so with
    `DashItem.examStyleOverride`). Three roads in, one card out:
    - **The syllabus.** `AppState+SyllabusExams.swift` runs
      `SyllabusExamRows` over each class's syllabus, course home page and
      course pages in the on-device course knowledge (not announcements,
      modules, assignment descriptions or Ed, which have their own
      readers), at launch and whenever the knowledge changes, off the main
      actor. `SyllabusExamExtractor` finds the lines that name an exam
      next to a date. Each exam is a `.canvasAnnouncement` row, kind
      `.event`, whose `sourceID` is `syllabus-{canvasCourseID}-{kind}[-n]
      [-makeup]` (`AnnouncementRecord.syllabusFindSourceID`,
      `ExamIdentity.sourceKey`): the id is the exam's identity and not its
      date, so a second pass writes the same rows, a moved date updates
      the row and keeps its tick, and an older build reads an announcement
      task. No new `Source`, no new column, for the reason given under Ed
      finds above. A date with no time is stored at 23:59:59 local like
      every all-day Canvas entry (`AllDayDueMoment`), so the exam is
      "today" all day and leaves the dashboard when the day is over (into prev
      only if it was finished), and the open
      card hides the clock time for it. Rows are never deleted when a
      syllabus stops naming an exam (Known gaps).
    - **An announcement.** An announcement task whose title *leads with*
      an exam ("Midterm 1", "Take the final exam"; not "Bring a calculator
      to the exam", `ExamDetection.leadingExamIdentity`) is a found exam
      too (`Assignment.isFoundExam`).
    - **Canvas or Gradescope** list it as an ordinary item and keep every
      rule they had.
    - **One card per exam.** `resolvingAnnouncementDuplicates` also joins
      by exam identity and date (`ExamDetection.isSameSitting`): the same
      kind, number and modifiers within 60 days is one sitting (a
      reschedule, not last year's recycled site), and an unnumbered exam
      against a numbered one, or Midterm N against Exam N, only when both
      are dated within a calendar day. A final is only another final, two
      different numbers never match, a makeup is its own exam. Precedence:
      a feed item, then an announcement, then the syllabus (the order
      `announcementDedupOrder` offers them in), so an announced new date
      replaces the syllabus's; an announcement with no day does not hide a
      syllabus row that has one, and neither does a Canvas or Gradescope
      exam with no due date (the dated twin is the card and the feed row is
      left out of the dashboard, `displaced`; nothing is written onto it).
      The hidden twin stays in the ledger and a tick on it carries to the
      card that is shown only if it was a tick on the same day: the
      tick on the syllabus's Oct 23 midterm does not complete the Oct 30
      one an announcement moved it to.
    - **Rules for a found exam.** It shows for every class that is not
      hidden whatever the class's "announcements on dashboard" and "items
      with nothing to submit" switches say. Past and unfinished, it leaves
      the dashboard like any announcement task (finished, it stays in prev);
      a feed exam keeps its normal overdue behaviour. It gets the ordinary lead-time reminders and never the
      loud 10-minute alert (`NotificationScheduler.loudAlerts` skips
      `isFoundExam`: the syllabus's rows are `.event` and already out, but
      the announcement extractors file every exam as a submission). A
      syllabus exam is in the megaphone's found list since 2026-10-18 (it
      was left out before, as found in no announcement), and its card
      says "from syllabus".
  - **Cards.** Tap a card to open it (full date, "edit date", and since
    2026-10-09 "open in canvas" / "open in gradescope", derived at display
    time by `Assignment.sourceLinks` from the URL the ledger already
    stores; a Canvas+Gradescope pair shows both, manual work and recurring
    tasks show none). An edited date is saved since 2026-10-10
    (`dueDateEditsV1` in `UserDefaults.lhf`, owned by `AppState`,
    `AppState+DueDateEdits.swift`) and is what the card, reminders, the
    widget and the on-device answerer all use; before that it lived only
    in the view model and was gone on relaunch. The context document sent
    to the server keeps the feed date on purpose, because
    `docs/PRIVACY.md` promises due-date edits never leave the phone. The
    ledger is the edit's proper home; defaults is the stopgap that avoids
    a schema migration. On the student's own work the opened card also
    shows "delete" (a one-off task) or "stop repeating" (an occurrence of
    a recurring task), each behind a system confirmation (2026-10-10;
    `OwnTaskRemoval`, `AppState.removeManualAssignment` /
    `removeRecurringTask`). Never on feed items or on preview and demo
    data. Swipe right
    to complete it, with a small paper-scatter animation. A floating
    button opens **ask**.
- **Grade Watcher** (`GradeWatcherView`). **Removed from the app by the
  owner on 2026-10-18** (`FeatureFlags.gradeWatcher = false`): no grades
  button, so no route to `GradeWatcherView` or `GradeReportView` in a
  Release build (the DEBUG `-LHFShowGrades`/`-LHFShowReport` launch
  arguments still work), and no "grade posted" notifications
  (`NotificationScheduler.gradeNoticesToPost`, at the posting point).
  Nothing is deleted, and the Canvas grade fetch
  (`AutoSyncCoordinator.refreshCanvasGrades`) deliberately keeps
  running: it is the only source of auto-submitted state, "turned in"
  notices, the 401 session-renewal probe, course intel and
  announcements, and the course-knowledge refresh. Gating that fetch on
  the flag is the wrong fix. What it was, per-course grades from
  Canvas's API with the student's session:
  - syllabus categories (`GradeCategoryMap`, editable in
    `GradeCategoryMapEditor`, with a server-suggested mapping)
  - a "decided" syllabus prediction (`GradeCountPredictor`)
  - per-item/category/course overrides with provenance
  - a "how this is calculated" panel
  - the grade report (`GradeReportView`)

  `docs/grades.md` is the design record.
- **ask / "the tree"** (`AssistantView`). A chat about your classes: the
  server path for Penn, with the on-device responder as fallback. Either
  way the search over course material runs on the phone (see "ask:
  retrieval is on the phone" under Architecture). Source chips under an
  answer are links when they can be tied to exactly one document
  (`CitationLinks`, 2026-10-10). Its own canned lines are a few words
  ("Couldn't find that.", "answering from your phone.").
- **Profile** (`SettingsPage`; `ProfileView` is only a wrapper), in order:
  1. your name
  2. accounts (Canvas and Gradescope connect/disconnect; "update password"
     only when Penn rejected a saved PennKey password; "sign in to
     canvas" under the canvas row when Canvas is connected with no saved
     login, since 2026-10-18). The sign-in health lines and the "ed
     discussion" status row that `v8` added here were taken off the page
     on 2026-10-10 ("a whole yap about Canvas", Marco), moved into one
     collapsed "sign-in diagnostics" disclosure, and on 2026-10-18 put
     back in plain view at their `ba75e97` places (health lines under
     the canvas row, the ed row under gradescope) at the co-owner's
     request, still `#if DEBUG`. The disclosure is gone. The three sync
     summary rows (announcements, ed tasks, course material) sit under the
     ed row, also `#if DEBUG`. A Release build shows none of it. The
     strings and `SignInHealthTests` remain.
  3. appearance (light / dark; there is no "system" option and the
     default is light, whatever this file said before 2026-10-10)
  4. reminders (on/off; 10 minutes, 1 hour, 3 hours, 1 day, 2 days;
     "turned in" confirmations). "10 minutes before" (`LeadOffset.m10`,
     2026-10-09) is opt-in: off by default and absent from the onboarding
     pills (`LeadOffset.onboardingOffered`). A reminder's title is the
     class and its body is the assignment's name then the lead phrase
     ("Problem Set 4. Due in 1 hour", `NotificationScheduler.reminderBody`,
     2026-10-09; before that the body was the lead phrase alone). Since
     2026-10-18 a **"loud 10-minute alert"** switch sits beside them, on
     by default (`notif.loudAlertEnabled`): for work that takes a
     submission and has not been handed in, three Time Sensitive
     notifications three seconds apart at 10 minutes before the due time
     (`NotificationScheduler.loudAlerts`). Not for anything with nothing
     to submit, a recurring occurrence, a completed item or an exam the
     app found (exam cards, below); at most 10 items, nearest first,
     planned before the ordinary reminders so they come out of the same 60
     pending slots, and it replaces the plain "10 minutes before" for an
     item that has the alert. It needs the Time Sensitive entitlement in
     `App/LHFApp.entitlements` (iOS only); without it iOS delivers them as
     ordinary notifications and says nothing. Never heard on a phone yet.
     The owner calls it **"Berserk mode"** (2026-10-19: right before an
     assignment goes unsubmitted it "goes berserk and forces you to notice
     and either fix it or do something about it"), and since 2026-10-19
     (`v8-loud-alert-actions`, not on a phone) each buzz carries two
     buttons: **"turned in"**, which silences that item's remaining
     buzzes at the tap and then marks it done exactly as a swipe does once
     the dashboard has loaded, and **"open in canvas"**, the card's own
     link ("open in gradescope" for a Gradescope-only item; manual work and
     Ed finds get "turned in" only). Both open the app (`.foreground`), on
     purpose: handling "turned in" without opening it would run app code
     off screen, the path that has crashed on every background wake. The
     one notification delegate (`NotificationResponseDelegate`) is
     installed in `LHFApp.init`, because iOS hands a button tap that
     cold-launches the app only to a delegate assigned before launch
     finishes; the old one was assigned at the first reschedule, too late.
     Taps wait in a queue (`NotificationActionInbox`) until the dashboard
     is bound, so none is lost or applied to an empty list; a waiting
     "open" expires after 2 minutes (a Mac with its window closed would
     otherwise open Canvas days later), a waiting "turned in" never does,
     because it is the student's own claim. Rules in
     `LoudAlertActions.swift`.
     **On iOS 26 it is a real alarm** (2026-10-19, owner's call: "the
     three buzzes doesn't quite do enough"; rang on Marco's iPhone the
     same day). When the
     student allows AlarmKit (one system prompt, from the first foreground
     reschedule that has something to ring; usage string in
     `NSAlarmKitUsageDescription`, kept in both `project.yml` and
     `App/Info.plist`), the three buzzes become one AlarmKit alarm at the
     same moment for the same items (`plannedAlarms` reuses `loudAlerts`).
     It goes full screen and rings through silent mode and Focus like the
     Clock app. Below iOS 26, on the Mac, with permission refused, or
     whenever AlarmKit throws, the buzzes stay. The secondary button is
     **"turned in"**, the only one that marks anything done. Stop opens
     the item's Canvas or Gradescope page, or only stops when there is
     none (Traps, "an alarm's stop is any dismissal"). Since iOS 26.1 the
     system draws its own "Stop" label. The intents are `LiveActivityIntent`s in
     `App/LHFApp.swift`, handed to the package through
     `BerserkAlarmIntents.factory`, because the system needs App Intents
     metadata it extracts from the app target. Alarm ids are a hash of
     (assignment id, ring time), so a reschedule is idempotent and a moved
     due date replaces the alarm. A reconcile never stops a ringing alarm
     except for an item the student has just finished. Preview and demo
     data never ring. Its sound is `App/berserk-alarm.caf` (2026-10-19, the
     owner's pick: the first 13 seconds of Ed Motta's "Seis da Tarde",
     faded out over the last 4, at 80% volume ("like 20% quieter"), 16-bit
     CAF), played from the main bundle
     because that is the only place developers report AlarmKit's
     `.named` finding a sound; without the file it is the default tone.
     **It is commercial music: fine on the owner's own phone, but it must
     come out (the file plus its four `project.pbxproj` lines) before any
     archive, TestFlight or App Store build unless it is licensed.** It
     is in the public repo since 2026-10-19: the owner chose to push it,
     saying he accepts the copyright risk, after being told the repo is
     public and that git history keeps it. Files: `BerserkAlarmPlan.swift` (pure rules),
     `BerserkAlarmDelivery.swift`, `BerserkAlarmScheduler.swift`
     (AlarmKit, iOS 26 only).
  5. classes (rename, hide, delete/restore; "add recurring task")
  6. notifications (per-class reminders, lead times, announcements on
     dashboard, items with nothing to submit, the announcement "ai assist"
     opt-out)
  7. sync (iCloud sync, off by default; on macOS, open at login)

  `ProfileSemesterSection` (semester rollover, "add a class") exists but
  is only reachable from its `#Preview`; `VisualStructureTests` forbids
  "semester" in the page body, so none of its text ships.

  **Copy rule (2026-10-10, Marco): the least text that works.** No
  explanatory sentences, no captions restating a control, no raw system
  errors, no developer diagnostics on a normal screen. Sync failures
  read "couldn't sync"; the Canvas banner reads "reconnect canvas",
  "duo needs you", or "pennkey password rejected". What must stay is
  listed in the memory note `keep-copy-minimal` and comes from
  `docs/PRIVACY.md` and `docs/appstore/REVIEW_NOTES.md`.
- **Background.** A 5-minute refresh loop while open, `BGAppRefreshTask` in
  the background (`BackgroundRefresh.swift`), silent Canvas session renewal
  (`CanvasSessionRenewer`, plus the saved PennKey password where
  available) and "turned in" notifications. Grade-change notifications
  are held back while Grade Watcher is off (2026-10-18).
- **Widget** (`LHFWidget/`, a separate process). Next-due list in small and
  medium; lock-screen inline, rectangular, and circular ("N due" within 24
  hours). It shows the app's published snapshot whenever one decodes,
  empty included ("all clear"), and reads the ledger only when the app
  has never published (`WidgetSnapshotStore.current`, 2026-10-10). Its
  timeline has an entry at each of the next due times so it re-renders
  when work goes overdue (`WidgetTimelinePlanner`); overdue work stays
  listed.
- **Mac.** The same app, plus a menu-bar extra that keeps the sync loop
  alive (`LHFScenes.swift`) and open-at-login.

## Commands

```bash
# Tests — the primary gate. Runs on the macOS host.
cd LowHangingFruitKit && swift test
# If a parallel run hangs (see Test baseline), this is the reliable form:
cd LowHangingFruitKit && swift test --no-parallel

# iOS build (simulator)
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# iOS build to a connected phone, then install and launch
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug \
  -destination 'id=<device UDID from -showdestinations>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <CoreDevice id from `xcrun devicectl list devices`> <path>/Smooth.app
xcrun devicectl device process launch --device <CoreDevice id> com.lhf.lowhangingfruit

# macOS build (the package; `swift test` also exercises this)
cd LowHangingFruitKit && swift build

# Backend — Deno/Supabase Edge Functions, a separate toolchain from the above
cd backend && deno task test
cd backend && deno task check
```

`xcrun devicectl` launch fails with `FBSOpenApplicationServiceErrorDomain
error 1` when the phone is locked; the install still succeeded. The built
product is `Smooth.app` (see the macOS naming trap below).

`-LHFDemoData` (DEBUG only) seeds the bundled sample courses so the app is
usable without a real Canvas session, and pairs with `-LHFShowSettings`,
`-LHFShowGrades`, `-LHFShowReport`, `-LHFShowAssistant`, `-LHFTabAll` or
`-LHFTabDone` to land directly on a screen:

```bash
xcrun simctl launch booted com.lhf.lowhangingfruit -LHFDemoData -LHFShowAssistant
```

`-LHFAgeCanvasSession` (DEBUG only) backdates the saved Canvas cookies'
`capturedAt` by 25 hours before launch, so the real renew-on-open path runs
now instead of tomorrow. Every silent-renewal step in a DEBUG build is
printed as an `LHF-RENEW` line and kept in `UserDefaults.lhf`
`debugRenewalLogV1` (last 50: time, app state, status; never a cookie, URL
or credential). Watch it live on a tethered phone (the `--` matters, or
devicectl eats the flag):

```bash
xcrun devicectl device process launch --console --terminate-existing --device <CoreDevice id> com.lhf.lowhangingfruit -- -LHFAgeCanvasSession
```

After the fact, read it (and the session flags) straight off the phone,
read-only, from the App Group plist:

```bash
xcrun devicectl device copy from --device <CoreDevice id> --domain-type appGroupDataContainer --domain-identifier group.com.lhf.lowhangingfruit --source Library/Preferences/group.com.lhf.lowhangingfruit.plist --destination /tmp/lhf.plist
```

Since 2026-10-19 (blind) that plist also holds one-line summaries of the
last announcement sync (`lastAnnouncementSyncSummaryV1`: where it exited,
Canvas count, eligible, finds, errors, processed, the first error's kind,
"gave up N"), the last Ed task pass (`lastEdTaskSyncSummaryV1`, 2026-10-20,
blind: eligible, finds, errors, processed, first error; a run with nothing
to read is written in front of the last real line, "| last run:") and the
last course-material sync (`lastCourseKnowledgeSyncSummaryV1`: outcome,
courses, documents, manifest, upload, the Ed status line); a DEBUG build
shows the three as "announcements", "ed tasks" and "course material" rows
in Profile → accounts, under the ed discussion row (they were in a
"sign-in diagnostics" disclosure before the merge, which no longer exists).
Counts and words only, never a title, id, body or URL. They exist because
on 2026-10-19 the Announcement Watcher produced no Ed finds on Olisa's
phone and nothing on the device said where the sync had stopped.

Crash reports come off the phone the same way (`--domain-type
systemCrashLogs`, files named `Smooth-<date>.ips`; list them with
`xcrun devicectl device info files --device <id> --domain-type systemCrashLogs`).
An `.ips` is one JSON header line plus a JSON body: read the thread with
`"triggered": true`. Reading someone else's phone needs it paired in
Xcode → Devices and Simulators first; Finder's "Trust" alone is not
enough for `devicectl`.

Release upload (2026-09-27, the path that worked; do **not** run
`xcodegen generate` first, whatever `docs/appstore/CHECKLIST.md` used to
say, and bump `CURRENT_PROJECT_VERSION` by hand in both `project.yml` and
`project.pbxproj`):

```bash
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Release -destination 'generic/platform=iOS' -archivePath build/Smooth.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Smooth.xcarchive -exportPath build/export -exportOptionsPlist docs/appstore/ExportOptions.plist -allowProvisioningUpdates
```

The export step uploads straight to App Store Connect, using the Apple
account signed into Xcode. Submitting for review is a separate, manual
step in App Store Connect; there is no API key on the dev Mac.

## Test baseline

**Last verified counts, one per line of work. The merged count below them
is a prediction, not a run.** (The three suites that write the shared
extraction keys, `EdAnnouncementTaskTests`, `EdAnnouncementTaskMergeTests`
and `AnnouncementWatcherSyncTests`, are nested under one serialized parent,
`AnnouncementExtractionSuites`, so a parallel run cannot interleave them.)
- **`v8` (Olisa's line): 2033 tests / 192 suites, all green, at `2b46ce7`**
  (2026-10-19, `swift test --no-parallel`, on Olisa's Mac, 6.0 s). That is
  the launch-prep merge (1975), the Ed posting-date fix (11), Ed posts
  through the Announcement Watcher (12), the sync summaries (8), the
  first-error line (2), announcement tasks vanishing at their due time
  (7), the work-identity dedup tier (13) and the extraction retry cap
  (5). Compiled for iOS in Debug the same day (built to Olisa's iPhone).
- **`v8-loud-alert-actions` (Marco's line): 2332 tests / 209 suites, all
  green** (2026-10-19, `e3f9af8` plus the AlarmKit alarm and its custom
  sound, `swift test --no-parallel` on Marco's Mac, 10.6 s, the only test
  run on the machine; its base `v8-announcements` is 2230/206,
  re-verified the same day before anything changed, and the 2026-10-10
  figure was 1975/189 on `v8-launch-prep`). The iOS Debug compile
  (`-destination 'generic/platform=iOS'`), which is what compiles
  `App/LHFApp.swift`, ended in BUILD SUCCEEDED. Both lines branch from
  `v8` at `beed156` (1975/189).
- **`v8-merge-loud-alert` (the two merged, 2026-10-20): predicted 2397
  tests / 214 suites.** First compile and run at `bc9d368` on Olisa's Mac:
  2397 / 214, exactly the prediction, with two failures (a no-selected-courses
  test that read other suites' leftovers in the shared course cache, and the
  megaphone page list filtered a level too early); both fixed afterwards,
  not yet re-run. 1975 plus Marco's 357 plus Olisa's 58 is
  2390; the merge's own net is +3 tests and +1 suite (see the history
  entry below for what was deleted and added), and the review of
  2026-10-20 added 4 tests (a moved exam is not the syllabus's twin; the Ed
  pass's three-strike cap and its back-off; a Canvas post restating an Ed
  find) and the parent suite: +4 and +1. There is no Swift toolchain
  where the merge was written, so nothing in it has been compiled; the
  first thing to do with this branch on a Mac is `swift test
  --no-parallel` and then `xcodebuild -destination
  'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`. Replace this
  paragraph with the real count; do not leave a prediction standing as a
  baseline.

Either tree compiles for iOS in Debug and Release (`xcodebuild
-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`), which
is what builds the widget extension and `BackgroundRefresh.swift`; `swift
test` compiles neither, so a change in `LHFWidget/` or behind `#if
os(iOS)` needs that `xcodebuild` before it counts as compiled. `v8` before
either line's work was 1539/154 at `e2672eb` (2026-10-09). Hold the rule:
a change that lowers the count has lost work. Investigate rather than accept it, and when a
count drops on purpose (a feature removed with its tests), say which tests
and why in the commit.

Known problems, all pre-existing:
- **Full-run hang.** A parallel `swift test` sometimes stops forever with
  the main thread inside `SecItemCopyMatching` →
  `ItemImpl::checkIntegrity` (the legacy macOS file keychain). It is not a
  Keychain prompt; no SecurityAgent is running. Sampled 2026-09-23 through
  `CanvasAccessTokenStore.load()`; `fac110d` gated that read behind
  `FeatureFlags.canvasAccessTokenValue`, and it still recurred on
  2026-09-24 in the Keychain suites. `--no-parallel` has never hung. When
  it recurs, sample it from a second terminal before killing it:
  `sample $(pgrep -f LowHangingFruitKitPackageTests | head -1) 3 -file /tmp/sample.txt`.
- **`SessionCookieStoreTests` "a calendar-link-only install … cannot use
  Grade Watcher"** reads `canvasSessionExpired` as true. It passes alone
  and in `--no-parallel` runs, but fails most parallel full runs since the
  session-persistence commits (`fac110d`..`99609c0`, 2026-09-24); before
  them it was about one run in ten. A cross-suite race over process-wide
  state that hasn't been pinned down.
- **`CourseContentDashboardTests`** ("flipping a content decision never
  changes `canvasCourseIDsByCode`…") races another suite over shared
  `UserDefaults`, perhaps one run in four. See the shared-`UserDefaults`
  trap: the fix belongs in the polluting suite, not the assertion.

Two lessons from diagnosing the hang: `swift test 2>&1 | grep` fully
buffers the runner's stdout, so the last line printed is not where it
stopped (use `script -q /tmp/log swift test` for a pty); and `--filter`
matches Swift type names (`SessionCookieStoreTests`, or
`SessionCookieStoreTests.testName` with multiple `--filter` flags), never
the quoted display names.

History (newest first; each verified on a Mac). The notes say what moved
the count, so a later drop can be traced:
- **2397/214 predicted, not run**, `v8-merge-loud-alert`, 2026-10-20 (2393/213
  at the merge commit, then +4 tests and the parent suite
  `AnnouncementExtractionSuites` from the review: `movedExamIsNotTheSyllabusTwin`
  and `threeFailuresGiveUp` and `backoffAfterAnAllFailedRun` in
  `EdAnnouncementTaskMergeTests`, `canvasPostRestatingAnEdFindAddsNoRow` in
  `AnnouncementWatcherSyncTests`; the harnesses of
  `EdAnnouncementTaskTests` and `EdAnnouncementTaskMergeTests` now also back
  up and clear the retry counters and the back-off, which the Ed pass writes
  with a fixed test clock): the
  merge of `v8` (Olisa) and `v8-loud-alert-actions` (Marco). Arithmetic:
  1975/189 (common base) + 357/20 (Marco) + 58/3 (Olisa) = 2390/212, then
  the merge's own changes. **Deleted on purpose (6, none of Marco's):** in
  `AnnouncementWatcherEdTests` (now `AnnouncementWatcherSyncTests`),
  because they fed Ed posts through `syncAnnouncements` or pinned the
  `announcement-ed:` find id of the Canvas loop's brief Ed reading, which
  the merge removed in favour of Marco's own Ed pass: `edPostBecomesFind`,
  `staffAndPinnedPostsAreRead`, `nothingElseIsRead`,
  `canvasAndEdTwinsMakeOneFind`, `edTwinOfAnEarlierFindIsDropped`; and in
  `AnnouncementLogTests`, `edAdapterSelection`, whose subject
  (`edAnnouncementsForExtraction`) was removed. The Ed pass's own
  selection is `EdAnnouncementTaskTests`'. **Added (9):**
  `edPostsAreNotReadHere` in the renamed suite, and the new suite
  `EdAnnouncementTaskMergeTests` (8: the posting day as the date and the
  window, the twin drop against the ledger and within a run, the quota
  stop, an ordinary failure still waiting, the summary lines, preview).
  **Rewritten, same names or renamed, none loosened:** the other 13 tests
  of the renamed suite now use Canvas announcements as fixtures (the
  summaries, the retry cap, the quota stop, the back-off);
  `AnnouncementLogTests` `edFindJoin` (Marco's `ed-` id and
  `recordID(fromFindSourceID:)`), `edAdapterUsesPostingDay` (now
  `edPostDateUsesPostingDay`, asserts `edPostDate`),
  `edFindCollapsesOntoCanvasAssignment`; `DashboardFilterTests`
  `expiredAnnouncementFindBoundaries` (asks `isHiddenAnnouncementTask`, and
  pins `isExpired` as the `.event` rule alone) and `pastDueFindVanishes`
  (its megaphone "find" fixtures now use informational wording, since
  Marco made every task a card); one call in Marco's
  `AnnouncementTasksOnDashboardTests` renamed `isExpiredEvent` →
  `isExpired`. Where the two sides could disagree, the tests worth reading
  first: `AnnouncementFindExpiryTests` (Olisa's vanish rule, whole) against
  `AnnouncementTaskRulesTests` (Marco's rule). Compiled: no.
- (`v8`'s own history, newest first)
- 2033/192 `v8`, 2026-10-19 (evening): the work-identity dedup tier
  (`AssignmentDeduplicatorTests`, 13) and the extraction retry cap
  (`AnnouncementWatcherEdTests`, 5; the suite is `AnnouncementWatcherSyncTests` since the merge).
- 2015/192 `v8`, 2026-10-19 (later): announcement and Ed tasks vanish at
  their due time (`AnnouncementFindExpiryTests`; its first run had one
  failure from fixture titles the twin check merged, fixed in `6291b2f`).
- 2008/191 `v8`, 2026-10-19 (afternoon): Ed posts through the
  Announcement Watcher (`AnnouncementWatcherEdTests`,
  `AnnouncementLogTests`), the sync summaries and the first-error line
  (`SyncSummaryFormatTests`).
- 1986/189 `v8`, 2026-10-19: the launch-prep merge plus the Ed
  posting-date fix (`EdDocumentHeaderTests`, `AnnouncementEdRowsTests`,
  `EdIngestionTests`, `EdClientTests`).
- (`v8-loud-alert-actions`'s own history, newest first)
- 2332/209 `v8-loud-alert-actions`, 2026-10-19: plus 4 tests for the
  alarm's custom sound (the pure choice, the file, the app target's
  Resources phase read from `project.pbxproj` as a property list, and
  the glue asking `Bundle.main`).
- 2328/209 `v8-loud-alert-actions`, 2026-10-19, `swift test --no-parallel`
  alone on the machine: 2269/207 plus 59 tests and 2 suites for the
  AlarmKit alarm (`BerserkAlarmTests`, `BerserkAlarmDeliveryTests`: the
  plan's parity with `loudAlerts`, stop never "turned in", the delivery
  and settlement tables, "every loud item ends with exactly one of alarm
  or buzzes", ringing-alarm rules, the reschedule serializer). Each review
  fix was reverted in turn and its tests seen failing. The iOS Debug build
  extracts App Intents metadata for both alarm intents; the macOS build
  (`CODE_SIGNING_ALLOWED=NO`) succeeds too.
- 2269/207 `v8-loud-alert-actions`, 2026-10-19, `swift test --no-parallel`
  as the only run on the machine: 2230/206 plus 39 tests, nothing removed.
  One new suite (`LoudAlertActionTests`: categories, labels, parsing,
  the bound-before-drain inbox, staleness, silencing at the tap, and
  source scans of `LHFApp.init` and the scheduler's delegate) and new
  request tests in `LoudAlertTests`. Each review fix was reverted in turn
  and its own test was seen failing.
- 2230/206 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as the
  only run on the machine: the next two entries applied together.
  2190/202 plus 17 (the rules) plus 19 (the sheet) plus 4 new in
  `AnnouncementSheetTests.swift` for the two together: the found list
  follows `isHiddenAnnouncementTask` (an undated task a week past its post and
  a same-day be-there reminder are off it, a syllabus exam is never aged,
  and it equals the not-hidden rows one for one), and through an `AppState`
  the aged-out task and the reminder leave both the list and the badge while
  `announcementPageItems` still holds them. Nothing removed; nothing
  rewritten in the merge. The sheet's own `megaphone` test in
  `SyllabusExamDashboardTests` and the rules' tests merged without conflict.
  Each of the new rules was checked by breaking it (dropping the post dates
  from the call) and watching four named tests fail. One fixture lesson, as
  twice before: the first version of the one-for-one test used titles
  "Task 3 to hand in" and "Task 4 to hand in" with dates hours apart, which
  `resolvingAnnouncementDuplicates` correctly collapses into one card.
- 2209/205 `v8-announcements`, 2026-10-18, the sheet redesign alone (before
  the rules patch below was applied), `swift test --no-parallel` as
  the only run on the machine: 2190/202 plus 19 tests in three new suites
  (`AnnouncementSheetRulesTests`, `AnnouncementSheetBadgeTests`,
  `AnnouncementSheetStructureTests`, in `AnnouncementSheetTests.swift`)
  and one in `SyllabusExamDashboardTests`; nothing removed. Two existing
  tests were rewritten because they pinned the old sheet: `megaphone` in
  `SyllabusExamDashboardTests` ("leaves the syllabus's out" is now "holds
  the announced exam and the syllabus's, soonest first, and each leaves
  once its date has passed"), and `VisualStructureTests` "announcement and
  calendar quick actions have distinct accents" (the megaphone circle is
  marigold now, not the announcement teal). Each new rule was checked by
  breaking it (the window's `>=`, the not-past filter) and watching named
  tests fail.
- 2207/203 `v8-ann-rules`, 2026-10-18, `swift test --no-parallel` as the
  only run on the machine: 2190/202 plus 17. New: a suite
  `AnnouncementTaskRulesTests` (13: the attendance vocabulary pinned, the
  12-hour / same-day window, undated tasks on day 6 and day 8 from the
  log, the Ed document and the first-seen fallback, a found exam never a
  reminder, finished work still in prev, feed items untouched, no ledger
  row lost); 4 in `EdAnnouncementTaskTests` (a Sept 14 Ed post is not read
  on Oct 18 and an Oct 15 post is; the window is the Canvas constant; a
  post with no date is skipped); 1 in `SyllabusExamDashboardTests` (a
  finished past exam stays in prev). **Rewritten, because they pinned the
  "past tasks move to prev" rule that was the bug:**
  `AnnouncementTasksOnDashboardTests` `lapseRule` (now `pastRule`),
  `pastTasksMoveToPrev` (now `pastTasksDropOff`: not in todo, all or prev),
  `boundaryAndOrdinaryEvents`, `completingAPastTask` (now
  `finishingAPastTask`), `finishedTaskIsNotPast`, `editedDateDecidesLapse`
  (now `editedDateDecides`); `AnnouncementLedgerSafetyTests`
  `sameTitleTwoWeeksApart`, `liveTwinOutlastsLapsedTwin`, `lapsedOrder` (now
  `hiddenOrder`, the `lapsed:` argument is `hidden:`);
  `SyllabusExamDashboardTests` `pastExamGoesToPrev` (now `pastExamDropsOff`),
  `allDayLapsesAtTheEndOfItsDay`, `feedExamIsNotLapsed`, `pastExamSparedToo`,
  `hiddenClass`; `AnnouncementDeletionTests` `finishedTaskSurvivesDeletion`
  (lost its `isPast` check). **Removed:** `prevCardMarksPast`, a scan of
  `DoneView`/`ContentView` source for the "past" card, which no longer
  exists.
- 2190/202 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only run on the machine: 2164/201 plus 26 tests, the ledger-safety
  fixes from the review of the announcement-task commit. New: a suite
  `AnnouncementLedgerSafetyTests` (9: two days are two tasks, the live twin
  outlasts the lapsed one, no tick across dates or a reschedule, an edited
  date survives a hidden row); 7 in `AnnouncementDeletionTests`; 5 in
  `EdAnnouncementTaskTests` (retry backoff, the class going away during a
  read); 5 in `SyllabusExamDashboardTests` (an undated Canvas exam yields to
  a dated twin, the syllabus pass re-check). **Rewritten, because they pinned
  the behaviour that was the bug:** `AnnouncementDeletionTests` "a gone row
  ages out like a gone feed item, but finished work never does" (it asserted
  that `pruneAgedOut` deletes a flagged announcement row; now three tests
  assert it does not, and that feed rows still age), and the three
  end-to-end deletion tests that flagged a post on one absent response
  (`deletedPostIsHidden`, `restoredPost`, `finishedTaskSurvivesDeletion`) now
  take two, per the two-miss rule. `EdAnnouncementTaskTests` "a failed
  extraction leaves the post unread, and the next pass tries it again" now
  waits out the six hours. Each new rule was also broken on purpose and a
  named test failed (13 rules; two first mutations did not bite, because the
  mutation or the test was wrong, and a test was added for the carry in the
  title loop).
- 2164/201 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only run on the machine: 2100/198 (the tree with the loud alert, the
  vault sheet and the exam detector and card style merged in; measured
  before this change) plus 64 tests in three new suites (`ExamSittingTests`
  21, `SyllabusExamRowsTests` 14, `SyllabusExamDashboardTests` 29); nothing
  removed or rewritten. A first full run failed one existing test, "the
  per-class switch governs cards for Canvas and Ed together" in
  `AnnouncementTasksOnDashboardTests`: the first version of
  `isFoundExam` asked only whether a title named an exam, so the Ed task
  "Bring a calculator to the exam" counted as one and ignored the class's
  switch. The code was changed (`leadingExamIdentity`: the exam has to be
  what the title leads with), not the test, and a regression test now pins
  it. Each rule was also checked by breaking it and watching a named test
  fail (toggle and nothing-to-submit exemptions, the loud-alert guard, the
  megaphone exclusion, the identity match, all-day storage, placement and
  order).
- 2028/194 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only run on the machine: 1985/191 plus 43 tests in three new suites
  (`AnnouncementTasksOnDashboardTests`, `EdAnnouncementTaskTests`,
  `AnnouncementDeletionTests`); nothing removed. Two existing tests in
  `AnnouncementWatcherWiringTests` were rewritten because they pinned the
  rule the owner reversed (preparation tasks as megaphone-only finds):
  the placement vocabulary test now expects `.main` for preparation and
  keeps `.find` for informational wording, and the dashboard-surface test
  now expects the preparation row on the dashboard; both say so in a
  comment. A first run of the new suites failed three tests, all from
  fixtures whose titles were duplicates by design (two near-identical
  titles with close dates collapse into one card), fixed in the fixtures.
- 1985/191 `v8-announcements`, 2026-10-18, `swift test --no-parallel` as
  the only test run on the machine: 1975/189 plus 10 tests in two new
  suites (`GradeWatcherRemovalTests`, `HeaderMegaphoneTests`) and two new
  `SettingsCopyTests`; nothing removed. Three existing tests were
  rewritten because they pinned the old layout, none loosened to pass:
  `SettingsCopyTests` "sign-in status and ed status render only inside
  the collapsed debug disclosure" (now: debug-only, under their account
  rows, no disclosure), `DashboardSmallFixesTests` "the add and
  announcements buttons have the same 44pt hit area…" (the megaphone is
  now the header's 48pt circle), and `VisualStructureTests` "announcement
  and calendar quick actions have distinct accents" (the megaphone tints
  with its accent through the shared header circle, no separate
  `smoothAnnouncementFill`). A first run overlapped another worktree's
  and failed two unrelated suites (the shared-defaults trap, below);
  the rerun alone was green.
- 1975/189 `v8-launch-prep`, 2026-10-10: `v8`'s 1539 plus 436, nothing
  removed. By commit, so a later drop can be traced: source links +25;
  the 10-minute reminder +17; the sign-up rule +43, and +16 when it was
  reworked to stay out of the sync; reminder wording +8; the
  announcements list +36 and its window fix +4; ask's search +27 and
  excerpts and follow-ups +54; saved due-date edits +28; ask and Ed +29,
  ask's own text +19, source chips +19; the Settings copy +6, ten small
  fixes +36, the widget +21; Grade Watcher copy +7; Ed rows in the
  megaphone +23; deleting your own tasks +18. Tests that pinned old
  wording were updated to pin the new wording exactly, never loosened;
  the one test whose subject disappeared ("class" against "classes" in
  a Grade Watcher message) was replaced by one for the string that
  replaced it. Four agents ran the suite in four worktrees at once
  while this was being built and saw unrelated suites fail at random;
  that is the shared-defaults trap, and none of those runs is a
  baseline.
- 1539/154 `v8`, 2026-10-09 (later that day): the sign-out review fixes
  (`SilentRenewalCoreTests`, `SwitchSchoolConfirmationTests`,
  `SignInHealthTests` rewritten) and the Ed session-token transport
  (three in `EdWiringTests`).
- 1499/152 `v8`, 2026-10-09: Ed Discussion ingestion (`EdIngestionTests`,
  `EdClientTests`, `EdKindTests`, `EdWiringTests`) and the sign-out fix
  (`RenewalPolicyTests`, `ReconnectPaneTests`, `SignInHealthTests`; two
  tests in `CanvasSessionDeadStateTests` rewritten for the new latch rule,
  none removed).
- 1411/140 `V7`, 2026-09-27: Olisa's 24-hour cookie rule restored
  (`df759f8`, `a16ea07`). Four tests removed on purpose because they pinned
  the "keep cookies forever" rule that was reverted:
  `SessionCookieRotationTests.sessionCookieWithoutExpiryIsRetained` and
  `.explicitExpiryIsAuthoritative`, and `SessionCookieStoreTests`'
  `finalCookieDeletionDoesNotResurrectPersistedValue` and
  `partialCookieDeletionDoesNotResurrectRemovedValue`.
- 1415/140 `V7`, 2026-09-25: `CourseAccentTests` (stable per-class
  colour) with the class-chip picker.
- 1412/139 `V7`, 2026-09-24: Settings trimmed, "1 week before" retired
  (one new test, two moved from `.d7` to `.d2`).
- 1411/139, 2026-09-24: class-filter and recurring-task course adoption.
  Dice and steps prototypes removed with their tests.
- 1407/138, 2026-09-24: session persistence (`fac110d`..`99609c0`), 12 new.
- 1395/138, 2026-09-23, on `V7-polish`.
- 1371/136 `v6`, 2026-09-23: Ed Discussion recon probe
  (`docs/ED_DISCUSSION.md`).
- 1336/130, 2026-09-17: gated Canvas access tokens and stay-signed-in.
- 1253/125 `v5`: expected after reverting the preview-mode removal on
  2026-09-16 (build 9). Not re-verified on `v5` itself.
- 1241/123, 2026-09-15: preview mode removed, 12 tests deleted with it
  (reverted next day).
- Earlier marks:
  - 1252/125 and 1253/125 (2026-09-15)
  - 1250/123 and 1244/122 (2026-09-12, the Smooth merge)
  - 1230/121 and 1193/119 (2026-09-11)
  - 1170/117, 1104/109 and 1068/105 (Grade Watcher rounds 1–3, 2026-09-10)
  - 1032/101 and 1020/98 (2026-09-09)
  - 976/95, 937/92, 853/90, 838/89 and 804/87 (early `v5`)
  - 736/76 and 769/78 (`assistant-ui`)
  - 693/70 (old `v6`), 608/61 (v3.5+v4 merge), 517/55 (`v3.5`)
  - 456/40 (`v4`)
- Deno: 324 at the last recorded run (2026-09-15). Re-run
  `deno task test` before trusting it.

Nothing under `backend/` is exercised by `swift test`, and the live backend
path has only ever been exercised by hand on a device.

## Layout

| Path | What |
|---|---|
| `LowHangingFruitKit/Sources/LowHangingFruitKit/` | Pure model + parsing + persistence. No SwiftUI. |
| `LowHangingFruitKit/Sources/LowHangingFruitUI/` | Views and `AppState`. Imports the Kit. |
| `…/LowHangingFruitUI/Resources/` | Bundled media. Load via `bundledImage(_:ext:)` (`Bundle.module`) — a bare `Image("name")` resolves against the *main* bundle and silently renders nothing. |
| `App/` | iOS/macOS app target, entitlements, assets |
| `LHFWidget/` | Home/Lock Screen widget extension — a **separate process** |
| `backend/` | The Supabase project: SQL migrations, Edge Functions, `PROTOCOL.md` (the contract the app and server are both written against) |
| `docs/` | Design docs and plain-language explainers |
| `ROADMAP.md` | The plan: release blockers, next features, parked experiments. Read with this file at the start of every session. |
| `smooth-prototype/` | Marco's dependency-free HTML/CSS/JS tester for the Smooth redesign. Isolated from the app; `python3 -m http.server 4173 --directory smooth-prototype`. |
| `project.yml` | xcodegen source of truth for the Xcode project |

## Architecture

### Three storage tiers — pick deliberately

Documented at length in `docs/persistence-explained.md`. The short version:

1. **SwiftData ledger** (`Persistence/StoredAssignment.swift`, `AssignmentStore.swift`)
   — the student's own record of work: assignments, completions, grade
   observations, manual work. Loss here is unrecoverable, so this tier never
   deletes.
2. **App Group `UserDefaults`** (`Persistence/SharedDefaults.swift`, reached as
   `UserDefaults.lhf`) — preferences: cheap to re-enter, meaningless off-device.
   Per-course settings live here in `CoursePreferences`.
3. **Keychain** (`SessionCookieStore.swift`) — session cookies and the Canvas feed
   URL (it embeds a per-user token, so it is a bearer credential). Device-bound
   via `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. **Never sync these.**

### The ledger is the point

The app used to hold assignments in memory and do `canvasItems = fetched` — a
wholesale replace — so a rolling Canvas feed or one flaky fetch erased work the
student had already seen and completed. `reconcile()` now *edits*: it upserts,
flags vanished items `isGoneFromFeed` rather than deleting, and refuses a
suspiciously empty fetch. Aging is deliberate (gone **and** 14 days overdue;
undated, still-in-feed, and finished items never age out).

When touching this, assume the invariant is "**nothing the student did is ever
lost**" and work backwards from there.

### Course identity

The Canvas course code (`"PHYS 151"`) is the key that selection, reminders,
grades, dedup and `CoursePreferences` all use. `CourseCode.parse` derives it from
Canvas's descriptor (`PSYC 1010-005 202430 Intro to Psych`). A failed parse falls
back to the raw descriptor, which is both an ugly label *and* a key nothing else
agrees with — so parsing bugs are identity bugs, not cosmetic ones. Renaming a
course is deliberately cosmetic only.

### Update gate

`LowHangingFruitKit/Sources/LowHangingFruitKit/Update/` (`AppVersion`,
`UpdatePolicy`, `UpdateManifestClient`, `UpdatePolicyCache`) and the
`LowHangingFruitUI` trio `UpdateGate.swift` / `UpdateRequiredView.swift` /
`UpdateAvailableBanner.swift` are a forced-update version gate: on launch and
foreground it fetches one small public static manifest and can show an
undismissable wall below `minimumVersion` or a dismissible banner below
`latestVersion`. The contract is **fail open** — any fetch failure, unset
manifest URL, or unparseable version leaves the last-known verdict untouched
rather than inventing a block, because a broken version check must never be
the thing that locks a student out of their own ledger.

**It is live.** The manifest is the `update-manifest` orphan branch of this
repo, served at
`raw.githubusercontent.com/OlisaNW247/penn-dashboard/update-manifest/lhf-update.json`.
An orphan branch because a shipped build has that URL compiled into it and can
never be told a new one, so the path must not move when feature branches merge;
and because GitHub's web UI can edit it from a phone, which is the only way to
lift a bad block.

`minimumVersion` and `latestVersion` are kept **equal** — every release is
mandatory, so `UpdateAvailableBanner` never fires in practice. Bump both on each
release, but **only once the new build is actually downloadable**. A floor above
what the App Store will serve is the one unrecoverable mistake here: the wall's
button leads to a version that still fails the check, and everyone is stuck. The
30-day ceiling in `UpdatePolicyCache` only rescues people who are offline.

Two things that surprise people. The gate cannot reach builds that shipped
without it — 1.2.1 and earlier never fetch the manifest, so no floor retires
them; only a future release can. And local builds are `3.0.0` (`project.yml`), above any floor
that is safe to publish, so the wall never appears in normal development: to see
it, build with `MARKETING_VERSION=1.0.0` (that is how the live path was verified
end to end) or pass `-LHFForceUpdateWall`.

### ask: the model, the hedge, and the loop that tunes them

`backend/supabase/functions/ask/index.ts` streams the answer. Primary
model `openai/gpt-4.1-mini` (`LHF_MODEL`), no reasoning field; if it has
produced no content delta by 5 s, `z-ai/glm-5.3-flash` at
`reasoning.effort: low` (`LHF_ASK_FALLBACK_MODEL`) starts alongside and
whichever streams first wins, the other aborted; a primary that fails
or ends empty before any content hands over outright; once content has
flowed nothing switches. Olisa's rule: never more than a ten-second
wait. Every request writes one row to `ask_outcomes` -- outcome, tokens
including reasoning, chars, deltas, first-delta and total latency,
pre-race and race time, the model that answered and why (`detail`), and
a `probe` tag for synthetic traffic -- never the question or answer.
The pre-race reads (auth, quota, enrolment, profiles, catalog) are
timed (`ask: timing {...}` in the function log), overlapped, and capped:
quota fails open at 1.5 s, auth at 3 s.

`ask-canary` serves the same `handleAsk` with probe overrides on
(`probe: { model, maxTokens, reasoning, provider, contextTrimChars,
fallbackModel, disableFallback, hedgeAfterMs }`), so a candidate change
is measured before it touches `ask`. The loop runs from any Node 22
shell with the Management API token: `node
backend/scripts/deploy-function.mjs ask-canary --also ask` deploys,
`node backend/scripts/ask-probe.mjs --slug ask-canary --runs 20 --set
mixed --tag <tag>` fires 14k-token syllabus prompts and exits non-zero
on any empty or errored run, and a `select ... from ask_outcomes where
probe = '<tag>'` through `POST /v1/projects/<ref>/database/query` reads
the result. Deploying `ask` itself is a production change and needs a
person's go. The 2026-09-22 promotion was 55/55 on the canary (first
word median 1.8 s, p95 3.9 s, max 6.5 s) and 5/5 on production.

### ask: retrieval is on the phone

The server does no searching. `ask` answers from the context document
and whatever passages the phone sends in `excerpts`, and the context
document tells the model to say it isn't in the app's records unless an
excerpt states the answer. So a passage the phone's search misses is an
answer nobody can give, and "ask can't find it" is nearly always a
client problem. The pieces, all exercised by tests:

- **Search** (`CourseSearch`, `BM25Index`, `QueryExpansion`,
  `CourseMatcher`). BM25 over 160-220 word passages, titles indexed,
  lone digits kept ("exam 2"), singular and plural on one stem, a small
  query-only synonym table, the course scope and kind boosts applied
  *before* the cut, and one unscoped retry when a scoped search finds
  nothing. The index is rebuilt in memory at launch; nothing to migrate.
- **What is sent** (`BackendAssistantResponder.retrievedExcerpts`). Up to
  eight passages of 1,500 characters, three per document, cut at a word
  boundary; Ed posts and announcements carry "posted Oct 3"; image-only
  Ed posts are skipped. It was four passages cut at 700 until
  2026-10-10, which dropped the tail of nearly every passage.
- **Follow-ups** (`FollowUpRetrieval`). A question that names no course
  searches within the course the nearest earlier question named (up to
  four back), and a question of six words or fewer is searched with the
  one before it. On the phone only: `history` is still sent empty and
  `question` is exactly what was typed. Sending earlier turns is a
  privacy-policy change nobody has approved.
- **What the phone holds** is the limit. Canvas Files (slides, readings,
  any PDF not named "syllabus") are not ingested at all, only the 40
  newest pages get their bodies, and no announcement has ever been
  collected (Known gaps). Those are in the course-material sync, which
  Marco has said not to touch (`parked/ask-course-sync-fixes`).

### Stay signed in (Penn only)

Canvas signs students out from time to time, and reconnecting means PennKey
(and often Duo) again. Stay signed in removes that: the app saves the
student's PennKey username and password and re-fills Penn's login form
itself.

- **How it turns on.** There is no toggle (removed 2026-09-24, owner's
  call: everyone should stay signed in). After every *interactive* Canvas
  login at Penn, while no password is saved, `OnboardingView.canvasConnected`
  offers `PennKeyCredentialsSheet`. The sheet is titled "the vault" (a
  vault-door emblem that shuts once as it opens, since 2026-10-18; it
  showed a lock icon before), then one line ("encrypted in this phone's
  keychain. never sent to smooth."), and the two fields. "Not now" is always available; nothing is stored unless the
  student saves. The offer is gated on `CanvasInstallation.penn`: the sheet
  asks for a PennKey, and other schools must never see it.
- **Where it lives.** `PennKeyLoginForm` (Kit, pure) recognizes the
  identity provider's form and knows how to fill it.
  `PennKeyCredentialStore` keeps the credentials in the Keychain,
  this-device-only, never synced.
- **How it's used.** When the visible reconnect pane or the background
  `CanvasSessionRenewer` hits an expired session, the fill happens through
  one seam. `LoginNavigationObserver` auto-fills and submits the IdP form
  in the visible pane. The renewer does the equivalent with one JavaScript
  submission of that same IdP credential form per attempt, never more than
  one. It never resubmits the SAML response form the browser posts back to
  Canvas afterward: that form is exactly what the login WebView's
  universal-link guard already has to rebuild by hand (see the Canvas
  Student trap below), and resubmitting it would double-POST it.
- **Failure handling.** One rejected password disables auto-login outright
  rather than retrying, so a typo or a changed password can't lock the
  PennKey account; Profile → accounts then shows "update password".
- **Duo is a hard boundary.** The stored credential only ever reaches the
  IdP's password field, never a Duo prompt. A student enrolled in Duo still
  completes that step themselves whenever Duo asks (with Duo's own "remember
  this device" for 30 days, roughly monthly).
- **When it runs.** Whenever the saved Canvas cookie is more than 24 hours
  past its last save (`SessionCookieStore.load`), on launch or on returning
  to the foreground, on a Grade Watcher 401, and, since `v8` (2026-10-09,
  blind), on each foreground refresh while the session is expired and
  `AppState.shouldRetrySilentRenewal` says the cooldown has passed, and on
  background wakes now that the crash below is fixed. A background
  renewal runs in `RenewalContext.background` with a 20 s budget and can
  only ever *help*: `.renewed` saves cookies, `.passwordRejected` still
  disables auto-login, and every other outcome changes nothing, so a
  hidden WebView stalled on Duo in the background cannot latch the
  session dead. In the foreground `.timedOut` never latches, a
  `.landedOnLoginPage` latches only on the second consecutive landing,
  and `.needsDuo` still latches, because a retry would push a Duo
  notification to the student's phone and only an interactive login can
  grant trust. Every outcome is written to `lastSilentRenewalSummaryV1`
  (outcome, time, context; never a URL or credential) and shown in
  Profile → accounts in plain words, with whether a password is saved
  (and whether Penn rejected it or Duo is waiting) and whether a live
  Duo cookie exists ("duo remembers this phone"; never a date, because
  the cookie seen on a device lives 399 days while Penn's remember window
  is about 30).
  The second blind round (2026-10-09, after a three-slice review of the
  first): every production trigger goes through
  `AppState.startSilentCanvasRenewal()`, which stores the task so the
  background wake can `awaitPendingSilentRenewal()` before telling iOS it
  is done, and `BGTask.expirationHandler` → `abortSilentRenewal()` tears
  the WebView down; the dashboard hides the reconnect banner while
  `isSilentRenewalInFlight`; a `.failed` navigation (offline, captive
  portal) is `.timedOut`, never a login landing
  (`CanvasSessionRenewer.failedNavigationOutcome`); the background's
  "Duo has asked" stand-down is its own persisted flag
  (`backgroundDuoStandDownV1`, lifted only by `.renewed`, an interactive
  login or a newly saved password); the renewer's hour cooldown is seeded
  from `lastSilentRenewalAttemptAtV1` (so `-LHFAgeCanvasSession` now also
  clears that key); and a token mint or Grade Watcher success resets the
  landing streak (`noteCanvasSessionProvenAlive`). The runbook for the
  device check is `docs/SIGNOUT_VERIFICATION.md`.
  Every successful pass through Duo re-issues Duo's 30-day
  `browsertrust` cookie, so a student who opens the app at least monthly
  should never see Duo again. Since `v8` the Canvas login pane's pre-login
  purge keeps that cookie (`CanvasInstallation.preLoginPurgeDomainHints`);
  before, every manual reconnect deleted it, which is the most likely
  reason students with a saved password still saw Duo and the banner
  (`docs/SIGNOUT_INVESTIGATION.md`). Disconnecting still purges Duo.
- **Removal.** Disconnecting Canvas deletes the saved password.
- **Verified on a device, 2026-09-27, in the foreground.** On Marco's
  phone, with a real PennKey and Duo, `-LHFAgeCanvasSession` renewed in 8
  seconds, hands-free, and Duo re-issued its trust. Olisa's phone renewed
  the same way on its own that afternoon. A renewal during a *background*
  wake has never happened on any phone, because background wakes crash
  first.

## Traps that have already bitten

- **A "flagged, never deleted" doc comment was a delete.** Announcement
  rows hidden because their post vanished get `isGoneFromFeed`
  (`markGoneFromFeed`), copying the flag a vanished feed item gets, and
  its doc comment said "never deleted". The flag's other reader said
  otherwise: `AssignmentStore.isAgedOut` (run by `reconcile` through
  `pruneAgedOut` on every Canvas sync, over every source) deleted any
  unfinished flagged row 14 days after its date, and a test
  (`AnnouncementDeletionTests`, "a gone row ages out like a gone feed
  item") pinned the deletion as intended. After that nothing could undo
  it: `markPresentInFeed` restores a flag, not a row, and the post's id
  is in `processedAnnouncementIDs`, so the extractor never produces the
  task again. A wrongly flagged row (a truncated fetch, a class that
  returned nothing) became a permanently lost task two weeks later. For a
  feed item the same rule is harmless, because the feed lists it again;
  an announcement row has no feed to re-derive it from. Found in review,
  2026-10-18, by reading the predicate instead of the comment. The fix
  exempts `.canvasAnnouncement` (Canvas, `ed-` and `syllabus-`) from aging
  by name, in the store and in the widget's copy of the predicate
  (`LedgerWidgetReader`, which also hides a flagged announcement row now,
  since aging no longer will), and the test now pins non-deletion and
  restoration. The wrong fix is trusting the flag's doc comment, or the
  test, over `isAgedOut`: when a rule says "flag, don't delete", find
  every reader of the flag, not just the writer. Two guards beside it
  make a wrong flag rarer (a class that returned nothing is not judged;
  two misses in a row), but a rarer wrong flag was never the fix.
- **`xcodegen generate` deletes Info.plist content** unless it lives in
  `project.yml`'s `info.properties`. The widget dependency must be
  `platformFilter: iOS` — case-sensitive; `platforms:` is silently discarded.
  Don't regenerate unless a build actually demands it.
- **iOS names an app from `CFBundleDisplayName`; macOS does not.** The Mac
  build called itself "LowHangingFruit" for every version of the Smooth
  rename, in the application menu beside the Apple logo, in About, and under
  its icon, while the phone said Smooth — because nothing on macOS reads
  `CFBundleDisplayName`. The menu bar, About box and alerts read
  **`CFBundleName`**, which was still `$(PRODUCT_NAME)`; Finder, Launchpad
  and the Dock read neither, they read the **file name of the .app bundle**,
  which is `PRODUCT_NAME` itself. So the rename took all three keys, and the
  fix is not complete with any two of them. The keys had to go in
  `project.yml`, not just `App/Info.plist` — the Mac archive is the one lane
  that must run `xcodegen generate`, for the per-SDK entitlements override,
  which is precisely the step that rewrites the plist (see the trap above).
  Renaming `PRODUCT_NAME` is safe for the ledger because every path that
  holds student data derives from the bundle id or the App Group, neither of
  which moved; what it does break is a script hard-coding the built product's
  path, and it leaves an existing Mac user's pinned Dock tile stale.

- **Tests share `UserDefaults.standard`.** Any test touching selection or
  completion must normalize on the way in *and* out, or it fails the *next*
  suite. Use a scratch suite (`UserDefaults(suiteName:)` + `removePersistentDomain`).
- **`UserDefaults(suiteName:)` succeeds for any string**, entitlement or not. The
  real test for a usable App Group is asking `FileManager` for the container.
- **Without the App Group entitlement the ledger degrades to memory** and the app
  looks completely normal until a relaunch loses everything. A "storage"
  section in Settings used to surface this; it dropped out of the page in a
  Settings merge before `V7` and its dead code was deleted on 2026-09-24,
  so from then until 2026-10-10 **nothing warned the student**. The
  dashboard now shows "not saving on this phone" (`StorageHealth`). See
  Known gaps.
- **`AVAudioSession` is never configured by default**, and `AVPlayer` then
  activates it as `.soloAmbient`, which stops the user's music. `SplashView` sets
  `.ambient` + `.mixWithOthers`. The splash clips have **no audio track** — if
  this resurfaces, muting is not the fix.
- **Regex patterns needing real Unicode characters must not be raw strings.**
  `#"...\u{2013}..."#` passes the escape through literally, the pattern fails to
  compile, and `try?` turns that into a silent wrong answer.
- **`swift test` compiles the macOS slice.** iOS-only API (`PageTabViewStyle`,
  WidgetKit, `AVAudioSession`) must sit behind `#if os(iOS)` / `canImport` or it
  breaks the test build.
- **An unsandboxed macOS test run resolves the App Group container WITHOUT the
  entitlement** (learned 2026-08-24) — `swift test` on a dev Mac would reach the
  real Mac app's ledger, shared defaults, and widget snapshot.
  `SharedDefaults.isTestRunner` guards all three choke points. Never remove
  those guards.
- **Preferences go through `UserDefaults.lhf`**, never `UserDefaults.standard`.
  Tests must save and restore through the same accessor or they are not reading
  what `AppState` writes.
- **Credentials never go in defaults.** Session cookies live in the Keychain
  (`SessionCookieStore`); so does the Canvas feed URL (`ICSFeedURLStore`),
  because `…/feeds/calendars/user_<token>.ics` is a bearer credential. This is
  why `canvasICSURL` is absent from `SharedDefaults.legacyKeys`.
- **`Path.addLines` moves, it does not connect.** Building a filled outline as
  `addLines(leftEdge)` then `addLines(rightEdge.reversed())` produces two
  separate open polylines, not one closed region, because the second call does
  a `move(to:)` to its first point. Filling that yields two zero-area slivers.
  The shape still *draws* — as a pair of hairlines with the page showing
  between them, which reads as a pale object with dark edges rather than as
  nothing — so it survives code review and previews and is only obvious on a
  device screenshot. Walk the second edge with explicit `addLine(to:)`
  (`BranchBackdrop.taperedPath`).
- **A prompt-cache prefix must be byte-stable or it is not a cache.** Anthropic
  caching is a *prefix match*: one changed byte anywhere invalidates everything
  after it, silently, with no error and no symptom except the bill. So
  `AssistantContextDocument` never reads a clock, never emits a relative date
  ("in 3 days"), sorts every collection, and pins its formatters to
  `en_US_POSIX`/UTC. The wrong fix — and it looks completely reasonable — is
  "put today's date at the top of the document so the model knows what day it
  is": that changes the prefix every day, and with a timestamp, every request.
  The current date belongs in the user message, after the `cache_control`
  breakpoint. Verify with `usage.cache_read_input_tokens`; a persistent zero
  means something upstream is varying.
- **Inverting black-on-white artwork for dark mode makes a negative.**
  The "chill" Buddha was drawn in dark mode with `.colorInvert()` +
  `.blendMode(.screen)`, which lights the shadows and darkens the face.
  Dark mode now draws `chill-dark.png` (the enclosed paper kept, ink and
  border-reachable paper transparent, flood-filled as below) as a template
  tinted light blue (`smoothCobaltInk`). Likewise the pastel accents are fills, never text:
  use their `…Ink` partners (`courseAccentInk(for:)`) for type.
- **Knocking a flat background out of artwork is a flood fill, not a colour
  key.** `Resources/persimmon.png` is the app logo with its cream plate
  removed, and the obvious approach — make every cream pixel transparent —
  destroys it: the seams *between* the calyx lobes are the same cream as the
  plate, so keying on colour punches holes straight through the calyx and the
  lobes lose the separation that makes them legible at 26pt. Fill from the
  image border instead, so only cream reachable from the edge goes. The same
  logic catches a subtler case — an *excluded* shape's enclosed detail (a
  leaf's cream vein) is equally unreachable from the border, so it survives as
  a stray mark floating where its leaf used to be, and has to be culled by
  asking which shape encloses it. There is no PIL, ImageMagick or numpy on the
  dev Mac; `sips` resizes and converts but does none of this. A short
  CoreGraphics script run with `swift file.swift` is the tool.
- **The Canvas assignment id is in the ICS event's URL *fragment*.** Canvas's
  `to_ics` (`app/models/calendar_event.rb`) writes every assignment event's
  URL as `/calendar?include_contexts=course_<id>&month=…&year=…#assignment_<id>`
  — never `/assignments/<id>` — and its section-override branch rewrites the
  UID to `event-assignment-override-<overrideID>` and the summary to
  `"<title> (<section>) [<code>]"` while leaving that URL alone (its own
  source says `# TODO: event.url`). So the fragment is the only id an
  override row carries, and the number in an override UID is an *override*
  id, a different id space: join on it and the wrong work reads as done.
  `Assignment.canvasAssignmentID` reads the fragment; the diagnostics
  report's `via=fragment` is the proof it worked. Confirmed on a real phone
  2026-09-09 after every PHYS 0151 lab row showed `via=none`.
- **`PersimmonMark`'s `size:` argument does not constrain it.** Its body is a
  `GeometryReader` that ends in `.frame(maxWidth: .infinity, maxHeight:
  .infinity)`, so the view expands to fill whatever space its parent hands
  it; `size:` only sizes the image drawn *inside* that already-expanded
  frame. Passing `size: 64` into an unconstrained `VStack` slot renders a
  full-screen persimmon, not a 64pt one — a caller must also apply an
  explicit `.frame(width:height:)`, exactly as the file's own `#Preview`
  does. The wrong fix would have been either hunting for a magic `size:`
  value that happens to look right in one place, or editing `PersimmonMark`
  to drop the `GeometryReader`/fill-to-frame behavior — every existing
  caller relies on that behavior and already pairs it with its own explicit
  frame. This is invisible in code review and in Xcode previews, where the
  surrounding layout happens to be bounded anyway, and only showed up on a
  device screenshot.
- **An unsized `Color.clear` expands to fill, and `minHeight:` is a floor, not a
  ceiling.** `OnboardingView.skipButton` returned a bare `Color.clear` for steps
  with no skip action, and `topBar` wrapped it in
  `.frame(minWidth: 44, minHeight: 32)`. `Color.clear` has no intrinsic size, so
  it took every point of height on offer, inflated the top bar, centred the back
  chevron a third of the way down the screen and pushed everything below it with
  it. The symptom pointed elsewhere entirely — the Canvas WebView rendered as a
  thin band under a screenful of empty background, which reads as "the login
  pane isn't filling" — so three separate fixes went looking for missing height
  inside the panes (`.frame(maxHeight: .infinity)` on the pane, a
  `safeAreaInset` restructure of the chrome, a fill on `OnboardingView.body`)
  and none of them touched the cause. The height was never missing; an invisible
  view was eating it. Size the placeholder at the source
  (`Color.clear.frame(width: 44, height: 32)`). Two tells worth remembering:
  `backButton` was never affected because it uses fixed `width:height:`, so the
  asymmetry between the two ends of one bar was the clue; and temporary
  `.border(Color.red)` on three views found this in one build cycle after three
  cycles of reasoning had not. When a layout bug survives two fixes, stop
  reasoning and draw the frames.
- **Never commit real Canvas/Gradescope data** — user ids, feed-token URLs, cookies.
- **A `static func` on a SwiftUI `View` is main-actor isolated, and Swift 6
  enforces it at run time.** `GradeCourseCardView.decidedText` is a pure
  string rule that tests call directly; the `{ $0.lowercased() }` closure
  inside its `map` inherited the View's isolation and, on swift-testing's
  executor, died in `_dispatch_assert_queue_fail` -- `swift test` exits
  with "signal code 5" and no "Fatal error" line, and the crash report's
  main thread shows only an idle run loop (read the `triggered` thread from
  the `.ips`). Three earlier tests in the same suite passed because they
  returned before the closure was formed. Mark such helpers `nonisolated`;
  do not mark the test suite `@MainActor`, which hides the trap and leaves
  the next background caller (a widget, a notification body) to find it.
- **Seeding a persisted flag through `UserDefaults.lhf` in a test is not
  hermetic even with backup-and-restore.** `FirstLaunchHoldDashboardTests`
  wrote `canvasSessionConfirmedDeadV1 = true` for the duration of each test
  and restored it after; that looked like the sanctioned pattern. But every
  `AppState.init` in every concurrently running suite that landed inside
  that window read a dead Canvas session, engaged the first-launch hold,
  and hid its own overdue fixtures -- ten assertions in four unrelated
  suites (dedup, Done tab, ledger scenarios, cookie store) failed at once
  with no grade code in their stacks, after two green runs of pure
  scheduling luck. The tell was the timing: every failure at 1.3-1.8s, the
  window that suite ran in. A flag another suite's `init` reads needs a
  per-instance seam (`forceCanvasSessionConfirmedDeadForTesting()`), not a
  shared-domain write. Restore-on-exit protects the *next* suite, never the
  ones running *alongside*.
- **An installed Canvas Student app steals the login WebView's return hop.**
  Confirmed 2026-09-12: with Canvas Student on the phone, "connect
  Canvas" opened the Canvas app and never connected; deleting Canvas
  Student fixed it. WebKit treats a main-frame navigation as a universal
  link candidate when it traces back to a user gesture (the identity
  provider's page was loaded by the user's Duo tap, and that permission
  propagates to navigations the page starts) and the destination host
  differs from the current main-frame host. The SAML return from
  idp.pennkey.upenn.edu to canvas.upenn.edu is exactly that, and Canvas
  serves the app-association file on canvas.upenn.edu, so iOS hands the
  hop to Canvas Student. Nothing in Locust opens a Canvas URL on purpose;
  the code had not changed in a month; the phone had. A programmatic
  `WKWebView.load(_:)` is never an app-link candidate, so
  `LoginNavigationObserver` cancels a cross-host arrival at the guard host
  and re-issues it itself (`appLinkGuardHost`). The wrong fix is
  cancelling and reloading `navigationAction.request`: WebKit never puts
  a POST body on that request, so the SAML POST would arrive empty. The
  guard rebuilds the POST from the identity provider's form in the page
  before re-issuing it, and allows the navigation unchanged when it cannot.
- **`NLEmbedding.sentenceEmbedding(for:)` blocks the calling thread while
  iOS downloads the asset.** On a fresh install (2026-09-12, the first
  Smooth build, the app deleted and reinstalled for the icon) the first
  question in ask showed the streaming cursor for two minutes and nothing
  else. Not the network: the phone's 60 s URLSession timeout would have
  printed the fallback message. `CourseSearch.rerank` asked Apple's
  NaturalLanguage framework for the English sentence embedding, on the
  main actor, synchronously, before the request was even built, and on a
  device that has never loaded that asset the call waits for a system
  daemon to fetch it, with no timeout and outside any URLSession. The
  tell: a stuck cursor that outlives every network timeout, on a device
  that just had the app reinstalled or was just restored. The embedding is
  a bonus on top of BM25, so `SentenceEmbeddingProvider` hands it out
  only once it is already loaded and starts the load on a background task
  the first time anyone asks; retrieval itself now runs off the caller's
  actor. The wrong fix is moving the whole search to a background queue:
  the student still waits minutes for an asset that may never arrive.
- **A jsonb column outlives the TypeScript type that wrote it.**
  `catalog_courses.components` rows written on 2026-09-07 had no
  `meetings`; the next day's code iterated `component.meetings`, the stored
  rows were read back untouched, and every manifest naming that course
  returned 500 for a day — silently, from the app's side, because the
  upload is gated on the manifest and the only symptom was
  `last_full_sync_at` never filling. Normalize jsonb at the read boundary
  (`dbRowToCatalogRow`), let a legacy row force a refetch
  (`catalogNeedsFetch`), and never let an enrichment step fail the exchange
  it decorates (`handleManifest` catches the catalog step). Deno tests
  cannot catch this: they only ever see rows the current code wrote.
- **A thinking model's reasoning counts against `max_tokens`, and the
  server never forwards it.** `z-ai/glm-5.3-flash` streams its reasoning as
  `delta.reasoning`; `_shared/openrouter.ts` forwards only `delta.content`.
  On a real phone (2026-09-14) "when's my next exam?" with a 14.5k-token
  prompt of real syllabi reasoned until the 1200-token cap and emitted no
  content: the server returned 200 after 35 s having sent exactly one
  line, `done`, and the student saw an empty bubble. Two repros with
  synthetic prompts of the same size reasoned briefly and answered, so
  size alone does not trigger it; real course text does. The tells: the
  `ask-trace` line `7 stream finished: 1 lines, 0 deltas … completion
  1200`, and `pg_stat_statements` showing the quota RPC never slow (it was
  the first suspect). `reasoning: { enabled: false }` was rejected by
  OpenRouter with 400 on its first live call and the 400 body was not
  logged then (it is now, `ask: upstream failure detail`) -- because `glm-5.3-flash` is an
  always-thinking model; OpenRouter rejects every attempt to disable it.
  Resolved 2026-09-22 by measurement on `ask-canary` (see the ask section
  under Architecture): `reasoning: { effort: "low" }` cuts its thinking to
  ~6 tokens but a third of requests still took 8-66 s to the first word
  with zero reasoning tokens -- provider time-to-first-token, which no
  parameter reaches -- so the primary is now `openai/gpt-4.1-mini`
  (1.9-3.0 s every time, and right about "tomorrow" where the cheaper
  models were wrong) with `glm-5.3-flash` at low effort as a five-second
  hedge. The client's `BackendAssistantResponder` still hands an empty
  `done` to the on-device answerer as the last resort.
- **A 504 from `/rest/v1` can be the API gateway, not Postgres.** The
  2026-09-13 20:47 "database stall" was `sb_gateway_version: 2` timing out
  after ~5 s (`origin_time: 5126`, 29-byte body
  `{"message":"Gateway Timeout"}`) on the hop to PostgREST, with Postgres
  idle, no restart, no errors, and the RPC's max ever 23 ms. Before
  blaming the database, pull `edge_logs` for the request id and read
  `origin_time`, then `pg_stat_statements` for the query; the management
  API's `logs.all` returns nothing for windows wider than a few minutes,
  so query narrow windows. Also from that day, a misdiagnosis worth
  keeping: every ask logged "record_ask_usage exceeded 4000ms deadline"
  while the row still landed, and this file blamed the write running
  after `yield done`. Measured on 2026-09-22, the write lands in 125-440
  ms; the warning came from the timeout promise's own `setTimeout`, which
  nothing cleared when the request won the race, and
  `EdgeRuntime.waitUntil` kept the isolate alive long enough for it to
  fire. Fixed by clearing that timer in `finally` (`quota.ts`,
  `outcomes.ts`). The tell that should have caught it sooner: the warning
  fired on every request at exactly the deadline, never at a
  request-shaped time.
- **A recycled Canvas site carries the previous year's due dates, and one
  of them can define the whole term.** `GradeCountPredictor.term(for:)`
  anchored the term on the earliest due date across a course's items, and
  `Term.elapsedWeeks` clamps to the term's own length, so CIS 4500 read
  "week 14 of 14" on 2026-09-15 — the third week of the semester — while
  every other course read "week 1 of 14". The site was reused: three items
  still carried 2025 dates ("Met Instructor" 2025-10-14, "Class
  Participation" and "Ed Participation" 2025-12-09) ahead of the real work
  starting 2026-09-11. The term now starts after the last gap wider than
  the term's own length, since two items more than a whole term apart
  cannot belong to the same term. The first attempt used a tuned 8-week
  threshold and its own new test caught the flaw on the first compile: the
  last 8-week-plus gap in that course is the eleven weeks between the
  September homework and the December final, so it anchored on the final
  exam and claimed the semester begins in December. When a rule needs a
  magic number, check whether the quantity it is really about is already
  in scope — here it was `weeks`, the parameter one line away.
- **Penn restricts student Canvas access tokens.** The app can mint a 120-day
  Canvas access token from inside the student's own login and use it for
  `/api/v1` fetches (`CanvasAccessToken.swift`, `CanvasAccessTokenMinter.swift`,
  `CanvasAccessTokenStore.swift`, `accessToken:` on the Canvas clients), but
  Olisa's own Canvas settings page shows "+ New Access Token" greyed out, with
  the tooltip "Your Canvas administrators have chosen to limit your ability to
  generate your own access token" (canvas.upenn.edu/profile/settings) — the
  tell to check for on any other Penn account before assuming this works. A
  mint would 403 for every Penn student, so `FeatureFlags.canvasAccessTokens =
  false` gates the whole path off rather than deleting it, for the day Penn
  issues an OAuth developer key (what the Canvas Student app uses) or lifts
  the restriction. `CanvasDiscoveryClient` must stay cookie-only regardless of
  that flag, because bearer tokens are only honoured on `/api/` paths
  (`lib/authentication_methods.rb`) and discovery hits non-API pages. The
  wrong fix in both directions: storing nothing and living with the daily
  re-login the app already had before this work is simply the *previous*
  state, not a fix owed here; and scraping the password back out of the
  login page's DOM to synthesize a token is the fix that was considered and
  rejected — it defeats the whole point of a scoped, revocable token by
  handing the app a full credential anyway.
- **The 24-hour cookie rule is what keeps a student signed in; removing it
  signed Marco out.** `fac110d` (2026-09-24) dropped
  `SessionCookieStore.load()`'s rule that treats a no-expiry Canvas cookie
  as dead 24 hours after its last save. The reasoning looked sound: the
  server, not a local clock, should decide when a session is dead, so keep
  the cookie until Canvas rejects it. But that rule is the *trigger*: it is
  what flips `canvasSessionExpired` and runs `CanvasSessionRenewer` on the
  next open, while the app is on screen and the hidden WebView runs at full
  speed. Without it the renewer only ran after a Grade Watcher 401, and on
  2026-09-26 one such attempt on Marco's phone filled the saved password
  and then sat on Duo until the 30 s timeout. That read as `.needsDuo`,
  latched `autoLoginAwaitingDuoV1` and `canvasSessionConfirmedDeadV1`, and
  showed the reconnect banner. Olisa's phone, still on a 2026-09-21 build
  with the rule, never signed out. The tells, read off the phones with
  `devicectl`: the two flags true on one phone and false on the other,
  and Duo's `browsertrust` cookie re-issued at each successful renewal.
  Restored for Penn byte for byte from `39b2fff` (`df759f8`), including
  the connect pane's `login/saml` start URL and cookie filters, and the
  failed-connect no-op (`a16ea07`). The wrong fix: trusting the server
  and dropping the clock, as above. Because background wakes crash (next
  trap), the 2026-09-26 failure was a renewal with the app open, not a
  background stall; whether Duo's trust had lapsed or its page was just
  slow that day is unknown.
- **Every background refresh crashed from 2026-08-24 until `v8`, invisibly**
  (fixed 2026-10-09, blind: the launch handler is now `{ @Sendable task in
  … }` into a `nonisolated` static, and background renewals never latch;
  the history stays here because the wrong fix is still tempting).
  `LHFBackgroundRefresh.register()` hands `BGTaskScheduler` a launch
  handler with `using: nil`, so iOS runs it on its own background queue.
  The closure inherits main-actor isolation, and Swift 6 checks that at
  run time, so the app dies on entry (`SIGTRAP`, `_dispatch_assert_queue_fail`,
  thread queue `com.apple.BGTaskScheduler (com.lhf.lowhangingfruit.refresh)`)
  before any work happens. It is the same trap as the `decidedText` entry
  above. Nobody sees it, because the app is closed at the time. The tell
  is the `.ips` reports on the phone (`Smooth-<date>.ips` under
  `systemCrashLogs`, five on Marco's phone from 2026-09-24 to 09-27). The
  consequence that matters: "Olisa's proven logic" has only ever been
  renew-on-open; no background refresh or background re-login has ever
  run. The wrong fix is to fix the crash alone. That turns on background
  re-logins, the one path never tested, whose hidden WebView may stall on
  Duo and latch `needs Duo`. Fix it together with a foreground-only guard
  on `CanvasSessionRenewer` (`ROADMAP.md` → Now).
- **A background wake that starts a renewal and does not await it has
  not run a renewal.** The first `v8` fix made `BGTask` wakes renew: the
  fresh `AppState()`'s `init` sees the expired cookie and fires
  `Task { await attemptSilentCanvasRenewal() }`, then `run()` does its
  syncs (which return in a second or two when the cookie is dead, because
  there is nothing to sync with) and calls `setTaskCompleted`. iOS then
  suspends the process with the renewal mid-navigation, or mid password
  submission, and nothing is saved or recorded; the next wake starts over
  and, six hours on, submits the password again. Found by review before
  any device saw it (2026-10-09). The fix is a stored task
  (`startSilentCanvasRenewal` / `awaitPendingSilentRenewal`) plus a
  teardown on expiry; the wrong fix is a timer in `run()`, which would
  race the renewer's own 20 s budget. From the same review: a `.failed`
  WebKit navigation (offline) fell through the host classification with a
  nil URL and came out as `.landedOnLoginPage`, so two tunnels an hour
  apart could latch a live session dead; and the one-hour attempt
  cooldown lived only in memory, so two relaunches bypassed it. The
  general tell: a "blind" commit's riskiest paths are the ones no test
  can drive (`BackgroundRefresh.swift` is iOS-only and never compiled by
  `swift test`); review those by hand before the device does.
- **Canvas's announcements API ends its window 28 days after it starts,
  unless told otherwise.** `end_date` defaults to `start_date` + 28 days.
  `CanvasAnnouncementsClient` sent only `start_date`, which was correct by
  accident while every caller asked for the last 14 days. On 2026-10-10
  the megaphone list widened its start to 60 days, and on Marco's phone
  the new log filled with exactly two announcements, 46 and 39 days old,
  and nothing newer: the request had become "60 to 32 days ago". Worse,
  the Announcement Watcher was silently dead, because nothing from the
  last 14 days reached extraction any more. Tests could not see it: the
  stub returned whatever it was handed. The tells, read off the phone:
  `announcement-log.json` holding only old records while
  `processedAnnouncementIDsV1` held newer ids. Fixed by passing `until:`
  (tomorrow) from `syncAnnouncements`; the regression test's stub now
  honours the window the way Canvas does. The wrong fix is shortening the
  look-back to 28 days. **Still broken, on purpose:**
  `CourseKnowledgeCollector` asks for 200 days back with no `until`, so
  its window ended about 172 days ago and it has never collected an
  announcement (Marco's phone, same day: 106 course documents, none of
  kind `announcement`). That is a one-argument fix in the course-material
  sync, left for Marco and Olisa because Marco said not to touch the sync
  (see Known gaps).
- **Every worktree's test run shares one defaults domain.** On 2026-10-10
  four agents ran `swift test` in four git worktrees at once and
  unrelated suites failed at random: `CourseContentDashboardTests` saw
  `"SCEN-G 100"` where it had written `"SCEN-A 100"`,
  `AnnouncementWatcherWiringTests` and `AskKnowledgeWiringTests` failed
  once each and passed on the next run. Under the test runner
  `UserDefaults.lhf` is the test process's standard domain, and that
  domain belongs to `swiftpm-testing-helper`, not to a checkout, so two
  runs in two directories write the same keys. It is the shared-
  `UserDefaults` trap again, across processes this time, which is why
  `--no-parallel` did not help. The tell is a failure in a suite the
  change never touched, with another checkout's values in the message.
  A verification run has to be the only test run on the machine; the
  counts in Test baseline were taken that way. The wrong fix is
  retrying until green and calling it verified.
- **"Ed and announcements aren't being scraped" was a deleted Canvas
  session, not a scraping bug.** On 2026-10-18 Marco reported that
  neither Ed posts nor Canvas announcements were arriving. Both were
  fine in code. Everything that reads Canvas with the student's login
  (announcements, course materials, Ed's launch) hangs off one chain,
  `refreshCanvasGrades` → `refreshCourseIntel` /
  `refreshCourseKnowledge`, and that chain returns early when no
  Canvas cookies are saved. On 2026-10-10 the Grade Watcher screen
  (`GradeWatcherView.performRefresh`) removed the saved cookies after a
  session-expired fetch, and with nothing saved,
  `SessionCookieStore.isExpired` reads false: no "needs a refresh"
  banner, no renew-on-open, and a dashboard that still looked alive
  because the calendar feed needs no login. The tells, read off the
  phone with `devicectl`: `edTabCheckedAtByCanvasCourseV1` frozen at
  2026-10-10 and no `debugRenewalLogV1` entry after that day. The
  missing Grade Watcher button (2026-10-15) was the same cause. Removing
  Grade Watcher (2026-10-18) removed that purge from every Release path,
  and Profile → accounts now shows "sign in to canvas" whenever Canvas
  is connected with no saved login. The wrong fix is chasing the
  scrapers; the purge-without-banner behaviour belongs to the sign-in
  code and was left for Olisa (Known gaps).
- **Stale cards from old Ed posts were a window problem, three layers
  deep, and not a bad class or a bad kind of task.** On 2026-10-18 the
  owner's todo, all and prev filled with tasks nobody could still do or
  needed to: "Take quiz covering assignments 1 and 2" (an Ed post from
  Sept 14, already taken), "Attend the weekly rotation quiz" (a
  start-of-class reminder), mostly from CIS 2620's Ed; "none of these
  previous ones are honestly helpful". Three things stacked.
  (1) The Ed documents the course-material sync pools reach back 120 days
  (`EdIngestion.defaultMaxAge`), while the Canvas pass extracts only from
  the last 14. The Ed pass has the same 14-day window, but on
  `CourseDocument.updatedAt`, which for Ed is the thread's last
  *activity*: a Sept 14 thread somebody replied to on Oct 15 is a
  14-day-old post by that measure. The document carries no creation date.
  (2) The extractors resolve "today" and weekday names against the
  extraction day, not the post's, so a task from an old post can carry a
  date that looks fresh. (3) A task whose date had passed was moved to
  prev as "past", and an undated one never lapsed, so whatever got
  through stayed forever. The fix is a set of visibility rules at rebuild
  time ("Which announcement tasks show", under What the app does), plus
  the Ed pass skipping a post it cannot date. The wrong fixes, each of
  which looks reasonable: filtering by kind (hide every Ed task) or by
  course (hide CIS 2620), which hides real work and leaves the pipeline
  that made the clutter; deleting the stale rows, which the ledger's
  invariant forbids and which `processedAnnouncementIDs` makes permanent
  (the post is marked read, so the extractor never produces the row
  again); parking them in a quieter list, which is what put them in prev;
  and hiding every Ed task whose post is older than 14 days whatever its
  due date, which would take "Project due Dec 1", pinned on Oct 1, off
  the dashboard on Oct 20.
- **An alarm's stop is any dismissal, so it must never mean "turned in".**
  The owner asked for "turned in" and "open in canvas" on the Berserk
  alarm (2026-10-19), and the obvious mapping is stop = "turned in".
  AlarmKit has one stop and one secondary button. Apple's AlarmKit FAQ
  says the stop intent also runs when the alarm is swiped away or the
  side button pressed (one developer reports it doesn't, on 26.2.1:
  developer.apple.com/forums/thread/815064). Either way, a student who
  silences the alarm without handing anything in would have the work
  marked done and taken off the dashboard ten minutes before it is due,
  the exact failure the alarm exists to prevent. So "turned in" is the
  `.custom` secondary, which only an explicit tap reaches, and stop opens
  the assignment. A wrong trigger then costs a Canvas page, not a missed
  deadline. Since iOS 26.1 the stop button's own label is ignored
  (`AlarmPresentation.Alert.init(title:stopButton:…)` is deprecated with
  "stopButton … will no longer be used"), so the system shows "Stop"; a
  stop that opens Canvas is a known, accepted surprise pending the
  owner's verdict on a phone.
- **Nothing under `backend/` can be exercised from `swift test`**; run its deno
  tests separately (`cd backend && deno task test`, `deno task check`).
  `BackendServices.client` is nil under tests and in an unconfigured build, so
  the app is fully on-device there — a green test run proves nothing about the
  backend path.

- **A textually clean merge can put a line in the wrong place, and two
  lines of work can build the same thing under different names**
  (2026-10-20, merging `v8` with `v8-loud-alert-actions`). Both sides
  edited `SettingsPage.swift`: one added two debug sync-summary rows inside
  a "sign-in diagnostics" disclosure, the other deleted that disclosure and
  moved its contents. Git merged without a marker and the two rows landed
  inside the Release-visible "sign in to canvas" row, so a student's
  Settings would have shown them. The tell is that a file merged "cleanly"
  while the thing around the hunk had been deleted on one side; read the
  merged file around every hunk, not only the conflicts. The same merge
  found the owner's rule "announcement and Ed tasks vanish at their due
  time" written twice (`AppState.isExpired` widened, and
  `isHiddenAnnouncementTask`), and the Ed posts read twice (one loop that
  read them as Canvas-shaped announcements, one pass of their own with a
  different find id). Both would have compiled, passed their own tests and
  disagreed on a phone: a task moved by the student would reappear in one
  and not the other, and one Ed post would have made two finds under two
  ids. The fix was to pick one of each, and give the survivor what the
  other had that it lacked. The wrong fix is keeping both "for safety".
  Grep the diff of each side for the same noun before merging.

## Conventions

- **Comments explain *why*, at length, in prose.** Read `StoredAssignment.swift`,
  `SharedDefaults.swift` or `CourseCode.swift` for the register. Thin comments
  that restate the code are worse than none. When a fix is non-obvious, record
  what the *wrong* fix would have been.
- **Commits**: short imperative subject, then prose paragraphs explaining the
  reasoning and what was rejected. End with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Tests are `swift-testing` (`@Test` / `@Suite`), not XCTest.

## Branches

`v8` is the line. Marco's launch-prep work (2026-10-09/10) was merged
into it on 2026-10-10 through pull request 9, at Marco's instruction;
`v8-launch-prep` is the branch it was built on. So `v8` now carries work
most of which has not been on a phone (Known gaps), and whatever ships
from `v8` next ships with it. The rest is history, kept because some of
it holds work that exists nowhere else.

| Branch | What |
|---|---|
| `v8-merge-loud-alert` | **The merge of `origin/v8` (Olisa, 10 commits of 2026-10-19, through `55a9203`) and `origin/v8-loud-alert-actions` (Marco: `75dc7aa`, `e3f9af8`, `5cdb4cc`), 2026-10-20, in progress when this was written; not compiled.** Decisions made by the overseer: one Ed task pass (Marco's, given Olisa's posting day, twin check, quota stop and a summary), one past-due rule for announcement tasks (Marco's `isHiddenAnnouncementTask`; `isExpired` back to the `.event` rule), Olisa's retry cap, quota stop, back-off and summaries kept in the Canvas loop, Grade Watcher stays hidden, Marco's `project.yml` kept. Rows the brief `announcement-ed:` reading wrote stay as inert `.canvasAnnouncement` rows. |
| `v8-launch-prep` | **Marco's launch-prep work, on `v8` at `e2672eb`** (2026-10-09/10): source links on cards, the 10-minute reminder, assignment names in reminders, the sign-up backlog rule, the real announcements list with Ed rows, the ask search / excerpt / follow-up / citation work, the copy cut, saved due-date edits, deleting your own tasks, the widget fixes and ten small fixes. It does not change sign-in or the sync: `sync()`, `syncGradescope` and `connectCanvas` are byte-identical to `e2672eb`. Compiled for iOS; only the first four items have been on a phone. Merged into `v8` on 2026-10-10 (pull request 9); kept as a branch because these notes cite it. |
| `v8-announcements` | **Pushed to origin 2026-10-18 as one commit on `v8` at `beed156`; not merged into `v8`.** Grade Watcher hidden (flag off, code and the grade fetch kept), the megaphone in the header, Olisa's sign-in lines back under canvas in DEBUG builds, "sign in to canvas" when no login is saved, announcement and Ed tasks as cards (per class, hidden once past or stale, deletion-flagged, deduped), the megaphone sheet redesigned (found cards and the past 7 days of announcements under one class filter), exam cards from feed / announcements / syllabus, the loud 10-minute alert (with the time-sensitive entitlement), and "the vault". `v8-loud-alert` and `v8-exams` were folded in as patches, so those two branches hold nothing extra. Its four local WIP commits were squashed into that one commit before the push. 2230/206 green. The last build installed on Marco's phone predates the sheet and the rules; the current build waits on the phone being reachable. Sign-in and sync files are byte-identical to `v8`. |
| `v8-loud-alert-actions` | **Pushed to origin 2026-10-19 as one commit `e3f9af8` on `v8-announcements` at `75dc7aa`; no PR, not merged. The AlarmKit alarm (with its custom sound) is a second commit, pushed the same day.** "Berserk mode": "turned in" and "open in canvas" buttons on the loud 10-minute alert, with the notification delegate installed at launch, and on iOS 26 a real AlarmKit alarm in place of the buzzes (What the app does → Profile → reminders). A build from before the review fixes was installed on Marco's iPhone on 2026-10-19 at 15:21. Separate from `fix/submission-status`, which branches from the same commit. Sign-in and sync files are byte-identical to `75dc7aa`. |
| `olisa-grade-watcher-beta` | Local, 2026-10-15, superseded: Olisa's `ba75e97` plus a grades button and a "beta" tag, uncommitted in `.claude/worktrees/olisa-latest`. Grade Watcher was removed three days later, so nothing there needs merging. |
| `parked/ask-course-sync-fixes` | **Parked, do not merge as is.** Fixes to the course-material sync written on 2026-10-09 and set aside when Marco said not to touch the sync: a half-failed sync no longer erasing documents, a 403 on one course no longer aborting all, 120 page bodies with the front page first. Its commit message lists what an independent review found still open, including one regression and two server-side prerequisites. |
| `v8` | **Current line (2026-10-02 onward); Marco's `v8-loud-alert-actions` is merged into it on `v8-merge-loud-alert` (2026-10-20), not yet on `v8` itself.** `V7` plus Ed Discussion ingestion (`docs/ED_DISCUSSION.md`): the `ed` document kind on both sides of the wire, the pure Kit `Ed/` layer, `EdClient`/`EdIngestion`, and the app wiring (`EdSessionLauncher`, `EdDiscussionCoordinator`, the Settings status row). Compiled green 2026-10-09 (1499/152); nothing run on a device yet. Also carries the sign-out fix, stamped 3.0.1 (12). |
| `V7` | The line from 2026-09-23 to 2026-10-02. Contains all of `v6`, `v5`, `V7-polish` and `v8-features`: the session-persistence work, the Settings trim, the todo · all · prev switch and class filter, multi-school sign-in, and (2026-09-27, `df759f8`/`a16ea07`, from the since-deleted `v7-olisa-session`) Olisa's `39b2fff` session logic restored for Penn. 3.0.0 (11) was archived from `ddef468`. New work branches from here, and lands back here. |
| `v8-ann-rules` | **Local, 2026-10-18, off `v8-announcements` at the WIP commit `80c21ec`; not merged or pushed.** The announcement-task visibility rules (past tasks leave the dashboard instead of moving to prev, undated tasks age out after 7 days, same-day class reminders are not cards, the Ed pass reads only posts from the last 14 days). Written to be merged into `v8-announcements` as a patch, and applied there on 2026-10-18, so it holds nothing extra. 2207/203 green on its own; compiled for generic iOS (the phone was unreachable), not installed. |
| `v8-dice-toggle` | `V7` as of 2026-09-24 with the dashboard's dice "pick one for me" button (`PickAssignmentSheet`, `DashboardViewModel.pickCandidates`). Kept on purpose, not for merging as-is; see `ROADMAP.md` → Tried and parked. |
| `v8-features`, `V7-polish` | Feature branches, fully merged into `V7` (fast-forward). Safe to delete. |
| `update-manifest` | **Orphan branch, never merge.** Holds `lhf-update.json`, the live update policy the shipped app fetches from raw.githubusercontent.com; edit it from GitHub's web UI to lift or set a version floor. |
| `v6` | The line from 2026-09-16 to 2026-09-23: `v5` plus the gated Canvas access-token plumbing and stay-signed-in. In `V7`. |
| `v5` | The **App Store submission line** that uploaded 3.0.0 builds 7–9 (2026-09-06 to 2026-09-16): `assistant-ui` + `v3.5` + the ask knowledge engine, the backend, the Locust onboarding, the update gate, the Smooth redesign and dark mode. In `V7`. |
| `codex/redesign-v5`, `codex/fire-dark-mode`, `codex/smooth-header-layout`, `codex/assignment-pop-empty-celebration` | Marco's design branches (Smooth redesign, "after sunset" dark mode, header and completion polish); `docs/DARK_MODE_HANDOFF.md` and `docs/SMOOTH_INTRO_AND_APP_POLISH_HANDOFF.md` are his notes. Merged into `v5`. |
| `assistant-ui`, `onboarding-walk`, `update-gate` | ask and "the tree"; the Locust intro and onboarding walk; the update gate alone. All folded into `v5`. |
| `v3.5`, `v4`, `v3`, `claude/v4-github-repo-kvu0e0` | The 2.x era: the SwiftData ledger, Grade Watcher, readings-only courses, iCloud Tier 2, background refresh, the Mac tier, per-course reminders, semester rollover. Carried uploaded (never live) 2.0.x builds. In `v5`. |
| `origin/v2.5` | Former ship line, 1.1.1 build 3, Grade Watcher gated off. |
| `main` | Old: 1.0.0 App Store prep. Not the ship line. |
| `v2.75` | Unmerged macOS sidebar/landscape work that exists nowhere else. |

`claude/*` branches on the remote are agent working branches from August;
none is a ship line.

## Known gaps

- **The Berserk alarm has rung once, on Marco's iPhone (iOS 26.6,
  2026-10-19, a build from before the review fixes).** The first try did
  not ring because alarms were not allowed for Smooth; after he allowed
  them, it rang. The review-fixed build with the song rang the same day,
  so AlarmKit does find a sound in the main bundle on 26.6; the owner:
  "this is perfect for berserk mode". Which buttons he tried, and whether
  the 13-second clip loops or plays once, are not recorded. Still unverified,
  and not answerable from the SDK: that an alert-only alarm needs no
  widget/Live Activity configuration (Apple requires one for countdown
  alarms only); what `schedule(id:)` does with an id that already exists
  and whether `cancel(id:)` throws for one that is gone; that both
  buttons work from the lock screen with `.foreground(.immediate)`;
  whether stop runs on swipe or the side button; whether the lock screen
  shows the due time next to the bare assignment name; and a launch on
  iOS 17–25 (AlarmKit is weak-linked in the Debug build; a Release archive
  has not been checked). Disconnecting Canvas does not cancel alarms until
  the next reschedule, so leaving the app straight from Settings can let
  one ring for purged work (the buzzes have the same gap).
- **The loud alert's buttons are proven on the Mac only** (2026-10-19,
  `v8-loud-alert-actions`). Unverified on a device: that a lock-screen
  "turned in" stops buzzes 2 and 3 in time, that a tap which
  cold-launches a force-quit app reaches the dashboard, and that
  `openURL` from a cold launch is honoured (iOS may ignore an open
  issued before the scene is active). Two limits by design: a "turned in"
  for an item the dashboard no longer lists only silences and re-plans,
  it completes nothing; and the alert still fires for work handed in while the app was
  closed, because only a foreground refresh re-plans it (the background
  wake is off limits).
- **A failed Canvas announcement read is retried on every sync.** Only the
  Ed pass waits (`edTaskRetryInterval`, six hours, per post). A Canvas
  post whose AI-assist call fails is left unread and asked for again on
  each 5-minute sync, which spends the backend quota `ask` shares. Not
  fixed: the review asked for Ed only.
- **A fetch that is cut short the same way twice is believed.** The
  two-miss rule (`announcementMissesToFlag`) and "a class that returned
  nothing is not judged" stop a one-off truncation, not a deterministic
  one (`CanvasAnnouncementsClient` caps at 50 pages). The flag is
  reversible and the row is never deleted, which is what makes that safe
  enough.
- **Exam cards have been tested on the Mac only** (2026-10-18; compiled
  for the connected phone, never installed). Never read against a real
  syllabus: the extractor, the 60-day and one-day matching rules and the
  year it picks for a date with no year are proven on fixtures. Known
  edges, none of them fixed:
  - A syllabus that stops naming an exam leaves its card. Rewriting the
    line updates it (the id is the exam's identity), but an edit that both
    renames the exam ("Midterm" to "Midterm 1") and moves its date leaves
    the old row beside the new one. Deleting on absence was refused on
    purpose: a failed sync drops whole courses from the material.
  - A title like "Bring a calculator to the exam" is not treated as an
    exam (`leadingExamIdentity`), but is still drawn black, because the
    card's colour only asks whether an exam is named.
  - Syllabus rows join the work list in the ask context document with the
    source label "announcement" (`assistantSourceLabel`; a disclosure
    boundary, left alone).
- **The summary sent with every ask question carries completion state,
  and `docs/PRIVACY.md` says it does not.** Read on 2026-10-10 while
  checking something else; it has been so since `assistant-ui`
  (2026-09-02/06). `AssistantContextDocument.render` writes each work
  item as `course | title | due … | done / nothing to submit /
  outstanding | source`, and `assistantContextDocument()` fills
  `isCompleted` from the student's real completion state. The policy
  says, three times, that completions never leave the phone, and that
  the summary is "built without your name, grades, or completion state";
  the privacy posture at the top of this file says the work list never
  leaves either, and the document is the work list (feed items; manual
  tasks are not in it). Nothing was changed: taking the status out makes
  "what am I missing?" worse and re-bills the cached prefix once, and
  changing the sentence changes a published promise. It is Marco's and
  Olisa's decision, and it should be made before the next release.
- **The launch-prep work is mostly unseen on a device** (`v8-launch-prep`,
  2026-10-10). Marco's phone took builds up to `b5ed8a1` (links,
  10-minute reminder, reminder wording, the first announcements list and
  its window fix) and was then unplugged. Everything after that is
  compiled for iOS and tested on the Mac only: the Settings and banner
  copy, the Ed rows in the megaphone, ask's changes, saved due-date
  edits, deleting your own tasks, the widget, the "not saving" banner,
  the under-an-hour "8m" form. The sign-up rule can only be seen on a
  fresh install.
- **ask has never seen an announcement.** `CourseKnowledgeCollector` asks
  Canvas for announcements from 200 days back without an `until`, and
  Canvas ends the window 28 days after it starts (the announcements-
  window trap). Marco's phone, 2026-10-10: 106 course documents, none of
  kind `announcement`. The fix is passing `until:` in that one call. It
  is in the course-material sync, so it waits for Marco and Olisa.
- **ask cannot read Canvas Files.** Slides, readings and any PDF not
  named like a syllabus are never ingested; only the 40 most recently
  updated pages get their bodies; module items contribute titles only.
  This is probably the largest remaining reason "it's in the class
  files but ask can't find it". Ingesting Files changes what is pooled
  on the server (instructors' files) and `docs/PRIVACY.md`, so it needs
  a decision, not just code.
- **A half-failed course-material sync erases documents**, for the
  student and, through the pool, for classmates; and one forbidden
  course aborts the whole run before anything is saved. Fixes exist on
  `parked/ask-course-sync-fixes` and are not merged (see Branches).
  Related and server-side: `selectLiveDocumentsForCourses` is an
  unpaginated select, so a student past PostgREST's row limit (1000 by
  default; unverified for this project) gets a silently truncated
  manifest.
- **`docs/PRIVACY.md` says anonymous Ed posts never leave the phone, and
  nothing enforces it.** `EdThreadFilter` never reads `isAnonymous`, so
  an anonymous post that staff pinned would be kept and pooled. Either
  the keep-rule or the sentence has to change; the keep-rule is scraping
  logic, which is Olisa's. Also from the 2026-10-10 Ed review, all in
  the coordinator and left alone: a 401 partway through a run drops the
  Ed documents of the classes not yet read; each read replaces a class's
  whole Ed set with the newest 100 threads, so older pinned posts vanish
  and pooled ones are downloaded and dropped again every sync; staff
  answers inside student questions are never captured.
- **A deleted announcement stays in the megaphone until it ages out**
  (since 2026-10-18 its task cards are hidden, for Canvas posts only; the
  list row is not). An Ed post that is deleted is not noticed at all: an
  Ed read replaces a class's documents with its newest 100 threads and a
  failed run drops the classes it had not reached, so a document missing
  from `courseKnowledge` is weak evidence of deletion, and hiding on it
  would hide real tasks. Fixing it means a trustworthy "this read
  completed" signal from the Ed coordinator, which is off limits to this
  line of work. An Ed row's date was the thread's last activity, so a
  bumped old pinned post read as recent; since 2026-10-19 the posting day
  in the document's header is the date (`edPostDate`, for the rows, the
  window and the 7-day lifetime), and the last-activity time remains only
  for a document synced before that (until its thread is fetched again),
  where a Sept 14 thread somebody replied to on Oct 15 can still be
  extracted. Both are blind. The day is noon US Eastern, not a minute.
- **ask and the widget after the 2026-10-20 merge (blind).** ask's work
  pool now drops what the dashboard hides (`announcementItemsStillOpen`),
  asked of the feed date, so a task the student moved into the future is
  gone from ask once its feed date passes. The widget's ledger fallback
  keeps only the dated half of the rule. A find that passes while the app
  is closed stays in the published widget snapshot until the app next
  republishes.
- **The merge of 2026-10-20 has not been compiled or run.** Written on a
  machine with no Swift toolchain, from re-reading: the conflicts in
  `AppState.swift` (and the `SettingsPage.swift` rows git merged into the
  wrong place, see Traps), the removal of `edAnnouncementsForExtraction`,
  the rewrite of the tests that used it, and `EdAnnouncementTaskMergeTests`.
  Expect compile errors before anything else, and run the first full
  `swift test --no-parallel` alone on the machine.
- **Ed finds from the Canvas loop's one day are inert, not gone.** On a
  phone that ran the 2026-10-19 build, `announcement-ed:{course}:{thread}-{n}`
  rows sit in the ledger as `.canvasAnnouncement` rows of Canvas origin.
  Their processed ids (`ed:{course}:{thread}`) are the ones Marco's pass
  uses, so nothing is read twice and they expire by the ordinary rule; a
  duplicate card is possible only if the same task also arrives by the Ed
  pass with a different title, and the dashboard's twin collapse catches
  the usual cases.
- **An edited due date lives in defaults, not the ledger** (see "What
  the app does" → Cards). It does not follow a row that later collapses
  into a twin, and the term cap, the sign-up rule and the overdue-Canvas
  hold still read the feed date.

- **Ed Discussion ingestion has not completed a sync on a device** (`v8`,
  2026-10-02, blind). The DEBUG "probe ed discussion" row settled the one
  real unknown on 2026-10-09 on Olisa's phone: the launch lands on Ed only
  once the Keychain's Canvas cookies are injected into the hidden WebView,
  and Ed's session is a `localStorage` token (`authToken`), not a cookie
  (a cookie-only `GET /api/user` is 401). The token path
  (`EdSessionTokenStore`, `EdAuth.token`) was wired, compiled and
  re-probed that day: `native whoAmI (token): status=200 courses=19`.
  The backend accepts kind `ed` since 2026-10-10 (migration
  `20261002090000_ed_kind.sql` applied through the Management API's
  `database/query`, `sync` version 7 deployed with
  `backend/scripts/deploy-function.mjs`; Node's fetch needs
  `NODE_USE_ENV_PROXY=1` in the cloud container or the proxy never
  injects the token). A full sync has since run on a device: Marco's
  phone, read on 2026-10-10 with a `v8-launch-prep` DEBUG build, held 27
  `ed` documents across two classes in `course-knowledge.json` (17 and
  10), one of those classes having no other documents at all. Nobody
  has yet checked those against what the two Ed boards show, and the Ed
  status line shows on a DEBUG build under the gradescope row in
  Profile → accounts (it left the normal page on 2026-10-10). The
  feature fails soft throughout: every error is a note in the sync trace
  and the Settings status line, never a thrown error.
- **Nothing has ever been tested against real Canvas or Gradescope data.**
  Every grade, submission and syllabus path is proven against fixtures
  only. This is the highest-value verification outstanding.
- **Stay signed in is proven in the foreground only.** A real PennKey and
  Duo renewed silently on two phones on 2026-09-27. If a student is ever
  signed out again, read `debugRenewalLogV1` off a DEBUG build before
  redesigning. App Store 3.0.0 users were signed out anyway; the
  investigation and the fix are `docs/SIGNOUT_INVESTIGATION.md` and the
  `v8` sign-out commit of 2026-10-09 (blind: Duo-preserving pre-login
  purge, reconnect straight to the Canvas login, background wakes
  un-crashed with a never-latch guard, foreground retries instead of a
  one-shot latch, a sign-in health line in Profile, Gradescope cookies
  re-stamped on sync), plus the second blind round of 2026-10-09 that a
  three-slice review of that commit forced (the background wake now waits
  for its renewal, see the trap below). None of it has run on a device;
  `docs/SIGNOUT_VERIFICATION.md` is the runbook. Known follow-ups, not
  blocking: a saved-password student whose session dies inside the
  six-hour credential cooldown gets GET-only retries whose landings count
  toward the latch; the live foreground `AppState` does not re-read the
  summary a background wake wrote until relaunch; `run()` reports
  `success: true` even when it skipped everything.
- **Background refresh crashed on every wake from 2026-08-24 to `v8`** (see
  the background-refresh trap, now historical). The `v8` fix has not been
  exercised on a device: verify with Xcode's Debug → Simulate Background
  Fetch on a DEBUG build and `debugRenewalLogV1`.
- **Non-Penn schools have only been exercised by tests.** The seven verified
  installations and the custom-address path have never been signed into on a
  device.
- **The `LedgerSchemaV1` migration has never opened a real pre-existing
  on-disk store.** v4 runs four migrations in one launch; the failure mode
  is a silent fallback to an empty ledger.
- **A non-persistent ledger is invisible.** If the App Group container is
  missing, `AssignmentStore` runs in memory and nothing on screen says so
  (see the App Group trap). Needs a small warning, somewhere a student
  would see it, whenever `assignmentStore.isPersistent` is false or saves
  are failing.
- **CloudKit sync is opt-in and default-off** (Profile → sync,
  docs/LAPTOP_INTEGRATION_PLAN.md Tier 2). The schema is CloudKit-eligible:
  every property on `StoredAssignment` carries a default, and every store
  pins `cloudKitDatabase: .none` unless the toggle was on at launch. The
  sync path has had little real-device soak time; treat it as Phase A.
- **The onboarding per-course walk** is covered by tests but has never been
  walked on a device (it needs a real Canvas session).
- **Recurring tasks can be stopped, not edited.** "stop repeating" on an
  opened occurrence removes the rule (2026-10-10); a task saved with the
  wrong title, time or class can still only be stopped and added again.
  A task saved without a class is filed under the class its title names
  (`RecurringTask.adoptingCourse`). Stopping an accepted syllabus
  suggestion removes it like any other, and the next Canvas scan offers
  it again: suggestions are kept in memory, not remembered once accepted.
- **A finished occurrence of a recurring task never shows in prev.**
  Completing one is recorded (a completion-only ledger row,
  `StoredAssignment.completionOnly`) and survives everything, but
  `DashboardViewModel.reload` builds prev from `mergedCoursework` plus
  the one-off tasks, and a generated occurrence is in neither. A
  student's weekly reading ticks vanish from view instead of counting
  toward "N down this week". Found 2026-10-10 while adding "stop
  repeating" and unchanged by it. Not fixed: it changes what prev shows.
- **Preview mode is App Review's only way in, and it was removed once.** The
  only sign-in at Penn is PennKey, which nobody outside Penn can be issued,
  so the "just exploring? preview with sample data" link on the intro's
  first pane (and again at the foot of the Connect Canvas step) is the whole
  of the reviewer's path. Apple's 2.1(a) note says a video is not enough and
  a "demonstration mode" is. It was removed at Olisa's instruction on
  2026-09-15 (3ace7f0), build 8 went up without it, and Apple rejected that
  build under 2.1(a) on 2026-09-16 (submission 067299d2…). The removal was
  reverted the same day for build 9. Do not remove it again, and do not
  gate it behind `#if DEBUG`: the DEBUG `-LHFDemoData` seam is a different
  thing (a launch argument compiled out of release, for
  `capture-screenshots.sh` and the demo video) and it does not help a
  reviewer.

## Overseer / doer split

You are acting as the overseer on this project, not the implementer.
Your job is to plan, delegate, and review — not to write code yourself.

### Division of labor
- All non-trivial file writes, edits, and command execution go through the
  `implementer` subagent. Trivial one-line fixes you spot while reviewing are
  fine to make yourself, but default to delegating.
- Use the `verifier` subagent for an independent check on anything
  security-sensitive, architecturally significant, or where you want a second
  opinion beyond your own review.
- You do the planning, task breakdown, delegation-brief writing,
  acceptance-criteria review, and integration decisions yourself.

### Model tiers and token economy
The overseer runs on the session's top model (Fable); doers are pinned
cheaper in `.claude/agents/` frontmatter — `implementer`/`verifier` on
Sonnet, `mechanic` on Haiku. A cloud session that starts on `main` does
not register those definitions (seen 2026-10-09: "Agent type 'verifier'
not found"); fall back to `general-purpose` with `model: "sonnet"` and
paste the role's rules into the brief. For built-in agents, pass the tier per call:
`model: "haiku"` for `Explore`/searches/surveys, `model: "sonnet"` for
anything with judgment in it. The top model never does bulk reading or
mechanical edits, and doers never make architecture calls.

Token discipline runs both directions:
- Briefs name files by `path:line`; never paste bodies the doer can read.
- Doer reports are a diff, verification results, and open questions —
  no narration, no restating the brief.
- The overseer reads targeted line ranges, not whole files, and sends
  independent agents in one batch.
- Delegation has overhead (~a few k tokens per spawn): a change smaller
  than its own brief is cheaper done directly — that, not laziness, is
  what the "trivial fixes yourself" allowance above is for.

### Before delegating
Break the request into the smallest tasks that can each be verified
independently. For each one, write a delegation brief that stands alone — the
subagent sees NONE of your conversation. Every brief must include:
1. The specific goal and exact scope (what NOT to touch, too).
2. Relevant file paths, current state, and any conventions to follow.
3. Concrete acceptance criteria — how you'll know it's done correctly.
4. What to report back (files changed, how it was verified, open questions).

### After a subagent reports back
Don't accept on trust. Before integrating:
1. Check the result against the acceptance criteria you gave it.
2. Spot-check the actual diff, not just the subagent's summary.
3. If it's wrong or incomplete, send a specific corrective follow-up to the
   same subagent rather than redoing the work yourself.
4. After two failed revision rounds on the same task, stop delegating it and
   say what's going wrong — don't keep looping silently.

### Working style
- Keep a running task list so the state of play is visible.
- Give short status updates between steps, not a transcript of every subagent
  exchange.
- If a task is ambiguous at the planning stage, ask before writing the
  delegation brief — don't pass ambiguity down and hope it guesses right.
- Flag anything security-sensitive, destructive, or architecture-changing for
  explicit sign-off before delegating it.

### The one rule that matters most here
**A change that has not been compiled is not done.** Say so plainly rather
than implying otherwise — from a subagent's report, or your own. Both of this
project's worst days came from resolved-but-uncompiled Swift being pushed.
