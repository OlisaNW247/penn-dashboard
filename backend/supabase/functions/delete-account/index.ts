// The `delete-account` edge function. Per PROTOCOL.md: deletes the
// caller's `enrollments` and `ask_usage` rows and the auth user itself;
// shared course material (`courses`, `course_documents`, `course_profiles`)
// is untouched because it is not the user's data -- it is the same Canvas
// course-site content every other enrolled student still sees, keyed by
// course id, not by this user.
import { corsHeaders, errorResponse, HttpError, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { deleteUserData } from "../_shared/db.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "delete-account only accepts POST");
    }

    const { userId, serviceClient } = await requireUser(req);

    // Row deletes first, then the auth user -- doing it in the other
    // order would leave `enrollments`/`ask_usage` rows referencing a user
    // id `auth.users` no longer has, and while the foreign keys are
    // `on delete cascade` (so an admin delete would clean them up anyway),
    // being explicit here means this function's own success/failure
    // reflects exactly what it did rather than relying on a cascade to
    // paper over a partial failure.
    await deleteUserData(serviceClient, userId);

    const { error } = await serviceClient.auth.admin.deleteUser(userId);
    if (error) {
      throw new HttpError(502, "upstream", "failed to delete auth user");
    }

    return json(200, { deleted: true });
  } catch (err) {
    if (err instanceof HttpError) {
      // Never logs the user id itself, only the outcome -- matching the
      // same logging discipline as sync/index.ts.
      console.error(`delete-account error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("delete-account error: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
});
