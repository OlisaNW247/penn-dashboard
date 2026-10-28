# Privacy Policy — Low Hanging Fruit (LHF)

_Last updated: 2026-10-27_

Low Hanging Fruit ("LHF", "the app") is a personal academic dashboard that shows
your Canvas assignments and deadlines in one place. This policy explains what
the app does with your information.

**In short:** your grades and your Canvas/Gradescope logins stay on your
phone. Your list of work stays there too, with three exceptions described
below: a summary of it, including which items are done, goes with each
question you ask "the tree"; if you pair the Smooth Chrome extension, it
travels end-to-end encrypted between your own phone and your own laptop,
where we cannot read it; and if you turn on iCloud sync, it goes to your own
iCloud. Course materials — syllabi, course pages, assignment descriptions,
announcements — are pooled with classmates in the same Canvas course, so
everyone shares one copy instead of each of you re-fetching it. Questions you
ask "the tree" are answered by an AI model running on our server. The
question and the answer are not stored; a small record of each request (when,
which model, how long, how many tokens, never the text) is. Deleting the app
does not remove everything it saved on the phone: see "Deleting your data".

## What stays on your phone

- **Your Canvas and Gradescope logins.** You sign in through each service's own
  web page inside the app. Session cookies and your Canvas calendar feed URL
  are stored in this device's Keychain. For Penn Canvas, the sign-in screen
  explains that Smooth also saves the PennKey credentials you submit after a
  successful connection, to reconnect automatically. Gradescope and other
  schools' passwords are not captured. See "Automatic Canvas reconnection" below.
  iOS keeps Keychain items when an app is deleted, so these can outlast the
  app; see "Deleting your data" below.
- **Your grades, completions, and submission state.** What you've turned in,
  what you've checked off, any grade the Grade Watcher has observed — all of it
  is kept on this phone. Grades and scores are never sent to our server. Three
  things carry part of it off the phone, and only these: whether each item is
  done (never a grade) goes to our server in the summary sent with each
  question to "the tree" (see "What is sent to our server"); completions go,
  end-to-end encrypted, to a laptop you pair (see "The Chrome extension"); and
  if you turn on iCloud sync, your record of each item, including the score
  you earned on it, goes to your own iCloud (see "iCloud sync").
- **Your work list and your name.** Assignments you add yourself, due-date
  edits, reminder settings, and the first name you enter never go to our
  server. The work Canvas and Gradescope give you is the exception: its titles
  and due dates are in the summary sent with each question you ask "the tree"
  (see "What is sent to our server"), though your own tasks and your due-date
  edits are not. Your own tasks and due-date edits are shared, encrypted, with
  a laptop you pair (below). With iCloud sync on, your own tasks and your
  per-class settings go to your own iCloud (below). Your name is never part of
  either sync, and your reminder settings are never part of the laptop's.
- **The widget snapshot.** A small "next due" summary written to a private
  container shared only between the app and its widget on your device.
- **The announcements list.** The megaphone on the dashboard lists your
  classes' Canvas announcements from the last 60 days. For that the app keeps
  each one's title, class, date, link and a short preview in a file on this
  phone. That file is never uploaded, and disconnecting Canvas deletes it.
  For a class that uses Ed Discussion, the list also shows that class's Ed
  announcements and pinned posts, and an instructor's or TA's post while it
  still matters, taken from the course material already on your phone
  (described below); showing them makes no new request and sends nothing.
  Which posts stay listed is decided on this phone: a post leaves once what
  it was about is over, or once every task found in it is done. For that the
  app keeps, per post, a short note of what kind of post it is and until when
  it matters (see "AI assist" below). The note stays on this phone, is never
  uploaded, and disconnecting Canvas deletes it. Whether you finished a task
  is never sent anywhere to make this decision.
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

## iCloud sync (optional, off by default)

Profile → sync has a switch, "sync between my devices". It is off until you
turn it on, and it takes effect the next time you open the app. With it on,
the app keeps two things in your own iCloud account, using Apple's CloudKit
and iCloud key-value storage, so your other devices signed in to the same
Apple ID (a Mac running Smooth, for example) see them:

- **Your record of your work.** For each item: its class, title, due date and
  link, where it came from, whether you checked it off or it was turned in
  (and when), the score you earned and its maximum when Canvas or Gradescope
  has given one, and the tasks you added yourself.
- **Your per-class settings.** The names you gave classes, which classes are
  hidden or deleted, each class's reminder choices, and the app's per-class
  choices about course content.

It does not carry your name, your Canvas or Gradescope logins, cookies,
calendar feed address or saved PennKey password (those stay in each device's
own Keychain and are never synced), your grade history over time, or due
dates you changed.

This copy lives in your iCloud, under your Apple ID, with the protection
Apple gives iCloud data. It does not pass through our server, and we cannot
read it. Turning the switch off stops new changes going up; it does not
delete what is already in your iCloud, and neither does deleting the app. You
can remove it in iOS Settings → your name → iCloud → Manage Account Storage.

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

  **What is never included in that upload:** your grades, completions,
  submission state, your work list, your name, or anything else specific to
  you. Only the shared, public-to-the-class content described above. The only
  other request the app makes on its own is the anonymous update-policy check
  described below.

- **Questions you ask "the tree."** When you ask a question, the app sends the
  question, a summary of your classes and work that the app builds on your
  phone, the most relevant excerpts of the pooled course material, the Canvas
  ids of your classes, and the time of the question and your phone's time zone
  (so that due times and "tomorrow" read correctly) to our server, which
  forwards them to an AI model to generate an answer streamed back to you.
  Neither the question nor the answer is stored anywhere — see "What we keep
  and for how long" below.

  What the summary holds: for each class, its code, any name you gave it, and
  the grading weights (percentages) from its syllabus or Grade Watcher; and,
  for each item of work from Canvas and Gradescope, each reading, and each
  task the app found in an announcement, its class, its title, the due date
  Canvas or Gradescope gave, where it came from, and **whether it is done**
  (you checked it off or it was turned in), still outstanding, or has nothing
  to submit. So your completion state is sent: one word per item, beside the
  item. The summary does not hold your name, any grade or score, a due date
  you changed, a task you added yourself, or your reminder settings.

  The Announcement Watcher's "AI assist" toggle is on by default (you can turn
  it off in Settings). With it on, extracting a task and due date from an
  announcement's text works the same way — the announcement
  text goes to the same server and model, and the server doesn't store the
  result either.
  Each of these requests carries the post's title and body, the post's id (a
  Canvas announcement's id, or the Ed thread's), the class code and the post's
  date, and nothing else about you.
  Since 2026-10-18 the same switch covers Ed Discussion announcements and
  pinned posts for classes that use it (Penn): such a post's title and body
  (never an author's name, which the app does not keep) go to the same server
  and model, with the class code, the post's id and the date, once, only when
  an on-device check says the text could contain a task, and only for a class
  you have not hidden. It is text the app already pools per class (see
  above). Since 2026-10-23 an instructor's or TA's ordinary Ed post is sent
  the same way, once, a few a day at most, so the model can say whether it
  still matters; no task is ever made from such a post. The answer to every
  one of these requests also says what kind of post it is and until when it
  matters; the phone keeps that short note (and the tasks, as above), and
  the server keeps nothing. A post read before the server could give that
  note is sent once more, only for the note, a few a day at most and only
  while it is under two weeks old; the second answer's tasks are thrown
  away. With the switch off, Canvas and Ed posts are read on the phone and
  nothing is sent.

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
the meantime. While that notice is up, the app also clears the reminders it
had scheduled and the Home Screen widget shows "update smooth" instead of your
work; both come back once you update.

Requests the app makes to its own backend (the Penn features above) also
carry the app's version number, for example "3.3.0", so the backend can refuse
a version that is no longer supported. The version number is the same for
every copy of that release and says nothing about you.

## Feedback form

Smooth may show a card on the dashboard asking how the app is going, and
Profile has a "send feedback" row. Either one opens a Google Form in
Safari. The app adds nothing to the link and sends the form nothing about
you, your device or your coursework; whatever you type is sent to Google by
the form itself, under Google's privacy policy, and is read by the
developer. The card's wording and link come from the same public update
file described above, so checking for it sends nothing new.

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
  Files or linked from its pages, assignments and modules (slides,
  readings), plus Ed announcements, pinned posts and staff posts under the same
  rule as the phone (never a student's post, never an author's name). That
  material is pooled per class exactly like the phone's ("What is sent to
  our server"), so classmates share one copy.
- **Pairing.** The extension shows a QR code; you scan it with your iPhone and
  confirm "pair this laptop?" in Smooth. The code contains the secret key
  itself, made on the laptop, so anyone who can see or photograph the code
  while it is on screen could read the key: pair in private. The key goes from
  the laptop's screen to your phone's camera and is never sent to our server.
  The code works once, expires after ten minutes, and links nothing unless
  your own phone confirms; an unused code leaves nothing saved on the laptop.
  The server only learns that the extension's anonymous account now belongs
  with your phone's.
- **End-to-end encrypted sync.** With that key, your phone and laptop share
  what you've checked off, due dates you've changed, tasks you've added, and
  your list of what's due. Each device encrypts its copy (AES-256-GCM) before
  it leaves, and our server stores only that encrypted copy. We cannot read
  it, and neither can Supabase. Your name, reminder settings and grades are
  never part of it.
- **What the laptop keeps.** In the extension's storage in Chrome, on your
  laptop: the secret key, the extension's anonymous sign-in, its own copy of
  your checked-off items, due-date edits, tasks and list of what's due, and,
  after each sync, your phone's list of what's due. Chrome stores that the way
  it stores any extension's data; the extension adds no encryption of its own
  on the laptop, so protect the laptop (a screen lock and disk encryption) as
  you would for any saved login.
- **Unpairing** (from the extension, or Profile → accounts → laptop on the
  phone) deletes the extension's account and its encrypted copy from our
  server, and removes the key and your phone's list from the laptop. The
  extension keeps its own copy of your checked-off items, due-date edits and
  tasks there until you remove the extension or clear its data. Disconnecting
  Canvas on the phone does the same on the server side for every paired
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
  There is no transcript. What we do keep about asking is two kinds of record,
  both tied to your anonymous account id and to nothing else about you:
  - a per-day count of how many questions were asked and a running token
    total, used to enforce fair-use limits; and
  - one log row for each request: when it was made, which model answered, how
    it ended (answered, empty, error, over the daily limit), how many tokens
    went in and came out, how many characters and pieces of the answer
    streamed back, how long each stage took, and, if it failed, a short error
    note (at most 200 characters). No column in that table can hold the
    question, the summary, the excerpts or the answer. We read these rows to
    see whether answers are quick and working; the app never reads them back;
    they have no automatic expiry today; and they are deleted with your
    anonymous account when you disconnect Canvas.
- **Your enrollment list** (which Canvas courses you're synced to) is kept so
  the pooling and quota system work, and is deleted if you delete your
  account.
- **Encrypted sync copies**, if you paired the Chrome extension: one
  encrypted copy per device, replaced each time that device syncs, deleted
  when you unpair or disconnect Canvas. We hold no key to them.

## Deleting your data

**Disconnecting Canvas** (Profile → accounts → canvas) deletes your class data
from our server along with your login on the device: your enrollment records,
your usage counters, your per-request log rows (see "What we keep"), and the
anonymous account itself, and it removes the Canvas calendar feed address, the
saved PennKey password and the Ed Discussion session from this phone, and it
unpairs every laptop: their anonymous accounts and encrypted sync copies are
deleted too. The confirmation says so before you tap it. If our server can't be reached at that moment, your login still comes off
the phone right away, and the app keeps retrying the server-side deletion
on later launches until it succeeds (Settings shows "couldn't reach smooth
· will retry" meanwhile). If the server refuses the deletion outright, the
app stops retrying and says so. It does not delete the shared course
material other students are still using, because that material was never
yours alone — it's the same syllabus and assignment pages every enrolled
student can already see on Canvas. Disconnecting Gradescope removes your
Gradescope login and its synced work from this phone.

**Deleting the app does not remove everything.** iOS removes the app's own
storage with it: your list of work and what you've checked off, your grade
readings and settings, the announcements list and the widget snapshot. iOS
does not remove Keychain items when an app is deleted. If you delete Smooth
and install it again on the same phone, these can still be there: your Canvas
and Gradescope session cookies, your Canvas calendar feed address, a PennKey
password you saved, your Ed Discussion session, the key that signs the phone
in to its anonymous account, and a laptop pairing key. Smooth does not clear
them when it is installed fresh, so a reinstall is not a clean sign-out. They
are kept on this phone only (never in iCloud or on another device), and a
saved PennKey password only ever goes to Penn's own login page, as described
above. To remove them, disconnect Canvas and Gradescope in Settings before you
delete the app. Deleting the app also does not delete anything on our server
(only disconnecting Canvas does that) or the copy in your iCloud if you turned
sync on (you remove that in iOS Settings, as described under "iCloud sync").

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
- We don't sell your data. There's nothing to sell: we keep no questions,
  answers, grades or lists of your work that we can read.

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

## Finding your school

School search runs on your device against a bundled list of 220 university
Canvas sites. Search terms are not sent to Instructure or saved as search
history. You can enter your Canvas address if your school is missing.
Selecting a result opens that school's sign-in page.
