// The two OAuth discovery documents the agent connection publishes
// (research §3): the authorization server metadata (RFC 8414) served by
// `agent-auth`, and the protected resource metadata (RFC 9728) served by
// `mcp`. One file so the two can never disagree on the issuer or the MCP
// URL, which the clients compare exactly.
//
// `publicBase` is the origin plus `/functions/v1`: in production
// `https://<ref>.supabase.co/functions/v1`, on the dev tunnel
// `https://<name>.ngrok.app/functions/v1`. It comes from the function
// secret `LHF_AGENT_PUBLIC_BASE` when set and otherwise from `SUPABASE_URL`,
// because a function cannot trust the `Host` it is called with for a value
// that ends up inside signed-off metadata.

export const AGENT_SCOPES = ["read", "draft", "offline_access"] as const;
export type AgentScope = (typeof AGENT_SCOPES)[number];

/** The scopes a client is told to ask for. `offline_access` is what makes
 *  Claude request a refresh token (research §3). */
export const DEFAULT_SCOPE = "read draft offline_access";

export function issuerURL(publicBase: string): string {
  return `${trimSlash(publicBase)}/agent-auth`;
}

export function mcpURL(publicBase: string): string {
  return `${trimSlash(publicBase)}/mcp`;
}

export function protectedResourceMetadataURL(publicBase: string): string {
  return `${mcpURL(publicBase)}/oauth-protected-resource`;
}

export function publicBaseFromEnv(env: { get(name: string): string | undefined } = Deno.env): string {
  const explicit = env.get("LHF_AGENT_PUBLIC_BASE")?.trim();
  if (explicit) return trimSlash(explicit);
  const supabase = env.get("SUPABASE_URL")?.trim();
  if (!supabase) throw new Error("neither LHF_AGENT_PUBLIC_BASE nor SUPABASE_URL is set");
  return `${trimSlash(supabase)}/functions/v1`;
}

/** RFC 8414 document. `client_id_metadata_document_supported` plus `none`
 *  in the token auth methods is what makes Claude use CIMD instead of
 *  dynamic registration; `authorization_response_iss_parameter_supported`
 *  is what ChatGPT requires before it will use its redirect URI. No
 *  `registration_endpoint`: DCR is deliberately absent until a client
 *  that cannot do CIMD turns up (Phase 0 answers that). */
export function authorizationServerMetadata(publicBase: string): Record<string, unknown> {
  const issuer = issuerURL(publicBase);
  return {
    issuer,
    authorization_endpoint: `${issuer}/authorize`,
    token_endpoint: `${issuer}/token`,
    revocation_endpoint: `${issuer}/revoke`,
    registration_endpoint: `${issuer}/register`,
    response_types_supported: ["code"],
    response_modes_supported: ["query"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    revocation_endpoint_auth_methods_supported: ["none"],
    scopes_supported: [...AGENT_SCOPES],
    client_id_metadata_document_supported: true,
    authorization_response_iss_parameter_supported: true,
    service_documentation: "https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md",
  };
}

/** RFC 9728 document. `resource` must equal the MCP URL byte for byte, and
 *  only the first `authorization_servers` entry is read by Claude. */
export function protectedResourceMetadata(publicBase: string): Record<string, unknown> {
  return {
    resource: mcpURL(publicBase),
    authorization_servers: [issuerURL(publicBase)],
    scopes_supported: [...AGENT_SCOPES],
    bearer_methods_supported: ["header"],
    resource_name: "Smooth",
    resource_documentation: "https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md",
  };
}

/** The `WWW-Authenticate` value for a request without a usable token. The
 *  `resource_metadata` URL is the only way Claude finds the authorization
 *  server (it ignores the header on a 200), and `scope` tells it what to
 *  ask for. `error` is set only when a token was presented and refused. */
export function bearerChallenge(publicBase: string, error?: "invalid_token" | "insufficient_scope", description?: string): string {
  const parts = [`resource_metadata="${protectedResourceMetadataURL(publicBase)}"`, `scope="read draft"`];
  if (error) parts.unshift(`error="${error}"`);
  if (description) parts.push(`error_description="${description.replaceAll('"', "'")}"`);
  return `Bearer ${parts.join(", ")}`;
}

function trimSlash(value: string): string {
  return value.endsWith("/") ? value.slice(0, -1) : value;
}
