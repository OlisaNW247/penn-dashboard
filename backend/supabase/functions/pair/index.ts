// The `pair` edge function: links the Chrome extension's own anonymous user
// to the phone's user (docs/CHROME_EXTENSION.md, "Pairing"; PROTOCOL.md ->
// `pair`). The decisions are in `_shared/devices.ts`; this file is request
// parsing, the sequence of steps and the response shape.
//
// Not rate limited. A cap of five `start` calls per caller per hour was
// considered and is skipped for now: each start replaces the caller's
// previous code, so the table cannot grow beyond one row per anonymous
// user, and the code is not guessable. Revisit if anonymous signups are
// abused.
//
// Never logs user ids or codes, only outcome codes.
import { corsHeaders, errorResponse, HttpError, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import {
  consumePairing,
  insertDeviceLink,
  removeDevices,
  replacePairing,
  selectLinkedDeviceIDs,
  selectOwnedDeviceIDs,
  selectPairing,
} from "../_shared/db.ts";
import {
  DeviceValidationError,
  decideClaim,
  decideStart,
  generatePairingCode,
  PAIRING_CODE_PATTERN,
  pairingExpiry,
  planUnpair,
  validatePairRequest,
  type PairRequest,
} from "../_shared/devices.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "pair only accepts POST");
    }

    const identity = await requireUser(req);
    const { serviceClient } = identity;

    let request: PairRequest;
    try {
      request = validatePairRequest(await readJSON<unknown>(req));
    } catch (err) {
      if (err instanceof DeviceValidationError) throw new HttpError(400, "bad_request", err.message);
      throw err;
    }

    if (request.action === "start") {
      const refusal = decideStart(identity);
      if (refusal) throw new HttpError(refusal.status, refusal.code);

      const code = generatePairingCode();
      const expiresAt = pairingExpiry(new Date());
      await replacePairing(serviceClient, identity.callerUserId, code, expiresAt);
      return json(200, { code, expiresAt: expiresAt.toISOString() });
    }

    if (request.action === "claim") {
      // A code of the wrong shape is "not found", the same answer as an
      // unknown or expired one, so the response never separates them.
      const pairing = PAIRING_CODE_PATTERN.test(request.code) ? await selectPairing(serviceClient, request.code) : null;
      const refusal = decideClaim({ identity, pairing, now: new Date() });
      if (refusal) throw new HttpError(refusal.status, refusal.code);

      // The device user must not itself own devices: a chain of links would
      // make one-hop identity resolution wrong for the devices below it.
      const deviceUserId = pairing!.deviceUserId;
      if ((await selectLinkedDeviceIDs(serviceClient, deviceUserId)).length > 0) {
        throw new HttpError(409, "already_paired");
      }

      // Consuming is the claim: a delete that reports whether this call
      // removed the row, so two phones racing for one code cannot both
      // link it. A plain select-then-delete would let both through.
      if (!(await consumePairing(serviceClient, request.code))) {
        throw new HttpError(404, "pairing_not_found");
      }
      const result = await insertDeviceLink(serviceClient, deviceUserId, identity.callerUserId);
      if (result === "already_linked") throw new HttpError(409, "already_paired");
      return json(200, { paired: true });
    }

    if (request.action === "status") {
      return json(200, { paired: identity.deviceOwnerLinked });
    }

    // unpair
    const plan = planUnpair(identity, request.deviceUserId);
    if (plan.kind === "refuse") throw new HttpError(plan.refusal.status, plan.refusal.code);

    if (plan.kind === "self") {
      // `identity.userId` is the owner here; the link row is the proof the
      // device belongs to them, and `removeDevices` scopes by both.
      const n = await removeDevices(serviceClient, identity.userId, [plan.deviceUserId]);
      return json(200, { unpaired: n });
    }

    // From the owner. The ids actually removed are the intersection with
    // this owner's links, so naming someone else's device removes nothing.
    const owned = await selectOwnedDeviceIDs(
      serviceClient,
      identity.userId,
      plan.kind === "named" ? [plan.deviceUserId] : undefined,
    );
    if (plan.kind === "named" && owned.length === 0) {
      throw new HttpError(404, "device_not_found");
    }
    const n = await removeDevices(serviceClient, identity.userId, owned);
    return json(200, { unpaired: n });
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`pair error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("pair error: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
});
