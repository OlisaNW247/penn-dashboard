# smooth ambassadors

The poster scan tracker for **Smooth for Students**, plus the campus
ambassador system built on top of it. One Cloudflare Worker, one D1
database, no accounts, no passwords, runs on a phone.

> **Where this should live:** a private repository
> (`OlisaNW247/smooth-ambassadors`) with Marco as collaborator. It was
> drafted inside `penn-dashboard` (public) only because that was the repo
> available to the session. Nothing private is in these files; the roster
> and contacts live in D1. See "Moving to the private repo" below.

## What is here

| Path | What |
|---|---|
| `worker/index.js` | entry. ambassador routes first, then the legacy tracker |
| `worker/legacy.js` | today's routes (`/`, `/api/stats`, `/scan/...`, `/posters/...`), re-implemented from the handoff spec. **Replace with the live `worker/index.js` from the Sites repo when merging** (see docs/deploy.md) |
| `worker/ambassadors.js` | new routes: `/a/{token}...`, `/f/{secret}...`, `/api/leaderboard` |
| `worker/data.js` | every D1 query. the roster is only touched here |
| `worker/pages.js` | the ambassador page and the founder view |
| `worker/digest.js` | the two-week digest, welcome text and campus-moment texts |
| `worker/catalog.js` | schools, designs, scan-key rules (printed QR keys, never rename) |
| `worker/templates/*.json` | **messages, campus moments, checklist. plain files, edit freely, no code** |
| `migrations/0001_ambassadors.sql` | additive D1 migration. `scans` is never altered |
| `docs/` | role description, checklist, incentives + reminders plan, posting rules, conversion reporting, deploy |
| `scripts/check-no-secrets.mjs` | refuses commits with phone numbers, emails, tokens, `.dev.vars`, csv exports |
| `test/routes.test.mjs` | end-to-end tests in Miniflare with a local D1 (14 tests, every route) |

## Routes

Existing, unchanged (printed QR codes depend on these):

| Route | Behaviour |
|---|---|
| `/` | public dashboard |
| `/api/stats` | counts per school and design |
| `/scan/{poster}` | UPenn legacy keys (`ib`) |
| `/scan/{school}/{poster}` | other schools (`umiami/ib`) |
| `/posters/{school}/{poster}.jpg` | poster previews |

New:

| Route | Who | Behaviour |
|---|---|---|
| `/a/{token}` | ambassador | their private page: numbers, messages with their own links, drop log, posters, feedback, checklist, pause |
| `/a/{token}/s/{channel}` | public (in their messages) | share link, counts for them, redirects to the App Store |
| `/a/{token}/p/{design}` | public (their QR stickers) | poster code, counts for **the school and them**, redirects |
| `/a/{token}/stickers` | ambassador | printable QR sheet, one per design |
| `/a/{token}/me.json` | ambassador | their numbers only |
| `POST /a/{token}/drop` `post` `check` `feedback` `pause` | ambassador | forms on their page |
| `/f/{FOUNDER_TOKEN}` | founders | roster, add ambassador, performance by school / design / ambassador, digest generator, campus moments, feedback |
| `/f/{FOUNDER_TOKEN}/export.json` | founders | full export (backup) |
| `/api/leaderboard` | public | school totals only. never a person |

Decisions baked in:
- A scan on an ambassador's poster code counts toward the school/design
  total **and** the ambassador, so the public dashboard stays complete.
- Share links (group chat, fizz, ...) count only for the ambassador. They
  are not posters.
- Every scan on any route now also writes a row to `scan_events`, so "last
  two weeks" exists. Totals stay in `scans`, untouched.
- The founder view is behind one unguessable secret (`FOUNDER_TOKEN`,
  at least 16 chars). Wrong or missing secret → 404, same as any other
  unknown page.
- Redirects go to the App Store listing. When `APPLE_PROVIDER_TOKEN` is
  set, they carry Apple campaign tokens (`pt`, `ct`) per school/design and
  per ambassador link, for download attribution (docs/conversion-reporting.md).

## Run it locally

```sh
npm install
cp .dev.vars.example .dev.vars          # set FOUNDER_TOKEN to something long
npm run migrate:local
npm run dev                              # http://localhost:8787
```

Then open `http://localhost:8787/f/<your FOUNDER_TOKEN>` and add yourself.

Tests: `npm test`. Secrets check: `npm run check` (or install the hook once
with `sh scripts/install-hooks.sh`).

## Editing the words

Everything ambassadors read is in `worker/templates/`:
- `messages.json`: the copy-paste messages and posting tips. `{link}` becomes
  the ambassador's own tracked link for that channel.
- `moments.json`: campus-moment texts (welcome-back, add/drop, midterms...).
- `checklist.json`: the onboarding checklist. Don't rename a `key` once
  people have ticked it.

Change a file, commit, deploy. No code.

## Data and privacy

- Ambassador names and contacts are in the `ambassadors` table in D1 and
  are shown only on the founder view. The public dashboard, `/api/stats`
  and `/api/leaderboard` never read that table's name or contact columns.
- An ambassador's page shows only their own rows.
- Never commit: `.dev.vars`, exports, csv files, anything with a phone
  number in it. `scripts/check-no-secrets.mjs` enforces this on commit and
  in CI.
- Back up before any migration: `npm run backup:remote` (or the Sites
  equivalent) writes `backups/<timestamp>.sql`, which is git-ignored.

## Moving to the private repo

```sh
# in penn-dashboard, on branch claude/new-session-b3ylkg
git subtree split --prefix=smooth-ambassadors -b smooth-ambassadors-export
# new empty private repo created on GitHub as OlisaNW247/smooth-ambassadors
git push https://github.com/OlisaNW247/smooth-ambassadors.git smooth-ambassadors-export:main
```

Then add Marco as a collaborator, run `sh scripts/install-hooks.sh`, and
delete the folder from `penn-dashboard`.

## Deploying

See `docs/deploy.md`. Short version: the live site must stay on
`smooth-poster-scans.jazzysmile20.chatgpt.site` because that is what every
printed QR code encodes. The Worker code in this repo is designed to drop
into the Sites repository's `worker/` folder next to the existing file.
