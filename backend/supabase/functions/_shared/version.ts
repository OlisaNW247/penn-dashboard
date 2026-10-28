// Server-side second lock behind the app's update wall.
//
// The app (see CLAUDE.md "Update gate") shows an undismissable wall below the
// manifest's `minimumVersion`, but a wall is only a UI: a build that predates
// it, a modified client, or a scripted caller can still talk to these
// functions. This module makes the edge functions refuse requests from app
// versions below the same floor, reading the SAME manifest the app reads so
// that lifting or raising the floor (one edit on the `update-manifest`
// branch) moves both locks together.
//
// The app sends `X-Smooth-Version: <marketing version>` on every backend
// request. Builds 3.2.x and older send nothing.

import { HttpError } from "./http.ts";

/** Same file the app fetches (UpdateManifestClient). Lives on an orphan
 * branch so the URL never moves; see CLAUDE.md. */
export const MANIFEST_URL =
  "https://raw.githubusercontent.com/OlisaNW247/penn-dashboard/update-manifest/lhf-update.json";

export const VERSION_HEADER = "x-smooth-version";

/** The floor is cached this long. A floor edit therefore takes up to five
 * minutes to reach the functions; in exchange the manifest host is hit at
 * most once per isolate per window rather than once per request. */
export const CACHE_TTL_MS = 5 * 60 * 1000;

/** After a failed fetch we do not retry for this long. Without it, a manifest
 * host outage would add the full fetch timeout to every single request. */
export const FAILURE_RETRY_MS = 60 * 1000;

export const FETCH_TIMEOUT_MS = 2000;

/** Strict dotted-numeric parse, mirroring the app's `AppVersion`: every
 * dot-separated component must be non-empty ASCII digits; anything else
 * ("", "abc", "2.x", "-1.0", "2..0", "3.3.0-beta") returns null rather than
 * a plausible default. A parse failure must make the check inert, never make
 * it block: reading "can't parse" as 0.0.0 would lock out everyone on a typo
 * in the manifest. Surrounding whitespace is trimmed, as in the app. */
export function parseVersion(raw: string | null | undefined): number[] | null {
  if (raw == null) return null;
  const trimmed = raw.trim();
  if (trimmed === "") return null;
  const out: number[] = [];
  for (const part of trimmed.split(".")) {
    if (!/^[0-9]+$/.test(part)) return null;
    const n = Number(part);
    if (!Number.isSafeInteger(n)) return null;
    out.push(n);
  }
  return out;
}

/** Component-wise compare, missing trailing components count as 0
 * ("3.3" == "3.3.0"). Negative, zero or positive like a sort comparator. */
export function compareVersions(a: number[], b: number[]): number {
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

type Cache = { floor: number[] | null; fetchedAt: number; ok: boolean };
let cache: Cache | null = null;

/** Test hook: forget the module-level cache. */
export function resetVersionCache(): void {
  cache = null;
}

export interface VersionOptions {
  /** Never require the header, even when LHF_REQUIRE_VERSION_HEADER is on.
   * For functions the Chrome extension calls: it never sends the header, and
   * it is not versioned with the app. A present header that is below the
   * floor is still refused. */
  headerOptional?: boolean;
  fetchFn?: typeof fetch;
  now?: () => number;
  env?: (key: string) => string | undefined;
  manifestUrl?: string;
}

/** Returns the current floor, or null when there is none to enforce.
 * Never throws: every failure is "no floor" (fail open). */
async function currentFloor(opts: VersionOptions): Promise<number[] | null> {
  const now = (opts.now ?? Date.now)();
  if (cache) {
    const ttl = cache.ok ? CACHE_TTL_MS : FAILURE_RETRY_MS;
    if (now - cache.fetchedAt < ttl) return cache.floor;
  }
  const fetchFn = opts.fetchFn ?? fetch;
  try {
    const res = await fetchFn(opts.manifestUrl ?? MANIFEST_URL, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`manifest status ${res.status}`);
    const body = await res.json();
    const raw = body && typeof body === "object" ? (body as Record<string, unknown>).minimumVersion : undefined;
    // An unparseable floor is stored as null (no floor) and counts as a
    // successful fetch: re-fetching a typo every minute would not fix it.
    cache = { floor: typeof raw === "string" ? parseVersion(raw) : null, fetchedAt: now, ok: true };
    return cache.floor;
  } catch (err) {
    console.error(`version check: manifest unavailable, allowing (${err instanceof Error ? err.message : String(err)})`);
    // Keep the last known floor if we had one (the app's gate does the same);
    // otherwise there is nothing to enforce.
    cache = { floor: cache?.floor ?? null, fetchedAt: now, ok: false };
    return cache.floor;
  }
}

/** Throws HttpError(426, "update_required") when the caller's declared app
 * version is below the manifest floor. Call after the CORS/OPTIONS early
 * return and before real work, inside the function's try so its catch turns
 * the throw into a JSON error.
 *
 * Fail open, deliberately. This is the same contract as the app's gate: a
 * broken version check must never be what locks a student out of their own
 * data. A manifest fetch failure, a non-JSON body, or an unparseable
 * `minimumVersion` all allow the request (one log line on fetch failure).
 *
 * Missing or unparseable header: allowed by default, because builds 3.2.x
 * and older are in the field and send no header; refusing them now would
 * lock out exactly the people the app-side wall cannot reach. The
 * LHF_REQUIRE_VERSION_HEADER switch ("true") turns "no usable header" into
 * a 426. Flip it only once every allowed version sends a header, i.e. once
 * the floor is at or above the first build that sends it; before that it
 * would refuse legitimate current users. */
export async function enforceMinimumVersion(req: Request, opts: VersionOptions = {}): Promise<void> {
  const env = opts.env ?? ((k: string) => Deno.env.get(k));
  const declared = parseVersion(req.headers.get(VERSION_HEADER));

  if (declared === null) {
    if (!opts.headerOptional && env("LHF_REQUIRE_VERSION_HEADER") === "true") {
      throw new HttpError(426, "update_required", "this version of the app is no longer supported; please update");
    }
    return;
  }

  const floor = await currentFloor(opts);
  if (floor !== null && compareVersions(declared, floor) < 0) {
    throw new HttpError(426, "update_required", "this version of the app is no longer supported; please update");
  }
}
