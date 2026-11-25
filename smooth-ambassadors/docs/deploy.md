# deploy

## The constraint

Every printed poster encodes
`https://smooth-poster-scans.jazzysmile20.chatgpt.site/scan/...`. That
domain is a ChatGPT Sites project (`appgprj_6aebbfcc56e48191a690c176014ceddf`)
running a Cloudflare Worker with D1 bound as `DB`. The hosting stays there.
A branded domain means reprinting, so it is a later decision.

The live site was read on 2026-11-10 (read-only routes; no `/scan/` link
was opened, so no counter moved), and `worker/legacy.js` now answers the
same way: the dashboard page is byte-identical, `/api/stats` lists the same
62 rows in the same order with the same names, posters and unknown routes
answer alike. One thing is still taken from the handoff and not from the
live site: where a scan redirects (Smooth's App Store listing), because
checking it means opening a real code.

The Sites repository's source arrived as an archive on 2026-11-10 (commit
`3770608`). It settles how a deploy works: the Sites build ships exactly one
dependency-free file, `worker/index.js`, with the poster images embedded in
it, and runs no install. Nothing here can publish to Sites; the ChatGPT
session that owns the project does (it saves a version and deploys it). So
this repository's job is to produce that one file.

`worker/legacy.js` stays as a faithful stand-in for local work and for
`npm test`. It is not what deploys. In the Sites build the real tracker's
own code serves the old routes, untouched, and the ambassador system is
folded in beside it.

**First deploy: 2026-11-11**, by that session, from the zip built here.
Checked afterwards from outside, read-only: dashboard, `/api/stats`
against the backup (nothing lower), posters, the 404s and 405, the
leaderboard, and an unknown code refused.

**Second deploy: 2026-11-12**, the same way: school-prefixed codes, poster
ideas, the posters section and the restyled pages. Checked afterwards the
same read-only way, plus the font route, a prefixed code's `plan.json`
and the page itself mirrored with its real posters.

**Not deployed as of 2026-11-18:** the fourth zip (2026-11-12: the job box,
no checklist, the rewritten posts) was handed over and never went up; the
live site read that day still had none of it. The fifth zip (2026-11-18)
contains the fourth plus the playbook, posts to try from the founders, and
the feed and post-result uploads, so it is the only one to deploy. Its
`CHANGES_FOR_DEPLOYMENT.md` has the checks to run afterwards.

**Tenth zip, 2026-11-25:** the ninth (live since 2026-11-24) plus the
per-channel share links on the founder and ambassador pages. Page changes
only. Not deployed when this was written.

**Seventh zip, 2026-11-22:** two designs retired, five generic designs
added. The first zip that changes the Maps and `imageData` (see
`sites/CHANGES_FOR_DEPLOYMENT.md`). The Sites archive it is built from was
not on the dev Mac that day; it needs a fresh export from the ChatGPT
session (step 1) before steps 2 to 5 can run.

## Step by step

1. **Get the current Sites source** (the archive ChatGPT exports, with
   `repository/worker/index.js`). Unpack it somewhere outside this repo and
   keep one copy untouched.
2. **Fold the ambassador system in.**
   `node scripts/build-sites.mjs <copy>/repository` makes two small edits to
   the real `fetch` (ask the ambassador handler first; log a scan to
   `scan_events` after its counter is saved), adds any catalog design the
   host's `posters` Map does not have yet (its name there, its preview from
   `posters/previews/` in `imageData` for every school) and appends the
   bundled ambassador code between two markers. It refuses to write if the
   real file no longer looks the way it expects, the image dictionary
   included (`scripts/lib/add-posters.mjs` reads its shape rather than
   assuming one), and a second run changes nothing.
3. **Prove nothing moved.** In `<copy>/repository`: `node --check
   worker/index.js && bash scripts/build.sh && node
   scripts/validate-artifact.mjs`. Then here:
   `SITES_ORIGINAL=<untouched>/repository/worker/index.js
   SITES_EDITED=<copy>/repository/dist/server/index.js npm run test:sites`
   runs both Workers side by side and compares every existing route byte
   for byte, then walks the app's whole contract. `bash
   scripts/verify-sites-bytes.sh <original> <edited>` shows the diff with
   the image line left out.
4. **Rehearse on the real numbers.** Ask the ChatGPT session for an export
   of `scans` (it produced `scans.json` and `scans.sql` on 2026-11-10) and
   run `node scripts/rehearse-backup.mjs <backup-dir> <untouched index.js>
   <copy>/repository/dist/server/index.js`, with `LIVE=1` to also compare
   the backup with the live `/api/stats`. It loads the real rows into both
   Workers and checks that the dashboard numbers match the backup, that
   the whole ambassador flow leaves every row alone, and that a scan adds
   exactly 1. The 2026-11-10 run: 62 rows, 70 link opens, 24 checks
   passed, live totals equal to the backup.
5. **Pack it.** `node scripts/package-sites.mjs <untouched> <copy> <zip>`.
   Hand the zip to the ChatGPT session with
   `sites/CHANGES_FOR_DEPLOYMENT.md` (it is inside the zip).
6. **There, before deploying:** export the `scans` table; set
   `FOUNDER_TOKEN` (32 random characters, never in git or chat). No
   migration has to be run: the tables are created lazily with `CREATE ...
   IF NOT EXISTS`, the way the tracker has always created `scans`.
   `migrations/0001_ambassadors.sql` is the same statements for a platform
   that wants an explicit migration.
7. **Re-test live** with the list in `sites/AMBASSADORS.md` (it is copied
   into the Sites repository). Compare `/api/stats` totals to the backup:
   identical, plus the one deliberate test scan.

## Adding a school

1. Append the school to `SCHOOLS` in `worker/catalog.js` (the id is a
   lowercase slug, the name is what the dashboard shows, `canvasHosts` are the
   hosts the app's catalog lists for it). At the end, never in the middle: the
   order is the order of `/api/stats`, and the old rows must keep theirs.
2. Run `npm run gen:hosts` if the Canvas host is not already in
   `worker/canvas-hosts.json` (a test fails when it drifts).
3. Rebuild (`node scripts/build-sites.mjs <repository>`). It appends the school
   to the host's `schools` Map, the dashboard's `<select>` and its
   `schoolNames`, then gives it a picture for every design: copied where the
   design is the same at every school, rebuilt with the school's own QR where
   it is not (`scripts/lib/school-edition.mjs` needs `npm install` for
   `jpeg-js` and `jsqr`; they are build-time only and never end up in the
   deployed file). It stops if a template poster's QR does not say what it
   should, if a result does not decode to the new URL, or if any school and
   design pair is left without a picture.
4. Look at the editions it made (they are in the host's image dictionary; write
   one out to a file and read it) before packaging. A QR edition is the
   template's artwork with one square redrawn, so a design whose QR sits on
   busy artwork is the one to look at twice.
5. Package and deploy as usual. The checks to run afterwards are in
   `sites/CHANGES_FOR_DEPLOYMENT.md`, "Update, 2026-11-24: Harvard".

## How Marco ships a change without Olisa

Today he cannot, and the mirror job in `.github/workflows/deploy.yml` does
not change that. The Sites handoff says a git push alone does not publish:
a version has to be saved and deployed from the ChatGPT account that owns
the project. So a change ships by building the zip (steps 1 to 5) and
giving it to whoever can open that ChatGPT session, which is Olisa.

The way out is the "later decision" above: move the Worker and its D1
database onto a Cloudflare account both founders hold, keep the printed
domain pointing at it, and deploy with `wrangler deploy` from CI. Until
then the deploy workflow stays switched off (`DEPLOY_MODE` unset).

## After every deploy

Open the public dashboard and two printed codes with a phone. Counters go
up by one each. Nothing else should change.
