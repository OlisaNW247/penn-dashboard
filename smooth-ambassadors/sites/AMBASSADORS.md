# Ambassador system

This Worker serves the poster tracker and, since this change, the campus
ambassador system that the Smooth iOS app's "ambassador mode" signs in to.
Both live in `worker/index.js`, because the Sites build ships that one file.

## What changed in `worker/index.js`

Three things, and nothing else:

1. `fetch` takes `ctx` and first asks `smoothAmbassadors.handle(...)`. It
   answers only `/a/...`, `/f/...`, `/r/...` and exactly `/api/leaderboard`
   (so `/api/leaderboard/` stays the host's 404). For every other
   path it returns `null` before touching the database, so `/`,
   `/api/stats`, `/scan/...`, `/posters/...`, the 404s and the 405s run the
   original code.
2. After a scan's counter is saved, the scan is also appended to
   `scan_events` through `ctx.waitUntil`, so "last 14 days" numbers exist.
   It runs after the redirect is sent and its failure is swallowed.
3. A generated section at the end of the file, between the
   `// >>> smooth-ambassadors` and `// <<< smooth-ambassadors` markers.
   It reads the tracker's own `posters`, `schools`, `counterKey`,
   `initialize` and `appStore` through `SMOOTH_HOST`, so there is one list
   of schools and designs.

The embedded poster images (`imageData`) are byte-identical.

Do not edit the generated section by hand. Its source is the
`smooth-ambassadors` project (`worker/`, `sites/`, `scripts/build-sites.mjs`
in the `penn-dashboard` repository). `node scripts/build-sites.mjs
<this repository>` rewrites the section and is safe to run twice. Adding a
school or poster to the Maps at the top of the file needs no rebuild. A new
UPenn-only poster also needs adding to `SMOOTH_HOST.upennOnly`.

## Sign-in: there are no accounts

An ambassador is a row in D1 with two ids, both generated with
`crypto.getRandomValues` and independent of each other:

- the **code** (the school, a hyphen, then 14 random characters from a
  31-letter alphabet, about 69 bits: `uva-7k3m9x2p4q8w`) is
  the whole credential. It travels in the path of the private page link the
  founders text to each ambassador: `https://<this site>/a/{code}`. It is
  shown only to the ambassador and the founders, never in anything posted
  or printed.
- the **ref** (10 characters, same alphabet) is public. It is in the share
  links an ambassador pastes into chats and in their sticker QR codes:
  `/r/{ref}/s/{channel}` and `/r/{ref}/p/{design}`. It opens nothing
  private, and seeing it says nothing about the code.

The app stores the code in the iOS Keychain. No password, no email, no
session, no cookie, and no CORS need (the app is native, not a browser).
An unknown code answers a plain 404 on every route. So does the code of an
ambassador the founders have marked `left`: that is how access is ended.
The public `/r/...` links keep redirecting after that (a printed sticker
must still count for the school), but credit no ambassador.

Bodies of POSTs are limited to 16 KB (413 above that). Invalid JSON, an
empty body, JSON that is not an object, or an unknown content type is a 400.
Fields are read as short strings and anything else is treated as missing.

## Routes

The app (JSON):

| Request | Answer |
|---|---|
| `GET /a/{code}/plan.json?anon={fizz\|sidechat\|yikyak}&tz={minutes west of UTC}` | 200, the plan: `name`, `school`, `schoolName`, `title`, `status`, `pausedUntil`, `page`, `appStore`, `numbers`, `today`, `messages`, `checklist`, `tips`, `channels`, `generatedAt`, and since 2026-11-11 three additive keys: `posters` (`[{key, name, image, scans}]` for their school, `image` an absolute URL, `scans` that design's total there), `dashboard` (absolute `/?school={school}`) and `ideas` (`{sent, limit: 30, dailyLimit: 5}`), and since 2026-11-18 three more additive keys: `playbook` (`{lead, steps, examples}` from `worker/templates/playbook.json`), `suggested` (`[{id, text, reply, ts}]`, only that ambassador's, newest first, always present) and `captures` (`{feed: {framesPerRecording: 16, frameBytes: 200000, sentToday, dailyLimit: 32, stored, limit: 96}, results: {imageBytes: 300000, sentToday, dailyLimit: 8, stored, limit: 60}, styles: [{key, label}]}`). 404 for an unknown code. Since 2026-11-19 `today` and each `messages` entry may carry an optional string `reply` (the follow-up to post under the post), `messages` is two entries (`question`, `list`), no post text holds a link, and `today.kind` is never `rest`. |
| `POST /a/{code}/post` `{"channel": "...", "place": "daily"}` | 200 `{"ok": true, "message": "..."}`. 400 for an unknown channel. |
| `POST /a/{code}/check` `{"step": "...", "done": "1"\|"0"}` | 200 `{"ok": true}` |
| `POST /a/{code}/feedback` `{"body": "..."}` | 200 `{"ok": true}` |
| `POST /a/{code}/pause` `{"weeks": "4"\|"0"}` | 200 `{"ok": true}` |
| `POST /a/{code}/idea` `{"note": "...", "image": "<base64>", "type": "..."}` | 200 `{"ok": true, "message": "sent. thank you."}`. At least one of note and image, else 400. Note is trimmed and cut at 500 characters. Image is base64 only (a `data:...;base64,` prefix and whitespace are stripped), at most 600,000 bytes decoded (413), and its type is decided from its first bytes (JPEG, PNG or WebP, else 400): the `type` field is ignored. Limits per ambassador: 5 a UTC day and 30 stored (429). Errors are `{"ok": false, "message"}` for JSON requests, plain text otherwise. This route alone accepts a body up to 900,000 characters; every other route keeps 16 KB. |
| `POST /a/{code}/capture` `{"kind": "feed"\|"result", "image": "<base64>", ...}` | 200 `{"ok": true, "message": "sent."}` (303 back to the page for a form post). Image rules as for `idea` (base64, prefix and whitespace stripped, type sniffed from the bytes, JPEG/PNG/WebP else 400) but the decoded cap is 200,000 bytes for `feed` and 300,000 for `result` (413). `feed` also needs `batch` (`[a-z0-9]{8,32}`, one recording) and `seq` (0 to 15, the still's place): a (batch, seq) already held answers 200 and stores nothing, so a retry is safe. `result` takes `platform` (fizz, sidechat, yikyak, else other), `style` (question, list, pitch, else other), optional `upvotes` and `views` (digits, at most 10,000,000, else stored NULL) and a `note` cut at 300. Limits per ambassador, enforced inside the INSERT: feed 32 a UTC day, 96 stored, 16 per batch; result 8 a day, 60 stored (429). `upvotes` and `views` may carry thousands separators ("1,200", "1 200"); "1.2k", "12.5", "-5" and "1e3" store NULL. A global ceiling also applies, see Schema. Body cap 900,000 characters, like `idea`. |

A POST answers JSON when `Accept` or `Content-Type` is `application/json`.
The same routes take form posts from the web page and answer a 303 back to it.

The ambassador's own web page and links:

| Request | Answer |
|---|---|
| `GET /a/{code}` | their private page |
| `GET /a/{code}/stickers`, `GET /a/{code}/me.json` | sticker sheet, their numbers |
| `POST /a/{code}/drop` | log a poster drop |
| `GET /a/_fonts/{name}.woff2` | the page fonts (`familjen-grotesk`, `inter`, `space-mono`, `space-mono-bold`), public, `immutable` for a year, about 54 KB in all, served by the Worker so the pages call no other host. Anything else under `/a/_fonts/` is the plain 404. Handled before the code lookup. |

The public links (the ref, never the code; GET only, 405 otherwise):

| Request | Answer |
|---|---|
| `GET /r/{ref}/s/{channel}` | tracked share link: counts a link open for the ambassador, redirects to the App Store. Does not touch `scans`. An unknown channel counts as `other`. |
| `GET /r/{ref}/p/{design}` | their poster code: `scans.total` for their school and design goes up by one, exactly as `/scan/{school}/{design}` would, and it also counts for the ambassador. For a `left` ambassador it counts for the school only. |

The founders:

| Request | Answer |
|---|---|
| `GET /f/{FOUNDER_TOKEN}` | roster, numbers, feedback, the weekly digest generator. This is where an ambassador is added and where their code comes from. |
| `POST /f/{FOUNDER_TOKEN}/add\|update\|reminder\|replied\|feedback-seen\|idea-seen\|idea-delete` | roster and idea actions |
| `POST /f/{FOUNDER_TOKEN}/suggest` `id` (an ambassador), `text` (1 to 600), `reply` (optional, cut at 300) | stores a post for that ambassador to try, at most 20 each (429, enforced inside the INSERT). A `left` ambassador is refused like an unknown one (404 `no such ambassador.`). `suggest-delete` takes the suggestion's `id`. |
| `POST /f/{FOUNDER_TOKEN}/capture-seen\|capture-delete` `id`, or `amb` plus `batch` | acts on one capture, or on one ambassador's whole recording (the batch id alone never matches another ambassador's). Ids are digits only, as for every founder action, and are checked against the value exactly as sent, so `"1 "` or `"1\n"` is refused (400) and never read as 1. |
| `GET /f/{FOUNDER_TOKEN}/capture/{id}` | a capture's image bytes, with exactly the idea route's headers. Ambassadors cannot reach it. |
| `GET /f/{FOUNDER_TOKEN}/idea/{id}` | a poster idea's image bytes with the sniffed type, `nosniff`, `private, no-store`, `Content-Security-Policy: default-src 'none'; sandbox`, `inline`. 404 for an id with no image. Ambassadors cannot reach it. The id uses the same strict digits rule: `/capture/01`, `/capture/+1` and `/capture/1%20` are 404. |
| `GET /f/{FOUNDER_TOKEN}/export.json` | everything, for a backup (poster ideas without their image data: id, ambassador, ts, note, mime, hasImage; `captures` as metadata only, with no image data; and `suggestions`) |

Public: `GET /api/leaderboard?days=14` gives counts per school. No names,
contacts or codes.

## Runtime variables

| Name | Required | What |
|---|---|---|
| `FOUNDER_TOKEN` | yes | Secret, 16 characters or more (use 32 random ones). Until it is set, every `/f/...` route is a 404, nobody can be added to the roster, and so nobody can sign in. Never put it in git or in a chat with anyone but the tool that sets it. |
| `PUBLIC_ORIGIN` | no | The site's public origin, used in the links shown on pages. Defaults to the origin of the request, which is right for this site. |
| `APPLE_PROVIDER_TOKEN` | no | Apple campaign `pt` value. When set, ambassador links carry `pt`, `ct`, `mt`. Plain `/scan/...` redirects never change. |

The code reads them as `env.FOUNDER_TOKEN` and so on, next to `env.DB`.

## Schema

`migrations/0001_ambassadors.sql`, `migrations/0002_poster_ideas.sql` (the
`poster_ideas` table, image kept as base64 TEXT, with an index) and `migrations/0003_captures.sql` (`captures`, feed stills and post-result screenshots in one table with the image as base64 TEXT, and `suggestions`), reference copies of what the Worker
creates by itself. Every statement is `CREATE TABLE IF NOT EXISTS` or
`CREATE INDEX IF NOT EXISTS`: `ambassadors` (with `token` and `ref`), `amb_hits`, `scan_events`,
`activity`, `checklist`, `feedback`, `reminders`, `poster_ideas`, `captures` and `suggestions`. The Worker runs all three files once
per isolate on the first ambassador request or the first scan, the same way
the tracker has always created `scans`. Nothing alters, drops or rewrites
`scans` or any of its rows. Applying the file as a migration first is
equally fine and changes nothing.

**Capture ceiling.** `captures` holds base64 images, and each ambassador's limits
are independent: 96 feed frames of 200,000 bytes plus 60 results of 300,000 bytes
is about 26 MB decoded, about 34 MB of base64 text, for one code. A roster of
thirty leaked or hostile codes could therefore store about a gigabyte in a
database that also holds the real scan counts, so a global number bounds the
table whatever the roster: `CAPTURES_GLOBAL_LIMIT` (1500 rows, in
`worker/data.js`), enforced inside the same INSERT statements as the
per-ambassador limits, never by a count read first. When it is the global ceiling
that refuses a write the answer is 429 `we're full right now. tell olisa or
marco.` Founders free room by deleting recordings and results from the founder
page.

Names and contacts of real people live only in D1. Export `scans` before
the first deploy anyway.

## Verify after a deploy

Do not open a `/scan/...` link casually: each one is a real count.

1. `GET /` and `GET /api/stats` look as before, and every total equals the
   backup.
2. `GET /posters/upenn/ib.jpg` shows the poster. `POST /` is still 405.
   `GET /scan/uva/jester` is still 404.
3. One deliberate scan: `GET /scan/uva/ib` redirects to the App Store and
   that row's total in `/api/stats` is up by exactly one.
4. `GET /a/aaaaaaaaaaaaaa/plan.json` is 404 (it was 404 before too; now it
   is the ambassador code path answering).
5. `GET /f/{FOUNDER_TOKEN}` opens the founder page. Add a test ambassador
   and copy their code.
6. `GET /a/{code}/plan.json?anon=fizz&tz=300` is 200 JSON with `name` and
   `school`.
7. `curl -X POST -H 'content-type: application/json' -H 'accept: application/json' -d '{"channel":"fizz","place":"daily"}' https://<site>/a/{code}/post`
   answers `{"ok":true,...}`, and the founder page shows one post.
8. In the Smooth app: Profile, ambassador mode, paste the code. The page
   shows today's post.
