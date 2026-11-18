// The Sweeper wake's rules (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md §1.1,
// §3): what a phone may upload, the store behind it, and the once-a-minute
// tick that turns a due minute into a silent push. Pure of Deno and of the
// network except through its parameters, so every rule runs under test.
//
// What the server may know about a student here is a device token and a list
// of minutes. `validateWakeBody` refuses every other key rather than
// trimming it (the rule `agent-snapshot` applies), so a client that starts
// sending an assignment id shows up as a counted 400 instead of a quiet leak.
// Nothing in this file logs a token, a user id or a moment.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import type { ApnsEnvironment, ApnsResult } from "./apns.ts";

export const MAX_MOMENTS = 24;
export const HORIZON_MS = 48 * 60 * 60 * 1000;
export const MINUTE_MS = 60 * 1000;
/** Moments older than this are dropped from a row the tick has just claimed. */
export const PRUNE_AFTER_MS = 5 * MINUTE_MS;
/** A row whose pushes keep failing is deleted at this many failures; the phone's next upload recreates it. */
export const MAX_FAILURES = 3;
export const CLAIM_LIMIT = 2000;

const ALLOWED_KEYS = new Set(["action", "token", "environment", "moments", "plan"]);

export interface WakeValue {
  token: string;
  environment: ApnsEnvironment;
  /** Whole minutes, ascending, no duplicates, all in (now, now + 48 h]. */
  moments: Date[];
  planHash?: string;
}

export type WakeValidation = { ok: true; value: WakeValue } | { ok: false; reason: string };

const truncateToMinute = (ms: number): number => Math.floor(ms / MINUTE_MS) * MINUTE_MS;

export function validateWakeBody(body: unknown, now: Date): WakeValidation {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { ok: false, reason: "invalid_body" };
  const b = body as Record<string, unknown>;
  for (const key of Object.keys(b)) if (!ALLOWED_KEYS.has(key)) return { ok: false, reason: "forbidden_field" };

  if (typeof b.token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(b.token)) return { ok: false, reason: "invalid_token" };
  const token = b.token.toLowerCase();

  if (b.environment !== "production" && b.environment !== "development") return { ok: false, reason: "invalid_environment" };
  const environment = b.environment;

  if (!Array.isArray(b.moments)) return { ok: false, reason: "invalid_moments" };
  if (b.moments.length > MAX_MOMENTS) return { ok: false, reason: "too_many_moments" };

  const nowMs = now.getTime();
  const seen = new Set<number>();
  for (const raw of b.moments) {
    if (typeof raw !== "string") return { ok: false, reason: "invalid_moment" };
    const parsed = Date.parse(raw);
    if (Number.isNaN(parsed)) return { ok: false, reason: "invalid_moment" };
    const minute = truncateToMinute(parsed);
    // Past moments are dropped without complaint: a phone that computed a
    // list a minute ago is not at fault when its first entry has passed.
    if (minute <= nowMs) continue;
    if (minute > nowMs + HORIZON_MS) return { ok: false, reason: "moment_beyond_horizon" };
    seen.add(minute);
  }
  const moments = [...seen].sort((a, b2) => a - b2).map((ms) => new Date(ms));

  let planHash: string | undefined;
  if (b.plan !== undefined && b.plan !== null) {
    if (typeof b.plan !== "string" || !/^[0-9a-fA-F]{16}$/.test(b.plan)) return { ok: false, reason: "invalid_plan" };
    planHash = b.plan.toLowerCase();
  }
  return { ok: true, value: { token, environment, moments, ...(planHash ? { planHash } : {}) } };
}

// ---- the store ---------------------------------------------------------

export interface WakeRow {
  token: string;
  userId: string;
  environment: ApnsEnvironment;
  moments: Date[];
  planHash?: string;
}

export interface ClaimedRow {
  token: string;
  environment: ApnsEnvironment;
  userId: string;
}

export interface SweeperWakeStore {
  /** Inserts the row for a token, or replaces its owner, environment, moments and plan
   *  (a token that moves to another anonymous account follows the new owner).
   *  The failure count starts again: an upload shows the token is alive. */
  upsert(row: WakeRow): Promise<void>;
  deleteForUser(userId: string): Promise<number>;
  /** Rows with a moment at `minute` that have not been claimed for it or a later minute,
   *  claimed in the same operation, at most `limit`. */
  claim(minute: Date, limit: number): Promise<ClaimedRow[]>;
  /** Counts one more failed send and answers the new total. */
  markFailure(token: string): Promise<number>;
  deleteToken(token: string): Promise<void>;
  /** Removes moments earlier than `before` from the named rows. */
  pruneMoments(before: Date, tokens: string[]): Promise<void>;
}

interface MemoryRow extends WakeRow {
  lastSentFor: Date | null;
  failures: number;
}

/** The dumbest correct implementation: the SQL's rules, spelled out. */
export class MemorySweeperWakeStore implements SweeperWakeStore {
  rows = new Map<string, MemoryRow>();

  upsert(row: WakeRow): Promise<void> {
    const previous = this.rows.get(row.token);
    this.rows.set(row.token, {
      ...row,
      moments: [...row.moments],
      lastSentFor: previous?.lastSentFor ?? null,
      failures: 0,
    });
    return Promise.resolve();
  }

  deleteForUser(userId: string): Promise<number> {
    let n = 0;
    for (const [token, row] of this.rows) {
      if (row.userId === userId) {
        this.rows.delete(token);
        n++;
      }
    }
    return Promise.resolve(n);
  }

  claim(minute: Date, limit: number): Promise<ClaimedRow[]> {
    const out: ClaimedRow[] = [];
    for (const row of [...this.rows.values()].sort((a, b) => (a.token < b.token ? -1 : 1))) {
      if (out.length >= Math.max(limit, 0)) break;
      if (!row.moments.some((m) => m.getTime() === minute.getTime())) continue;
      if (row.lastSentFor !== null && row.lastSentFor.getTime() >= minute.getTime()) continue;
      row.lastSentFor = minute;
      out.push({ token: row.token, environment: row.environment, userId: row.userId });
    }
    return Promise.resolve(out);
  }

  markFailure(token: string): Promise<number> {
    const row = this.rows.get(token);
    if (!row) return Promise.resolve(0);
    row.failures += 1;
    return Promise.resolve(row.failures);
  }

  deleteToken(token: string): Promise<void> {
    this.rows.delete(token);
    return Promise.resolve();
  }

  pruneMoments(before: Date, tokens: string[]): Promise<void> {
    for (const token of tokens) {
      const row = this.rows.get(token);
      if (row) row.moments = row.moments.filter((m) => m.getTime() >= before.getTime());
    }
    return Promise.resolve();
  }
}

const PRUNE_SELECT_CHUNK = 100;

/** The production store. Every method is one PostgREST request except
 *  `markFailure` and `pruneMoments`, which read and then write. That is
 *  deliberate: the claim is what must be atomic, and it is (the
 *  `claim_sweeper_wakes` function, one UPDATE). A row is claimed by one tick
 *  at a time, so only one tick ever fails or prunes it; and PostgREST has no
 *  array filter or `failures + 1`, so the alternative is a second SQL
 *  function for two statements that cannot race. If the tick's "took" ever
 *  says pruning is slow, that function is the fix. */
export class PostgrestSweeperWakeStore implements SweeperWakeStore {
  constructor(private readonly client: SupabaseClient) {}

  async upsert(row: WakeRow): Promise<void> {
    const { error } = await this.client.from("sweeper_wakes").upsert({
      device_token: row.token,
      user_id: row.userId,
      environment: row.environment,
      moments: row.moments.map((m) => m.toISOString()),
      plan_hash: row.planHash ?? null,
      updated_at: new Date().toISOString(),
      failures: 0,
    }, { onConflict: "device_token" });
    if (error) throw error;
  }

  async deleteForUser(userId: string): Promise<number> {
    const { data, error } = await this.client.from("sweeper_wakes").delete().eq("user_id", userId).select("device_token");
    if (error) throw error;
    return (data ?? []).length;
  }

  async claim(minute: Date, limit: number): Promise<ClaimedRow[]> {
    const { data, error } = await this.client.rpc("claim_sweeper_wakes", { at_minute: minute.toISOString(), max_rows: limit });
    if (error) throw error;
    return ((data ?? []) as Array<Record<string, unknown>>).map((r) => ({
      token: r.device_token as string,
      environment: r.environment as ApnsEnvironment,
      userId: r.user_id as string,
    }));
  }

  async markFailure(token: string): Promise<number> {
    const { data, error } = await this.client.from("sweeper_wakes").select("failures").eq("device_token", token).maybeSingle();
    if (error) throw error;
    if (!data) return 0;
    const failures = (data.failures as number) + 1;
    const { error: updateError } = await this.client.from("sweeper_wakes").update({ failures }).eq("device_token", token);
    if (updateError) throw updateError;
    return failures;
  }

  async deleteToken(token: string): Promise<void> {
    const { error } = await this.client.from("sweeper_wakes").delete().eq("device_token", token);
    if (error) throw error;
  }

  async pruneMoments(before: Date, tokens: string[]): Promise<void> {
    for (let i = 0; i < tokens.length; i += PRUNE_SELECT_CHUNK) {
      const chunk = tokens.slice(i, i + PRUNE_SELECT_CHUNK);
      const { data, error } = await this.client.from("sweeper_wakes").select("device_token, moments").in("device_token", chunk);
      if (error) throw error;
      for (const row of (data ?? []) as Array<{ device_token: string; moments: string[] }>) {
        const kept = row.moments.filter((m) => Date.parse(m) >= before.getTime());
        if (kept.length === row.moments.length) continue;
        const { error: updateError } = await this.client.from("sweeper_wakes").update({ moments: kept }).eq("device_token", row.device_token);
        if (updateError) throw updateError;
      }
    }
  }
}

// ---- the tick ----------------------------------------------------------

export interface ApnsSender {
  send(row: ClaimedRow, now: number): Promise<ApnsResult>;
  /** Forget the cached provider token for an environment, so the next send mints a new one. */
  forget(environment: ApnsEnvironment): void;
}

/** A failure the tick must not absorb: the key is wrong, or our own remint logic is. */
export class TickFatal extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TickFatal";
  }
}

export interface TickDeps {
  store: SweeperWakeStore;
  apns: ApnsSender;
  /** The clock, in epoch milliseconds. */
  now: () => number;
  log: (line: string) => void;
  disabled?: boolean;
  concurrency?: number;
  /** Called once with the number of rows claimed, after both claims and before any send,
   *  so the HTTP answer can go out while the sends run (the pg_net timeout is 2 s). */
  onClaimed?: (claimed: number) => void;
}

export interface TickCounts {
  disabled?: boolean;
  claimed: number;
  sent: number;
  byStatus: Record<string, number>;
  deleted: number;
  took: number;
}

export async function runTick(deps: TickDeps): Promise<TickCounts> {
  const startedAt = deps.now();
  if (deps.disabled) return { disabled: true, claimed: 0, sent: 0, byStatus: {}, deleted: 0, took: 0 };
  const concurrency = Math.max(1, deps.concurrency ?? 32);
  const minute = new Date(truncateToMinute(startedAt));

  // The minute just before is claimed too, to forgive a tick that ran late
  // (pg_cron is "up to a minute" precise). The earlier minute goes first, so
  // `last_sent_for` ends on the newest, and a row with moments in both
  // minutes is sent to once.
  const late = await deps.store.claim(new Date(minute.getTime() - MINUTE_MS), CLAIM_LIMIT);
  const current = await deps.store.claim(minute, CLAIM_LIMIT);
  const byToken = new Map<string, ClaimedRow>();
  for (const row of [...late, ...current]) byToken.set(row.token, row);
  const rows = [...byToken.values()];
  deps.onClaimed?.(rows.length);

  const byStatus: Record<string, number> = {};
  const bump = (key: string) => {
    byStatus[key] = (byStatus[key] ?? 0) + 1;
  };
  let sent = 0;
  let deleted = 0;
  let fatal: TickFatal | null = null;
  let configErrorLogged = false;
  const reminted = new Set<ApnsEnvironment>();

  const sendOne = async (row: ClaimedRow): Promise<void> => {
    let result: ApnsResult;
    try {
      result = await deps.apns.send(row, deps.now());
      if (result.outcome === "remint") {
        // One new token per environment per tick, however many sends saw the
        // 403: the first to see it drops the cached token, the rest retry
        // with whatever is cached by then.
        if (!reminted.has(row.environment)) {
          reminted.add(row.environment);
          deps.apns.forget(row.environment);
        }
        result = await deps.apns.send(row, deps.now());
        if (result.outcome === "remint") throw new TickFatal("APNs refused a freshly minted provider token twice; the key, key id or team id is wrong");
      }
    } catch (err) {
      if (err instanceof TickFatal) throw err;
      // Our own side (a missing secret, an unreadable key): not the row's
      // fault, so the row is neither counted nor deleted. The message names
      // a variable, never a value.
      bump("error");
      if (!configErrorLogged) {
        configErrorLogged = true;
        deps.log(`sweeper-wake: send failed before reaching Apple (${err instanceof Error ? err.message : "unknown"})`);
      }
      return;
    }
    sent++;
    bump(String(result.status));
    switch (result.outcome) {
      case "ok":
      case "tooMany":
        return;
      case "unregistered":
        await deps.store.deleteToken(row.token);
        deleted++;
        return;
      case "providerTokenAbuse":
        throw new TickFatal("APNs says provider tokens are being minted too often");
      default: {
        // badToken, serverError, failed. A status of 0 is a connection that
        // never reached Apple, which says nothing about the token.
        if (result.status === 0) return;
        const failures = await deps.store.markFailure(row.token);
        if (failures >= MAX_FAILURES) {
          await deps.store.deleteToken(row.token);
          deleted++;
        }
      }
    }
  };

  let next = 0;
  const worker = async () => {
    while (fatal === null) {
      const i = next++;
      if (i >= rows.length) return;
      try {
        await sendOne(rows[i]);
      } catch (err) {
        if (err instanceof TickFatal) fatal = err;
        else throw err;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, rows.length) }, worker));
  if (fatal) {
    deps.log(`sweeper-wake tick ${minute.toISOString()}: FAILED, ${(fatal as TickFatal).message}`);
    throw fatal;
  }

  const survivors = rows.map((r) => r.token);
  if (survivors.length > 0) await deps.store.pruneMoments(new Date(minute.getTime() - PRUNE_AFTER_MS), survivors);

  const took = deps.now() - startedAt;
  deps.log(
    `sweeper-wake tick ${minute.toISOString()}: claimed ${rows.length}, sent ${sent}, status ${JSON.stringify(byStatus)}, deleted ${deleted}, took ${took} ms`,
  );
  return { claimed: rows.length, sent, byStatus, deleted, took };
}
