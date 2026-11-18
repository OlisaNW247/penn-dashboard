// The `sweeper-wake` edge function (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md
// §3). Two callers, one function:
//
//   POST /       the phone, with the student's own Supabase JWT, uploads the
//                minutes at which it wants a silent nudge (`action: "put"`) or
//                withdraws them (`action: "delete"`). Run with
//                `verify_jwt = false` (config.toml), so the bearer is verified
//                here by `requireUser`, the way `agent-auth` and `mcp` do it.
//   POST /tick   pg_cron through pg_net, once a minute, with a dedicated
//                secret in `x-sweeper-tick-secret` (never the service key).
//                It claims the rows due now and sends each a background push.
//
// `put` and `delete` are POSTs with an `action` because the phone's
// `BackendClient` has one wire and `agent-snapshot` already uses this shape.
//
// Logs counts only: never a token, a user id or a moment.
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { corsHeaders, errorResponse, HttpError, json } from "../_shared/http.ts";
import { enforceMinimumVersion, type VersionOptions } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import { apnsCredentialsFromEnv, forgetProviderToken, sendBackgroundPush } from "../_shared/apns.ts";
import {
  type ApnsSender,
  PostgrestSweeperWakeStore,
  runTick,
  type SweeperWakeStore,
  validateDeleteBody,
  validateWakeBody,
} from "../_shared/sweeperWake.ts";

const MAX_BODY_BYTES = 16 * 1024;

export interface SweeperWakeDeps {
  store: SweeperWakeStore;
  apns: ApnsSender;
  now?: () => Date;
  /** Environment lookup; defaults to `Deno.env`. Tests pass their own. */
  env?: (key: string) => string | undefined;
  /** Hands the sends to the runtime so the tick can answer first. Defaults to
   *  `EdgeRuntime.waitUntil` when it exists; when neither is given the tick
   *  awaits its sends (tests, and any runtime without background tasks). */
  waitUntil?: (promise: Promise<unknown>) => void;
  /** Passed through to the version check (tests inject a manifest). */
  version?: Partial<VersionOptions>;
}

/** Constant-time comparison of two strings (the tick secret). */
function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function defaultWaitUntil(): ((p: Promise<unknown>) => void) | undefined {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } }).EdgeRuntime;
  return runtime?.waitUntil ? (p) => runtime.waitUntil!(p) : undefined;
}

async function handleTick(req: Request, deps: SweeperWakeDeps, env: (k: string) => string | undefined): Promise<Response> {
  const expected = env("LHF_SWEEPER_TICK_SECRET");
  const given = req.headers.get("x-sweeper-tick-secret");
  if (!expected || !given || !sameSecret(given, expected)) {
    console.error("sweeper-wake: tick refused (403)");
    throw new HttpError(403, "forbidden", "forbidden");
  }
  if (env("LHF_SWEEPER_WAKE_DISABLED") === "1") return json(200, { disabled: true });

  const now = deps.now ?? (() => new Date());
  let claimed = 0;
  let onClaimed: () => void = () => {};
  const claimedSignal = new Promise<void>((resolve) => {
    onClaimed = resolve;
  });
  const work = runTick({
    store: deps.store,
    apns: deps.apns,
    now: () => now().getTime(),
    log: (line) => console.log(line),
    concurrency: 32,
    onClaimed: (n) => {
      claimed = n;
      onClaimed();
    },
  });

  const waitUntil = deps.waitUntil ?? defaultWaitUntil();
  if (waitUntil) {
    // The sends outlive this response: pg_net gives up after its timeout and
    // the function's CPU cap is for CPU, not for waiting on Apple.
    waitUntil(work.catch((err) => console.error("sweeper-wake: tick failed", err instanceof Error ? err.name : typeof err)));
    await Promise.race([claimedSignal, work]);
  } else {
    await work;
  }
  return json(202, { claimed });
}

async function handleStudent(req: Request, deps: SweeperWakeDeps, env: (k: string) => string | undefined): Promise<Response> {
  // The header is required here (a new function has no old callers), which
  // `enforceMinimumVersion` does by reading LHF_REQUIRE_VERSION_HEADER as on.
  await enforceMinimumVersion(req, {
    headerOptional: false,
    ...deps.version,
    env: (k) => (k === "LHF_REQUIRE_VERSION_HEADER" ? "true" : env(k)),
  });
  const { userId } = await requireUser(req);
  const now = (deps.now ?? (() => new Date()))();

  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) throw new HttpError(413, "payload_too_large", "body is larger than 16 KB");
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "bad_request", "body is not valid JSON");
  }
  const action = typeof body === "object" && body !== null ? (body as Record<string, unknown>).action : undefined;

  if (action === "put") {
    const checked = validateWakeBody(body, now);
    if (!checked.ok) {
      console.error(`sweeper-wake: refused (${checked.reason})`);
      throw new HttpError(400, "bad_request", checked.reason);
    }
    const { token, environment, moments, planHash } = checked.value;
    if (env("LHF_SWEEPER_WAKE_DISABLED") === "1") return json(200, { stored: 0, disabled: true });
    await deps.store.upsert({ token, userId, environment, moments, planHash });
    console.log(`sweeper-wake: put stored=${moments.length}`);
    return json(200, { stored: moments.length, nextMoment: moments.length > 0 ? moments[0].toISOString() : null });
  }

  if (action === "delete") {
    const checked = validateDeleteBody(body);
    if (!checked.ok) {
      console.error(`sweeper-wake: refused (${checked.reason})`);
      throw new HttpError(400, "bad_request", checked.reason);
    }
    const deleted = await deps.store.deleteForUser(userId);
    console.log(`sweeper-wake: delete deleted=${deleted}`);
    return json(200, { deleted });
  }

  throw new HttpError(400, "bad_request", `"action" must be put or delete`);
}

export async function handleSweeperWake(req: Request, deps: SweeperWakeDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  const env = deps.env ?? ((k: string) => Deno.env.get(k));
  try {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed", "sweeper-wake only accepts POST");
    const path = new URL(req.url).pathname.replace(/\/+$/, "");
    if (path.endsWith("/tick")) return await handleTick(req, deps, env);
    return await handleStudent(req, deps, env);
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`sweeper-wake error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("sweeper-wake error: unexpected", err instanceof Error ? err.constructor.name : typeof err);
    return errorResponse("internal_error", "unexpected server error", 500);
  }
}

function productionApns(): ApnsSender {
  return {
    send: (row, now) => {
      const credentials = apnsCredentialsFromEnv(row.environment);
      return sendBackgroundPush({ token: row.token, environment: row.environment, topic: credentials.topic, now, fetch, credentials });
    },
    forget: (environment) => forgetProviderToken(apnsCredentialsFromEnv(environment).keyID),
  };
}

function productionDeps(): SweeperWakeDeps {
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { store: new PostgrestSweeperWakeStore(client), apns: productionApns() };
}

if (import.meta.main) Deno.serve((req) => handleSweeperWake(req, productionDeps()));
