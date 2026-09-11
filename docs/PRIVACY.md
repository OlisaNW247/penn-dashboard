# Privacy Policy — Low Hanging Fruit (LHF)

_Last updated: 2026-09-07_

Low Hanging Fruit ("LHF", "the app") is a personal academic dashboard that shows
your Canvas assignments and deadlines in one place. This policy explains what
the app does with your information.

**In short:** your grades, your work, and your Canvas/Gradescope logins stay on
your phone. Course materials — syllabi, course pages, assignment descriptions,
announcements — are pooled with classmates in the same Canvas course, so
everyone shares one copy instead of each of you re-fetching it. Questions you
ask "the tree" are answered by an AI model running on our server and are not
stored.

## What stays on your phone

- **Your Canvas and Gradescope logins.** You sign in through each service's own
  web page, shown inside the app. The app never sees or stores your password.
  Session cookies and your personal Canvas calendar feed URL (a bearer
  credential) are kept in the iOS Keychain, encrypted at rest, this-device-only,
  and never included in unencrypted backups.
- **Your grades, completions, and submission state.** What you've turned in,
  what you've checked off, any grade the Grade Watcher has observed — all of it
  stays local. None of it is uploaded.
- **Your work list and your name.** Assignments you add yourself, due-date
  edits, reminder settings, and the first name you enter never leave the
  device.
- **The widget snapshot.** A small "next due" summary written to a private
  container shared only between the app and its widget on your device.

## What is sent to our server (and why)

LHF now runs a small backend of our own (Supabase: a Postgres database plus a
few serverless functions) so that two things work better than they could
on-device alone:

- **Course materials, pooled per class.** After you connect Canvas, the app
  fetches your class's syllabus, course pages, module listings, assignment
  descriptions, and announcements using your own logged-in session — exactly
  as it always has — and uploads the extracted text to our server, keyed by
  Canvas's own course id. Every student in the same Canvas course site shares
  one copy: if a classmate already synced it, you get it instantly instead of
  waiting on your own fetch, and a new student gets the whole course's material
  on day one. We record which Canvas section you're in for possible future use,
  but material isn't split by section yet — see "Anonymous accounts" below for
  the limits of this design. This sync is automatic: it runs once after you
  connect Canvas, then again on the app's normal hourly refresh if a course's
  material is stale. There's no manual sync button and nothing to type in.

  **What is never included:** your grades, completions, submission state, your
  work list, your name, or anything else specific to you. Only the shared,
  public-to-the-class content described above. The only other request the app
  makes on its own is the anonymous update-policy check described below.

- **Questions you ask "the tree."** When you ask a question, the app sends the
  question, an on-device summary of your dashboard (built without your name,
  grades, or completion state), and the most relevant excerpts of the pooled
  course material to our server, which forwards them to an AI model to
  generate an answer streamed back to you. Neither the question nor the answer
  is stored anywhere — see "What we keep and for how long" below.

  The Announcement Watcher's "AI assist" toggle is on by default (you can turn
  it off in Settings). With it on, extracting a task and due date from an
  announcement's text works the same way — the announcement
  text goes to the same server and model, and the result isn't stored either.

  Grade Watcher can also ask the server how a class's Canvas assignment
  groups line up with its syllabus categories. That request carries the
  *names* of the groups and assignments, their points possible and
  submission types — never a score, never whether you submitted anything.
  The answer is a suggestion the report shows you; nothing changes until
  you tap "use it." Because the structure of a class's assignment groups is
  the same for everyone in it, the answer is cached per class and shared
  with classmates, so the model is asked about each class once, not once
  per student.

- **An anonymous account id.** The first time you launch the app, it creates an
  anonymous account with our backend — no email, no password, no name — so the
  server can tell your enrollment and quota apart from every other student's
  without knowing who you are. See "Anonymous accounts" below.

**Offline, or if you've asked more questions than the daily limit, or if our
server is unreachable, ask still works** — it answers from what's already
synced to your phone, exactly as it did before this backend existed, just
without the AI model's help on questions that need it.

## Keeping the app up to date

On launch, and whenever you bring LHF back to the foreground, the app makes a
plain request to a small public file the developer hosts (for example on
GitHub), to check whether your copy of the app is still supported. That
request has no query parameters, no headers identifying you or your device,
and carries nothing about your Canvas or Gradescope data, your grades, or
your coursework — it is a version check, not a phone-home. Like any request
to any website, whoever's server answers it can see an IP address, the way it
could for any page you load, but nothing else about you or your coursework.
If the check finds your build is too old, LHF can show a full-screen notice
that stops the app from opening again until you update; if a newer version
simply exists, it shows a dismissible banner instead. If the check fails for
any reason — no signal, the file is unreachable, anything — the app opens
normally and relies on the last successful check, kept for up to 30 days, in
the meantime.

## Who we send data to

- **Supabase** hosts our database and server functions. They act as our
  infrastructure provider; they don't get a separate copy for their own use
  beyond running the service.
- **OpenRouter**, and the AI model providers it routes to, process the
  questions "the tree" is asked (and, if AI assist is on, announcement text)
  in order to generate an answer. We send every request with OpenRouter's
  data-collection-deny setting turned on, which instructs providers on that
  route not to retain or train on the request. We don't control what
  OpenRouter or upstream providers do beyond honoring that setting, but it's
  the strictest option they offer.

We do not sell data, run ads, or share anything with data brokers, and we have
no relationship with Supabase or OpenRouter beyond paying for infrastructure
and API access.

## What we keep and for how long

- **Course materials** are kept as long as they're current, shared per Canvas
  course as described above. They're not tied to you individually — deleting
  your account doesn't delete a course's shared material, because it isn't
  your data; it's the course site's public content.
- **Questions and answers are never stored**, not even briefly for debugging.
  We keep only a per-user daily count of how many questions were asked and a
  running token total, used solely to enforce fair-use limits. There is no
  transcript.
- **Your enrollment list** (which Canvas courses you're synced to) is kept so
  the pooling and quota system work, and is deleted if you delete your
  account.

## Deleting your data

Settings has a **"Delete my class data from LHF's server"** button. It deletes
your enrollment records, your usage counters, and the anonymous account itself
from our server. It does not delete the shared course material other students
are still using, because that material was never yours alone — it's the same
syllabus and assignment pages every enrolled student can already see on
Canvas. Deleting the app also removes everything stored on your device,
including the Keychain-stored sessions.

## Anonymous accounts

Signing in anonymously means there's no email, password, or name tied to your
account — just an id the server uses to tell requests apart for enrollment and
quota purposes. One honest limitation: the app currently tells the server
which Canvas courses you're in, and the server takes that at face value rather
than verifying it against Canvas directly (verifying it would require the
server to hold your Canvas login, which we've deliberately built the whole
system to avoid). In practice this means a tampered copy of the app could
claim membership in a course it isn't enrolled in and read that course's
pooled material — material that's already visible to every real student in
that course's Canvas site, so nothing personal is exposed this way, but it's
worth stating plainly rather than implying a guarantee we haven't built.

## What we don't do

- **No analytics, tracking, or advertising**, and no data broker or ad network
  ever receives anything from this app.
- **No third-party SDKs.** The app is built directly against Apple's and
  Supabase's plain HTTP APIs — no analytics kit, ad kit, or crash reporter
  bundled in.
- **No push notifications.** Reminders are scheduled and delivered locally on
  your device.
- We don't sell your data. There's nothing to sell — we don't have it.

## Affiliation

LHF is an independent app. It is not affiliated with, endorsed by, or
sponsored by the University of Pennsylvania, Instructure (Canvas), Turnitin
(Gradescope), Supabase, or OpenRouter.

## Children's privacy

The app is intended for university students and is not directed at children
under 13.

## Changes

If this policy changes, the updated version will be posted at this page.

## Contact

Questions about this policy: **lowhangingfruit.help@gmail.com**
