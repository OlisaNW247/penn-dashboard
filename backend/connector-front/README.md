# connector-front

A small Deno HTTP front that answers the OAuth discovery paths at the root of its own host and forwards `/functions/v1/mcp` and `/functions/v1/agent-auth` to the Supabase Edge Functions. Claude Code reads discovery documents only at the host root and an Edge Function cannot answer a root path (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md, section 8 item 3).

It logs one line per request (method, path, status) and nothing else. Bodies are streamed, upstream redirects are never followed.

## Environment

- `UPSTREAM_BASE` (required): the functions origin plus `/functions/v1`, e.g. `https://ynetfjixexksxqrrkwsg.supabase.co/functions/v1`.
- `PUBLIC_BASE` (required): this front's origin plus `/functions/v1`, e.g. `https://smooth-agent.deno.dev/functions/v1`.
- `UPSTREAM_APIKEY` (optional): sent as the `apikey` header upstream. Supabase's gateway may want it even with `verify_jwt = false`; the first deploy decides whether it is needed. Try without, set the anon key if upstream answers 401 with a gateway message instead of our `WWW-Authenticate`.
- `PORT` (local only, default 8000).

## Run locally

    UPSTREAM_BASE=... PUBLIC_BASE=http://127.0.0.1:8790/functions/v1 PORT=8790 deno run --allow-net --allow-env main.ts

## Deploy (Deno Deploy)

`deploy.sh` does it: it needs a Deno Deploy access token (dash.deno.com → Account → Access tokens, any Deno Deploy account; the project lands in that account's personal org) in `~/lhf-bench/deno-deploy.token`, mode 600, and creates the project `smooth-agent` on the first run (`LHF_CONNECTOR_PROJECT` to pick another name; `PUBLIC_BASE` follows it). `deploy.sh --dry-run` uploads nothing. `deployctl` is installed with `deno install -gArf jsr:@deno/deployctl` (1.13.1 on the dev Mac since 2026-11-08). The dashboard route still works: new project, entrypoint `backend/connector-front/main.ts`, the two env vars. A custom domain can replace the `*.deno.dev` host later; update `PUBLIC_BASE` and `LHF_AGENT_PUBLIC_BASE` together.

## Point the functions at it

Deploy `agent-auth` and `mcp` with `LHF_AGENT_PUBLIC_BASE` set to the same value as `PUBLIC_BASE`, so the issuer and MCP URL they emit are this host's.

## Smoke checks

    curl -s $PUBLIC/.well-known/oauth-protected-resource/functions/v1/mcp
    curl -s $PUBLIC/.well-known/oauth-authorization-server/functions/v1/agent-auth
    curl -s $PUBLIC/.well-known/openid-configuration/functions/v1/agent-auth
    curl -si -X POST $PUBLIC/functions/v1/mcp -d '{}'

(`$PUBLIC` is the host without `/functions/v1`.) The last must answer 401 with a `WWW-Authenticate` header naming this host.
