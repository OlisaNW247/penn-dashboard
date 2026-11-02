# Hand-off, 2026-11-02: getting the tree fixes onto phones without Olisa's Mac

Written 2026-11-02. Olisa has no laptop this week; Marco has his. This
page is what each of them runs, in order, and what each step proves. The
work it refers to is on `v8` (`docs/TREE_IMPROVEMENT_PLAN.md` → Status
for the why): local dates, kept excerpt structure, the website-discovery
chunking, the citation contract, the `.meeting` recency kind and the
conversation history, all compiled only on GitHub's macOS runner so far
(the `tests` workflow, `.github/workflows/tests.yml`), never on a phone.

## 1. The server prompt: a cloud session with deploys allowed (Olisa)

**Amended 2026-11-02 17:30 UTC:** the canary is dark until
`LHF_PROBE_SECRET` exists (Status, below). Paste this into the deploy
session first:

> The project has no `LHF_PROBE_SECRET`, so the canary you deployed
> answers 404 to every probe. I approve setting one. Generate a random
> 48-hex-character value and set it with one call: `POST
> https://api.supabase.com/v1/projects/ynetfjixexksxqrrkwsg/secrets` with
> body `[{"name":"LHF_PROBE_SECRET","value":"<value>"}]` (the proxy injects
> the token); print only the HTTP status, never the value, and wait 20 s.
> Then `export LHF_PROBE_SECRET=<value>` in the same shell and run the
> 20-run `citations` probe with tag `cite-def`. If every run answered and
> the four counts are no worse than the 2026-10-25 baseline (6/6
> answered, 2/2 Meyerson, 3/6 titles), deploy production `ask`
> (`deploy-function.mjs ask`), record ask-canary v8, the new `ask`
> version, the date and the counts in CLAUDE.md's ask section, ROADMAP →
> Next and `docs/HANDOFF_2026-11-02_TREE.md` → Status, and push to `v8`
> after `git pull --rebase origin v8`. Show me the secret value once in
> chat so I can save it; never write it into the repo. Deploy nothing
> else.

Only the cloud sessions hold the Supabase Management API token (there is
none on either Mac), and this session's permission mode refuses a
function deploy. Open a new Claude Code session on this repository with
Bash allowed for `node backend/scripts/deploy-function.mjs` (or in a
mode that does not ask), and paste:

> Read CLAUDE.md → "ask: the model, the hedge, and the loop that tunes
> them" first. On `v8` at or after `8bbbc67`, deploy the `ask-canary`
> function with the `ask` directory bundled
> (`NODE_USE_ENV_PROXY=1 node backend/scripts/deploy-function.mjs
> ask-canary --also ask`), then run `NODE_USE_ENV_PROXY=1 node
> backend/scripts/ask-probe.mjs --slug ask-canary --runs 20 --set
> citations --tag cite-def` and read the four counts it prints at the
> end. If every run answered and the counts are no worse than the
> 2026-10-25 baseline in `docs/TREE_IMPROVEMENT_PLAN.md` → Status
> (6/6 answered, 2/2 Meyerson, 3/6 titles under the old prompt), deploy
> production `ask` the same way (`deploy-function.mjs ask`), record the
> new version numbers in CLAUDE.md's ask section and ROADMAP → Next, and
> push to `v8` with `git pull --rebase origin v8` first. Deploy nothing
> else: `sync` v15 and `extract-announcement` wait for their own go.

What it changes on every phone today, before any app update: the model
is told the weekly schedule never says whether a class meets on a given
day and must not claim nothing was announced; the citation detail is the
excerpt's title (chips link); a newer post beats an older one.

## 2. The phone build: Marco's laptop

Paste into a Claude Code session on Marco's Mac, in the repo:

> Read CLAUDE.md top to bottom, then ROADMAP.md. Check out `v8` at or
> after `8bbbc67` (`git pull --rebase origin v8`). Run `cd
> LowHangingFruitKit && swift test --no-parallel` alone on the machine
> (CLAUDE.md → Traps, the shared defaults domain) and compare the count
> with the GitHub `tests` workflow's last green run on the same commit;
> record the count in CLAUDE.md → Test baseline as the notes do. Then the
> iOS Debug build for the connected phone (CLAUDE.md → Commands), install
> it, and on the phone open the tree and ask, in one conversation: "Do I
> not have cis 2620 class today?" and then "you should've said that in my
> original question" (any class with an Ed post from the last two weeks
> works; CIS 2620 posted "No lectures this week but quiz on Monday" on
> 2026-11-01). The first answer should lead with that post and carry its
> chip; the second should acknowledge the correction, not say it has no
> record of the question. Also ask "what's due tomorrow" after 8 pm
> Eastern and check the day. Write what you saw into CLAUDE.md → Known
> gaps (the two entries dated 2026-10-24 and the follow-ups bullet dated
> 2026-11-02) and push to `v8`.

## 3. The release: Marco's laptop, after 2 is green and Olisa says go

> On `v8` green per step 2, stamp 3.4.1 (18) in `project.yml` and
> `project.pbxproj` by hand (CLAUDE.md → Commands → Release upload; never
> `xcodegen generate`), archive and export with the two `xcodebuild`
> commands there, confirm the widget's AlarmKit link is weak with
> `otool -L` on the archive, and upload. Record the archive commit and
> the upload time in CLAUDE.md → Release state and
> `docs/appstore/CHECKLIST.md`. Submitting in App Store Connect is a
> person's step; the `update-floor` workflow raises the floor six hours
> after it is live.

## 4. The retrieval bench: whoever has a developer build on a phone

`docs/TREE_IMPROVEMENT_PLAN.md` → "Running the bench": copy
`course-knowledge.json` off the phone into a folder outside the repo and
run `RetrievalBenchTests` with `LHF_BENCH_KNOWLEDGE` set. Paste the
output into a session; it replaces the plan's predicted verdicts with
measured ones.

## Status

- 2026-11-02: written. The `tests` workflow's first macOS run failed on
  Xcode 16 (`Schema.Version` not `Sendable`); the job moved to the macOS
  26 image at `8bbbc67`. Deno 470/0 and the extension's suite are green on
  the runners. **Swift: 3414 tests / 329 suites green at `01a71db`**
  (Xcode 26.6 on the macOS 26 runner, 100.8 s), after one test that pinned
  the old no-history rule was rewritten to the new contract. So step 2's
  compile is done; what Marco's laptop adds is the iOS build, the phone
  and the archive. The workflow runs on the macOS 15 image since
  `784da81` (Xcode 26.3 there) because the macOS 26 pool queued one run
  for 15 minutes and cancelled it.
- 2026-11-02, 17:30 UTC: Olisa's deploy session put `ask-canary` v8 live
  (the new prompt), then its probe stopped: since the 2026-10-27 hardening
  the canary answers 404 to any request without `x-lhf-probe-secret`
  equal to the function secret `LHF_PROBE_SECRET`, and the project has
  **no such secret** (the Management API lists none). So no probe can run
  against the canary until one is set, from a session whose permission
  mode allows a secret write (the overseer session's does not, and it
  could not even relay the instruction). Production `ask` is not gated
  and is unaffected. Step 1 below is amended: set the secret first.
