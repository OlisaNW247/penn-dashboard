// Local dev server for the agent connection: `mcp` over the fixture backend
// and an in-memory store, reachable through a tunnel so claude.ai, Claude
// Code or MCP Inspector can connect before anything is deployed.
//
//   LHF_AGENT_PUBLIC_BASE=https://xyz.ngrok.app/functions/v1 \
//     deno run --allow-net --allow-env --allow-read scripts/serve-agent.ts
//
// `/dev/token` mints a connection and access token without the OAuth flow,
// so curl can call tools directly. Dev only: nothing here is deployed.
import { handleMcp, type McpDeps } from "../supabase/functions/mcp/index.ts";
import { handleAgentAuth, type AgentAuthDeps } from "../supabase/functions/agent-auth/index.ts";
import { HttpError } from "../supabase/functions/_shared/http.ts";
import { MemoryAgentStore } from "../supabase/functions/_shared/agentStoreMemory.ts";
import { FixtureToolBackend } from "../supabase/functions/_shared/agentTools.ts";
import { generateToken, hashToken } from "../supabase/functions/_shared/agentTokens.ts";
import { authorizationServerMetadata, mcpURL, protectedResourceMetadata } from "../supabase/functions/_shared/agentMetadata.ts";

const publicBase = Deno.env.get("LHF_AGENT_PUBLIC_BASE")?.trim().replace(/\/$/, "");
if (!publicBase) {
  console.error("LHF_AGENT_PUBLIC_BASE is required, e.g. https://xyz.ngrok.app/functions/v1");
  Deno.exit(1);
}
const hint = Deno.env.get("LHF_MCP_PROPOSE_HINT");

const store = new MemoryAgentStore();
const deps: McpDeps = {
  store,
  backend: new FixtureToolBackend(),
  publicBase,
  proposeHint: hint === "none" || hint === "true" ? hint : "false",
};

const DEV_USER = "dev-user";

// The authorization server over the same store. The phone is stood in for by
// a header (`Authorization: Bearer dev-<user>`) and the authorize page gets
// an "approve (dev)" link to `/dev/approve`, so the whole OAuth flow can be
// driven from one browser with no phone. Client metadata is fetched for real
// (claude.ai's document is public), with no address guard: this is a dev
// box, not the function.
const authDeps: AgentAuthDeps = {
  store,
  publicBase,
  fetchClientMetadata: async (url) => {
    const res = await fetch(url, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error(`client metadata ${res.status}`);
    return await res.json();
  },
  requireUserId: (req) => {
    const m = /^Bearer dev-(\S+)$/.exec(req.headers.get("authorization") ?? "");
    if (!m) return Promise.reject(new HttpError(401, "unauthorized"));
    return Promise.resolve(m[1]);
  },
  devApproveURL: (id) => `${new URL(publicBase).origin}/dev/approve?p=${encodeURIComponent(id)}`,
};

async function mintDevToken(): Promise<Response> {
  const now = new Date();
  const connectionId = crypto.randomUUID();
  const token = generateToken("access");
  const scopes = ["read", "draft", "offline_access"];
  await store.insertConnection({
    id: connectionId,
    userId: DEV_USER,
    clientId: "dev",
    clientName: "dev token",
    scopes,
    createdAt: now.toISOString(),
    lastUsedAt: null,
    revokedAt: null,
  });
  await store.insertTokens([{
    hash: await hashToken(token),
    kind: "access",
    connectionId,
    resource: mcpURL(publicBase!),
    scopes,
    expiresAt: new Date(now.getTime() + 12 * 3_600_000).toISOString(),
    rotatedFrom: null,
    usedAt: null,
    createdAt: now.toISOString(),
  }]);
  console.log(`dev access token: ${token}`);
  return Response.json({ access_token: token, token_type: "Bearer", expires_in: 12 * 3600, scope: scopes.join(" ") });
}

// Root-path discovery (RFC 9728 §3.1 / RFC 8414 §3.1 "path insertion"):
// `/.well-known/oauth-protected-resource/functions/v1/mcp` and
// `/.well-known/oauth-authorization-server/functions/v1/agent-auth`. Seen on
// 2026-11-08: Claude Code's sign-in step probes ONLY these root forms (and a
// root `/register`), never the path-appended ones the function can serve on
// supabase.co, so production needs a host whose root we control in front of
// the two functions. The dev tunnel is such a host; this is what that front
// has to answer.
function wellKnown(path: string): Response | null {
  const json = (body: unknown) => Response.json(body, { headers: { "Cache-Control": "public, max-age=300", "Access-Control-Allow-Origin": "*" } });
  if (/^\/\.well-known\/oauth-protected-resource(\/functions\/v1\/mcp)?\/?$/.test(path)) return json(protectedResourceMetadata(publicBase!));
  if (/^\/\.well-known\/(oauth-authorization-server|openid-configuration)(\/functions\/v1\/agent-auth)?\/?$/.test(path)) {
    return json(authorizationServerMetadata(publicBase!));
  }
  return null;
}

async function route(req: Request, path: string): Promise<Response> {
  const known = wellKnown(path);
  if (known) return known;
  if (path.startsWith("/functions/v1/mcp")) return handleMcp(req, deps);

  if (path.startsWith("/functions/v1/agent-auth")) return handleAgentAuth(req, authDeps);

  if (path === "/dev/token" && req.method === "GET") return mintDevToken();

  if (path === "/dev/approve" && req.method === "GET") {
    const id = new URL(req.url).searchParams.get("p") ?? "";
    const ok = await store.approvePending(id, DEV_USER);
    return new Response(ok ? "<p>approved</p>" : "<p>nothing to approve</p>", {
      status: ok ? 200 : 404,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  }

  return Response.json({ error: "not_found" }, { status: 404 });
}

Deno.serve({ hostname: "127.0.0.1", port: 8787 }, async (req) => {
  const path = new URL(req.url).pathname;
  let res: Response;
  try {
    res = await route(req, path);
  } catch (err) {
    console.error("serve-agent error:", err instanceof Error ? err.constructor.name : typeof err);
    res = Response.json({ error: "internal_error" }, { status: 500 });
  }
  console.log(`${req.method} ${path} ${res.status}`);
  return res;
});
