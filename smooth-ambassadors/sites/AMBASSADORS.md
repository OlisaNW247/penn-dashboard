# Ambassador system

This Worker serves the poster tracker and, since this change, the campus
ambassador system that the Smooth iOS app's "ambassador mode" signs in to.
Both live in `worker/index.js`, because the Sites build ships that one file.

## What changed in `worker/index.js`

Three things, and nothing else:

1. `fetch` takes `ctx` and first asks `smoothAmbassadors.handle(...)`. It
   answers only `/a/...`, `/f/...` and `/api/leaderboard`. For every other
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

An ambassador is a row in D1 with an unguessable code (14 characters from a
31-letter alphabet, about 69 bits, generated with `crypto.getRandomValues`). The code is
the whole credential. It travels in the path, like the private page link
the founders text to each ambassador:

    https://<this site>/a/{code}

The app stores the code in the iOS Keychain. No password, no email, no
session, no cookie, and no CORS need (the app is native, not a browser).
An unknown code answers a plain 404 on every route.

## Routes

The app (JSON):

| Request | Answer |
|---|---|
| `GET /a/{code}/plan.json?anon={fizz\|sidechat\|yikyak}&tz={minutes west of UTC}` | 200, the plan: `name`, `school`, `schoolName`, `title`, `status`, `pausedUntil`, `page`, `appStore`, `numbers`, `today`, `messages`, `checklist`, `tips`, `channels`, `generatedAt`. 404 for an unknown code. |
| `POST /a/{code}/post` `{"channel": "...", "place": "daily"}` | 200 `{"ok": true, "message": "..."}`. 400 for an unknown channel. |
| `POST /a/{code}/check` `{"step": "...", "done": "1"\|"0"}` | 200 `{"ok": true}` |
| `POST /a/{code}/feedback` `{"body": "..."}` | 200 `{"ok": true}` |
| `POST /a/{code}/pause` `{"weeks": "4"\|"0"}` | 200 `{"ok": true}` |

A POST answers JSON when `Accept` or `Content-Type` is `application/json`.
The same routes take form posts from the web page and answer a 303 back to it.

The ambassador's own web page and links:

| Request | Answer |
|---|---|
| `GET /a/{code}` | their private page |
| `GET /a/{code}/s/{channel}` | tracked share link: counts a link open for the ambassador, redirects to the App Store. Does not touch `scans`. |
| `GET /a/{code}/p/{design}` | their poster code: `scans.total` for their school and design goes up by one, exactly as `/scan/{school}/{design}` would, and it also counts for the ambassador. |
| `GET /a/{code}/stickers`, `GET /a/{code}/me.json` | sticker sheet, their numbers |
| `POST /a/{code}/drop` | log a poster drop |

The founders:

| Request | Answer |
|---|---|
| `GET /f/{FOUNDER_TOKEN}` | roster, numbers, feedback, the weekly digest generator. This is where an ambassador is added and where their code comes from. |
| `POST /f/{FOUNDER_TOKEN}/add\|update\|reminder\|replied\|feedback-seen` | roster actions |
| `GET /f/{FOUNDER_TOKEN}/export.json` | everything, for a backup |

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

`migrations/0001_ambassadors.sql`, a reference copy of what the Worker
creates by itself. Every statement is `CREATE TABLE IF NOT EXISTS` or
`CREATE INDEX IF NOT EXISTS`: `ambassadors`, `amb_hits`, `scan_events`,
`activity`, `checklist`, `feedback`, `reminders`. The Worker runs them once
per isolate on the first ambassador request or the first scan, the same way
the tracker has always created `scans`. Nothing alters, drops or rewrites
`scans` or any of its rows. Applying the file as a migration first is
equally fine and changes nothing.

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
