# 3.5.0 (21): hostile test pass, 2026-11-22

Branch `claude/test-release-350-823c96`, cut from the release line
`claude/ambassador-header` at `b760d47`, then merged with its tip `4657640`
(the ambassador contacts `d886fad` and the overdue swipe lesson `0071a1f`) at
the master session's ask. Read-only on production code: no production file
changed. New tests: `LowHangingFruitKit/Tests/LowHangingFruitKitTests/ReleaseTestPass350Tests.swift`.
Every test that pins a defect is wrapped in `withKnownIssue`, so the file is
green today and turns red ("known issue was not recorded") the day the
defect is fixed: drop the wrapper then.

The Sweeper accuracy work, `SubmissionRead`, the poller's scene rules, the
Duo trust renewal and `DuoWaitNotice` were already tested hostile the same
day (`docs/TEST_SWEEPER_SIGNIN_2026-11-22.md`, H1/M1/M2 merged on the line
since); they were not repeated here beyond the swipe and app-link guard
edges. This pass went to what that one did not cover: the update list, the
ambassador page (tasks, goals, guidance, streak, contacts), the install
count, the onboarding practice cards, the either-way swipe, the agent flag,
and the overdue swipe lesson.

## Summary

- **Blocker 0, high 0, medium 4, low 7, info 4.**
- None blocks the archive. The four mediums are small, local fixes; the
  update-list one (R-M4) is a release-notes expectation, not code.
- Gates: `swift test --no-parallel --filter ReleasePass` (30 tests / 8 suites, 13 known issues). Filtered only; other sessions were testing on the Mac.

## Findings

| # | Sev | Where | Finding | Test | Suggested fix |
|---|---|---|---|---|---|
| R-M1 | medium | `AmbassadorModel.swift:327` (`todayIndex`) | **A tick made after midnight under a cached plan is filed under yesterday.** `todayIndex` prefers `plan?.today?.dayIndex`, and the plan is cached for 30 minutes (`staleAfter`) or for as long as the phone is offline. Plan fetched at 23:50, "done" tapped at 00:05: the post reaches the server and is logged on the server's *today*, the phone records `postedDayIndex` and `anonDays` as *yesterday*. After the next refresh the anonymous task reads not done (the ambassador is asked to post again, a double count for the founders) and the streak is off by a day. The same stale index decides every weekly tick. | `ReleasePassAmbassadorTaskTests.staleCachedDayIndex` (known issue) | The phone's own index uses exactly the server's formula (`floor((ms − tz·60000)/86400000)` with the phone's offset; `AmbassadorClient.tzOffsetMinutes`), so drop the plan branch and always compute it locally. `postedToday` should compare against the same local index. |
| R-M2 | medium | `AmbassadorModel.swift:361` (`markDone`), `AmbassadorTaskSheets.swift:127` | **A post that failed to log can never be logged.** `markDone(.anonChats)` ticks first, then calls `markPostedToday`; when that fails (offline, a 5xx), the tick stays, `isDone` is true, and the done row becomes a disabled check, so the button that would retry is gone. The founders' post count misses it for good, which `markPostedToday`'s own comment rules out ("The tap fails visibly instead, and can be repeated"). The group-chat drop has the same shape and fails silently (`try?`). | `offlinePostIsNotRetried` (known issue), `offlineGroupChat` | For `.anonChats`, tick only after `markPostedToday` returns true (or keep the tick but leave a "send again" button while `!postedToday`). For `.groupChats`, keep a pending flag and resend on the next `refresh()`. |
| R-M3 | medium | `OverdueSwipeLesson.swift` `candidate(in:now:)` | **The overdue lesson can pick an item the instructor cancelled.** The filter is "unfinished and five days late"; an applied `cancel` fact (`DashItem.isFactCancelled`) is not excluded, though the dashboard takes such a card out of todo into its own "cancelled" section. The student is told "9 days late. pull it right once it's done." over work that no longer exists, and the swipe writes a completion to the ledger. | `ReleasePassOverdueLessonTests.cancelledByFact` (known issue) | Add `!$0.isFactCancelled` to the filter. |
| R-M4 | medium (expectation) | `docs/appstore/LISTING.md` "Update wall list for 3.5.0"; `UpdatePolicy.swift:106` | **The four "changes" lines will be seen by nobody.** `changes` was added on 2026-11-11; 3.4.1 (20), the build every student who meets the 3.5.0 wall is on, was archived from `v10` `c3a4feb`, whose `UpdatePolicy` has no `changes` key (`git show c3a4feb:…/UpdatePolicy.swift | grep -c changes` → 0), so its wall ignores the list. And on 3.5.0 itself the list only shows below the floor (wall) or below `latestVersion` (banner, never: the two are kept equal). The lines first reach anyone on the 3.6 wall, where they would describe 3.5.0 unless replaced. The sanitizer itself is fine: all four of Marco's lines survive unchanged, including the one that is exactly 40 characters. | `ReleasePassUpdateChangesTests.allFourKept`, `manifestDecode` (held) | Nothing in code. Either set the list anyway (harmless) and tell Marco it is for 3.6's wall, or leave it out of `lhf-update.json` until 3.6 and write 3.6's lines then. |
| R-L1 | low | `AmbassadorStatsCard.swift:18` | **"1 users at uva so far".** No singular. Also a negative count from the server would print as is. | read from the code | `users == 1 ? "user" : "users"`; `max(0, users)`. |
| R-L2 | low | `InstallCountRule.swift:60` | **A last-attempt stamp in the future blocks the count until the clock catches up.** A phone whose date was once set ahead stamps `installCountLastAttemptAtV1` in the future; `now − lastAttempt` is negative, always `< retryInterval`, so no attempt is made until real time passes the stamp (never, for a year-2100 clock). | `ReleasePassInstallCountTests.futureStamp` (known issue) | `if let lastAttempt, lastAttempt <= now, now.timeIntervalSince(lastAttempt) < retryInterval { return false }`. |
| R-L3 | low | `InstallCountRule.swift:36-43` | **The phone's host rule is looser than the Worker's.** `normalizedHost` accepts `canvas.upenn.edu.`, `.canvas.upenn.edu`, `canvas..upenn.edu` and `....`; the Worker's `/^[a-z0-9-]+(\.[a-z0-9-]+)+$/` answers each with 400, and a 400 is `.done`, so that install is never counted. Only a hand-typed Canvas address can produce one; the catalog hosts all pass both rules. | `hostRuleMatchesWorker` (known issue) | Use the Worker's regex in `normalizedHost` (or strip one trailing dot first, then apply it). |
| R-L4 | low | `CanvasCompletionGuide.swift:74` (`PracticeCards.items`) | **The practice lesson offers work already handed in, and calendar events.** The pool is the raw `state.canvasItems`; an assignment Canvas already lists as submitted, and a `.event` (a lecture) are picked like anything else, so "swipe right to finish" lands on a lecture or on work that is done. Harmless (nothing is written), but it is the student's first look at their own list. | `ReleasePassPracticeCardsTests.submittedAndEvents` (known issue) | Filter `!$0.submitted && $0.kind != .event` before picking; fall back as now when nothing is left. |
| R-L5 | low | `UpdatePolicy.swift:162` (`containsLink`) | **A bare domain is not a link to the filter.** NSDataDetector does not flag a scheme-less domain on every TLD, so a line such as "see smooth.app now" reaches the undismissable wall, which the sanitizer's comment says must not happen. The manifest is the owners' own file, so this needs a compromised or careless edit. | `ReleasePassUpdateChangesTests.bareDomains` (known issue; the test prints which of four candidates pass) | Also drop a line matching `[a-z0-9-]+\.[a-z]{2,}(/|\b)` (a dot between letters), since no change line needs one. |
| R-L6 | low | `OverdueSwipeLesson.swift` `candidate` | **"Most overdue" is the oldest row, and that is often the worst card to show.** A recycled Canvas site keeps last year's rows (CLAUDE.md, the term trap: CIS 4500's 2025 "Met Instructor"), so the one card a student sees is "387 days late". A `.event` and a nothing-to-submit item (`requiresNoSubmission`, "in class") are picked the same way. | `oldestIsNotBest` (two known issues) | Exclude `.event` and `requiresNoSubmission`; prefer the *least* overdue item past five days (it is the one the student recognises), or cap at, say, 60 days late. |
| R-L7 | low | `AmbassadorPlan.swift` `Contact` (`d886fad`) | **Contact ids collide, and phone digits are concatenated blindly.** `id` is `name + phone`: two identical rows in the deploy variable, or ("Ol", "isa1") against ("Olisa", "1"), share an id inside `ForEach` (SwiftUI drops or duplicates rows). `smsURL` keeps every ASCII digit, so "1-800-SMOOTH1" texts 18001 and "215-555-0100 ext 22" texts 215555010022. A row with an empty phone draws a button that does nothing. The founders write the variable, so all of this needs a typo. | `ReleasePassContactsTests.ids`, `lettersAndExtensions` (known issues), `sms`, `lenient` (held) | `id` = `"\(name)\u{1F}\(phone)"` plus the index (`ForEach(Array(contacts.enumerated()), id: \.offset)`); reject a phone with letters; hide a row whose `smsURL` is nil. |
| R-I1 | info | `AssignmentCardView.swift:546-583`, `DoneView.swift:124-150` | **A cancelled drag leaves `swipeAxis` stuck.** `swipeAxis` is `@State` reset only in `onEnded`; SwiftUI does not call `onEnded` when a gesture is cancelled (a system interruption, the scroll view taking the touch under `.simultaneousGesture`). A stuck `.horizontal` makes the next vertical drag on that card move it sideways until a drag ends normally. Not reproducible under `swift test`. | none (needs a device) | Hold the axis in `@GestureState` (reset on cancel), or reset it in `.onChanged` when `value.translation == .zero`. |
| R-I2 | info | `ContentView.swift` `decideOverdueLesson` | **The overdue lesson's key is written before the cover is known to have presented.** If another sheet is already up when the first non-empty item list arrives (the add sheet, an alarm takeover's sheet), `fullScreenCover` fails to present and the key stays written: the lesson is lost for that install. Rare, and the cost is only a lesson. | read from the code | Write the key in the cover's `onAppear`, keeping the "decided" flag as now. |
| R-I3 | info | `AppState.swift:5521`, flag `agentConnection = false` | **Agent flag: nothing leaks on the phone** (`agentDraftDisplay`, `agentSubmittedNamesByItemID` and the cache seed guard on `agentSurfacesAllowed`; the passes guard on `AgentPassRules.shouldStart`; `smooth://link` on `canUseAgentConnection`; disconnect deletes the server snapshot ungated). But on a phone that ran a `v11` build (Marco's), the server snapshot and the claude.ai connection stay live, and 3.5.0 has no control to turn them off short of a Canvas disconnect: a connected Claude can still read the last uploaded work list. | read from the code | Tell Marco; disconnect the agent in claude.ai or delete the server row by hand. A one-shot "if opted in and the flag is off, delete the snapshot once" in the foreground pass would close it for everyone. |
| R-I4 | info | `AmbassadorModel.swift:361` | `markDone` ticks even when there is no plan, or on a rest day (`today.channel == nil`), and sends nothing; the server's bank has no rest day today, so it cannot happen with the live Worker. | read from the code | Folded into R-M2's fix. |

## What held

- **Update list.** Marco's four lines decode, survive the sanitizer in order
  and round-trip through the cache; a 41-character line, a scheme link and a
  `www.` link are dropped; case and a trailing tab are normalised.
- **Ambassador pure rules.** The streak never counts a future day and
  survives an unposted today; a corrupt stored task log decodes with the
  good half kept; goal progress clamps and a zero target is safe; filling the
  guidance twice changes nothing; the posters count clamps from either side.
- **Install count.** The body is exactly two keys; catalog hosts pass both
  the phone's and the Worker's rule; the existing `InstallCountTests` truth
  table stands.
- **Practice cards.** One per class first, soonest first, at most three, no
  duplicates; past and undated work falls back to the generic three; 10,000
  items pick in under a second.
- **Swipe.** `acceptsCompletion` is symmetric, a fling the opposite way of
  the drag never counts, NaN and −0 never complete, more vertical than
  horizontal never completes; prev's undo stays left-only.
- **App-link guard.** Fires only on a cross-host arrival at the guard host
  (case-insensitive), never on back/forward, never with the reissue marker,
  never with no current host; the reissue cap holds; the form script embeds
  the target as one JS string with the fragment stripped.
- **Contacts.** Malformed rows are dropped one by one and never cost the
  plan; `contacts` as a string, an object, null or empty never throws.
- **Overdue lesson.** Empty lists, future dates and fractional days behave;
  its own suite already pins the five-day boundary and the store.

## Gates

`swift test --no-parallel --filter ReleasePass`: 30 tests / 8 suites, green, with 13 known issues (each one a finding above; R-L5's run named `smooth.app` and `smooth.dev` as the bare domains that pass). The existing suites the findings touch (`OverdueSwipeLessonTests`, `InstallCount*`, `UpdateChangesTests`, `CompletionSwipeTests`, the practice and plan suites; filter matched 64 tests / 10 suites) re-ran green on the merged tree. No iOS-only file changed, so no `xcodebuild`.

Nothing was pushed, merged into the release line, deployed or installed.
