// The Sweeper wake's rules (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md §1.1,
// §3): what a phone may upload, the store behind it, and the once-a-minute
// tick that turns a due minute into a content-free alert push. Pure of Deno and of the
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

const ISO_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;
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

/** `{ "action": "delete" }` carries nothing else; extra keys are refused like a put's. */
export function validateDeleteBody(body: unknown): { ok: true } | { ok: false; reason: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { ok: false, reason: "invalid_body" };
  for (const key of Object.keys(body)) if (key !== "action") return { ok: false, reason: "forbidden_field" };
  return { ok: true };
}

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
    if (!ISO_INSTANT.test(raw)) return { ok: false, reason: "invalid_moment" };
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
  /** Counts one more failed send and answers the new total (in place, one statement). */
  markFailure(token: string): Promise<number>;
  /** A 200 for this row: its failure count starts again (three in a row delete it). */
  resetFailures(token: string): Promise<void>;
  deleteToken(token: string): Promise<void>;
  /** Removes moments earlier than `before` from the named rows, in place. */
  pruneMoments(before: Date, tokens: string[]): Promise<void>;
  /** Deletes rows whose phone has not uploaded since `before`; answers how many. */
  deleteStale(before: Date): Promise<number>;
}

interface MemoryRow extends WakeRow {
  lastSentFor: Date | null;
  failures: number;
  updatedAt: Date;
}

/** The dumbest correct implementation: the SQL's rules, spelled out. */
export class MemorySweeperWakeStore implements SweeperWakeStore {
  rows = new Map<string, MemoryRow>();
  /** Tests move this to age rows. */
  clock: () => Date = () => new Date();

  upsert(row: WakeRow): Promise<void> {
    const previous = this.rows.get(row.token);
    this.rows.set(row.token, {
      ...row,
      moments: [...row.moments],
      lastSentFor: previous?.lastSentFor ?? null,
      failures: 0,
      updatedAt: this.clock(),
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

  resetFailures(token: string): Promise<void> {
    const row = this.rows.get(token);
    if (row) row.failures = 0;
    return Promise.resolve();
  }

  deleteToken(token: string): Promise<void> {
    this.rows.delete(token);
    return Promise.resolve();
  }

  deleteStale(before: Date): Promise<number> {
    let n = 0;
    for (const [token, row] of this.rows) {
      if (row.updatedAt.getTime() < before.getTime()) {
        this.rows.delete(token);
        n++;
      }
    }
    return Promise.resolve(n);
  }

  pruneMoments(before: Date, tokens: string[]): Promise<void> {
    for (const token of tokens) {
      const row = this.rows.get(token);
      if (row) row.moments = row.moments.filter((m) => m.getTime() >= before.getTime());
    }
    return Promise.resolve();
  }
}

/** The production store. Every method is one PostgREST request. The claim,
 *  the failure bump and the prune are SQL functions (migration
 *  `20261118090000_sweeper_wake.sql`) because each must act on the row as it
 *  is now: a prune that read the moments and wrote them back could overwrite
 *  a list the phone uploaded in between with a stale one. */
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
    const { data, error } = await this.client.rpc("bump_sweeper_failure", { token });
    if (error) throw error;
    return Number(data ?? 0);
  }

  async resetFailures(token: string): Promise<void> {
    const { error } = await this.client.from("sweeper_wakes").update({ failures: 0 }).eq("device_token", token).gt("failures", 0);
    if (error) throw error;
  }

  async deleteToken(token: string): Promise<void> {
    const { error } = await this.client.from("sweeper_wakes").delete().eq("device_token", token);
    if (error) throw error;
  }

  async pruneMoments(before: Date, tokens: string[]): Promise<void> {
    if (tokens.length === 0) return;
    const { error } = await this.client.rpc("prune_sweeper_moments", { tokens, before: before.toISOString() });
    if (error) throw error;
  }

  async deleteStale(before: Date): Promise<number> {
    const { data, error } = await this.client.from("sweeper_wakes").delete().lt("updated_at", before.toISOString()).select("device_token");
    if (error) throw error;
    return (data ?? []).length;
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
  /** Requests Apple answered (any status). A send that never reached Apple is `unreachable`. */
  sent: number;
  byStatus: Record<string, number>;
  unreachable: number;
  deleted: number;
  /** Rows deleted because their phone has not uploaded in 30 days. */
  aged: number;
  /** Store calls (a bump, a delete, a reset, a prune) that failed; the tick carried on. */
  storeErrors: number;
  took: number;
}

/** A phone that is alive re-uploads at least every ten minutes while open, so
 *  thirty days untouched is a dead install whose token Apple has not yet told us about. */
export const STALE_AFTER_MS = 30 * 24 * 60 * 60 * 1000;

export async function runTick(deps: TickDeps): Promise<TickCounts> {
  const startedAt = deps.now();
  if (deps.disabled) {
    return { disabled: true, claimed: 0, sent: 0, byStatus: {}, unreachable: 0, deleted: 0, aged: 0, storeErrors: 0, took: 0 };
  }
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
  let unreachable = 0;
  let deleted = 0;
  let aged = 0;
  let storeErrors = 0;
  let fatal: TickFatal | null = null;
  const loggedClasses = new Set<string>();
  const reminted = new Set<ApnsEnvironment>();

  // A store call that fails (a PostgREST error) is counted and named by its
  // class, once per class per tick, and never stops the tick: the summary
  // line and the prune still run. The error's message is never logged.
  const guarded = async <T>(fn: () => Promise<T>): Promise<T | undefined> => {
    try {
      return await fn();
    } catch (err) {
      storeErrors++;
      const name = err instanceof Error ? err.constructor.name : typeof err;
      if (!loggedClasses.has(name)) {
        loggedClasses.add(name);
        deps.log(`sweeper-wake: store call failed (${name})`);
      }
      return undefined;
    }
  };

  aged = (await guarded(() => deps.store.deleteStale(new Date(startedAt - STALE_AFTER_MS)))) ?? 0;

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
      if (!loggedClasses.has("send")) {
        loggedClasses.add("send");
        deps.log(`sweeper-wake: send failed before reaching Apple (${err instanceof Error ? err.message : "unknown"})`);
      }
      return;
    }
    if (result.status === 0) {
      // A connection that never reached Apple says nothing about the token.
      unreachable++;
      return;
    }
    sent++;
    bump(String(result.status));
    switch (result.outcome) {
      case "ok":
        await guarded(() => deps.store.resetFailures(row.token));
        return;
      case "tooMany":
        return;
      case "unregistered":
        if ((await guarded(async () => (await deps.store.deleteToken(row.token), true))) === true) deleted++;
        return;
      case "config":
        // BadTopic, Forbidden and kin: the setup is wrong for every row, so
        // fail loudly and count nothing against anyone.
        throw new TickFatal(`APNs refused the request for a reason in our setup (${result.status} ${result.reason ?? "no reason"})`);
      case "providerTokenAbuse":
        throw new TickFatal("APNs says provider tokens are being minted too often");
      default: {
        // badToken, serverError, failed: three in a row delete the row.
        const failures = await guarded(() => deps.store.markFailure(row.token));
        if (failures !== undefined && failures >= MAX_FAILURES) {
          if ((await guarded(async () => (await deps.store.deleteToken(row.token), true))) === true) deleted++;
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

  if (rows.length > 0) await guarded(() => deps.store.pruneMoments(new Date(minute.getTime() - PRUNE_AFTER_MS), rows.map((r) => r.token)));

  const took = deps.now() - startedAt;
  deps.log(
    `sweeper-wake tick ${minute.toISOString()}: claimed ${rows.length}, sent ${sent}, status ${JSON.stringify(byStatus)}, unreachable ${unreachable}, deleted ${deleted}, aged ${aged}, store errors ${storeErrors}, took ${took} ms`,
  );
  return { claimed: rows.length, sent, byStatus, unreachable, deleted, aged, storeErrors, took };
}
