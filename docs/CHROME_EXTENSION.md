# The Smooth Chrome extension

_Design record, written 2026-10-22 on `v8`. Nothing here has been loaded in
a real Chrome yet; each section says what is built and what is only
planned. Same register as `docs/ED_DISCUSSION.md`: why first, then how._

## What it is for (the owner's scope, 2026-10-22)

Olisa's answers to the scope questions, first exchange of the session:

- **A helper for the phone.** "It is a helper for the phone. Collects all
  the info that the phone can't or steps up when phone is off/unavailable."
  The extension rides the browser's own Canvas, Gradescope and Ed sessions,
  which removes the whole PennKey / Duo / stay-signed-in problem the phone
  fights, and uploads course material to the existing `sync` pool.
- **What it collects beyond the phone:** every announcement (the phone has
  never collected one into course material, Known gaps), every Canvas page
  (the phone stops at 40 bodies), the text of Canvas Files (slides, PDFs),
  and Ed staff posts under the phone's own filter (announcements, pinned,
  staff; never a student post, never an author).
- **Phone sync, end-to-end encrypted, paired by QR from the start.**
  Completions, due-date edits, manual tasks, and the work list view are
  shared between the laptop and the phone. The server stores only
  ciphertext it cannot read.
- **One identity.** The extension is paired to the phone before it talks to
  the backend for anything but pairing, so one student is one user.
- **Penn only** (the backend is Penn-only; one Canvas host permission).
- **Unpacked**, for the owner and friends. No Web Store listing in v1.

Rejected for v1: a laptop-only popup dashboard (the Mac app already is
one), ask in a side panel (later, once the collector has proven itself),
page helpers on Canvas assignment pages.

## Why the browser is worth it

The phone keeps a WebView session alive with saved cookies, a 24-hour
renewal dance and a saved PennKey password, and it still loses the session.
In Chrome the student is already signed in to `canvas.upenn.edu`,
`www.gradescope.com` and `edstem.org`. An extension that holds
`host_permissions` for those hosts can `fetch(…, { credentials: "include" })`
from its service worker and the browser attaches the student's own cookies.
**No cookie is ever read, copied or stored by the extension**; it has no
`cookies` permission and never touches `document.cookie`. That keeps
principle 1 of `backend/PROTOCOL.md` intact: Canvas credentials never reach
the server, and here they never reach the extension's own storage either.

Ed keeps no session cookie; its token lives in the Ed tab's `localStorage`
(`docs/ED_DISCUSSION.md`). The extension reads it, when Ed is open or
openable, from a content script on `edstem.org` and holds it only in
`chrome.storage.session` (memory, cleared when the browser closes), never
in `storage.local`.

## Layout

```
chrome-extension/
  manifest.json        MV3, service worker, popup, minimal host permissions
  src/core/            pure ES modules, no chrome.* and no DOM: the ported rules
  src/adapters/        thin chrome.* / fetch / DOM wrappers
  src/popup/           the popup (Smooth paper ground, after-sunset dark)
  test/                node --test, fixtures copied from the Swift tests
  README.md            load-unpacked steps
```

No build step, no npm dependencies, no third-party code except where a
section below says so and why. `node --test chrome-extension/test` is the
gate the cloud container can run; Chrome itself only runs on the owner's Mac.

## The pure core: what must match the phone exactly

Each of these is a port whose Swift tests are its spec. A JavaScript port
that disagrees with Swift is a bug in the port.

- **`CourseCode.parse`** (`Models/CourseCode.swift`). The course code is
  the key the phone uses for everything; an extension that keys a
  completion on a different code than the phone is an identity bug that
  silently fails to sync.
- **Canvas assignment id** from an ICS URL fragment (`#assignment_<id>`,
  Traps) and from a REST `html_url`.
- **Gradescope HTML parsing** (`GradescopeHTMLParser` in
  `Gradescope/GradescopeClient.swift`).
- **Dedup** (`AssignmentDeduplicator`): the same work on Canvas and
  Gradescope is one item, with the same tolerances.
- **Document ids and hashes** (`CourseDocument`): `id` is
  `"{kind}:{courseID}:{sourceID}"`, `contentHash` is FNV-1a over
  `title + "\u{1F}" + text` (`ContentHash.fnv1a`). A hash that differs from
  the phone's for the same document makes the two clients re-upload each
  other's copy forever.
- **Ed filter** (`EdThreadFilter`): announcements, pinned, staff only.

## Collecting course material

Built on the existing `sync` exchange (`backend/PROTOCOL.md` → `sync`),
with two server changes that must land **before** the extension uploads
anything:

1. **Who collected a document.** The upload step marks `gone_at` on every
   live document of a fully-synced course whose id the client did not list.
   The phone does not hold announcements, pages past 40, or files, so its
   hourly sync would mark every one of the extension's documents gone. The
   fix: `course_documents.collector` (`'phone'` default, `'extension'`), set
   from a `client` field on the upload, and a phone's complete-set report
   only retires `collector = 'phone'` rows. Rejected: exempting kinds (the
   phone does upload pages 1 to 40, and an extension copy of page 41 is the
   same kind), and making the extension's uploads non-complete (then a page
   deleted on Canvas would never leave the pool).
2. **A `file` kind behind a capability.** `CourseDocument.Kind` is a strict
   `Codable` enum on the phone, so a `file` document in `download` would
   fail the whole manifest decode on every 3.1.0 phone in the field. The
   server sends `file` documents only to a client whose manifest request
   carries `acceptsKinds` including `"file"`. A new phone build adds the
   case and sends the field; old phones never see a file. Rejected: filing
   PDFs as `page` (it lies about the source, makes every slide deck profile
   input, and would still need fix 1).

Announcements and pages use existing kinds, so every phone already in the
field gets them through `download` the moment the extension uploads them.

**Files text.** Canvas Files of type PDF (and plain text) in courses the
student is enrolled in, extracted in the browser. PDF text needs a parser;
the only practical one is Mozilla's pdf.js (Apache-2.0), vendored as a
fixed file with no network access of its own. That is a library, not an
SDK: it sends nothing anywhere. It is the one third-party file in the
extension and is recorded here so nobody adds a second one casually.
The server already caps a document at 200,000 characters
(`_shared/manifest.ts`); the extension caps a file at 60,000, as the
server's own PDF crawl does (`_shared/crawl.ts`).

**Stepping up when the phone is off.** The extension syncs on its own
alarm (`chrome.alarms`, hourly, the phone's staleness) whenever Chrome is
open, so the pool stays fresh for the class when the phone has not opened
in days.

## Pairing

The phone has no URL scheme today; pairing adds one (`smooth://`).

1. The extension signs up anonymously (`POST /auth/v1/signup`, `{}`) as its
   own GoTrue user, generates a random 256-bit key `K`, and calls a new
   `pair` function `{ action: "start" }`. The server stores a pairing row
   (random code, the extension's user id, ten-minute expiry) and returns the
   code.
2. The popup shows a QR code of `smooth://pair?c=<code>#k=<K, base64url>`.
   The key is in the fragment and never sent to the server by anyone.
3. The student points the iPhone camera at it. iOS offers "Open in Smooth";
   the app asks "pair this laptop?" and, on yes, posts `pair`
   `{ action: "claim", code }` with **its own** token. The server links the
   extension's user to the phone's (`device_links`), single use, and deletes
   the pairing row. The phone keeps `K` in its Keychain (device-bound, like
   the cookies).
4. The extension polls `pair { action: "status" }` until linked, then keeps
   `K` in `chrome.storage.local`.

The phone approves, not the laptop, because the phone is the student's
established identity: a QR code photographed off someone's screen gives
the photographer nothing unless their own phone claims it, and then it
links their laptop to their own account. After linking, every function
resolves the extension's user to the phone's user, so enrollments and the
ask quota are one student's. Disconnecting Canvas on the phone
(`delete-account`) deletes the links, the extension's auth user and every
sync blob. Either side can unpair.

Rejected: handing the phone's refresh token to the extension (refresh
tokens rotate, so two holders log each other out), and the laptop
scanning a QR on the phone (a webcam in a popup is worse in every way).
A custom scheme can in principle be claimed by another app on the phone;
the code is single use, ten minutes, and useless without the phone's
approval, which is why that is acceptable here.

## Phone sync, end to end encrypted

What syncs: completions, due-date edits, manual tasks (one-off and
recurring), and the merged work list for the extension to show. Each
device writes one encrypted snapshot of its own state; each reads the
others'. AES-256-GCM with `K`: CryptoKit's `AES.GCM` on the phone,
WebCrypto's `AES-GCM` in the extension (12-byte nonce, 16-byte tag; the
envelope is `nonce || ciphertext || tag`, which is CryptoKit's
`combined`). The server (`device-sync`, table `device_sync_blobs`) sees
the owner id, the device id, a size and a time, nothing else.

Merging follows the ledger invariant: nothing the student did is ever
lost. Every record carries the time it was last changed; a completion and
an un-completion are both changes; the later change wins; a record is
never deleted by a merge, only flagged. The phone applies remote changes
through the same paths a swipe and an edited date use, so reminders, the
widget and the Sweeper follow.

`docs/PRIVACY.md` changes in the same commit that first sends a blob:
"Your own data leaves your phone only encrypted, to your own paired
devices; we cannot read it."

## Build order

Each step is its own commit on `v8` with its docs. Container-verifiable
steps come first; everything after step 3 needs the owner's Mac.

1. **Pure core with tests** (course code, ids, hashes, Gradescope parsing,
   dedup). `node --test`. Built here.
2. **Readers and the popup**: the work list from Canvas and Gradescope in
   the browser, local only. Owner loads it unpacked and reports.
3. **Course-material builders** (announcements, all pages, files, Ed),
   pure and tested, not yet uploading.
4. **Backend**: migration (`collector`, `file` kind, `pairings`,
   `device_links`, `device_sync_blobs`), `sync` changes, `pair`,
   `device-sync`, `delete-account`. Deno tests, blind here; the owner runs
   them, then gives the go for the migration and each deploy.
5. **Phone**: the `smooth://` scheme and pairing sheet, the `file` kind and
   `acceptsKinds`, the encrypted snapshot and merge. Swift, blind here.
6. **Extension pairing and upload**, then **phone sync** in the
   extension. `docs/PRIVACY.md` changes in step 6's first upload commit.

## Status

- 2026-10-22: scope settled with the owner, this record written.
- 2026-10-22: step 1, first half: `src/core/` ports of `Term`,
  `CourseCode`, the `Assignment` ids (`canvasAssignmentID` included), the
  content hash and the ICS parser, 74 `node --test` tests whose cases name
  their Swift origin. The FNV-1a hash is pinned to the published 64-bit
  vectors (no Swift test pins a value) and is unpadded hex, as Swift's
  `String(hash, radix: 16)` is. `\b` and `\d` are rewritten as Unicode
  lookarounds so JS matches ICU on every case the Swift tests reach.
  Gradescope parsing and dedup are next.
- 2026-10-22: the shell. `manifest.json` (MV3; `storage` and `alarms`
  only; Canvas, Gradescope and the Supabase project as hosts; no
  `cookies`, no content scripts yet), a service worker that only arms an
  hourly `sync` alarm, and the popup rendered from a sample state by a
  pure `render(state, root)`. Colours are `RedesignTokens.swift`'s (the
  prototype's CSS is an older palette); a class's accent uses the phone's
  own hash, so it matches. Bundled faces are Inter, Familjen Grotesk and
  Space Mono with their OFL texts; Roobert and Satoshi are not
  redistributed, so the wordmark is Familjen Grotesk. Loaded unpacked in
  headless Chromium in the container (manifest accepted, worker started,
  popup rendered); not yet in the owner's Chrome.
- 2026-10-22: `src/core/dedup.js`, a line-for-line port of
  `AssignmentDeduplicator` (64 tests; the two AppState-bound Swift cases
  are not portable). One deliberate difference: Swift traps on duplicate
  Gradescope ids in `merge` (`Dictionary(uniqueKeysWithValues:)`); the
  port lets the later one win, because a crashed service worker loses the
  whole run.
