# Ambassador sign-in for the existing Sites project

For the ChatGPT session that deploys project
`appgprj_6aebbfcc56e48191a690c176014ceddf`. Base commit:
`3770608515c285cc1e034f8be04e8d5e4c335640`.

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
- The full app contract above, the founder flow, the public `/r/{ref}` poster and
  share links, a left ambassador's code ending, bad request bodies, the scan log, and a start from an empty database.
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
