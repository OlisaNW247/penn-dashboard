// The `delete-account` edge function. Per PROTOCOL.md: deletes the
// caller's `enrollments` and `ask_usage` rows and the auth user itself;
// shared course material (`courses`, `course_documents`, `course_profiles`)
// is untouched because it is not the user's data -- it is the same Canvas
// course-site content every other enrolled student still sees, keyed by
// course id, not by this user.
//
// With the Chrome extension there are two callers. The owner (the phone)
// deletes everything above plus every linked device's auth user, the links
// and every sync blob. A linked device must NOT delete its owner: after
// identity resolution (`_shared/auth.ts`) its `userId` is the owner's id,
// so the unmodified path would erase the student's account from a laptop.
// A device's delete-account is `unpair` of itself; `decideDeleteAccount`
// makes that decision and refuses anything it cannot classify.
//
// Idempotent (hardening BE-14): calling it again is safe and answers 200
// `{ "deleted": true }` however far the first call got. A retry is exactly
// what a phone does after a dropped response, and before this a deletion that
// had half finished could never be completed: the second call died on an
// auth user that was already gone, or never found the devices whose link rows
// the first call had removed.
import { corsHeaders, errorResponse, HttpError, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { deleteUserData, removeDevices, selectLinkedDeviceIDs } from "../_shared/db.ts";
import { decideDeleteAccount, isAuthUserGone } from "../_shared/devices.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";

/** Deletes one auth user. "Already gone" is success, not an error, and is
 *  what makes every step below safe to run twice. */
async function deleteAuthUser(serviceClient: SupabaseClient, id: string, failure: string): Promise<void> {
  const { error } = await serviceClient.auth.admin.deleteUser(id);
  if (error && !isAuthUserGone(error)) {
    throw new HttpError(502, "upstream", failure);
  }
}

export async function handleDeleteAccount(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    // Deliberately NO enforceMinimumVersion here: a student must always be
    // able to delete their data, whatever app version they run, including
    // one below the update floor.
    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "delete-account only accepts POST");
    }

    const identity = await requireUser(req);
    const { userId, callerUserId, serviceClient } = identity;

    const decision = decideDeleteAccount(identity);

    if (decision === "unpair_self") {
      // The owner's data is untouched. `removeDevices` scopes by owner and
      // by the device's own id, so even a mistake upstream could only
      // remove this one device.
      try {
        await removeDevices(serviceClient, userId, [callerUserId]);
      } catch {
        throw new HttpError(502, "upstream", "failed to unpair device");
      }
      return json(200, { deleted: true });
    }

    if (decision === "refuse") {
      throw new HttpError(500, "internal_error", "identity did not resolve consistently");
    }

    // Linked devices first, while the link rows that name them still exist.
    // The links used to go first (inside `deleteUserData`), so a failure part
    // way through the devices left the remaining ones unreachable: the retry
    // read an empty link table and their auth users were never deleted.
    // Deleting a device user cascades its link row away (`device_links`
    // references `auth.users` on delete cascade), and an id that is already
    // gone is skipped, so this can fail anywhere and be called again.
    const deviceIDs = await selectLinkedDeviceIDs(serviceClient, userId);
    for (const deviceID of deviceIDs) {
      await deleteAuthUser(serviceClient, deviceID, "failed to delete device auth user");
    }

    // Then the owner's rows, then the auth user -- rows before the user
    // because doing it in the other order would leave `enrollments`/
    // `ask_usage` rows referencing a user id `auth.users` no longer has,
    // and while the foreign keys are `on delete cascade` (so an admin
    // delete would clean them up anyway), being explicit here means this
    // function's own success/failure reflects exactly what it did rather
    // than relying on a cascade to paper over a partial failure. Deleting
    // zero rows is not an error, so a retry passes straight through.
    await deleteUserData(serviceClient, userId);
    await deleteAuthUser(serviceClient, userId, "failed to delete auth user");

    return json(200, { deleted: true });
  } catch (err) {
    if (err instanceof HttpError) {
      if (err.code === "user_not_found") {
        // A genuine token for an account that no longer exists: the
        // deletion already finished (typically the response was lost and the
        // phone is retrying). The caller asked for this account to be gone,
        // and it is. A bad or expired token is a different code and still a
        // 401; nothing about any other account is revealed either way.
        return json(200, { deleted: true });
      }
      // Never logs the user id itself, only the outcome -- matching the
      // same logging discipline as sync/index.ts.
      console.error(`delete-account error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("delete-account error: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
}

// Guarded by `import.meta.main`, like `ask/index.ts`, so a test can import
// `handleDeleteAccount` without starting a second server. Deployed, this file
// is the entry point the runtime executes, so it serves exactly as before.
if (import.meta.main) {
  Deno.serve(handleDeleteAccount);
}
