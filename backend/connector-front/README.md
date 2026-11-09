# connector-front

A small HTTP front (Deno-testable `handle`, served on Vercel as an Edge Function) that answers the OAuth discovery paths at the root of its own host and forwards `/functions/v1/mcp` and `/functions/v1/agent-auth` to the Supabase Edge Functions. Claude Code reads discovery documents only at the host root and an Edge Function cannot answer a root path (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md, section 8 item 3).

It logs one line per request (method, path, status) and nothing else. Bodies are streamed, upstream redirects are never followed.

## Environment

- `UPSTREAM_BASE` (required): the functions origin plus `/functions/v1`, e.g. `https://ynetfjixexksxqrrkwsg.supabase.co/functions/v1`.
- `PUBLIC_BASE` (required): this front's origin plus `/functions/v1`, e.g. `https://smooth-agent.vercel.app/functions/v1`.
- `UPSTREAM_APIKEY` (optional): sent as the `apikey` header upstream. Supabase's gateway may want it even with `verify_jwt = false`; the first deploy decides whether it is needed. Try without, set the anon key if upstream answers 401 with a gateway message instead of our `WWW-Authenticate`.
- `PORT` (local only, default 8000).

## Run locally

    UPSTREAM_BASE=... PUBLIC_BASE=http://127.0.0.1:8790/functions/v1 PORT=8790 deno run --allow-net --allow-env main.ts

## Deploy (Vercel)

`backend/` is the Vercel project root. `vercel.json` rewrites every path to `api/connector-front.js, which imports the esbuild bundle deploy.sh makes of connector-front/vercel-entry.ts`, an Edge Function that calls `handle` with `UPSTREAM_BASE`, `PUBLIC_BASE` and `UPSTREAM_APIKEY` from the project's environment; `.vercelignore` uploads only `api/`, `connector-front/`, `supabase/functions/_shared/` and `vercel.json`.

1. Once: `vercel login`.
2. `connector-front/deploy.sh` (`--dry-run` prints the commands and runs nothing). It links the project `smooth-agent` (`LHF_CONNECTOR_PROJECT` to pick another name; `PUBLIC_BASE` follows it), replaces the production env vars and runs `vercel deploy --prod --yes`.
3. It deploys to production only, on purpose: Hobby preview deployments carry Vercel Authentication, which would answer Claude with a login page.
4. The host is `https://smooth-agent.vercel.app`. A custom domain can replace it later; update `PUBLIC_BASE` and `LHF_AGENT_PUBLIC_BASE` together.

Offline proof without an account: `node connector-front/bundle-check.mjs [scratchDir]` bundles the edge function with esbuild and runs it under Node against a stub upstream (discovery documents, `/functions/v1/mcp` 401 pass-through, root `/register` forwarding).

Not confirmable offline: that Vercel applies the `/(.*)` rewrite to root `/.well-known/...` paths before filesystem routing (the documented behaviour for rewrites is that they run after filesystem matches, and nothing else exists here), and that the Edge runtime streams request bodies with `duplex: "half"`.

## Point the functions at it

Deploy `agent-auth` and `mcp` with `LHF_AGENT_PUBLIC_BASE` set to the same value as `PUBLIC_BASE`, so the issuer and MCP URL they emit are this host's.

## Smoke checks

    curl -s $PUBLIC/.well-known/oauth-protected-resource/functions/v1/mcp
    curl -s $PUBLIC/.well-known/oauth-authorization-server/functions/v1/agent-auth
    curl -s $PUBLIC/.well-known/openid-configuration/functions/v1/agent-auth
    curl -si -X POST $PUBLIC/functions/v1/mcp -d '{}'

(`$PUBLIC` is the host without `/functions/v1`.) The last must answer 401 with a `WWW-Authenticate` header naming this host.
