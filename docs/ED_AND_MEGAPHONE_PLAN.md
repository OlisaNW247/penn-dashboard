# Ed and the megaphone: what broke, what changed, what is next

Written 2026-10-23 for Marco, from his own phone's data (3.1.0 (13) from the
App Store, read through a debug build installed over it) and the code at
`1450fdc` (the 3.1.0 source) and `origin/v8` (`a480eb1`). Olisa owns Ed and
announcements since 2026-10-18; everything here is on branches for him to
review, nothing is merged into `v8`, nothing is deployed.

## What Marco saw

The megaphone listed only PHYS 0151. A post about "combined worksheet 6-7"
kept showing after the worksheet was turned in.

## Why: three separate causes

1. **The list only reached back 7 days.** Canvas returned 21 announcements
   in 60 days: 20 PHYS 0151, 1 FNAR 0010 (Sept 15), none from CIS 2620 or
   CIS 3990. Those two classes post on Ed instead. So outside PHYS there was
   nothing on Canvas inside the window, and FNAR vanished entirely.
2. **The phone deleted its Ed posts whenever an Ed run did not finish.**
   Olisa is right that Ed works: at 15:05 that day Marco's phone read both
   CIS classes ("connected: CIS 2620, CIS 3990") and a replay of the saved
   data through the 3.1.0 rules lists three Ed posts. But all 35 Ed posts
   on the phone were first stored at 15:05, so none had survived from
   earlier runs, and the megaphone's seen set shows an earlier moment with
   no Ed rows at all. The server agrees: CIS 3990 had no successful Ed read
   from 10-19 to 10-23. Three code paths delete instead of keep:
   - **The course-material sync drops them and saves to disk first.**
     `CourseKnowledgeCollector` merges each re-synced class as a complete
     set, which removes its `.ed` documents, and writes the file at once.
     Ed's own pass only puts them back afterwards, after a hidden sign-in
     that can take about 40 seconds. If the app leaves the screen in that
     window, or the Ed step fails, the file has no Ed posts and the next run
     has nothing to put back. This is the main one, and it is in `v8` too.
   - **A sign-out partway through an Ed run** deleted the classes not yet
     read (3.1.0 only; Olisa fixed it on `v8` in `ad4f920`).
   - **A failed Ed-tab lookup for one class** counts as "no Ed" and deletes
     that class's posts (`v8` too; already a Known gap in `CLAUDE.md`).
   Ed reads themselves fail when the chain behind them breaks: a live
   Canvas session, the Canvas tab check, a hidden launch into Ed, then the
   reads. Marco's Canvas session has been fragile (the analytics-cookie
   trap in `CLAUDE.md`). A failed read is harmless once failures keep the
   old posts; it was the deleting that emptied the megaphone.
3. **Only Ed "announcement" and "pinned" posts were ever listed.** Staff
   posts such as CIS 2620's "No recitation today + HW 5" and "Practice
   questions midterm" never appeared, however relevant.

## Staying signed in to Ed

There is no Ed password. The app signs in to Ed through the student's
Canvas session (the class's Ed tab is an LTI launch; the app runs it in a
hidden WebView), keeps Ed's token in the Keychain, reuses it until Ed
rejects it, and then launches again silently (at most every 30 minutes).
So Ed stays signed in exactly as long as Canvas does, and the Canvas side
is Olisa's sign-out fix plus "stay signed in" (PennKey on file). Nothing in
this work touches either.

What could make Ed need Canvas less: renewing Ed's own token before it
lapses, the way Ed's website does. That call has never been seen working
from this app, so it is not built blind. Next step, if wanted: a DEBUG-only
measurement (when the stored token was saved, when Ed first rejected it)
to learn the token's real lifetime on a phone, then decide.

## What changed (branches, uncommitted state described in the commits)

`fix/megaphone-every-class` (off `v8`):
- The announcements list is the past 7 days **plus each class's newest
  post**, so every class appears.
- A task found in an announcement leaves the megaphone once its real
  Canvas/Gradescope twin is finished. The title matcher now splits
  camelCase and folds "worksheets", so `CombinedWorksheets6-7` and
  "combined worksheet 6-7" are one item.
- **The keep-check.** The server's extractor (which already reads each
  post that might carry a task, once) also returns a judgment per post:
  `event` (over at a date), `task`, `standing` (useful all term) or `news`.
  The phone stores it and decides, with completion state that never leaves
  the phone:
  - a post in the standing set (7 days + each class's latest) is hidden
    once it is over: its event has passed, or every task found in it is
    finished or past (no AI needed for this part, so it works on posts
    read before the change: Marco's worksheet post goes);
  - an older post comes back while it still matters: `standing`, an
    `event` still ahead, a `task` still open;
  - an Ed staff post is listed only while judged to matter (an event or
    a due date still ahead). Staff posts are read for that judgment only:
    what the extractor finds in them is thrown away, because a staff post
    is often an answer, and "you can submit by Friday" in a reply is not a
    task the class was given. About one backend call per staff post, ever.
  - A judgment's `until` may be a date alone ("2026-10-26"); the phone
    reads it as the end of that day in its own time zone.
  - **Backfill.** Posts read before the server gave judgments (on Olisa's
    phone, two staff posts an older build had already processed; on every
    phone, whatever is read before the deploy) get one relevance-only
    call later, tasks discarded, sharing the 6-a-day budget. Nothing is
    sent for this, and no staff post is read, until the install has seen
    the server return a judgment once, so installing before the deploy
    costs nothing.
- **Class bubbles** at the top of the sheet ("all" by default, any class
  or subset); with classes selected, found tasks and posts are one list,
  each task directly above the post it came from.
- Backend (`extract-announcement`): the `relevance` field, and the fix for
  the 502 seen on Marco's phone (a thinking model that spent its whole token
  cap reasoning returned no content and the function failed; now the
  reasoning is capped for `z-ai/` models and an empty answer is retried on
  the fallback model). **Not deployed.**

`fix/ed-posts-durable` (off `v8`): the collector keeps `.ed` documents it
never owned, and a class whose Ed state is unknown this run is kept, never
dropped. Only a successful Ed read (or Ed saying the class has no Ed
course) changes a class's Ed posts.

## Order to ship

1. Review both branches (Olisa: they touch his Ed and announcement code;
   neither touches sign-in), merge into `v8`.
2. Install on Marco's phone (Codex was testing a Sweeper build on it on
   2026-10-23, so ask first) and watch for a few days: Ed rows must stay
   through failed runs; every class must show; finished-task posts must go.
3. Deploy `extract-announcement` (a production change: a person's go and
   the Supabase token, which the dev Mac does not have). Old app versions
   ignore the new field.
4. Release.

## Open decisions

- Whether `standing` posts older than a class's latest should list
  (currently: yes, while within the 60-day log).
- A way for the student to hide a post by hand.
- Posts the on-device gate decides carry no task are never sent to the
  server, so they get no judgment and follow the plain 7-day rule. Sending
  every post would cost quota shared with ask.
- Ed token renewal (above): measure first.
