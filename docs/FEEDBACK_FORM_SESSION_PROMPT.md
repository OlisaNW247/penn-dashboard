# Prompt: reach every Smooth user with the feedback form (written 2026-10-27)

Paste everything below the line into a new session.

---

Read `CLAUDE.md` and `ROADMAP.md` first; you are the overseer described there.

**The situation.** On 2026-10-26 I handed out free smoothies at Penn to
students who downloaded Smooth, which brought in several hundred new installs.
I want every one of them to see this feedback form:

https://docs.google.com/forms/d/e/1FAIpQLScZJ4BBXicAOFYSbCkHGcM5kWcDD8OXSSWtkK64kSSUO4WcJQ/viewform

I have no contact details for any of them. Smooth has no accounts with email,
no push notifications from a server, and no analytics (see the privacy posture
in `CLAUDE.md`). Each Penn install does have an anonymous backend account, but
it holds no contact information.

**What I want from you.**
1. Research and recommend the best way to get the form in front of these users,
   inside and outside the app. Rank the options by reach, speed, effort and
   risk, and recommend one plan. Things to weigh, which you should check in the
   code rather than take from me:
   - **The update gate** (`LowHangingFruitKit/Sources/LowHangingFruitKit/Update/`,
     `LowHangingFruitUI/UpdateGate.swift`, `UpdateRequiredView.swift`,
     `UpdateAvailableBanner.swift`) is the only thing every install fetches
     from a file I control without an app update: `lhf-update.json` on the
     `update-manifest` orphan branch. It is read on launch and on return to the
     foreground. Its `message` is shown only on the update wall or banner, as
     plain text (`Text(verbatim:)`), and its button goes to the App Store, so
     using it as-is for a survey would be misleading. Find out whether the
     current builds could show a link from it at all. My guess is no.
   - **A small remote-config "notice" in a new build.** The app fetches a
     notice, for example new optional fields in the same manifest or a new file
     on that branch, and shows a one-time, dismissible card on the dashboard
     that opens the form. Once that build is live, raising the update floor
     would bring everyone onto it. That only works if the build doesn't crash
     (see below).
   - A permanent "send feedback" row in Profile as a fallback.
   - Channels outside the app: What's New text in the App Store listing, QR
     codes or flyers where the smoothies were handed out, Penn GroupMe and
     Instagram, class Ed boards, and so on.
2. If the in-app route wins, plan it, then delegate and review the build as
   `CLAUDE.md`'s overseer rules describe. Constraints:
   - **Privacy:** the link must not carry anything that identifies the student
     or the install. No prefilled ids, and nothing from the backend account.
     Prefilling the app version is the most I would accept. Check whether
     `docs/PRIVACY.md` needs a line about linking out to Google Forms, and
     update it in the same commit if so.
   - **Copy rule:** the least text that works, lowercase, in Smooth's voice
     (see "Copy rule" in `CLAUDE.md`).
   - **Never shown** in preview or demo mode, and never on top of onboarding or
     the update wall. Shown once, and remembered once dismissed or tapped, in
     `UserDefaults.lhf`.
   - **Fail open:** a failed fetch shows nothing and must never block the app,
     the same contract as the update gate.
   - **No incentive tied to App Store ratings or reviews** (App Store Review
     Guideline 5.6.3 and the review-incentive rules). The form is feedback,
     not a rating prompt.
   - Tests in `swift-testing`. A change is not done until it has compiled on
     my Mac (`cd LowHangingFruitKit && swift test --no-parallel`, then the iOS
     build); say plainly what has and hasn't compiled.

**A blocker to settle first.** On 2026-10-25 a first-time user's phone (a
friend's, App Store 3.2.0 build 14) crashed every time, about 2 seconds after
launch, while the dashboard showed "checking canvas…". The cause is not known
yet. An audit of the 3.1.0 to 3.2.0 changes found no definite line. The leading
theory is the first full Canvas sync that 3.2.0 now runs at launch, combined
with that student's data. Those smoothie downloads are exactly first-time
3.2.0 or 3.2.1 installs. Before anything else:
- Ask me whether I have the crash report (`Smooth-<date>.ips`) or Xcode
  Organizer crash data, and whether anyone else crashed.
- Tell me if the update floor (currently 3.2.0, `feec931`) should come down to
  3.1.0 while this is open.
- Do not plan a "raise the floor so everyone sees the notice" step on a build
  that might crash for new users.

Ask me anything you need decided before you write a delegation brief.
