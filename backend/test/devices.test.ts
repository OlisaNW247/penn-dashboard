// Unit tests for the pure pairing / device-sync / delete-account decisions
// in supabase/functions/_shared/devices.ts. No network, no database.
import {
  BlobTooLargeError,
  blobRowKey,
  decideClaim,
  decideDeleteAccount,
  decideDeviceSyncAccess,
  decideStart,
  decodedBase64Length,
  DeviceValidationError,
  generatePairingCode,
  isPairingLive,
  MAX_BLOB_BYTES,
  PAIRING_CODE_PATTERN,
  pairingExpiry,
  planUnpair,
  resolveIdentity,
  validateDeviceSyncRequest,
  validatePairRequest,
} from "../supabase/functions/_shared/devices.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message ?? `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assert(condition: boolean, message?: string): void {
  if (!condition) throw new Error(message ?? "assertion failed");
}
function assertThrows(fn: () => unknown, cls?: new (...args: never[]) => Error): void {
  try {
    fn();
  } catch (err) {
    if (cls && !(err instanceof cls)) throw new Error(`expected ${cls.name}, got ${String(err)}`);
    return;
  }
  throw new Error("expected function to throw");
}

const OWNER = "11111111-1111-1111-1111-111111111111";
const DEVICE = "33333333-3333-3333-3333-333333333333";
const NOW = new Date("2026-10-22T12:00:00Z");

const ownerIdentity = resolveIdentity(OWNER, null);
const deviceIdentity = resolveIdentity(DEVICE, OWNER);

// ---- identity -------------------------------------------------------

Deno.test("resolveIdentity: a plain user is their own student", () => {
  assertEquals(ownerIdentity, { userId: OWNER, callerUserId: OWNER, deviceOwnerLinked: false });
});

Deno.test("resolveIdentity: a linked device resolves to its owner and remembers who called", () => {
  assertEquals(deviceIdentity, { userId: OWNER, callerUserId: DEVICE, deviceOwnerLinked: true });
});

Deno.test("resolveIdentity: a self-referential link is not a device", () => {
  assertEquals(resolveIdentity(OWNER, OWNER).deviceOwnerLinked, false);
});

// ---- pairing codes --------------------------------------------------

Deno.test("generatePairingCode: 128 bits, 22 url-safe characters, no padding", () => {
  for (let i = 0; i < 50; i++) {
    const code = generatePairingCode();
    assert(PAIRING_CODE_PATTERN.test(code), `bad shape: ${code}`);
    assertEquals(code.length, 22);
  }
});

Deno.test("generatePairingCode: asks for 16 bytes and encodes them as base64url", () => {
  let asked = 0;
  const code = generatePairingCode((n) => {
    asked = n;
    return new Uint8Array(n).fill(0xfb); // 0xfb bytes produce '+' and '/' in plain base64
  });
  assertEquals(asked, 16);
  assert(!/[+/=]/.test(code), "must be url-safe and unpadded");
  assertEquals(code, "-_v7-_v7-_v7-_v7-_v7-w");
});

Deno.test("generatePairingCode: two codes differ", () => {
  assert(generatePairingCode() !== generatePairingCode());
});

Deno.test("pairingExpiry is ten minutes out and isPairingLive is exclusive at the boundary", () => {
  const exp = pairingExpiry(NOW);
  assertEquals(exp.getTime() - NOW.getTime(), 10 * 60_000);
  assert(isPairingLive(exp, new Date(exp.getTime() - 1)));
  assert(!isPairingLive(exp, exp));
  assert(!isPairingLive("not a date", NOW));
});

// ---- pair requests --------------------------------------------------

Deno.test("validatePairRequest accepts each action", () => {
  assertEquals(validatePairRequest({ action: "start" }), { action: "start" });
  assertEquals(validatePairRequest({ action: "status" }), { action: "status" });
  assertEquals(validatePairRequest({ action: "claim", code: "abc" }), { action: "claim", code: "abc" });
  assertEquals(validatePairRequest({ action: "unpair" }), { action: "unpair" });
  assertEquals(validatePairRequest({ action: "unpair", deviceUserId: DEVICE.toUpperCase() }), {
    action: "unpair",
    deviceUserId: DEVICE,
  });
});

Deno.test("validatePairRequest rejects malformed requests", () => {
  assertThrows(() => validatePairRequest(null), DeviceValidationError);
  assertThrows(() => validatePairRequest([]), DeviceValidationError);
  assertThrows(() => validatePairRequest({ action: "nope" }), DeviceValidationError);
  assertThrows(() => validatePairRequest({ action: "claim" }), DeviceValidationError);
  assertThrows(() => validatePairRequest({ action: "claim", code: 5 }), DeviceValidationError);
  assertThrows(() => validatePairRequest({ action: "claim", code: "" }), DeviceValidationError);
  assertThrows(() => validatePairRequest({ action: "unpair", deviceUserId: "not-a-uuid" }), DeviceValidationError);
});

Deno.test("decideStart refuses a caller that is already a linked device", () => {
  assertEquals(decideStart(ownerIdentity), null);
  assertEquals(decideStart(deviceIdentity), { status: 409, code: "already_paired" });
});

// ---- claim ----------------------------------------------------------

const livePairing = { deviceUserId: DEVICE, expiresAt: new Date(NOW.getTime() + 60_000).toISOString() };
const expiredPairing = { deviceUserId: DEVICE, expiresAt: new Date(NOW.getTime() - 1).toISOString() };

Deno.test("decideClaim accepts a live code from a phone that is not a device", () => {
  assertEquals(decideClaim({ identity: ownerIdentity, pairing: livePairing, now: NOW }), null);
});

Deno.test("decideClaim: unknown and expired codes give the identical refusal", () => {
  const unknown = decideClaim({ identity: ownerIdentity, pairing: null, now: NOW });
  const expired = decideClaim({ identity: ownerIdentity, pairing: expiredPairing, now: NOW });
  assertEquals(unknown, { status: 404, code: "pairing_not_found" });
  assertEquals(expired, unknown);
});

Deno.test("decideClaim refuses a caller that is itself a linked device", () => {
  assertEquals(decideClaim({ identity: deviceIdentity, pairing: livePairing, now: NOW }), {
    status: 403,
    code: "forbidden",
  });
});

Deno.test("decideClaim refuses claiming your own code", () => {
  const self = resolveIdentity(DEVICE, null);
  assertEquals(decideClaim({ identity: self, pairing: livePairing, now: NOW }), { status: 403, code: "forbidden" });
});

// ---- unpair ---------------------------------------------------------

Deno.test("planUnpair from a device removes only itself", () => {
  assertEquals(planUnpair(deviceIdentity, undefined), { kind: "self", deviceUserId: DEVICE });
  assertEquals(planUnpair(deviceIdentity, DEVICE), { kind: "self", deviceUserId: DEVICE });
});

Deno.test("planUnpair from a device naming anyone else is refused", () => {
  assertEquals(planUnpair(deviceIdentity, "44444444-4444-4444-4444-444444444444"), {
    kind: "refuse",
    refusal: { status: 403, code: "forbidden" },
  });
});

Deno.test("planUnpair from the owner: named or all", () => {
  assertEquals(planUnpair(ownerIdentity, DEVICE), { kind: "named", deviceUserId: DEVICE });
  assertEquals(planUnpair(ownerIdentity, undefined), { kind: "all" });
});

// ---- delete-account (the dangerous one) -----------------------------

Deno.test("decideDeleteAccount: a linked device only ever unpairs itself", () => {
  assertEquals(decideDeleteAccount(deviceIdentity), "unpair_self");
});

Deno.test("decideDeleteAccount: the owner deletes their account", () => {
  assertEquals(decideDeleteAccount(ownerIdentity), "delete_owner");
});

Deno.test("decideDeleteAccount: a resolved user that is not the caller, without a device flag, is refused", () => {
  assertEquals(decideDeleteAccount({ userId: OWNER, callerUserId: DEVICE, deviceOwnerLinked: false }), "refuse");
});

Deno.test("decideDeleteAccount: no input can make a device delete its owner", () => {
  // Every identity with the device flag set, whatever the ids, is a self-unpair.
  for (const callerUserId of [DEVICE, OWNER, "x"]) {
    for (const userId of [DEVICE, OWNER, "y"]) {
      assertEquals(decideDeleteAccount({ userId, callerUserId, deviceOwnerLinked: true }), "unpair_self");
    }
  }
});

// ---- device-sync ----------------------------------------------------

Deno.test("decodedBase64Length computes decoded size from the text", () => {
  assertEquals(decodedBase64Length("AAAA"), 3);
  assertEquals(decodedBase64Length("AAA="), 2);
  assertEquals(decodedBase64Length("AA=="), 1);
  assertEquals(decodedBase64Length(btoa("hello world")), 11);
  assertEquals(decodedBase64Length(""), null);
  assertEquals(decodedBase64Length("AAA"), null);
  assertEquals(decodedBase64Length("AA=A"), null);
  assertEquals(decodedBase64Length("AA-_"), null, "url-safe alphabet is not base64");
});

Deno.test("validateDeviceSyncRequest accepts get and a well-formed put", () => {
  assertEquals(validateDeviceSyncRequest({ action: "get" }), { action: "get" });
  assertEquals(validateDeviceSyncRequest({ action: "put", deviceId: "laptop-01", ciphertext: "AAAA" }), {
    action: "put",
    deviceId: "laptop-01",
    ciphertext: "AAAA",
    decodedBytes: 3,
  });
});

Deno.test("validateDeviceSyncRequest rejects bad device ids, bad base64 and unknown actions", () => {
  assertThrows(() => validateDeviceSyncRequest({ action: "put", deviceId: "short", ciphertext: "AAAA" }), DeviceValidationError);
  assertThrows(() => validateDeviceSyncRequest({ action: "put", deviceId: "has space 1", ciphertext: "AAAA" }), DeviceValidationError);
  assertThrows(() => validateDeviceSyncRequest({ action: "put", deviceId: "x".repeat(65), ciphertext: "AAAA" }), DeviceValidationError);
  assertThrows(() => validateDeviceSyncRequest({ action: "put", deviceId: "laptop-01", ciphertext: "***" }), DeviceValidationError);
  assertThrows(() => validateDeviceSyncRequest({ action: "put", deviceId: "laptop-01" }), DeviceValidationError);
  assertThrows(() => validateDeviceSyncRequest({ action: "delete" }), DeviceValidationError);
  assertThrows(() => validateDeviceSyncRequest("get"), DeviceValidationError);
});

Deno.test("validateDeviceSyncRequest: exactly 2 MB decoded is accepted, one byte more is too large", () => {
  const atLimit = "AAAA".repeat(MAX_BLOB_BYTES / 3 | 0) + "AA=="; // floor(2MiB/3)*3 + 1 bytes
  // Build precisely: 2 MiB = 699050*3 + 2 bytes -> 699050 groups + "AAA=".
  const exact = "AAAA".repeat(699050) + "AAA=";
  assertEquals(decodedBase64Length(exact), MAX_BLOB_BYTES);
  assertEquals(validateDeviceSyncRequest({ action: "put", deviceId: "laptop-01", ciphertext: exact }).action, "put");
  assert(decodedBase64Length(atLimit)! <= MAX_BLOB_BYTES);
  const over = "AAAA".repeat(699050) + "AAAA"; // 2 MiB + 1 bytes
  assertThrows(() => validateDeviceSyncRequest({ action: "put", deviceId: "laptop-01", ciphertext: over }), BlobTooLargeError);
});

Deno.test("blobRowKey: a device's row is keyed by its own id, an owner's by the label it chose", () => {
  assertEquals(blobRowKey(deviceIdentity, "anything-goes"), DEVICE);
  assertEquals(blobRowKey(ownerIdentity, "phone-label"), "phone-label");
});

Deno.test("decideDeviceSyncAccess: devices and owners with devices only", () => {
  assertEquals(decideDeviceSyncAccess(deviceIdentity, true), null);
  assertEquals(decideDeviceSyncAccess(ownerIdentity, true), null);
  assertEquals(decideDeviceSyncAccess(ownerIdentity, false), { status: 403, code: "not_paired" });
});
