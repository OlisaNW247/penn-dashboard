# Privacy Policy — Low Hanging Fruit (LHF)

_Last updated: 2026-09-07_

Low Hanging Fruit ("LHF", "the app") is a personal academic dashboard that shows
your Canvas assignments and deadlines in one place. This policy explains
what the app does with your information. In short: **your coursework stays on
your device by default.** There is no LHF account, and no LHF server stores
your data. Two things do leave your device, and both are described in full
below: a small, anonymous check that your copy of the app is still allowed to
run, and — only if you paste in your own Anthropic API key — the class data
behind two optional AI features. If you never add a key, the app is fully
on-device apart from that update check.

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
- **No LHF server holds your data.** For your Canvas and Gradescope data, the
  app talks directly to `canvas.upenn.edu` and, if you connect it,
  `gradescope.com` — never through a server of ours. It also makes one small
  outbound request entirely on its own, described next, and, if you turn on
  either optional AI feature, sends the data those features need straight to
  Anthropic. We do not operate a server that receives your academic data, and
  there is still no LHF account.

## Keeping the app up to date

On launch, and whenever you bring LHF back to the foreground, the app makes a
plain request to a small public file the developer hosts (for example on
GitHub), to check whether your copy of the app is still supported. That
request has no query parameters, no headers identifying you or your device,
and carries nothing about your Canvas or Gradescope data — it is a version
check, not a phone-home. Like any request to any website, whoever's server
answers it can see an IP address, the way it could for any page you load, but
nothing else about you or your coursework. If the check finds your build is
too old, LHF can show a full-screen notice that stops the app from opening
again until you update; if a newer version simply exists, it shows a
dismissible banner instead. If the check fails for any reason — no signal,
the file is unreachable, anything — the app opens normally and relies on the
last successful check, kept for up to 30 days, in the meantime.

## Optional AI features (off unless you add your own key)

Two features in LHF are the exception to "everything stays on your device,"
and both are off until you turn them on yourself:

- **Ask ("the tree")** — a chat screen for asking questions grounded in your
  own class data.
- **The Announcement Watcher's AI assist** — an AI summary of your course
  announcements.

Neither feature does anything until you go to Settings and paste in **your
own Anthropic API key**. That key is stored in the iOS Keychain — the same
encrypted, on-device storage used for your Canvas and Gradescope sessions —
never in UserDefaults, and it is only ever sent to Anthropic alongside your
own requests. Once a key is set, using either feature sends the class data it
needs (assignments, grades, announcements, whatever that feature draws on) to
Anthropic's API, billed to your own Anthropic account, so it can generate a
response. What Anthropic does with that data is governed by Anthropic's own
privacy policy and terms, not this one.

If you never enter a key, both features stay off, nothing goes to Anthropic,
and — apart from the update check above — the app is fully on-device. There
is still no LHF server and no LHF account either way.

## What we collect and share

- **Nothing, unless you turn on an AI feature yourself.** LHF has no
  analytics, no tracking, no advertising, and no third-party SDK. By default
  we do not collect, transmit, sell, or share any of your data. The one
  exception is opt-in: if you add your own Anthropic API key, the two AI
  features above send the class data they need to Anthropic's API, as
  described above. Short of that, nothing leaves your device except the
  anonymous update check.

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
