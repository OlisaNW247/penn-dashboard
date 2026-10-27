// The `device-sync` edge function: stores and returns end-to-end encrypted
// snapshots between an owner (the phone) and its linked devices (the
// extension). The server never parses `ciphertext`: it checks that it is
// base64 of at most 2 MB and stores the string. Never logs ids or
// ciphertext. Decisions are in `_shared/devices.ts`.
import { corsHeaders, errorResponse, HttpError, json, readJSON } from "../_shared/http.ts";
import { enforceMinimumVersion } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import { selectDeviceBlobs, selectLinkedDeviceIDs, upsertDeviceBlob } from "../_shared/db.ts";
import {
  BlobTooLargeError,
  blobRowKey,
  decideDeviceSyncAccess,
  DeviceValidationError,
  validateDeviceSyncRequest,
  type DeviceSyncRequest,
} from "../_shared/devices.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    // The Chrome extension calls this function and never sends the version
    // header, so only a present-and-below-floor header is refused here;
    // never the "header required" switch (headerOptional).
    await enforceMinimumVersion(req, { headerOptional: true });

    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "device-sync only accepts POST");
    }

    const identity = await requireUser(req);
    const { serviceClient } = identity;

    let request: DeviceSyncRequest;
    try {
      request = validateDeviceSyncRequest(await readJSON<unknown>(req));
    } catch (err) {
      if (err instanceof BlobTooLargeError) throw new HttpError(413, "payload_too_large", err.message);
      if (err instanceof DeviceValidationError) throw new HttpError(400, "bad_request", err.message);
      throw err;
    }

    // `identity.userId` is the owner for both an owner and a linked device,
    // so one query scope serves both. A caller that is neither (never
    // paired) is refused. The owner check is only needed when the caller
    // is not a device.
    const ownerHasDevices = identity.deviceOwnerLinked
      ? true
      : (await selectLinkedDeviceIDs(serviceClient, identity.userId)).length > 0;
    const refusal = decideDeviceSyncAccess(identity, ownerHasDevices);
    if (refusal) throw new HttpError(refusal.status, refusal.code);

    if (request.action === "put") {
      const deviceId = blobRowKey(identity, request.deviceId);
      const updatedAt = await upsertDeviceBlob(serviceClient, identity.userId, deviceId, request.ciphertext);
      return json(200, { deviceId, updatedAt });
    }

    const blobs = await selectDeviceBlobs(serviceClient, identity.userId);
    return json(200, { blobs });
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`device-sync error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("device-sync error: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
});
