# LHF backend — deploy guide

The Supabase project behind course-material pooling and `ask`'s server path.
Read `PROTOCOL.md` first — it's the contract this README's steps exist to
stand up; if the two ever disagree, `PROTOCOL.md` wins.

## Prerequisites

- A Supabase account and an empty project (Postgres + Edge Functions; the
  free tier is enough to start — see "Cost expectations" below).
- An OpenRouter account and API key (`https://openrouter.ai`), with billing
  set up — this is LHF's own key, never a per-student key.
- The Supabase CLI (`supabase`) installed locally.
- Deno, for running this directory's tests and type-checking the functions
  before deploying — `deno.json` in this directory defines the tasks.

## One-time setup

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
```

`supabase db push` applies `supabase/migrations/` — `courses`,
`course_documents`, `enrollments`, `course_profiles`, `ask_usage`, and the
row-level-security policies scoping every table to the caller's own
enrollment.

In the Supabase dashboard, **Authentication → Providers → enable Anonymous
Sign-ins**. This is off by default on a new project; `sync` and `ask` will
401 every request until it's on, because the app never creates an email/
password account — see `PROTOCOL.md` § Auth.

Set the function secrets (values below are placeholders — never commit a real
key or project URL anywhere in this repo):

```bash
supabase secrets set \
  OPENROUTER_API_KEY=<your-openrouter-key> \
  LHF_MODEL=z-ai/glm-5.3-flash \
  LHF_FALLBACK_MODEL=openai/gpt-5.6-luna \
  ASK_DAILY_LIMIT=40 \
  ASK_MONTHLY_GLOBAL_LIMIT=100000
```

`LHF_MODEL`/`LHF_FALLBACK_MODEL` and the two limits all have the same
defaults baked into the functions (see `PROTOCOL.md` § Model and § `ask`), so
setting them explicitly here is about making the deployed configuration
legible, not strictly required on day one.

Deploy the functions:

```bash
supabase functions deploy
```

## Wiring up the app

Paste the project's URL and anon (public) key into
`LowHangingFruitKit/Sources/LowHangingFruitUI/BackendConfiguration.swift`.
Both values are safe to embed in the app binary — the anon key is meant to be
public; every row it can touch is behind RLS scoped to the caller's own
(anonymous) auth id. Never put the service-role key or `OPENROUTER_API_KEY`
in the app; both live only as function secrets on the server.

## Local testing

Two independent checks, neither of which needs a deployed project:

```bash
cd backend
deno task test    # unit tests against test/, no network
deno task check   # type-checks the sync and delete-account functions
```

The RLS policies and the `ask_usage` quota functions need a real Postgres to
exercise, but not a full Supabase stack (Docker is unavailable in some
environments this runs in). Against a scratch local Postgres:

```bash
psql <scratch-db-url> -f test/local_auth_stub.sql
psql <scratch-db-url> -f supabase/migrations/20260907000000_init.sql
psql <scratch-db-url> -v ON_ERROR_STOP=1 -f test/rls.test.sql
```

`local_auth_stub.sql` stands in for the slice of Supabase's managed `auth`
schema the migration depends on (an `auth.users` table and `auth.uid()`
reading the same JWT-claims GUC PostgREST sets on every real request) so the
schema can be tested against bare Postgres. `rls.test.sql` is a sequence of
`RAISE EXCEPTION`-on-failure checks proving the policies match `PROTOCOL.md` —
a nonzero `psql` exit means something failed and names what. Never run either
script against a database that might be a real project's.

## Cost expectations

- **Per question**, list price: roughly $0.0005 through OpenRouter with
  `z-ai/glm-5.3-flash` for LHF's context-document-plus-excerpts request shape
  — see the "why this model" reasoning in `docs/decisions.md`'s 2026-09-07
  entry. `ASK_DAILY_LIMIT` bounds the worst case per student per day;
  `ASK_MONTHLY_GLOBAL_LIMIT` bounds it across everyone.
- **Supabase**: the free tier (500MB Postgres, 500K Edge Function
  invocations/month, 2 CPU-hours) is enough to start; move to Pro when either
  ceiling is close, well before it would silently start failing requests.

## Kill switches

- `supabase secrets set ASK_DAILY_LIMIT=0` takes the `ask` server path down
  for every student without touching a deploy — the app falls back to
  `OnDeviceAssistantResponder`, exactly as it does offline or over quota
  today. Restore the normal value to bring it back.
- Undeploying or pausing the Supabase project has the same effect for both
  `sync` and `ask`: the app treats an unreachable backend the same as being
  offline.

See `PROTOCOL.md` for the full wire contract, and `docs/decisions.md` for why
this exists at all and what was rejected.
