# Privacy Policy — Low Hanging Fruit (LHF)

_Last updated: 2026-07-26_

Low Hanging Fruit ("LHF", "the app") is a personal academic dashboard that shows
your Canvas assignments and deadlines in one place. This policy explains
what the app does with your information. In short: **everything stays on your
device, and we collect nothing.**

We have no servers. There is no LHF account. Nothing you do in the app is
transmitted to us, because there is no "us" to transmit it to — the app talks
only to the school services you sign in to.

## What the app accesses

- **Canvas login.** You sign in to your own Canvas account through Canvas's own
  web page, shown inside the app. The app never sees or stores your password.
- **Canvas calendar feed.** After you log in, the app captures your personal
  Canvas calendar feed URL and reads your assignments and deadlines from it.
- **Canvas submission status.** So that work you've already turned in can file
  itself away automatically, the app reads your own submission records from
  Canvas using your logged-in session — the same information you see on
  Canvas's own pages. This is read-only; the app never submits or changes
  anything on Canvas.
- **Gradescope (optional).** If you connect Gradescope, you sign in through
  Gradescope's own web page inside the app. The app reads your own assignments
  and their due dates so they appear alongside your Canvas work.
- **Assignments you create.** Any one-off or recurring tasks you add yourself.
- **Paste-your-calendar-link fallback.** As an alternative to signing in
  inside the app, you can paste your Canvas calendar feed link directly
  (Canvas → Calendar → Calendar Feed). This connects the same assignment/
  deadline dashboard as the in-app login, without the app ever seeing your
  Canvas credentials at all. It does not enable submission-status tracking or
  Grade Watcher, both of which need a logged-in session.
- **Diagnostics report (optional, user-initiated).** Settings has a "Copy
  diagnostics report" button for troubleshooting a stuck Canvas login. It
  copies device/app version info and a short login redirect log (server
  hostnames, URL paths, and HTTP status codes only — never a full URL, query
  string, cookie, password, or your calendar feed link) to your clipboard, for
  you to paste into a support message yourself. The app never sends this
  anywhere on its own.

## Where your data lives

- **On your device only.** Assignments, completions, due-date edits, your name,
  reminder settings and self-created tasks are stored locally on your device.
- **Login sessions are stored in the iOS Keychain.** Canvas and Gradescope
  session cookies are kept encrypted at rest, on this device only, and are never
  included in unencrypted backups. They are used solely to re-authenticate you
  to those services.
- **The widget.** If you add the LHF widget, the app writes a small "next due"
  snapshot to a private container shared between the app and its widget on your
  device. No other app can read it.
- **No servers of ours.** The app has no backend. It talks only directly to
  `canvas.upenn.edu` and, if you connect it, `gradescope.com`. We operate no
  server and never receive your data.

## What we collect and share

- **Nothing.** We do not collect, transmit, sell, or share any of your data.
  There is no analytics, tracking, advertising, or third-party SDK in the app.

## Notifications

If you enable reminders, they are scheduled and delivered **locally** on your
device. There are no push notifications and no notification data leaves the
device.

## Your control

- **Disconnect at any time.** Settings → Account has **Disconnect Canvas** and
  **Disconnect Gradescope**. Disconnecting erases that service's saved login
  from your device along with the data synced from it. Disconnecting one service
  leaves the other connected.
- **There is no account to delete** — LHF never creates one.
- **Deleting the app removes all of its data** from your device, including
  Keychain-stored sessions.

## Affiliation

LHF is an independent app. It is not affiliated with, endorsed by, or sponsored
by the University of Pennsylvania, Instructure (Canvas), or Turnitin
(Gradescope).

## Children's privacy

The app is intended for university students and is not directed at children
under 13.

## Changes

If this policy changes, the updated version will be posted at this page.

## Contact

Questions about this policy: **lowhangingfruit.help@gmail.com**
