# deploy

## The constraint

Every printed poster encodes
`https://smooth-poster-scans.jazzysmile20.chatgpt.site/scan/...`. That
domain is a ChatGPT Sites project (`appgprj_6aebbfcc56e48191a690c176014ceddf`)
running a Cloudflare Worker with D1 bound as `DB`. The hosting stays there.
A branded domain means reprinting, so it is a later decision.

This session could not reach the Sites git repository or the live site
(the network policy blocked the host), so the integration below is
written, not executed. **Access needed to go live:** read/write to the
Sites project's git repository, and the ability to run the D1 migration
and set the `FOUNDER_TOKEN` secret on that project. Olisa grants that, or
runs the steps.

## Step by step (first deploy)

1. **Back up D1.** Export the `scans` table before anything else and keep
   the file off git (`backups/` is ignored).
2. **Bring the real legacy code in.** Copy the live `worker/index.js` from
   the Sites repo into this repo as `worker/legacy.js`, exporting
   `default { fetch }` and the two helpers `recordScan(env, key, ambassadorId)`
   and `appStoreRedirect(env, campaignToken)` (copy them from the current
   `legacy.js`; they are ~30 lines). Keep its poster images exactly as they
   are. Run `npm test`: the existing-route tests must still pass.
3. **Apply the migration.** `migrations/0001_ambassadors.sql` is additive
   (`CREATE TABLE IF NOT EXISTS` only). Apply it to the Sites D1 database.
4. **Set the secret.** `FOUNDER_TOKEN`, at least 24 random characters:
   `node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"`.
   Never in git, never in chat. Set `PUBLIC_ORIGIN` to the live origin.
5. **Deploy** the Worker from this repo's `worker/` (bundled: it imports
   `qrcode-generator` and JSON templates, so the deploy step must bundle,
   which wrangler and Sites' Worker build both do).
6. **Re-test live.** `/`, `/api/stats`, `/scan/ib`, `/scan/uva/ib`,
   `/scan/uva/jester` (must 404), a poster preview, then
   `/f/<FOUNDER_TOKEN>`. Compare `/api/stats` totals to the backup: they
   must be identical plus your test scans.

## How Marco ships a change without Olisa

Pick one and delete the other job from `.github/workflows/deploy.yml`:

- **Mirror (recommended).** GitHub is the source of truth; on every push
  to `main`, CI runs the tests and pushes the same commit to the Sites git
  repository, which deploys it. Needs two repository secrets:
  `SITES_GIT_URL` and `SITES_DEPLOY_KEY`, and the repository variable
  `DEPLOY_MODE=mirror`. If Sites only accepts https pushes with a token,
  swap the ssh lines for a `https://x-access-token:${TOKEN}@...` remote.
- **Manual.** Same thing by hand: `git remote add sites <url>` once, then
  `git push sites main`. Documented in one line so either founder can do it.
- **Wrangler direct** only applies if the Worker ever moves off Sites onto
  the founders' own Cloudflare account. Then the printed domain would have
  to be re-pointed, which is the "later decision".

## After every deploy

Open the public dashboard and two printed codes with a phone. Counters go
up by one each. Nothing else should change.
