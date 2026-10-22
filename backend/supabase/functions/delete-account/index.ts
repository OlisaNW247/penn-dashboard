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
import { corsHeaders, errorResponse, HttpError, json } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { deleteUserData, removeDevices, selectLinkedDeviceIDs } from "../_shared/db.ts";
import { decideDeleteAccount } from "../_shared/devices.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
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

    // Read the device ids before deleting the links that name them.
    const deviceIDs = await selectLinkedDeviceIDs(serviceClient, userId);

    // Row deletes first, then the auth user -- doing it in the other
    // order would leave `enrollments`/`ask_usage` rows referencing a user
    // id `auth.users` no longer has, and while the foreign keys are
    // `on delete cascade` (so an admin delete would clean them up anyway),
    // being explicit here means this function's own success/failure
    // reflects exactly what it did rather than relying on a cascade to
    // paper over a partial failure.
    await deleteUserData(serviceClient, userId);

    for (const deviceID of deviceIDs) {
      const { error } = await serviceClient.auth.admin.deleteUser(deviceID);
      if (error) {
        throw new HttpError(502, "upstream", "failed to delete device auth user");
      }
    }

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
