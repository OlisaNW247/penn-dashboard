# Ambassador sign-in for the existing Sites project

For the ChatGPT session that deploys project
`appgprj_6aebbfcc56e48191a690c176014ceddf`. Base commit:
`3770608515c285cc1e034f8be04e8d5e4c335640`.

## Update, 2026-11-12 (small)

This archive is the fourth one. The third was deployed on 2026-11-12 and is
live. Since it, one change, to page text only:

- **No more checklist.** The ambassador page no longer shows the
  "checklist" section (its first step told people who already use the app to
  download it), and the founder roster no longer shows "checklist n/5".
- **The job, at the top.** Under the greeting the ambassador page now says:
  "the job: get smooth in front of as many eyes as you can. spam the chats.
  put up posters. post every day. bring back what people say and ideas for
  smooth." The feedback section is now headed "feedback and ideas for
  smooth" (same form, same route).

What that means for the deploy:

- Only the generated section of `worker/index.js` changes. No route, schema,
  variable or API change. `plan.json` is byte-for-byte the same shape and
  still carries `checklist`; `POST /a/{code}/check` still works. The public
  dashboard at `/` is untouched.
- Check after deploying: open any ambassador page. The yellow "the job" box
  is under "hey {name}", there is no "checklist" section or tab, and
  everything else is where it was.

## Update, 2026-11-11

The third archive. The first was deployed on 2026-11-11. What the third
added:

- **Codes start with the school.** A new ambassador's code now starts with
  their school, for example `uva-7k3m9x2p4q8w` or
  `case-western-4hd82kq9zt3mxa`. One code per person, as before. The prefix
  is a readable label. The 14 random characters after it are still the whole
  secret. Codes created before this deploy have no prefix and keep working.
  The public id in share and sticker links (`/r/{ref}/...`) is unchanged.
- **Poster ideas.** An ambassador can send an image, a note, or both, from
  their page or the app (`POST /a/{code}/idea`). New table `poster_ideas`,
  created lazily by the Worker like the others: no manual migration and no
  new runtime variable. Images are base64 text, at most 600,000 bytes, typed
  by sniffing JPEG, PNG or WebP bytes; 5 a day and 30 in total per
  ambassador. The founder page lists them (seen, delete, image at
  `/f/{FOUNDER_TOKEN}/idea/{id}`). `plan.json` gains three additive keys
  (`posters`, `dashboard`, `ideas`); every existing key is unchanged.
- **Restyled pages.** The ambassador page, the stickers page and the founder
  page now use Smooth's look (white paper, accents, dark mode, lowercase),
  with three big buttons under the header (all posters, scan dashboard,
  poster idea), a posters section with an explicit "open full size" and
  "copy my link" on each design, and a "send a poster idea" card
  (the browser shrinks the picture first). The public dashboard at `/` is
  untouched, byte for byte.
- **Fonts route.** `GET /a/_fonts/{name}.woff2` serves four subsetted woff2
  files (about 54 KB, SIL OFL), embedded in the generated section, so the
  pages load nothing from any other host.

What that means for the deploy:

- Only `worker/index.js` changes, inside the generated section between
  `// >>> smooth-ambassadors` and `// <<< smooth-ambassadors`. The file grows
  by about the size of the fonts. `AMBASSADORS.md` is updated and
  `migrations/0002_poster_ideas.sql` is new (a reference copy).
- No new runtime variable. `FOUNDER_TOKEN` stays as it is. The first
  ambassador request after the deploy creates `poster_ideas` by itself.
- This archive was built on the same base as the first one. If the Sites
  repository was changed during or after the first deploy, keep those
  changes and take only the generated section from this `worker/index.js`.

Check after deploying (no `/scan/...` link needs opening):

1. `GET /` and `GET /api/stats` look as before.
2. `GET /a/_fonts/inter.woff2` is 200 `font/woff2`; `GET /a/_fonts/nope.woff2`
   is the plain 404.
3. Add an ambassador at UVA in the founder page: the code starts with
   `uva-`; `/a/{code}/plan.json` is 200 and has `posters` (12 for UVA, 14 for
   UPenn), `dashboard` and `ideas`; the ambassador created during the first
   deploy still opens with their old code.
4. Open `/a/{code}`: three big buttons under the header, the posters grid,
   the "send a poster idea" card. Send a note-only idea, then see it under
   "poster ideas" at the top of the founder page, and delete it.

The rest of this file is the first archive's notes, still accurate.

## The finding

The app is not sending a sign-in request to an auth endpoint, because the
design has no accounts. An ambassador's unguessable code is the credential
and it travels in the path of their private page. Share links and sticker
QR codes carry a separate public id (`/r/{ref}/...`), so posting a link
never reveals the code. What the iOS app (`AmbassadorClient.swift`)
sends to this origin:

- `GET /a/{code}/plan.json?anon={fizz|sidechat|yikyak}&tz={minutes west of UTC}`
  with `Accept: application/json`. It expects 200 with a JSON plan (`name`
  and `school` required), and treats 404 as "unknown code".
- `POST /a/{code}/post`, `/check`, `/feedback`, `/pause` with a JSON body of
  strings, `Content-Type` and `Accept` both `application/json`. It expects
  any 2xx, and treats 404 as "unknown code".

The app is native (URLSession), so there is no preflight and no CORS need.

Against the deployed Worker, the GET falls through to `Not found` (404) and
every POST hits `Method not allowed` (405). Sign-in is the GET, so the app
reads the 404 as an unknown code and says "that code didn't work" for every
code. It says "couldn't reach smooth" only for a network failure or a
status other than 2xx and 404. Either way the cause is the same: the
contract was not deployed. This archive adds it.

## What is in the archive

`repository/` is the Sites repository with these changes only:

| File | Change |
|---|---|
| `worker/index.js` | `fetch(request, env, ctx)` asks the ambassador handler first; a scan is also logged to `scan_events` through `ctx.waitUntil`; a generated section is appended between `// >>> smooth-ambassadors` and `// <<< smooth-ambassadors`. Line 22 (`imageData`) is byte-identical. |
| `AMBASSADORS.md` | new: routes, variables, schema, verification |
| `migrations/0001_ambassadors.sql` | new: reference copy of the schema the Worker creates lazily |
| `README.md` | one paragraph pointing at `AMBASSADORS.md` |

`.openai/hosting.json`, `package.json`, `scripts/build.sh`,
`scripts/validate-artifact.mjs` and `.gitignore` are untouched. The Worker
is still one dependency-free ES module, so the same three commands apply:

    [["node","--check","worker/index.js"],["bash","scripts/build.sh"],["node","scripts/validate-artifact.mjs"]]

`WORKER_LOGIC_FOR_REVIEW.txt` is the edited `worker/index.js` with the image
line replaced by a placeholder. `worker-index.diff` is the diff of the
original and edited files with that line left out. `SOURCE_MANIFEST.json`
lists the new hashes.

## Runtime variables

| Name | Required | What |
|---|---|---|
| `FOUNDER_TOKEN` | yes | Secret, 16 characters or more. Generate 32 random URL-safe characters, set it with `sites_update_environment_variables`, and show it to Olisa once. Until it is set every `/f/...` route is a 404 and no ambassador can be created. |
| `PUBLIC_ORIGIN` | no | Defaults to the request's origin. |
| `APPLE_PROVIDER_TOKEN` | no | Apple campaign `pt`. Leave unset for now. |

The code reads `env.FOUNDER_TOKEN`. Please confirm that Sites environment
variables arrive on the Worker's `env` object, as `env.DB` does. If they
arrive elsewhere, that one lookup (`founderRoutes` in the generated
section, source `worker/ambassadors.js`) is the only place to adapt.

## Schema

Additive only: `ambassadors` (a secret `token` and a public `ref`), `amb_hits`, `scan_events`, `activity`,
`checklist`, `feedback`, `reminders`, plus three indexes, all
`CREATE ... IF NOT EXISTS`. The Worker creates them by itself on the first
ambassador request or first scan, the way it has always created `scans`.
If the Sites storage guidance prefers an explicit migration, apply
`migrations/0001_ambassadors.sql`; the lazy path then finds everything in
place. `scans` is never altered and no row in it is rewritten.

Before deploying, export the `scans` table and keep the export.

## What was verified here, and what was not

Verified locally, in Miniflare with D1, original and edited Workers side by
side:

- 15 requests on the existing routes answer with the same status, the same
  body bytes and the same `content-type`, `cache-control`, `location` and
  `allow` headers from both. Counters end equal in both databases.
- Near-miss paths (`/api/leaderboard/`, `/api//leaderboard`, `/r`) still get
  the tracker's own 404.
- The full app contract above, the founder flow, the public `/r/{ref}`
  poster and share links, a left ambassador's code ending, bad request
  bodies, the scan log, and a start from an empty database.
- The private code appears in no post text and on no sticker page.
- A separate review of the first build ran about 40 more requests through
  both Workers (trailing slashes, HEAD, DELETE, percent-encoding) and 20
  concurrent scans: identical answers, 20 counted. That build is the same
  as this one on the existing routes.
- `node --check`, `scripts/build.sh` and `scripts/validate-artifact.mjs` pass.

Not verified, because it needs the real deployment:

- that Sites exposes environment variables on `env`;
- that the Sites runtime passes a `ctx` with `waitUntil` (if it does not,
  the scan log is skipped and nothing else changes);
- anything on the live site or on a phone.

## After deploying

Follow "Verify after a deploy" in `repository/AMBASSADORS.md`. Do not open
`/scan/...` links beyond the one deliberate check: each is a real count.
Then create one ambassador named for App Review in the founder page; its
code goes into the App Store review notes.
