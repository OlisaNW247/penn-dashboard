// The `mcp` edge function: the remote MCP server a student's agent (Claude
// first) connects to. It serves their work list and the pooled course
// material behind an opaque bearer token minted by `agent-auth`; the tools
// are in `_shared/agentTools.ts`, the token rules in `_shared/agentTokens.ts`
// and the discovery documents in `_shared/agentMetadata.ts` (research §2, §3).
//
// The SDK's handler verifies nothing: `authInfo` is passed through to the
// tools untouched. So the bearer check is done here, by hand, in front of
// it. Every refusal that is about the token itself answers with the same
// words, so a response never says which of "unknown", "wrong audience",
// "expired" or "connection revoked" it was.
//
// `legacy: "stateless"` serves the 2025-era clients Claude is today without
// sessions (GET and DELETE answer 405, no `Mcp-Session-Id` is ever minted),
// and the 2026-07-28 per-request envelope too.
//
// Never logs tokens, user ids or request bodies: an unexpected failure
// logs its error class and nothing else.
import { createMcpHandler, McpServer } from "npm:@modelcontextprotocol/server@2.4.0";
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { corsHeaders, json } from "../_shared/http.ts";
import type { AgentStore } from "../_shared/agentStore.ts";
import { PostgrestAgentStore } from "../_shared/agentStorePostgrest.ts";
import { hashToken, looksLikeToken, parseBearer, tokenKindOf } from "../_shared/agentTokens.ts";
import { bearerChallenge, mcpURL, protectedResourceMetadata, publicBaseFromEnv } from "../_shared/agentMetadata.ts";
import { registerTools, type ToolBackend } from "../_shared/agentTools.ts";
import { PostgrestToolBackend } from "../_shared/agentToolsPostgrest.ts";

export interface McpDeps {
  store: AgentStore;
  backend: ToolBackend;
  /** Origin plus `/functions/v1`. */
  publicBase: string;
  now?: () => Date;
  proposeHint?: "none" | "false" | "true";
}

const mcpCors: Record<string, string> = {
  ...corsHeaders,
  "Access-Control-Allow-Headers": `${corsHeaders["Access-Control-Allow-Headers"]}, mcp-protocol-version, mcp-method, mcp-name, accept`,
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Expose-Headers": "WWW-Authenticate",
};

const TOKEN_REFUSED = "token is not valid for this server";

// One SDK handler per deps object, so production builds it once. The
// factory still builds a fresh server per request and captures nothing of
// any request: tools read the principal from `authInfo` on each call.
const handlers = new WeakMap<McpDeps, ReturnType<typeof createMcpHandler>>();

function handlerFor(deps: McpDeps): ReturnType<typeof createMcpHandler> {
  let handler = handlers.get(deps);
  if (!handler) {
    handler = createMcpHandler(() => {
      const server = new McpServer({ name: "smooth", version: "0.1.0" });
      registerTools(server, deps.backend, {
        proposeHint: deps.proposeHint ?? "false",
        now: deps.now ?? (() => new Date()),
      });
      return server;
    }, {
      legacy: "stateless",
      onerror: (e) => console.error("mcp handler error:", e.message),
    });
    handlers.set(deps, handler);
  }
  return handler;
}

export async function handleMcp(req: Request, deps: McpDeps): Promise<Response> {
  try {
    return await route(req, deps);
  } catch (err) {
    console.error("mcp internal error:", err instanceof Error ? err.constructor.name : typeof err);
    return json(500, { error: "internal_error" }, mcpCors);
  }
}

async function route(req: Request, deps: McpDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: mcpCors });

  // The path after the `mcp` segment: "" or "/" is the endpoint itself.
  const rest = /(?:^|\/)mcp(\/.*)?$/.exec(new URL(req.url).pathname)?.[1] ?? "";
  const publicBase = deps.publicBase;

  if (req.method === "GET" && (rest === "/oauth-protected-resource" || rest === "/.well-known/oauth-protected-resource")) {
    return json(200, protectedResourceMetadata(publicBase), { ...mcpCors, "Cache-Control": "public, max-age=300" });
  }
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" }, { ...mcpCors, Allow: "POST" });
  }
  if (rest !== "" && rest !== "/") return json(404, { error: "not_found" }, mcpCors);

  // Loose on purpose: Claude's egress is a published range and a host list
  // here would turn into initialize timeouts. A browser page on plain http
  // or an opaque origin has no business here.
  const origin = req.headers.get("origin");
  if (origin !== null && !origin.startsWith("https://")) return json(403, { error: "forbidden_origin" }, mcpCors);

  const refuse = (error?: "invalid_token", description?: string) =>
    json(401, { error: error ?? "unauthorized" }, {
      ...mcpCors,
      "WWW-Authenticate": bearerChallenge(publicBase, error, description),
    });

  const token = parseBearer(req.headers.get("authorization"));
  if (token === null) return refuse();
  if (!looksLikeToken(token) || tokenKindOf(token) !== "access") return refuse("invalid_token", TOKEN_REFUSED);

  const now = (deps.now ?? (() => new Date()))();
  const row = await deps.store.selectToken(await hashToken(token));
  if (!row || row.kind !== "access" || Date.parse(row.expiresAt) <= now.getTime() || row.resource !== mcpURL(publicBase)) {
    return refuse("invalid_token", TOKEN_REFUSED);
  }
  const connection = await deps.store.selectConnection(row.connectionId);
  if (!connection || connection.revokedAt !== null) return refuse("invalid_token", TOKEN_REFUSED);

  if (!row.scopes.includes("read")) {
    return json(403, { error: "insufficient_scope" }, {
      ...mcpCors,
      "WWW-Authenticate": bearerChallenge(publicBase, "insufficient_scope"),
    });
  }

  await deps.store.touchConnection(connection.id, now.toISOString());

  const response = await handlerFor(deps).fetch(req, {
    authInfo: {
      token,
      clientId: connection.clientId,
      scopes: row.scopes,
      expiresAt: Math.floor(Date.parse(row.expiresAt) / 1000),
      resource: new URL(mcpURL(publicBase)),
      extra: { userId: connection.userId, connectionId: connection.id, clientName: connection.clientName },
    },
  });

  // The SDK's response headers may be immutable; rebuild with CORS added.
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(mcpCors)) if (!headers.has(name)) headers.set(name, value);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

let cachedDeps: McpDeps | null = null;

function productionDeps(): McpDeps {
  if (cachedDeps) return cachedDeps;
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
  const hint = Deno.env.get("LHF_MCP_PROPOSE_HINT");
  const client = createClient(url, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const store = new PostgrestAgentStore(client);
  cachedDeps = {
    store,
    publicBase: publicBaseFromEnv(),
    proposeHint: hint === "none" || hint === "true" ? hint : "false",
    backend: new PostgrestToolBackend({ client, store }),
  };
  return cachedDeps;
}

if (import.meta.main) Deno.serve((req) => handleMcp(req, productionDeps()));
