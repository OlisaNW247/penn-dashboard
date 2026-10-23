# Privacy Policy — Low Hanging Fruit (LHF)

_Last updated: 2026-10-23_

Low Hanging Fruit ("LHF", "the app") is a personal academic dashboard that shows
your Canvas assignments and deadlines in one place. This policy explains what
the app does with your information.

**In short:** your grades, your work, and your Canvas/Gradescope logins stay on
your phone, or, if you pair the Smooth Chrome extension, travel only
end-to-end encrypted between your own phone and your own laptop, where we
cannot read them. Course materials — syllabi, course pages, assignment descriptions,
announcements — are pooled with classmates in the same Canvas course, so
everyone shares one copy instead of each of you re-fetching it. Questions you
ask "the tree" are answered by an AI model running on our server and are not
stored.

## What stays on your phone

- **Your Canvas and Gradescope logins.** You sign in through each service's own
  web page inside the app. Session cookies and your Canvas calendar feed URL
  are stored in this device's Keychain. For Penn Canvas, the sign-in screen
  explains that Smooth also saves the PennKey credentials you submit after a
  successful connection, to reconnect automatically. Gradescope and other
  schools' passwords are not captured. See "Automatic Canvas reconnection" below.
- **Your grades, completions, and submission state.** What you've turned in,
  what you've checked off, any grade the Grade Watcher has observed — all of it
  stays local. None of it is uploaded in readable form; the one exception is
  the end-to-end encrypted sync with your own paired laptop, described in
  "The Chrome extension" below.
- **Your work list and your name.** Assignments you add yourself, due-date
  edits, reminder settings, and the first name you enter never leave the
  device, except encrypted, to your own paired laptop (below). Your name and
  your reminder settings are never part of that sync.
- **The widget snapshot.** A small "next due" summary written to a private
  container shared only between the app and its widget on your device.
- **The announcements list.** The megaphone on the dashboard lists your
  classes' Canvas announcements from the last 60 days. For that the app keeps
  each one's title, class, date, link and a short preview in a file on this
  phone. That file is never uploaded, and disconnecting Canvas deletes it.
  For a class that uses Ed Discussion, the list also shows that class's Ed
  announcements and pinned posts, taken from the course material already on
  your phone (described below); showing them makes no new request and sends
  nothing.
- **Tasks found in announcements.** When an announcement says to do
  something by a date (and, for a class that uses Ed Discussion, when an Ed
  announcement or pinned post does), the app turns it into a card on your
  list. The card and a task you check off stay on this phone with the rest of
  your work list, and a task leaves your list once its date has passed. The
  only thing that can leave the phone is the post's text, and only if AI
  assist is on (see "What is sent to our server").
- **Due dates you change.** If you edit an assignment's due date, the new
  date is saved on this phone and used for your list, your reminders and the
  widget. It is never uploaded in readable form (only inside the encrypted
  sync with your own paired laptop): a question you ask "the tree" is sent
  with the date Canvas or Gradescope gave, not the one you set.
- **Your voice.** The mic in "the tree" turns what you say into text on
  this phone, with Apple's on-device speech recognition. The audio never
  leaves the phone and is not kept; only the text you then choose to send
  goes anywhere. On a phone or language where on-device recognition is not
  available, the mic is simply not shown rather than sending audio to a
  server.

## Automatic Canvas reconnection

Staying connected is part of signing in to Penn Canvas with Smooth; there is
no separate "stay signed in" choice or second password entry.

- **What is captured:** the username and password submitted on the verified
  PennKey login form. Smooth holds one pair in memory while Canvas verifies
  the session, for at most ten minutes. It does not record keystrokes or Duo
  codes. Cancelled, failed, or expired attempts release the temporary pair.
- **When it is saved:** only after Canvas successfully connects. The login
  screen explains this before you enter your credentials.
- **Where:** the iOS/macOS Keychain, encrypted at rest, this-device-only,
  never synced to iCloud or other devices. Credentials are never logged,
  written to preferences, or sent to Smooth's servers.
- **Use:** to fill Penn's own HTTPS login page when Canvas requires a new
  session. Duo approval may still be required. A rejected stored password
  stops automatic retries and asks you to reconnect or update the password.
- **How to remove it:** disconnect Canvas in Settings. This removes the saved
  credentials and stops automatic reconnection.
- **SSO and other schools:** if a login succeeds without submitting a PennKey
  password, Smooth can retain the session but cannot manufacture a saved
  password. Other institutions continue using their existing session handling.

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

  **Ed Discussion, for classes that use it (Penn, since 2026-10-02).** If a
  class's Canvas site has an "Ed Discussion" tool, the app opens it the way
  you would, signed in through your own Canvas session, and reads the
  class's Ed board. It keeps only the posts that are course material:
  announcements, pinned posts, and posts written by the instructor or TAs.
  Student posts and questions, private posts, and anonymous posts never
  leave your phone, and no author's name is ever recorded. The kept posts
  are pooled per class exactly like a syllabus. You never type an Ed password or
  token; the Ed session the app receives is stored in this
  phone's Keychain like your Canvas session and deleted with it. (The
  "AI assist" switch below also covers these posts.)

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
  Each of these requests carries the post's title and body, the post's id (a
  Canvas announcement's id, or the Ed thread's), the class code and the post's
  date, and nothing else about you.
  Since 2026-10-18 the same switch covers Ed Discussion announcements and
  pinned posts for classes that use it (Penn): such a post's title and body
  (never an author's name, which the app does not keep) go to the same server
  and model, with the class code, the post's id and the date, once, only when
  an on-device check says the text could contain a task, and only for a class
  you have not hidden. It is text the app already pools per class (see
  above), and the result isn't stored either. With the switch off, Canvas and
  Ed posts are read on the phone and nothing is sent.

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

## The Chrome extension (optional, Penn)

Smooth has a Chrome extension for your laptop. It is optional and does
nothing until you pair it with your phone.

- **It uses the Canvas, Gradescope and Ed Discussion sessions already open in
  your browser.** It never reads, copies or stores a cookie or a password;
  Chrome attaches your own session to its requests, the same way it does
  when you open those sites. Your Canvas calendar feed address is looked up
  fresh each time and never saved. Your Ed session token is kept only in
  Chrome's memory and is gone when Chrome closes.
- **It collects course material your phone can't reach**: every course
  announcement, every course page, and the text of PDFs in a course's
  Files (slides, readings), plus Ed announcements, pinned posts and staff posts under the same
  rule as the phone (never a student's post, never an author's name). That
  material is pooled per class exactly like the phone's ("What is sent to
  our server"), so classmates share one copy.
- **Pairing.** The extension shows a QR code; you scan it with your iPhone and
  confirm "pair this laptop?" in Smooth. The code carries a secret key made
  on the laptop. The key goes from the laptop's screen to your phone's camera
  and is never sent to our server. The server only learns that the
  extension's anonymous account now belongs with your phone's.
- **End-to-end encrypted sync.** With that key, your phone and laptop share
  what you've checked off, due dates you've changed, tasks you've added, and
  your list of what's due. Each device encrypts its copy (AES-256-GCM) before
  it leaves, and our server stores only that encrypted copy. We cannot read
  it, and neither can Supabase. Your name, reminder settings and grades are
  never part of it.
- **Unpairing** (from the extension, or Profile → accounts → laptop on the
  phone) deletes the extension's account and its encrypted copy from our
  server. Disconnecting Canvas on the phone does the same for every paired
  laptop, along with everything listed under "Deleting your data".

## Who we send data to

- **Supabase** hosts our database and server functions. They act as our
  infrastructure provider; they don't get a separate copy for their own use
  beyond running the service.
- **OpenRouter**, and the AI model providers it routes to, process the
  questions "the tree" is asked (and, if AI assist is on, announcement and
  Ed post text) in order to generate an answer. We send every request with OpenRouter's
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
- **Encrypted sync copies**, if you paired the Chrome extension: one
  encrypted copy per device, replaced each time that device syncs, deleted
  when you unpair or disconnect Canvas. We hold no key to them.

## Deleting your data

**Disconnecting Canvas** (Profile → accounts → canvas) deletes your class data
from our server along with your login on the device: your enrollment records,
your usage counters, and the anonymous account itself, and it removes the
Ed Discussion session from this phone, and it unpairs every laptop: their
anonymous accounts and encrypted sync copies are deleted too. The
confirmation says so before you tap it. It does not delete the shared course material other students
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
