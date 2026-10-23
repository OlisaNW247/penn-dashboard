// Authenticates the caller of an edge function against Supabase's GoTrue
// and hands back a service-role client for the rest of the handler to use.
//
// Two clients matter here and it is worth being explicit about why both
// exist: the *user* client (built with the anon key plus the caller's own
// bearer token) is only ever used to ask "who is this", because that's the
// one operation GoTrue will answer honestly for a token it can verify. The
// *service* client (built with the service role key, which bypasses RLS
// entirely per the migration's grants) is what every actual read or write
// in sync/delete-account goes through -- the whole point of doing identity
// checks in application code (is this course id in the caller's
// enrollments? do they own this ask_usage row?) rather than leaning on RLS
// for every query is that the protocol's data model needs cross-user reads
// (every enrolled student reads the same course_documents rows) that plain
// per-row RLS can't express as cleanly as `is_enrolled()` already does, and
// the functions need to *write* at all, which RLS deliberately blocks for
// every role except service_role.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";
import { resolveIdentity } from "./devices.ts";

export interface AuthContext {
  /** The student every enrollment and quota rule scopes to. For a caller
   *  that is a linked device (the Chrome extension's own anonymous user,
   *  see `device_links`) this is the OWNER's id, so every function that
   *  already scopes by `userId` serves the device as the student with no
   *  other change. For everyone else it is the token's own user. */
  userId: string;
  /** The token's own user, whoever that resolves to. Only `pair`,
   *  `device-sync` and `delete-account` should ever need it. */
  callerUserId: string;
  /** True when the caller is a device linked to an owner. */
  deviceOwnerLinked: boolean;
  serviceClient: SupabaseClient;
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    // A missing secret is an operator mistake, not a caller mistake --
    // 500, not 401, so it doesn't get confused with "your token is bad"
    // in logs or client-side retry logic.
    throw new HttpError(500, "server_misconfigured", `missing required environment variable ${name}`);
  }
  return value;
}

/** Verifies the `Authorization: Bearer` header against GoTrue and returns
 * the caller's user id plus a service-role client. Throws `HttpError(401)`
 * for anything short of a verified session: no header, a malformed
 * header, or a token GoTrue rejects (expired, revoked, garbage). Per
 * PROTOCOL.md, "a 401 means refresh and retry once" is the client's job,
 * not this function's -- it only ever answers the single question of
 * whether *this* request is authenticated. */
export async function requireUser(req: Request): Promise<AuthContext> {
  const authHeader = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!authHeader || !/^Bearer\s+\S+/i.test(authHeader)) {
    throw new HttpError(401, "unauthorized", "missing or malformed Authorization header");
  }

  const supabaseUrl = requireEnv("SUPABASE_URL");
  const anonKey = requireEnv("SUPABASE_ANON_KEY");
  const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) {
    throw new HttpError(401, "unauthorized", "invalid or expired session");
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // One lookup, for every caller: a linked device has a row keyed by its
  // own user id, everyone else has none. Failing it must fail the request.
  // Falling back to the token's own id would quietly treat a linked device
  // as a fresh student with no enrollments and a full ask quota, which is
  // wrong in a way nobody would notice.
  const { data: link, error: linkError } = await serviceClient
    .from("device_links")
    .select("owner_user_id")
    .eq("device_user_id", data.user.id)
    .maybeSingle();
  //
  // The one exception is the table not existing at all (Postgres 42P01, or
  // PostgREST's PGRST205 when its schema cache lacks it). Then no link can
  // exist, so "not linked" is exactly true, and failing would take `ask`
  // and `sync` down for every phone if any function were deployed from
  // `v8` before `20261022090000_chrome_extension.sql` was applied.
  if (linkError && !isMissingTable(linkError)) {
    throw new HttpError(502, "upstream", "failed to resolve caller identity");
  }
  const ownerUserId = (link as { owner_user_id: string } | null)?.owner_user_id;

  return { ...resolveIdentity(data.user.id, ownerUserId), serviceClient };
}

/** True for the errors PostgREST returns when `device_links` does not
 * exist yet; see the lookup in `requireUser`. */
export function isMissingTable(error: { code?: string | null }): boolean {
  return error.code === "42P01" || error.code === "PGRST205";
}
