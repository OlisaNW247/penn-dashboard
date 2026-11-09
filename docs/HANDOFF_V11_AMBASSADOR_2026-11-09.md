# Handoff: ambassador mode, for `v11` (2026-11-09)

Branch: `claude/new-session-b3ylkg` = `v10` `4c136b2` + two commits.
Olisa or Marco creates `v11` from it. Nothing here is on a phone.

## What was built

**In the app** (Profile → ambassador; CLAUDE.md → What the app does →
Profile → 8 has the full description):
- `Kit/Ambassador/AmbassadorCode.swift`: the code parser (bare code, page
  link, `smooth://ambassador?code=`).
- `Kit/Ambassador/AmbassadorPlan.swift`: the server's `plan.json` model.
- `UI/AmbassadorCodeStore.swift`: Keychain (Tier 3).
- `UI/AmbassadorClient.swift`: the HTTP client; `AmbassadorService` seam.
- `UI/AmbassadorReminders.swift`: the daily local notification requests,
  the `ambassador:` prefix, the reserved slots.
- `UI/AmbassadorModel.swift`: state, the shared singleton, every action.
- `UI/AmbassadorPage.swift`: the page.
- Edits: `SettingsPage` (the row, `ambassadorSection`), `ContentView`
  (`DashRoute.ambassador`, `openAmbassadorIfAsked`), `RootView` (the link,
  `sceneBecameActive`), `NotificationResponseRouter` (the tap),
  `BerserkAlarmDelivery.applyNotifications` (the carve-out),
  `NotificationScheduler.reservedForeignSlots` (the budget),
  `VisualStructureTests` (the marker).
- Tests: `AmbassadorTests.swift`.

**On the server** (`smooth-ambassadors/`, the Worker): `GET
/a/{code}/plan.json?anon=&tz=`, JSON answers for the app's POSTs, the
`daily` bank in `worker/templates/messages.json` (edit the words there),
"open in the smooth app" on the ambassador's web page. `npm test`: 17 green.

## What to do next, in order

1. **Compile and run the suite.** `cd LowHangingFruitKit && swift test
   --no-parallel`. The `tests` workflow was dispatched on the branch; read
   its summary first. Fix what the compiler says; the author could not run
   it.
2. **Deploy the server** (`smooth-ambassadors/docs/deploy.md`): back up
   D1, bring in the live `worker/index.js` as `legacy.js`, apply the
   migration, set `FOUNDER_TOKEN`, deploy, re-test the printed routes.
   Until then the app's sign-in says "couldn't reach smooth".
3. **Add one ambassador in the founder view** and put their code in the
   review notes (`docs/appstore/REVIEW_NOTES.md`, the new paragraph).
4. **On a phone:** sign in with the code; set the reminder to a minute
   from now; background the app; the notification fires; tap it; the app
   opens on Profile → ambassador with today's post; copy; "i posted it";
   the founder view shows the post. Then open the dashboard and wait five
   minutes (a reschedule pass): the pending reminder is still there
   (Settings → Notifications shows nothing useful; check with a second
   fire the next day, or a DEBUG print of `pendingNotificationRequests`).
5. **Dark mode and Dynamic Type** on the page.
6. **Stamp `v11`** when Marco says so; the version is still 3.4.1 (20).

## Decisions worth knowing

- Daily, because Olisa asked for daily. The bank rotates 14 variants with
  one rest day so the same words never go up twice in a row; the anonymous
  app is the ambassador's choice. If daily proves too much, `weekdays` is
  one tap, and the founders can thin the bank without an app release.
- One repeating notification, not one per day with the day's words: the
  64-slot cap and the planner's 60-slot budget (see
  `AmbassadorReminders`'s doc comment).
- No push server, no email, no texting service. Local notifications and the
  existing Worker.
- The "two unanswered digests means quiet" rule on the founder view still
  stands for the founders' texts; the in-app reminder is the student's own
  setting and is not auto-silenced. The pause button turns both off.
