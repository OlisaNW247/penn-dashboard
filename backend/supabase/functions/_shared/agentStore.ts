// Storage contract for the agent connection: the authorization server
// (`agent-auth`), the MCP server (`mcp`) and the phone's snapshot upload
// (`agent-snapshot`) all read and write through this interface and nothing
// else. Two implementations: `PostgrestAgentStore` (`agentStorePostgrest.ts`,
// the service-role client over the tables in
// `20261108090000_agent_connection.sql`) and `MemoryAgentStore`
// (`agentStoreMemory.ts`), which the Deno tests and the local dev server
// (`backend/scripts/serve-agent.ts`) use, because this Mac has no Supabase
// CLI and the OAuth flow has to be exercised end to end against real
// clients before anything is deployed.
//
// Every "atomic" method below is one statement in the PostgREST
// implementation (`update ... where status = 'pending' returning`), so two
// racing callers cannot both win. The memory store is single-threaded and
// trivially atomic. Dates are ISO 8601 strings on the wire and in rows.

export interface AuthorizeParams {
  /** The CIMD URL (`https://claude.ai/oauth/mcp-oauth-client-metadata`, or
   *  Claude Code's, or ChatGPT's). Exactly as the client sent it. */
  clientId: string;
  /** Exactly the URI the client asked to be sent back to, already matched
   *  against the client's metadata document. */
  redirectUri: string;
  /** PKCE S256 challenge, base64url, 43 characters. */
  codeChallenge: string;
  /** The client's own `state`, echoed back verbatim. */
  state: string | null;
  /** The RFC 8707 resource: must equal the MCP URL. Stored so `token` can
   *  check the second copy against the first. */
  resource: string;
  /** Scopes granted (a subset of `read draft offline_access`). */
  scopes: string[];
}

export type PendingAuthStatus = "pending" | "approved" | "denied" | "consumed";

export interface PendingAuthRow {
  /** 128 random bits, base64url (22 chars): the `c` in `smooth://link?c=…`
   *  and the `p` the page polls with. Never shown to the student as the
   *  typed code. */
  id: string;
  /** The 8-character typed code (RFC 8628 consonant alphabet), for a phone
   *  that cannot scan or tap. Unique among live pending rows. */
  userCode: string;
  /** The two-digit number the page shows and the phone asks the student to
   *  pick from `matchChoices` (QRLJacking defence). */
  matchNumber: number;
  matchChoices: number[];
  /** sha256 of the browser's nonce cookie: `status` only answers a browser
   *  holding the cookie. */
  nonceHash: string;
  params: AuthorizeParams;
  /** Set on approval. */
  userId: string | null;
  /** sha256 of the one-time authorization code; set on approval. */
  authCodeHash: string | null;
  authCodeExpiresAt: string | null;
  /** Host of the client's metadata URL plus its `client_name`, for the page
   *  and the phone to show. */
  clientName: string;
  status: PendingAuthStatus;
  createdAt: string;
  expiresAt: string;
}

export interface AgentConnectionRow {
  id: string;
  userId: string;
  clientId: string;
  clientName: string;
  scopes: string[];
  createdAt: string;
  lastUsedAt: string | null;
  revokedAt: string | null;
}

export interface AgentTokenRow {
  /** sha256 hex of the token string; the primary key. */
  hash: string;
  kind: "access" | "refresh";
  connectionId: string;
  /** The MCP URL the token is good for (its audience). */
  resource: string;
  scopes: string[];
  expiresAt: string;
  /** For a refresh token: the hash of the refresh token it replaced, or
   *  null for the first of its family. */
  rotatedFrom: string | null;
  /** For a refresh token: when it was redeemed. A second presentation of a
   *  redeemed token is reuse, and revokes the whole connection. */
  usedAt: string | null;
  createdAt: string;
}

/** A client registered through RFC 7591 dynamic registration, for SDK-based
 *  clients (MCP Inspector, Claude Code's SDK) that do not use a client
 *  metadata document. Public clients only: there is no secret. */
export interface AgentClientRow {
  /** `smc_` + 22 base64url chars. */
  clientId: string;
  clientName: string;
  redirectUris: string[];
  createdAt: string;
}

export interface AgentSnapshotRow {
  userId: string;
  /** `[{ courseID, code, name, canvasCourseID }]`, validated by `agentSnapshot.ts`. */
  courses: unknown;
  /** `[{ id, course, title, kind, dueAt, done, noSubmission, url, source }]`. */
  workList: unknown;
  /** `[{ id, course, title, dueAt, repeatsWeekly }]`, the student's own tasks. */
  manual: unknown;
  writtenAt: string;
}

export interface AgentStore {
  // Pending authorizations.
  insertPending(row: PendingAuthRow): Promise<void>;
  selectPendingById(id: string): Promise<PendingAuthRow | null>;
  selectPendingByUserCode(userCode: string): Promise<PendingAuthRow | null>;
  /** pending -> approved, binding the student. False when the row was not
   *  `pending` any more (already decided, or raced). The authorization code
   *  is NOT minted here: the phone approves, but only the browser that
   *  started the flow (it holds the nonce cookie) may be handed the code,
   *  so `status?go=1` mints it with `issueAuthCode` below. */
  approvePending(id: string, userId: string): Promise<boolean>;
  /** Records the one-time authorization code on an approved row that has
   *  none yet. False when the row is not `approved` or already has a code,
   *  so one pending authorization yields exactly one code. */
  issueAuthCode(id: string, authCodeHash: string, authCodeExpiresAt: string): Promise<boolean>;
  /** pending -> denied. False when it was not pending. */
  denyPending(id: string): Promise<boolean>;
  /** approved -> consumed by authorization-code hash, returning the row so
   *  `token` can check PKCE, redirect URI, client id and resource. Null
   *  when no approved row has that code (unknown, already consumed, or
   *  the row expired). The caller checks `authCodeExpiresAt` itself. */
  consumeAuthCode(authCodeHash: string): Promise<PendingAuthRow | null>;
  /** Housekeeping: rows past `expiresAt`. Returns how many went. */
  deleteExpiredPending(now: string): Promise<number>;

  // Dynamically registered clients.
  insertClient(row: AgentClientRow): Promise<void>;
  selectClient(clientId: string): Promise<AgentClientRow | null>;

  // Connections.
  insertConnection(row: AgentConnectionRow): Promise<void>;
  selectConnection(id: string): Promise<AgentConnectionRow | null>;
  listConnections(userId: string): Promise<AgentConnectionRow[]>;
  /** Sets `revokedAt` on the student's own connection and deletes every
   *  token of it. False when no live connection of that student has the id. */
  revokeConnection(id: string, userId: string, at: string): Promise<boolean>;
  /** Revokes every connection of the student (Canvas disconnect, account
   *  deletion, opt-out). Returns how many were live. */
  revokeAllConnections(userId: string, at: string): Promise<number>;
  touchConnection(id: string, at: string): Promise<void>;

  // Tokens.
  insertTokens(rows: AgentTokenRow[]): Promise<void>;
  selectToken(hash: string): Promise<AgentTokenRow | null>;
  /** Marks a refresh token redeemed: `usedAt` null -> `at`. False when it
   *  was already redeemed, which is the reuse signal. */
  markRefreshUsed(hash: string, at: string): Promise<boolean>;
  deleteToken(hash: string): Promise<void>;
  deleteTokensForConnection(connectionId: string): Promise<void>;
  deleteExpiredTokens(now: string): Promise<number>;

  // The opted-in student's work list.
  upsertSnapshot(row: AgentSnapshotRow): Promise<void>;
  selectSnapshot(userId: string): Promise<AgentSnapshotRow | null>;
  deleteSnapshot(userId: string): Promise<void>;
}
