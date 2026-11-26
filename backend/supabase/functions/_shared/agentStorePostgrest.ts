// `AgentStore` over PostgREST: the service-role client against the tables in
// `20261108090000_agent_connection.sql`. Behaves exactly like
// `MemoryAgentStore`. Every "atomic" method is a single statement whose
// filter carries the precondition and which returns the rows it changed, so
// the answer is true only when exactly one row moved and two racing callers
// cannot both win. Errors are thrown as the PostgREST error object, as
// `db.ts` does.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import type {
  AgentClientRow,
  AgentConnectionRow,
  AgentSnapshotRow,
  AgentStore,
  AgentTokenRow,
  AuthorizeParams,
  PendingAuthRow,
  PendingAuthStatus,
} from "./agentStore.ts";

// Column mapping, snake_case (database) <-> camelCase (rows).
export function pendingToDb(row: PendingAuthRow): Record<string, unknown> {
  return {
    id: row.id,
    user_code: row.userCode,
    match_number: row.matchNumber,
    match_choices: row.matchChoices,
    nonce_hash: row.nonceHash,
    params: row.params,
    user_id: row.userId,
    auth_code_hash: row.authCodeHash,
    auth_code_expires_at: row.authCodeExpiresAt,
    client_name: row.clientName,
    status: row.status,
    created_at: row.createdAt,
    expires_at: row.expiresAt,
  };
}

export function pendingFromDb(r: Record<string, unknown>): PendingAuthRow {
  return {
    id: r.id as string,
    userCode: r.user_code as string,
    matchNumber: r.match_number as number,
    matchChoices: r.match_choices as number[],
    nonceHash: r.nonce_hash as string,
    params: r.params as AuthorizeParams,
    userId: (r.user_id as string | null) ?? null,
    authCodeHash: (r.auth_code_hash as string | null) ?? null,
    authCodeExpiresAt: (r.auth_code_expires_at as string | null) ?? null,
    clientName: r.client_name as string,
    status: r.status as PendingAuthStatus,
    createdAt: r.created_at as string,
    expiresAt: r.expires_at as string,
    claimedBy: (r.claimed_by as string | null | undefined) ?? null,
  };
}

export function connectionToDb(row: AgentConnectionRow): Record<string, unknown> {
  return {
    id: row.id,
    user_id: row.userId,
    client_id: row.clientId,
    client_name: row.clientName,
    scopes: row.scopes,
    created_at: row.createdAt,
    last_used_at: row.lastUsedAt,
    revoked_at: row.revokedAt,
  };
}

export function connectionFromDb(r: Record<string, unknown>): AgentConnectionRow {
  return {
    id: r.id as string,
    userId: r.user_id as string,
    clientId: r.client_id as string,
    clientName: r.client_name as string,
    scopes: r.scopes as string[],
    createdAt: r.created_at as string,
    lastUsedAt: (r.last_used_at as string | null) ?? null,
    revokedAt: (r.revoked_at as string | null) ?? null,
  };
}

export function tokenToDb(row: AgentTokenRow): Record<string, unknown> {
  return {
    hash: row.hash,
    kind: row.kind,
    connection_id: row.connectionId,
    resource: row.resource,
    scopes: row.scopes,
    expires_at: row.expiresAt,
    rotated_from: row.rotatedFrom,
    used_at: row.usedAt,
    created_at: row.createdAt,
  };
}

export function tokenFromDb(r: Record<string, unknown>): AgentTokenRow {
  return {
    hash: r.hash as string,
    kind: r.kind as "access" | "refresh",
    connectionId: r.connection_id as string,
    resource: r.resource as string,
    scopes: r.scopes as string[],
    expiresAt: r.expires_at as string,
    rotatedFrom: (r.rotated_from as string | null) ?? null,
    usedAt: (r.used_at as string | null) ?? null,
    createdAt: r.created_at as string,
  };
}

export function clientToDb(row: AgentClientRow): Record<string, unknown> {
  return {
    client_id: row.clientId,
    client_name: row.clientName,
    redirect_uris: row.redirectUris,
    created_at: row.createdAt,
  };
}

export function clientFromDb(r: Record<string, unknown>): AgentClientRow {
  return {
    clientId: r.client_id as string,
    clientName: r.client_name as string,
    redirectUris: r.redirect_uris as string[],
    createdAt: r.created_at as string,
  };
}

export function snapshotToDb(row: AgentSnapshotRow): Record<string, unknown> {
  return {
    user_id: row.userId,
    courses: row.courses,
    work_list: row.workList,
    manual: row.manual,
    written_at: row.writtenAt,
  };
}

export function snapshotFromDb(r: Record<string, unknown>): AgentSnapshotRow {
  return {
    userId: r.user_id as string,
    courses: r.courses,
    workList: r.work_list,
    manual: r.manual,
    writtenAt: r.written_at as string,
  };
}

type Rows = Record<string, unknown>[];

export class PostgrestAgentStore implements AgentStore {
  constructor(private readonly client: SupabaseClient) {}

  // Pending authorizations.
  async insertPending(row: PendingAuthRow): Promise<void> {
    const { error } = await this.client.from("agent_pending_auth").insert(pendingToDb(row));
    if (error) throw error;
  }

  async selectPendingById(id: string): Promise<PendingAuthRow | null> {
    const { data, error } = await this.client.from("agent_pending_auth").select("*").eq("id", id).maybeSingle();
    if (error) throw error;
    return data ? pendingFromDb(data as Record<string, unknown>) : null;
  }

  async selectPendingByUserCode(userCode: string): Promise<PendingAuthRow | null> {
    const { data, error } = await this.client
      .from("agent_pending_auth")
      .select("*")
      .eq("user_code", userCode)
      .eq("status", "pending")
      .maybeSingle();
    if (error) throw error;
    return data ? pendingFromDb(data as Record<string, unknown>) : null;
  }

  async approvePending(id: string, userId: string): Promise<boolean> {
    const { data, error } = await this.client
      .from("agent_pending_auth")
      .update({ status: "approved", user_id: userId })
      .eq("id", id)
      .eq("status", "pending")
      .select("id");
    if (error) throw error;
    return ((data ?? []) as Rows).length === 1;
  }

  async issueAuthCode(id: string, authCodeHash: string, authCodeExpiresAt: string): Promise<boolean> {
    const { data, error } = await this.client
      .from("agent_pending_auth")
      .update({ auth_code_hash: authCodeHash, auth_code_expires_at: authCodeExpiresAt })
      .eq("id", id)
      .eq("status", "approved")
      .is("auth_code_hash", null)
      .select("id");
    if (error) throw error;
    return ((data ?? []) as Rows).length === 1;
  }

  async claimPending(id: string, userId: string): Promise<boolean> {
    const { data, error } = await this.client
      .from("agent_pending_auth")
      .update({ claimed_by: userId })
      .eq("id", id)
      .eq("status", "pending")
      .select("id");
    if (error) throw error;
    return ((data ?? []) as Rows).length === 1;
  }

  async denyPending(id: string): Promise<boolean> {
    const { data, error } = await this.client
      .from("agent_pending_auth")
      .update({ status: "denied" })
      .eq("id", id)
      .eq("status", "pending")
      .select("id");
    if (error) throw error;
    return ((data ?? []) as Rows).length === 1;
  }

  async consumeAuthCode(authCodeHash: string): Promise<PendingAuthRow | null> {
    const { data, error } = await this.client
      .from("agent_pending_auth")
      .update({ status: "consumed" })
      .eq("auth_code_hash", authCodeHash)
      .eq("status", "approved")
      .select("*");
    if (error) throw error;
    const rows = (data ?? []) as Rows;
    return rows.length === 1 ? pendingFromDb(rows[0]) : null;
  }

  async deleteExpiredPending(now: string): Promise<number> {
    const { data, error } = await this.client.from("agent_pending_auth").delete().lte("expires_at", now).select("id");
    if (error) throw error;
    return ((data ?? []) as Rows).length;
  }

  // Dynamically registered clients.
  async insertClient(row: AgentClientRow): Promise<void> {
    const { error } = await this.client.from("agent_clients").insert(clientToDb(row));
    if (error) throw error;
  }

  async selectClient(clientId: string): Promise<AgentClientRow | null> {
    const { data, error } = await this.client.from("agent_clients").select("*").eq("client_id", clientId).maybeSingle();
    if (error) throw error;
    return data ? clientFromDb(data as Record<string, unknown>) : null;
  }

  // Connections.
  async insertConnection(row: AgentConnectionRow): Promise<void> {
    const { error } = await this.client.from("agent_connections").insert(connectionToDb(row));
    if (error) throw error;
  }

  async selectConnection(id: string): Promise<AgentConnectionRow | null> {
    const { data, error } = await this.client.from("agent_connections").select("*").eq("id", id).maybeSingle();
    if (error) throw error;
    return data ? connectionFromDb(data as Record<string, unknown>) : null;
  }

  async listConnections(userId: string): Promise<AgentConnectionRow[]> {
    const { data, error } = await this.client
      .from("agent_connections")
      .select("*")
      .eq("user_id", userId)
      .order("created_at", { ascending: true });
    if (error) throw error;
    return ((data ?? []) as Rows).map(connectionFromDb);
  }

  async revokeConnection(id: string, userId: string, at: string): Promise<boolean> {
    const { data, error } = await this.client
      .from("agent_connections")
      .update({ revoked_at: at })
      .eq("id", id)
      .eq("user_id", userId)
      .is("revoked_at", null)
      .select("id");
    if (error) throw error;
    if (((data ?? []) as Rows).length !== 1) return false;
    await this.deleteTokensForConnection(id);
    return true;
  }

  async revokeAllConnections(userId: string, at: string): Promise<number> {
    const { data, error } = await this.client
      .from("agent_connections")
      .update({ revoked_at: at })
      .eq("user_id", userId)
      .is("revoked_at", null)
      .select("id");
    if (error) throw error;
    const ids = ((data ?? []) as Rows).map((r) => r.id as string);
    if (ids.length > 0) {
      const { error: tokensError } = await this.client.from("agent_tokens").delete().in("connection_id", ids);
      if (tokensError) throw tokensError;
    }
    return ids.length;
  }

  async touchConnection(id: string, at: string): Promise<void> {
    const { error } = await this.client.from("agent_connections").update({ last_used_at: at }).eq("id", id);
    if (error) throw error;
  }

  // Tokens.
  async insertTokens(rows: AgentTokenRow[]): Promise<void> {
    if (rows.length === 0) return;
    const { error } = await this.client.from("agent_tokens").insert(rows.map(tokenToDb));
    if (error) throw error;
  }

  async selectToken(hash: string): Promise<AgentTokenRow | null> {
    const { data, error } = await this.client.from("agent_tokens").select("*").eq("hash", hash).maybeSingle();
    if (error) throw error;
    return data ? tokenFromDb(data as Record<string, unknown>) : null;
  }

  async markRefreshUsed(hash: string, at: string): Promise<boolean> {
    const { data, error } = await this.client
      .from("agent_tokens")
      .update({ used_at: at })
      .eq("hash", hash)
      .eq("kind", "refresh")
      .is("used_at", null)
      .select("hash");
    if (error) throw error;
    return ((data ?? []) as Rows).length === 1;
  }

  async deleteToken(hash: string): Promise<void> {
    const { error } = await this.client.from("agent_tokens").delete().eq("hash", hash);
    if (error) throw error;
  }

  async deleteTokensForConnection(connectionId: string): Promise<void> {
    const { error } = await this.client.from("agent_tokens").delete().eq("connection_id", connectionId);
    if (error) throw error;
  }

  async deleteExpiredTokens(now: string): Promise<number> {
    const { data, error } = await this.client.from("agent_tokens").delete().lte("expires_at", now).select("hash");
    if (error) throw error;
    return ((data ?? []) as Rows).length;
  }

  // Abuse limits and housekeeping: the SQL functions of
  // 20261109090000_agent_hardening.sql, service role only.
  async rateCheck(key: string, limit: number, windowSeconds: number): Promise<boolean> {
    const { data, error } = await this.client.rpc("agent_rate_check", {
      p_key: key,
      p_limit: limit,
      p_window_seconds: windowSeconds,
    });
    if (error) throw error;
    return data === true;
  }

  async sweep(): Promise<number> {
    const { data, error } = await this.client.rpc("agent_sweep_expired");
    if (error) throw error;
    return typeof data === "number" ? data : 0;
  }

  // Snapshots.
  async upsertSnapshot(row: AgentSnapshotRow): Promise<void> {
    const { error } = await this.client.from("agent_snapshots").upsert(snapshotToDb(row), { onConflict: "user_id" });
    if (error) throw error;
  }

  async selectSnapshot(userId: string): Promise<AgentSnapshotRow | null> {
    const { data, error } = await this.client.from("agent_snapshots").select("*").eq("user_id", userId).maybeSingle();
    if (error) throw error;
    return data ? snapshotFromDb(data as Record<string, unknown>) : null;
  }

  async deleteSnapshot(userId: string): Promise<void> {
    const { error } = await this.client.from("agent_snapshots").delete().eq("user_id", userId);
    if (error) throw error;
  }
}
