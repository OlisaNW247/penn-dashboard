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

export interface AuthContext {
  userId: string;
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

  return { userId: data.user.id, serviceClient };
}
