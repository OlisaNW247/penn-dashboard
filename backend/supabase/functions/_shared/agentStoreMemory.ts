// In-memory `AgentStore` for the Deno tests and the local dev server
// (`backend/scripts/serve-agent.ts`). It is deliberately the dumbest possible
// implementation of `agentStore.ts`: arrays and maps, every rule spelled out,
// so a handler test that passes here is a test of the handler and not of a
// clever mock. Nothing in production imports it; `mcp` and `agent-auth`
// take their store as a dependency and the `index.ts` entry points hand them
// `PostgrestAgentStore`.
import type {
  AgentClientRow,
  AgentConnectionRow,
  AgentSnapshotRow,
  AgentStore,
  AgentTokenRow,
  PendingAuthRow,
} from "./agentStore.ts";

export class MemoryAgentStore implements AgentStore {
  pending = new Map<string, PendingAuthRow>();
  connections = new Map<string, AgentConnectionRow>();
  tokens = new Map<string, AgentTokenRow>();
  snapshots = new Map<string, AgentSnapshotRow>();
  clients = new Map<string, AgentClientRow>();

  // Dynamically registered clients.
  insertClient(row: AgentClientRow): Promise<void> {
    if (this.clients.has(row.clientId)) return Promise.reject(new Error("duplicate client id"));
    this.clients.set(row.clientId, { ...row, redirectUris: [...row.redirectUris] });
    return Promise.resolve();
  }

  selectClient(clientId: string): Promise<AgentClientRow | null> {
    return Promise.resolve(this.clients.get(clientId) ?? null);
  }

  // Pending authorizations.
  insertPending(row: PendingAuthRow): Promise<void> {
    if (this.pending.has(row.id)) return Promise.reject(new Error("duplicate pending id"));
    for (const other of this.pending.values()) {
      if (other.userCode === row.userCode && other.status === "pending") {
        return Promise.reject(new Error("duplicate user code"));
      }
    }
    this.pending.set(row.id, { ...row, params: { ...row.params, scopes: [...row.params.scopes] } });
    return Promise.resolve();
  }

  selectPendingById(id: string): Promise<PendingAuthRow | null> {
    return Promise.resolve(this.pending.get(id) ?? null);
  }

  selectPendingByUserCode(userCode: string): Promise<PendingAuthRow | null> {
    for (const row of this.pending.values()) {
      if (row.userCode === userCode && row.status === "pending") return Promise.resolve(row);
    }
    return Promise.resolve(null);
  }

  approvePending(id: string, userId: string): Promise<boolean> {
    const row = this.pending.get(id);
    if (!row || row.status !== "pending") return Promise.resolve(false);
    this.pending.set(id, { ...row, status: "approved", userId });
    return Promise.resolve(true);
  }

  issueAuthCode(id: string, authCodeHash: string, authCodeExpiresAt: string): Promise<boolean> {
    const row = this.pending.get(id);
    if (!row || row.status !== "approved" || row.authCodeHash !== null) return Promise.resolve(false);
    this.pending.set(id, { ...row, authCodeHash, authCodeExpiresAt });
    return Promise.resolve(true);
  }

  denyPending(id: string): Promise<boolean> {
    const row = this.pending.get(id);
    if (!row || row.status !== "pending") return Promise.resolve(false);
    this.pending.set(id, { ...row, status: "denied" });
    return Promise.resolve(true);
  }

  consumeAuthCode(authCodeHash: string): Promise<PendingAuthRow | null> {
    for (const [id, row] of this.pending) {
      if (row.status === "approved" && row.authCodeHash === authCodeHash) {
        const consumed = { ...row, status: "consumed" as const };
        this.pending.set(id, consumed);
        return Promise.resolve(consumed);
      }
    }
    return Promise.resolve(null);
  }

  deleteExpiredPending(now: string): Promise<number> {
    const cutoff = Date.parse(now);
    let n = 0;
    for (const [id, row] of this.pending) {
      if (Date.parse(row.expiresAt) <= cutoff) {
        this.pending.delete(id);
        n++;
      }
    }
    return Promise.resolve(n);
  }

  // Connections.
  insertConnection(row: AgentConnectionRow): Promise<void> {
    if (this.connections.has(row.id)) return Promise.reject(new Error("duplicate connection id"));
    this.connections.set(row.id, { ...row, scopes: [...row.scopes] });
    return Promise.resolve();
  }

  selectConnection(id: string): Promise<AgentConnectionRow | null> {
    return Promise.resolve(this.connections.get(id) ?? null);
  }

  listConnections(userId: string): Promise<AgentConnectionRow[]> {
    return Promise.resolve(
      [...this.connections.values()]
        .filter((c) => c.userId === userId)
        .sort((a, b) => a.createdAt.localeCompare(b.createdAt)),
    );
  }

  async revokeConnection(id: string, userId: string, at: string): Promise<boolean> {
    const row = this.connections.get(id);
    if (!row || row.userId !== userId || row.revokedAt !== null) return false;
    this.connections.set(id, { ...row, revokedAt: at });
    await this.deleteTokensForConnection(id);
    return true;
  }

  async revokeAllConnections(userId: string, at: string): Promise<number> {
    let n = 0;
    for (const row of [...this.connections.values()]) {
      if (row.userId === userId && row.revokedAt === null && await this.revokeConnection(row.id, userId, at)) n++;
    }
    return n;
  }

  touchConnection(id: string, at: string): Promise<void> {
    const row = this.connections.get(id);
    if (row) this.connections.set(id, { ...row, lastUsedAt: at });
    return Promise.resolve();
  }

  // Tokens.
  insertTokens(rows: AgentTokenRow[]): Promise<void> {
    for (const row of rows) {
      if (this.tokens.has(row.hash)) return Promise.reject(new Error("duplicate token hash"));
    }
    for (const row of rows) this.tokens.set(row.hash, { ...row, scopes: [...row.scopes] });
    return Promise.resolve();
  }

  selectToken(hash: string): Promise<AgentTokenRow | null> {
    return Promise.resolve(this.tokens.get(hash) ?? null);
  }

  markRefreshUsed(hash: string, at: string): Promise<boolean> {
    const row = this.tokens.get(hash);
    if (!row || row.kind !== "refresh" || row.usedAt !== null) return Promise.resolve(false);
    this.tokens.set(hash, { ...row, usedAt: at });
    return Promise.resolve(true);
  }

  deleteToken(hash: string): Promise<void> {
    this.tokens.delete(hash);
    return Promise.resolve();
  }

  deleteTokensForConnection(connectionId: string): Promise<void> {
    for (const [hash, row] of this.tokens) {
      if (row.connectionId === connectionId) this.tokens.delete(hash);
    }
    return Promise.resolve();
  }

  deleteExpiredTokens(now: string): Promise<number> {
    const cutoff = Date.parse(now);
    let n = 0;
    for (const [hash, row] of this.tokens) {
      if (Date.parse(row.expiresAt) <= cutoff) {
        this.tokens.delete(hash);
        n++;
      }
    }
    return Promise.resolve(n);
  }

  // Snapshots.
  upsertSnapshot(row: AgentSnapshotRow): Promise<void> {
    this.snapshots.set(row.userId, row);
    return Promise.resolve();
  }

  selectSnapshot(userId: string): Promise<AgentSnapshotRow | null> {
    return Promise.resolve(this.snapshots.get(userId) ?? null);
  }

  deleteSnapshot(userId: string): Promise<void> {
    this.snapshots.delete(userId);
    return Promise.resolve();
  }
}
