// Pure decisions for the Chrome extension's pairing and encrypted device
// sync (docs/CHROME_EXTENSION.md; PROTOCOL.md -> `pair`, `device-sync`).
// Dependency-free like manifest.ts: every rule that has a "why" lives here
// where `devices.test.ts` can drive it without a database, and the edge
// functions only wire request -> decision -> db.ts.

/** Thrown by the validators below; callers turn it into a 400. */
export class DeviceValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DeviceValidationError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// ---------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------

export interface ResolvedIdentity {
  /** The student every data rule scopes to: the owner when the caller is a
   *  linked device, else the caller. */
  userId: string;
  /** The token's own user. */
  callerUserId: string;
  deviceOwnerLinked: boolean;
}

/** Folds the `device_links` lookup for the caller into the identity the
 * rest of the backend uses. `ownerUserId` is the link's owner, or null/
 * undefined when the caller is not a linked device. A link that points at
 * the caller itself is treated as no link: it cannot be created through
 * `pair`, and honouring it would make `deviceOwnerLinked` true for a user
 * whose "owner" is themself, which the delete-account rule would then
 * misread as a device. */
export function resolveIdentity(callerUserId: string, ownerUserId: string | null | undefined): ResolvedIdentity {
  if (ownerUserId && ownerUserId !== callerUserId) {
    return { userId: ownerUserId, callerUserId, deviceOwnerLinked: true };
  }
  return { userId: callerUserId, callerUserId, deviceOwnerLinked: false };
}

// ---------------------------------------------------------------------
// Pairing codes
// ---------------------------------------------------------------------

export const PAIRING_TTL_MS = 10 * 60_000;
/** 128 random bits as unpadded base64url is exactly 22 characters. */
export const PAIRING_CODE_PATTERN = /^[A-Za-z0-9_-]{22}$/;

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** A fresh pairing code: 128 bits from the platform CSPRNG. `randomBytes`
 * is a parameter only so a test can pin it; production uses
 * `crypto.getRandomValues`. The wrong fix would be a shorter, typeable
 * code: the code is carried by a QR, nobody types it, and a short one
 * could be guessed inside its ten minutes by anyone with an anonymous
 * account to call `claim` from. */
export function generatePairingCode(
  randomBytes: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n)),
): string {
  return base64url(randomBytes(16));
}

export function pairingExpiry(now: Date): Date {
  return new Date(now.getTime() + PAIRING_TTL_MS);
}

export function isPairingLive(expiresAt: string | Date, now: Date): boolean {
  const ms = new Date(expiresAt).getTime();
  return !Number.isNaN(ms) && ms > now.getTime();
}

// ---------------------------------------------------------------------
// `pair` requests
// ---------------------------------------------------------------------

const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export type PairRequest =
  | { action: "start" }
  | { action: "claim"; code: string }
  | { action: "status" }
  | { action: "unpair"; deviceUserId?: string };

export function validatePairRequest(raw: unknown): PairRequest {
  if (!isRecord(raw)) throw new DeviceValidationError("request body must be an object");
  switch (raw["action"]) {
    case "start":
      return { action: "start" };
    case "status":
      return { action: "status" };
    case "claim": {
      const code = raw["code"];
      if (typeof code !== "string" || code.length === 0 || code.length > 128) {
        throw new DeviceValidationError("claim requires a \"code\" string");
      }
      return { action: "claim", code };
    }
    case "unpair": {
      const id = raw["deviceUserId"];
      if (id === undefined || id === null) return { action: "unpair" };
      if (typeof id !== "string" || !UUID_PATTERN.test(id)) {
        throw new DeviceValidationError("\"deviceUserId\" must be a user id when present");
      }
      return { action: "unpair", deviceUserId: id.toLowerCase() };
    }
    default:
      throw new DeviceValidationError(`unknown action "${String(raw["action"])}"`);
  }
}

export interface Refusal {
  status: number;
  code: string;
}

/** `start`: the caller must not already be a linked device. */
export function decideStart(identity: ResolvedIdentity): Refusal | null {
  return identity.deviceOwnerLinked ? { status: 409, code: "already_paired" } : null;
}

export interface ClaimFacts {
  identity: ResolvedIdentity;
  /** The pairing row for the presented code, or null when none exists. */
  pairing: { deviceUserId: string; expiresAt: string } | null;
  now: Date;
}

/** `claim`: every refusal that should be decided before the code is
 * consumed. A malformed code, an unknown code and an expired code all give
 * the same 404 so that nothing can be learned about which codes exist or
 * have existed. The wrong fix for "expired" would be a distinct 410: that
 * would let a prober tell a real-but-stale code from a made-up one. */
export function decideClaim(facts: ClaimFacts): Refusal | null {
  if (facts.identity.deviceOwnerLinked) return { status: 403, code: "forbidden" };
  const { pairing } = facts;
  if (!pairing || !isPairingLive(pairing.expiresAt, facts.now)) {
    return { status: 404, code: "pairing_not_found" };
  }
  if (pairing.deviceUserId === facts.identity.callerUserId) return { status: 403, code: "forbidden" };
  return null;
}

/** Decides `unpair`, given who is calling and what they named. Returns the
 * device user ids to remove, constrained *before* any database lookup to
 * what the caller may even ask for; the function still intersects with
 * `device_links` by owner. */
export type UnpairPlan =
  | { kind: "refuse"; refusal: Refusal }
  | { kind: "self"; deviceUserId: string }
  | { kind: "named"; deviceUserId: string }
  | { kind: "all" };

export function planUnpair(identity: ResolvedIdentity, requested: string | undefined): UnpairPlan {
  if (identity.deviceOwnerLinked) {
    // A device may only remove itself. Naming anyone else is refused rather
    // than ignored, so a bug cannot look like success.
    if (requested !== undefined && requested !== identity.callerUserId.toLowerCase()) {
      return { kind: "refuse", refusal: { status: 403, code: "forbidden" } };
    }
    return { kind: "self", deviceUserId: identity.callerUserId };
  }
  return requested === undefined ? { kind: "all" } : { kind: "named", deviceUserId: requested };
}

// ---------------------------------------------------------------------
// delete-account
// ---------------------------------------------------------------------

export type DeleteAccountDecision = "delete_owner" | "unpair_self" | "refuse";

/** The most dangerous decision in the backend: after identity resolution a
 * linked device's `userId` IS its owner, so passing `userId` to the
 * existing delete path from a device's token would erase the student's
 * whole account from a laptop. A device therefore only ever unpairs
 * itself. The owner path additionally demands that the resolved user is
 * the token's own user, so a future change to identity resolution cannot
 * reopen the hole silently: any mismatch is refused. */
export function decideDeleteAccount(identity: ResolvedIdentity): DeleteAccountDecision {
  if (identity.deviceOwnerLinked) return "unpair_self";
  if (identity.userId !== identity.callerUserId) return "refuse";
  return "delete_owner";
}

// ---------------------------------------------------------------------
// device-sync
// ---------------------------------------------------------------------

export const MAX_BLOB_BYTES = 2 * 1024 * 1024;
export const DEVICE_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/** Decoded size of a standard base64 string without decoding it (the
 * server never parses ciphertext), or null if it is not canonical base64.
 * Computed from the length so a 2 MB limit does not cost a 2 MB allocation
 * to enforce. */
export function decodedBase64Length(text: string): number | null {
  if (text.length === 0 || !BASE64_PATTERN.test(text)) return null;
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  return (text.length / 4) * 3 - padding;
}

export type DeviceSyncRequest =
  | { action: "put"; deviceId: string; ciphertext: string; decodedBytes: number }
  | { action: "get" };

export class BlobTooLargeError extends Error {
  constructor() {
    super(`ciphertext exceeds ${MAX_BLOB_BYTES} decoded bytes`);
    this.name = "BlobTooLargeError";
  }
}

export function validateDeviceSyncRequest(raw: unknown): DeviceSyncRequest {
  if (!isRecord(raw)) throw new DeviceValidationError("request body must be an object");
  if (raw["action"] === "get") return { action: "get" };
  if (raw["action"] !== "put") throw new DeviceValidationError(`unknown action "${String(raw["action"])}"`);

  const deviceId = raw["deviceId"];
  if (typeof deviceId !== "string" || !DEVICE_ID_PATTERN.test(deviceId)) {
    throw new DeviceValidationError("\"deviceId\" must match ^[A-Za-z0-9_-]{8,64}$");
  }
  const ciphertext = raw["ciphertext"];
  if (typeof ciphertext !== "string") throw new DeviceValidationError("\"ciphertext\" must be a base64 string");
  const decodedBytes = decodedBase64Length(ciphertext);
  if (decodedBytes === null) throw new DeviceValidationError("\"ciphertext\" is not valid base64");
  if (decodedBytes > MAX_BLOB_BYTES) throw new BlobTooLargeError();
  return { action: "put", deviceId, ciphertext, decodedBytes };
}

/** Which blob row a `put` writes. An owner writes the label it chose. A
 * linked device's row is keyed by its own user id whatever label it sent:
 * the server must be able to find "that device's blob" when it is
 * unpaired, and a label the device picked cannot be traced back to it. The
 * ids are never logged. */
export function blobRowKey(identity: ResolvedIdentity, requestedDeviceId: string): string {
  return identity.deviceOwnerLinked ? identity.callerUserId : requestedDeviceId;
}

/** Only an owner (someone with at least one linked device) or a linked
 * device may use device-sync. A fresh anonymous user that never paired is
 * neither, and gets 403 `not_paired`. */
export function decideDeviceSyncAccess(identity: ResolvedIdentity, ownerHasDevices: boolean): Refusal | null {
  if (identity.deviceOwnerLinked || ownerHasDevices) return null;
  return { status: 403, code: "not_paired" };
}
