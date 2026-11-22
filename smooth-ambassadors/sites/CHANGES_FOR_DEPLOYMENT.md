# Ambassador sign-in for the existing Sites project

For the ChatGPT session that deploys project
`appgprj_6aebbfcc56e48191a690c176014ceddf`. Base commit:
`3770608515c285cc1e034f8be04e8d5e4c335640`.

## Note, 2026-11-22: founder contacts

Set one runtime variable, `FOUNDER_CONTACTS`, a JSON string, values from
Marco, never committed:
`[{"name":"olisa","phone":"+1 555 010 0100"},{"name":"marco","phone":"+1 555 010 0101"}]`.
`plan.json` then carries `contacts` (at most four; malformed entries dropped;
the key is omitted when nothing survives) and the app lists them at the foot
of the ambassador page. Unset, nothing changes.

## Update, 2026-11-22: downloads by school

This archive is the seventh. **The live site is the sixth** (the two-posts
change, read on 2026-11-21: `messages` is `question` and `list`). New here:
one public route, three small tables, two optional `plan.json` keys. No new
runtime variable. Every existing route and the public dashboard are
unchanged.

Why: Apple reports no downloads by school, so a future version of the iOS
app sends one anonymous count per install after the student connects Canvas.

- **`POST /api/install`**, public and unauthenticated on purpose, JSON
  `{"host":"canvas.upenn.edu","kind":"new"}` (`kind` is `new` or
  `existing`), at most 512 bytes. A well-formed body always answers 200
  `{"ok":true}`, including when a limit swallowed it or the host is unknown;
  a malformed one answers 400; any other method 405.
- **What is stored:** `installs(host, day, kind, n)`, a tally per school
  host per UTC day. No row per phone, no IP, no user agent.
- **Only known schools count.** A host is stored only if it is in the list
  bundled in the Worker (227 Canvas hosts generated from the app's own
  school catalog). Anything else answers 200 and writes nothing.
- **A limit per network.** At most 300 counts per network per school per
  day. To enforce it the Worker keeps a SHA-256 of a random daily value,
  the caller's network (`cf-connecting-ip`; an IPv6 address is reduced to
  its /64) and the host, in `install_seen`, with the daily value in
  `install_salts`. Both hold the current UTC day only and are deleted on the
  next install post, `plan.json` request or founder-page load after the day
  ends. The limit is enforced inside the write statement.
- **Where it shows:** `plan.json` `numbers.schoolInstalls` and
  `numbers.schoolInstallsRecent` (present only for a school with a mapped
  host; all five schools are mapped); a "{school} downloads" tile on the
  ambassador page; on the founder page a "downloads" card per school and
  "other schools" for hosts no ambassador school maps to.
- **New tables** `installs`, `install_seen`, `install_salts`
  (`migrations/0004_installs.sql`, a reference copy), created lazily like
  the others.

What that means for the deploy:

- Only the generated section of `worker/index.js` changes, plus
  `AMBASSADORS.md` and the reference migration.
- **One thing to confirm on the real runtime:** the limit depends on the
  `cf-connecting-ip` request header. If the Sites runtime does not pass it,
  every caller shares one bucket and a school would stop counting at 300 a
  day. After deploying, please say whether a request to the Worker carries
  that header.
- Check after deploying (no `/scan/...` or `/r/...` link needs opening):
  1. `GET /` and `GET /api/stats` look as before.
  2. `GET /api/install` answers 405. A POST with
     `{"host":"junk.example.com","kind":"new"}` answers 200 and changes
     nothing anywhere.
  3. One real test count: POST `{"host":"canvas.its.virginia.edu","kind":"new"}`
     once. A UVA ambassador's `plan.json` then shows
     `numbers.schoolInstalls` one higher, and the founder page's downloads
     card shows it for UVA. This test count cannot be removed through the
     site; if you want it gone, delete that one row from `installs` (host
     `canvas.its.virginia.edu`, today's date), and say that you did.
## Update, 2026-11-22 (posters)

The same seventh archive also carries the posters change (merged with the
downloads update above on 2026-11-22). This one changes the designs on offer and,
for the first time, the embedded images. No new table, no new route, no new
runtime variable.

Marco, 2026-11-21, looking at the poster gallery on his phone: "make more
generic ones. right now they're not very good. there are some specific ones
to Penn we need to get rid of."

- **Two designs retired: `tabard` and `these-two`.** Their printed codes are
  on walls, so `/scan/...`, `/r/{ref}/p/{design}` and `/api/stats` keep
  them exactly as before. They only leave what an ambassador is handed:
  `plan.json` `posters`, the page's gallery and drop chips, the stickers
  sheet. The list is `RETIRED` in the generated section.
- **Five generic designs added** (`missed`, `moved`, `one-list`, `sweeper`,
  `ask`), the first change to the Maps at the top of `worker/index.js` and
  to `imageData` since the handover. `build-sites.mjs` now adds any catalog
  design the host does not have yet: an entry at the end of the `posters`
  Map and one picture per school in `imageData` (the same JPEG for every
  school: these posters carry a dashed slot for the QR sticker instead of a
  printed code). Every original picture is kept as data; the line is
  re-serialised, so it is no longer byte-identical, and `package-sites.mjs`
  checks that nothing original was lost or changed instead.
- `/api/stats` therefore lists 87 rows (62 + 5 designs × 5 schools); the
  first 62 are unchanged and in their order, the new rows follow within
  each school. The public dashboard shows them at 0 until someone scans.

Check after deploying (no `/scan/...` or `/r/...` link needs opening):

1. `GET /api/stats`: 87 rows; every row of the 2026-11-10 backup still
   there with a total no lower than before.
2. `GET /posters/uva/missed.jpg` (and `moved`, `one-list`, `sweeper`,
   `ask`) answer `image/jpeg`; `GET /posters/upenn/ib.jpg` as before.
3. Any ambassador's `plan.json`: `posters` has no `tabard` and no
   `these-two`, and has the five new keys; the page's gallery and
   stickers sheet agree.

## Update, 2026-11-19 (small)

This archive is the sixth. **The live site is the fifth** (read on
2026-11-19 after its deploy: `plan.json` has `playbook`, `suggested` and
`captures`, the page has the job box, and no scan total is below the
2026-11-10 backup). This one changes text and one optional key. No new
table, no new route, no new runtime variable.

Olisa, the same day: "remove all the AI generated texts we have and put only
these 2".

- **The post bank is two posts.** Every written post is gone from
  `worker/templates/messages.json`. What is left is the two that already
  were the playbook's examples: the question ("What do you guys use to stop
  missing assignments?") and the ranking with Smooth slipped into it. Neither
  has a link or a pitch. Today's post alternates between them and there is no
  rest day any more.
- **A reply beside each post.** `plan.json` `today` and each entry of
  `messages` gain an optional string `reply` ("Smooth for Students on the App
  Store"). The ambassador page shows it under the post with a "copy reply"
  button. Every other key is as before; `messages` now has two entries
  (`question`, `list`) where it had six.
- **One "copy my link" button** under "your numbers" on the ambassador page
  (their `/r/{ref}/s/dm` link). The posts used to be the only place a
  tracked share link was shown; with link-free posts it would have been
  nowhere. The "opens" line under a post is gone because the post has no
  link to count.
- One posting tip that referred to a removed post is deleted (six remain).

Check after deploying (no `/scan/...` or `/r/...` link needs opening):

1. `GET /` and `GET /api/stats` look as before.
2. Any ambassador's `plan.json`: `messages` is two entries with keys
   `question` and `list`, each with `reply`; `today.text` is one of the two
   posts and holds no `http`; `today.reply` is set.
3. The ambassador page shows two message cards, each with "then reply:" and
   "copy reply", and "copy my link" under the numbers.

## Update, 2026-11-18

This archive is the fifth one. **The live site is still the third** (read on
2026-11-18: no "the job" box, the older posts). The fourth archive
(2026-11-12, described in the next section) was never deployed, and this one
contains it, so deploy only this one.

New since the fourth:

- **"what works" on the ambassador page.** A short playbook (the posts that
  work don't look like ads) with two worked examples, served in `plan.json`
  as `playbook` from `worker/templates/playbook.json`.
- **Posts to try, from the founders.** The founder page can write a post for
  one ambassador (`POST /f/{FOUNDER_TOKEN}/suggest`); it shows on their page
  and in `plan.json` as `suggested`. At most 20 stored per ambassador.
- **Two new uploads**, one route, `POST /a/{code}/capture`:
  - `kind: "feed"`: stills of the ambassador's school feed, up to 16 per
    recording, each at most 200,000 bytes. From the web page they choose
    screenshots; the app cuts stills out of a screen recording on the phone.
  - `kind: "result"`: one screenshot of how a post did (at most 300,000
    bytes) with the app it was on, the kind of post, and the upvote and view
    counts they type.
  The founder page lists both ("feed recordings", "post results" with
  averages by kind of post), with seen and delete, and serves each picture at
  `/f/{FOUNDER_TOKEN}/capture/{id}` with the same headers as a poster idea.
- **New tables** `captures` and `suggestions` (`migrations/0003_captures.sql`,
  a reference copy). Created lazily by the Worker like the others: no manual
  migration and no new runtime variable.
- **Limits**, all enforced inside the INSERT: feed 32 stills a day and 96
  stored per ambassador, 16 per recording; results 8 a day and 60 stored;
  1,500 capture rows across everyone, after which uploads answer 429
  ("we're full right now. tell olisa or marco."). Deleting on the founder
  page frees room.
- **Stricter founder ids.** An id with a space or a leading zero now acts on
  nothing, on every founder action.

What that means for the deploy:

- Only the generated section of `worker/index.js` changes, plus
  `AMBASSADORS.md` and the new reference migration. Every existing route,
  every existing `plan.json` key and the public dashboard are unchanged.
- **Storage.** Pictures are base64 text in D1. The worst case is about
  34 MB per ambassador and about 600 MB at the global ceiling (nearer
  200 MB in practice, since a shrunk screenshot is about 100 KB). If the Sites
  database has a size limit below that, say so and the ceiling
  (`CAPTURES_GLOBAL_LIMIT` in the generated section) can be lowered.
- Check after deploying (no `/scan/...` or `/r/...` link needs opening):
  1. `GET /` and `GET /api/stats` look as before.
  2. Any ambassador's `plan.json` has `playbook` (two examples), `suggested`
     (an array) and `captures`; every key it had before is still there.
  3. Open an ambassador page: the yellow "the job" box, then "what works",
     then further down "show us your feed" and "how did a post do". Send one
     screenshot through each.
  4. On the founder page both appear under "feed recordings" and "post
     results". Use "send a post to try" on the recording, reload the
     ambassador page and see it under "posts to try". Then delete the test
     recording, the test result and the test suggestion.

## Update, 2026-11-12 (small; included here, never deployed on its own)

The fourth archive. Text changes only:

- **No more checklist.** The ambassador page no longer shows the
  "checklist" section (its first step told people who already use the app to
  download it), and the founder roster no longer shows "checklist n/5".
- **The job, at the top.** Under the greeting the ambassador page now says:
  "the job: get smooth in front of as many eyes as you can. spam the chats.
  put up posters. post every day. bring back what people say and ideas for
  smooth." The feedback section is now headed "feedback and ideas for
  smooth" (same form, same route).

- **Longer anonymous posts.** The fizz / sidechat / yik yak posts in the
  daily bank, and the anonymous message under "messages", now each lead with
  one of three things the app does: it reads everywhere a professor posts
  about assignments and classes, the tree answers questions about your
  classes, and the smooth sweeper rings your phone like an alarm before
  something not turned in is due. Five more are in a hype voice ("smooth
  just saved my life", "this new smooth app is crazy"), so the daily bank is
  19 entries and the rest day comes round every 19 days. Text only; `today.text` and
  `messages[].text` in `plan.json` are longer strings, nothing else moves.

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
