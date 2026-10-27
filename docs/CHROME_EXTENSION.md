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
- **Announcement documents** (`CourseDocumentBuilder.announcement`):
  since 2026-10-23 the text is the trimmed message alone, with no
  `Posted:` line, because that line was device-zone and locale rendered
  (a hash the two clients could disagree on) and the post time already
  travels in `updatedAt`. An empty title becomes "Announcement" and an
  empty message produces no document, the two server-rejection guards.
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
2. **A `file` kind behind a capability.** A 3.1.0 phone tolerates an
   unknown kind (`CourseDocumentWire.kind` is a `String`, and
   `document()` returns nil for a kind it cannot name, so the download is
   dropped quietly). But it never stores what it drops, so it would
   download every file document again on every hourly sync. (This record
   first said an unknown kind would fail the whole manifest decode; the
   Swift side's own reading of `BackendWire.swift` showed it does not.)
   The server sends `file` documents only to a client whose manifest request
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

### The snapshot (format 1)

Plaintext is UTF-8 JSON; both clients write it and both parse it, so this
section is the contract and a test vector in each suite pins it.

```
{ "format": 1,
  "deviceId": "<the writer's own id>",
  "writtenAt": "<ISO 8601, UTC, milliseconds>",
  "completions": { "<assignment id>": { "done": true|false, "at": "<ISO>" } },
  "dueEdits":    { "<assignment id>": { "dueAt": "<ISO>"|null, "at": "<ISO>" } },
  "manual":      { "<manual id>": { "title", "course", "dueAt"|null,
                                    "kind", "repeatsWeekly": bool,
                                    "removed": bool, "at": "<ISO>" } },
  "workList":    [ { "id", "course", "title", "dueAt"|null, "kind",
                     "source", "url"|null, "done": bool } ] }
```

- Keys are `Assignment.id` (`"source:sourceID"`), which is why the course
  code, the Canvas id and dedup are exact ports: a key the phone does not
  know is a completion that never lands.
- `at` is when that record last changed on its writer. Merge is per key:
  the later `at` wins, ties go to the larger `deviceId`; un-ticking is a
  change like ticking (`done: false`), and a removed manual task is a
  tombstone (`removed: true`) that is never purged, so a stale device
  cannot resurrect it. A `dueEdits` entry with `dueAt: null` is "edit
  cleared".
- `workList` is the writer's own merged dashboard (phone: what todo · all
  · prev show, announcement tasks and found exams included), read-only to
  every other device. The extension shows it beside what it reads itself.
- The phone keeps the change times **outside the SwiftData ledger**, in a
  file beside the ledger or in `UserDefaults.lhf` (`syncChangeTimesV1`),
  because `completedAt` is legitimately nil for old completions and a
  schema change makes an older build fall back to an empty in-memory
  ledger (Traps). Applying a remote change goes through the same paths a
  swipe, an edited date and the add sheet use, so reminders, the widget
  and the Sweeper follow, and never deletes a ledger row.
- Settled details (2026-10-22, from the two implementations): keys inside
  `completions`, `dueEdits` and `manual` are written sorted ascending by
  code point (ids are ASCII, so byte order is the same), with no
  whitespace, and every date is UTC with exactly three fractional digits.
  `kind` is an `Assignment.Kind` raw value (`assignment`, `quiz`,
  `discussion`, `event`, `other`; manual tasks default to `assignment`).
  `at` is compared as a time, not a string. A record's tie-break id is the
  `deviceId` of the snapshot it came from. A merge returns the local
  snapshot's own `deviceId`, `writtenAt` and `workList` with merged
  records, and the remotes' work lists beside it; merge once over all
  remotes, not pairwise, since a merged snapshot no longer remembers
  which device won each tie.
- Envelope: AES-256-GCM, a fresh random 12-byte nonce per write, no
  associated data, sealed bytes `nonce || ciphertext || tag` (CryptoKit's
  `SealedBox.combined`), sent as standard base64 in `device-sync`'s
  `ciphertext`. The phone's `deviceId` is a random id made once per
  install; a linked device's row is keyed by its own auth user id (the
  server's choice, echoed by `put`).

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
- 2026-10-22: step 4, the backend, written and tested in the container
  (406 Deno tests, `--no-check`; the touched functions type-check): the
  migration, identity resolution in `requireUser`, `client` /
  `acceptsKinds` / `collector` in `sync`, `pair`, `device-sync`, and the
  `delete-account` device rule (a linked device only ever unpairs itself).
  A linked device's blob row is keyed by its own auth user id whatever
  `deviceId` it sends; `put` echoes the id used. **Not applied, not
  deployed**: the migration and the deploys of `sync`, `pair`,
  `device-sync` and `delete-account` each wait for the owner's go. The
  other functions pick up the new `requireUser` whenever they are next
  deployed, harmlessly before the migration (Traps).
- 2026-10-22: `src/core/gradescope.js`, `GradescopeHTMLParser` and the
  fetch-free parts of `GradescopeClient` (51 tests; the two URLSession
  cases are replaced by pure equivalents). `DateFormatter` is emulated by
  a small pattern engine; what it does where ICU's behaviour is only
  inferred (a `yyyy` field reading `26` as year 26, the later instant for
  a repeated wall time) is listed in the module's comments and is worth a
  Swift run if a Gradescope date ever disagrees between the phone and the
  laptop. Step 1 is complete.
- 2026-10-22: `src/core/syncSnapshot.js`: encode/decode, AES-GCM seal and
  open with WebCrypto, merge, and the record helpers (18 tests). It seals
  the shared vector to the same bytes node's own crypto produced and
  re-encodes its plaintext byte for byte. The details the spec had left
  open are now under "Settled details" above.
- 2026-10-22: the phone's first pieces, **written without a compiler**:
  `CourseDocument.Kind.file` (searched like a page; never syllabus,
  profile or split-course input), `client: "phone"` and `acceptsKinds` on
  the sync requests, a `download` decode that skips a malformed entry
  instead of failing the response, and `Sync/SyncSnapshot*.swift` (codec,
  CryptoKit envelope, merge) pinned to the same vector. Not yet: the
  `smooth://` scheme, the pairing sheet, the Keychain key, `device-sync`
  calls, change-time tracking, and applying remote changes.
- 2026-10-22: step 3, the course-material builders (141 tests): HTML to
  text and links, the Canvas endpoint URLs, assignment / page / syllabus
  / announcement / module documents, Ed (decode, staff filter, XML to
  text, header) and the sync plan, each hash cross-checked against
  strings a Swift test pins. Deliberate differences from the phone: no
  page cap (the phone's 40 is exported as `PHONE_MAX_PAGE_BODIES`); a
  course counts as fully synced only when **every** endpoint succeeded
  (the phone tolerates one failure in four), because the extension's
  complete-set report retires every collector's rows; announcements are
  asked for 200 days back through tomorrow, so the phone's `until:` bug
  cannot recur; Ed author names and emails are dropped at decode time;
  upload batches split on the 6 MB budget as well as 200 documents. No
  `home` document is built: the phone never builds one either, and
  inventing one would give the two clients different ids.
- 2026-10-22: step 2, the readers and a live popup. Canvas work comes
  from the student's own calendar feed, found through
  `/api/v1/users/self/profile` on every run and parsed by the ported ICS
  parser, so each item has the phone's exact id; the feed URL is a bearer
  credential and lives in one local variable, never in storage or a log.
  Gradescope is read page by page, one request at a time. A source that
  fails keeps its last good list, and a signed-out Canvas shows that list
  under "sign in to canvas" rather than an empty popup. The views are the
  phone's (`DashboardViewModel`, `dueText`): todo is overdue plus two
  days, all is upcoming without overdue, prev is finished work. A tick
  records into the local snapshot (`snapshotV1`); un-ticking records
  `done: false`. Left for the phone's own work list to supply once paired:
  Canvas events, announcement tasks, found exams, manual and recurring
  tasks, due-date edits, the sign-up backlog. Loaded in headless Chromium
  (worker ran `refresh`, popup rendered seeded states, a tick wrote the
  snapshot); **never run against a signed-in Canvas or Gradescope**, which
  the container cannot reach.
- 2026-10-22: the phone's pairing and sync layer, **written without a
  compiler**: `PairingLink` (strict `smooth://pair?c=…#k=…`),
  `SyncChangeLog` (change times in `UserDefaults.lhf`
  `syncChangeTimesV1`, the install's `syncDeviceIDV1`), `SyncSnapshotBuilder`
  (a change with no recorded time is dated the Unix epoch, or a
  completion's `completedAt`, so any real change elsewhere beats it;
  "now" would let a stale phone win), `SyncApplyPlan` (actions only where
  a remote won and the state differs; an unknown id's completion lands on
  a completion-only ledger row; no action deletes a feed row; adopted
  remote times are recorded as the remote's, never as now),
  `DeviceSyncClient` and `SyncKeyStore` (Keychain, this device only).
  `BackendClient.post` went from private to internal so the client reuses
  its auth and retry path. Not yet: the scheme, the sheet, and the wiring
  into `AppState`.
- 2026-10-22: the extension's backend client (`src/adapters/backend.js`:
  anonymous session in `backendSessionV1`, refresh-and-retry-once on 401,
  one shared sign-up for concurrent calls, typed `BackendError.kind`), the
  pairing flow (`src/core/pairing.js`: the key is persisted as
  `pairingKeyV1` only once `status` says paired, so an abandoned QR leaves
  nothing behind; unpair keeps the local snapshot, which is the student's
  own record), and a hand-written QR encoder (`src/core/qr.js`, byte mode,
  level M, versions 1 to 10), chosen over a second vendored library. 45 of
  46 test images decoded with OpenCV 4.10 to their exact input, the
  pairing link among them at every mask; the one miss (version 8, forced
  mask 3, only at scales 5 to 12) decodes at other scales and with
  OpenCV's other detector, so it reads as a detector quirk, and the
  pairing link is version 5. The QR is always drawn dark on white, also
  in after-sunset mode, because an inverted code does not scan
  everywhere. **Whether an iPhone camera reads it is unverified** until
  the owner points one at the popup.
- 2026-10-22: the collector (`src/adapters/collector.js`, with
  `src/core/edMatch.js` ported from `EdCourseMatcher`). It lists active
  courses, reads syllabus, every page, modules, assignments and
  announcements one request at a time with 250 ms between them, stops the
  whole run on a 429, and treats a truncated page listing as a failed
  endpoint. Syncing sends `client: "extension"`; in a course it fully
  fetched, it replaces its holdings of the kinds it re-read from Canvas
  (assignment, announcement, module, page, and Ed when Ed was read), so a
  page deleted on Canvas can leave the pool, and keeps every other kind
  (website crawls, files, syllabus, home) in its complete-set list.
  Ed's token comes from a content script on `edstem.org` that reads only
  `localStorage.authToken` (`EdSessionLauncher.swift:207`) and is kept in
  `chrome.storage.session`; the manifest gains the Ed hosts and that one
  content script. Not yet: the worker calling it, the phone's
  fire-and-forget `extract-profile` / `discover-websites` after an
  upload, and Canvas Files.
- 2026-10-22: the extension's pairing screen and encrypted sync
  (`src/deviceSync.js`). Pairing runs in the worker so closing the popup
  does not kill it; the link lives in `storage.session` only while the QR
  shows. Each sync pass first asks `pair {action: "status"}`: after the
  phone unpairs, the server deletes the extension's user and the backend
  client quietly signs up a fresh, unlinked one, for which `device-sync`
  answers an empty set rather than an error, so `status` is the only
  reliable signal (the first draft cleared the key on `unauthorized`,
  which a transient 401 would also have triggered). Passes run after each
  refresh and 5 s after a tick, throttled to one per 2 minutes except the
  tick's. The popup shows the phone's work list beside the laptop's own
  reads, deduped by id, with the merged completions and due edits
  applied. The QR in a popup screenshot decoded with OpenCV to the exact
  link; no iPhone camera has read it. `docs/PRIVACY.md` gains "The Chrome
  extension" in this commit, the first whose code sends a blob.
- 2026-10-22: Canvas Files (`src/adapters/files.js`, `pdfText.js`,
  `vendor/pdfjs/`: pdfjs-dist 4.10.38, Apache-2.0, the two minified
  legacy builds only, 1.8 MB, SHA-256s in `vendor/pdfjs/VERSION`). pdf.js
  runs in-thread in the module service worker (a service worker has no
  `Worker`; the worker module is imported statically and registered as
  `globalThis.pdfjsWorker`), with no eval, no font faces, and no CMap or
  standard-font fetches, so nothing it does touches the network; the cost
  is that text in a font needing an external CMap (some CJK) may come out
  empty. Seen extracting a generated two-page PDF in headless Chromium.
  Newest first, at most 60 new or changed PDFs per course per run, 25 MB
  limit, locked and hidden files skipped, scans remembered and skipped,
  failures never fatal and never part of the complete set. Not yet
  called by the worker; the download redirect is a Known gap.
- 2026-10-22: the phone app's wiring, **never compiled** (CLAUDE.md →
  What the app does → Pair a laptop). Two review changes to the first
  draft: unpairing no longer clears the change log (a re-pair would have
  dated every phone record the epoch, so the laptop's stale copy won
  everything), and pairing a second laptop unlinks the first instead of
  leaving it linked with a key nothing reads. Left open: a sheet already
  on screen can hide the pairing sheet; the Mac's menu-bar loop does not
  sync; `resetAllLoginData` does not forget the key.
- 2026-10-22: the worker runs the collector (`src/collectRun.js`) after
  the hourly refresh and device sync, and once right after pairing; never
  on a popup open. Only when paired; at most hourly; 6 hours of back-off
  after a rate limit, until local midnight after a quota refusal;
  holdings and the files-seen map saved even when a run stops halfway;
  `extract-profile` and `discover-websites` (three courses a call) fired
  after an upload without waiting, as the phone does. The Ed token
  listener accepts only `https://edstem.org`. pdf.js is imported with the
  worker (about 0.6 s to start in headless Chromium). One fresh-profile
  launch in ten showed a worker with no listeners and was never
  reproduced; if the extension ever seems dead on first install, reload
  it once and say so. `docs/PRIVACY.md` now names course files, in this
  commit, the first that collects them.

**Everything is built.** What remains is the owner's: run `swift test`,
build to the phone, apply the migration and deploy `sync`, `pair`,
`device-sync` and `delete-account`, load the extension, pair, and watch.

- 2026-10-22, about 16:05 UTC, with Olisa's go: **migration applied and
  four functions deployed** (`sync` v11, `pair` v1, `device-sync` v1,
  `delete-account` v6). Checked through the Management API: the three
  tables exist with RLS on and grants for `service_role` only, the kind
  check takes `file`, and all 709 existing documents read
  `collector = 'phone'`. Smoke-tested live with throwaway anonymous
  users: an old phone's manifest (no `client`) answers as before, an
  unpaired extension gets 403 `not_paired`, a bogus or reused code 404,
  a claim links, both devices put and the laptop reads both blobs, the
  laptop's `delete-account` only unpairs it (the phone's token still
  works afterwards), and the phone's deletes everything. The test users
  were deleted; no link, blob or pairing row remains. `extract-profile`
  and `discover-websites` still run the old `requireUser`, so the
  extension's post-upload calls are treated as an unlinked user's until
  those two are next deployed; the phone's own calls are unaffected.
- 2026-10-23, with Olisa's go: **`extract-profile` v8 and
  `discover-websites` v4 deployed**, so the extension's post-upload
  calls now act for the paired student. Neither function's own code had
  changed since its September deploy; the bundle carries the shared
  modules already live in `sync` v12 and `ask` v11, and
  `chatCompletionJSON` is byte-identical, so `extract-profile` keeps its
  model (`LHF_MODEL`). Smoke-tested with a throwaway user (an empty list
  answers 200; a course the caller is not enrolled in answers 200 with
  nothing updated, or 403 `not_enrolled` from discovery), then deleted.
  The other session's work of the same day landed beside this:
  announcements and Ed are window kinds the complete-set rule never
  retires, aged out on read at 120 days, and the extension's
  announcement documents now match the phone's byte for byte (no
  "Posted:" line; a post with no message is not a document). Swift
  2606 / 237 green at `ad4f920`; extension 471 and Deno 419 green on the
  merged tree in the container.
- 2026-10-23: **first real use, on Olisa's laptop and iPhone.** Loaded
  unpacked in his Penn Chrome profile; the popup listed his real work
  (test 1); pairing by camera linked the laptop at 19:09:19 UTC and both
  devices put sealed snapshots within 11 seconds (test 2); a tick crossed
  in each direction with a 2 to 3 minute delay, the throttles' design
  (test 3). The collector uploaded nothing: a course hiding its Files tab
  answers 401 to a live session, and the collector read any 401 as
  signed out and discarded the run (Traps). Fixed the same evening with a
  once-per-run `/users/self` check (482 node tests); the collector's
  hourly throttle (`collectRunAtV1`) has to be cleared once for the fixed
  build to run before the hour is up.
- 2026-10-24 to 2026-10-27: **the collector works on real Canvas.** After
  the fix, Olisa's laptop uploaded 685 documents as `collector =
  'extension'`: 396 pages (CIS 4500 alone 384; the phone stops at 40),
  145 assignments, 70 modules, 18 announcements, 3 syllabi and 53 PDFs
  (322 to 5,278 characters of text each, none near empty; all from
  "Physics Exam Archive", the one site with visible Files). No extra host
  permission was needed for the download redirect. The extension retired
  nothing: the 16 rows marked gone in those days are all in courses it
  never uploaded to (one is the website-crawl gap in CLAUDE.md).
  Encrypted sync was still exchanging on 2026-10-27 (phone 01:45, laptop
  12:05 UTC).
- 2026-10-27: the owner's extension error panel showed why the other
  courses' PDFs never arrived: the download redirect lands on Instructure's
  S3 bucket, whose wildcard CORS Chrome refuses for a credentialed fetch.
  Files now go through `/api/v1/files/:id/public_url` and an
  uncredentialed fetch of the signed URL (486 node tests). Not yet run on
  his laptop.
