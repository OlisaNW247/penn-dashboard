// Apple Push Notification service client for the Sweeper wake
// (docs/SERVER_SWEEPER_DESIGN_2026-11-17.md §3.3 and §3.4). One kind of push
// only: a silent background nudge, `{"aps":{"content-available":1}}`, that
// asks a suspended phone to run its wake handler. No library: the provider
// token is an ES256 JWT signed with `crypto.subtle` over the team's `.p8`
// key (PKCS#8), and the request is a plain `fetch` that the Edge runtime
// sends to Apple over HTTP/2 (whether it does is what the end-to-end probe
// settles; a connection-level failure shows as status 0 below).
//
// Never logs a device token, a JWT or a key. Every function takes its clock
// and its `fetch` as parameters so the tests run with neither.

export type ApnsEnvironment = "production" | "development";

/** What the caller does about an answer. */
export type ApnsOutcome =
  | "ok" // 200: accepted by Apple, which is not the same as delivered
  | "badToken" // 400 BadDeviceToken / DeviceTokenNotForTopic: the row is wrong, count a failure
  | "remint" // 403 ExpiredProviderToken / InvalidProviderToken: mint a new JWT and retry once
  | "unregistered" // 410: the app was removed or the token rotated; delete the row now
  | "tooMany" // 429 TooManyRequests: leave this row alone for this tick
  | "providerTokenAbuse" // 429 TooManyProviderTokenUpdates: our remint logic is wrong; fail loudly
  | "serverError" // 5xx: no retry inside the tick, the moment would be over
  | "failed"; // anything else

export interface ApnsResult {
  /** The HTTP status Apple answered, or 0 when no answer came (connection-level failure). */
  status: number;
  reason?: string;
  outcome: ApnsOutcome;
}

export interface ApnsCredentials {
  keyPEM: string;
  keyID: string;
  teamID: string;
  topic: string;
}

export const DEFAULT_TOPIC = "com.lhf.lowhangingfruit";
/** Apple: "Refresh your token no more than once every 20 minutes and no less than once every 60 minutes". */
export const PROVIDER_TOKEN_TTL_MS = 50 * 60 * 1000;
/** How long APNs may hold a nudge for a phone that is offline: a moment two minutes old is over. */
export const EXPIRATION_SECONDS = 120;

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDER(pem: string): ArrayBuffer {
  // A multi-line PEM pasted into a secret often arrives with literal "\n".
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out.buffer as ArrayBuffer;
}

/** The provider token: JWS compact, header {alg: ES256, kid}, claims {iss, iat}.
 *  WebCrypto's ECDSA signature is already the raw r||s form JWS wants, so it
 *  needs no DER unwrapping. */
export async function signProviderToken(
  { keyPEM, keyID, teamID, now }: { keyPEM: string; keyID: string; teamID: string; now: number },
): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemToDER(keyPEM), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: keyID })));
  const claims = base64url(encoder.encode(JSON.stringify({ iss: teamID, iat: Math.floor(now / 1000) })));
  const signingInput = `${header}.${claims}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(signingInput)));
  return `${signingInput}.${base64url(signature)}`;
}

// A per-isolate cache, keyed by key id. The entry holds the *promise*, so
// thirty-two sends starting together share one mint instead of racing to
// make thirty-two tokens (Apple refuses more than one new token per twenty
// minutes: TooManyProviderTokenUpdates).
const tokenCache = new Map<string, { promise: Promise<string>; mintedAt: number }>();

export function providerToken(credentials: ApnsCredentials, now: number): Promise<string> {
  const cached = tokenCache.get(credentials.keyID);
  if (cached && now >= cached.mintedAt && now - cached.mintedAt < PROVIDER_TOKEN_TTL_MS) return cached.promise;
  const promise = signProviderToken({ keyPEM: credentials.keyPEM, keyID: credentials.keyID, teamID: credentials.teamID, now });
  tokenCache.set(credentials.keyID, { promise, mintedAt: now });
  // A failed mint must not be cached for 50 minutes.
  promise.catch(() => {
    if (tokenCache.get(credentials.keyID)?.promise === promise) tokenCache.delete(credentials.keyID);
  });
  return promise;
}

/** Drops the cached token for a key, so the next send mints a new one. Used
 *  once, after a 403 ExpiredProviderToken / InvalidProviderToken. */
export function forgetProviderToken(keyID: string): void {
  tokenCache.delete(keyID);
}

/** Apple's answer, as the tick acts on it. `body` is the parsed JSON body
 *  (`{ reason, timestamp? }`) or anything else when Apple sent none. For a
 *  410 the body's timestamp is milliseconds since the epoch and is not read:
 *  the row is deleted either way. */
export function readAPNsAnswer(status: number, body: unknown): ApnsResult {
  const reason = body && typeof body === "object" && typeof (body as Record<string, unknown>).reason === "string"
    ? (body as Record<string, string>).reason
    : undefined;
  const result = (outcome: ApnsOutcome): ApnsResult => (reason === undefined ? { status, outcome } : { status, reason, outcome });
  if (status === 200) return result("ok");
  if (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) return result("badToken");
  if (status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) return result("remint");
  if (status === 410) return result("unregistered");
  if (status === 429 && reason === "TooManyRequests") return result("tooMany");
  if (status === 429 && reason === "TooManyProviderTokenUpdates") return result("providerTokenAbuse");
  if (status >= 500 && status <= 599) return result("serverError");
  return result("failed");
}

export const hostFor = (environment: ApnsEnvironment): string =>
  environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";

export interface SendDeps {
  token: string;
  environment: ApnsEnvironment;
  topic: string;
  /** Epoch milliseconds. */
  now: number;
  fetch: typeof fetch;
  credentials: ApnsCredentials;
}

/** One silent background push. Header values are Apple's, verbatim from
 *  "Sending notification requests to APNs": background type, priority 5
 *  ("using priority 10 is an error"), the bundle id as topic, an expiration
 *  two minutes out. A transport failure is `status: 0, outcome: "failed"`,
 *  with the error's class (never its message, which may hold the URL and so
 *  the token) as the reason. */
export async function sendBackgroundPush(deps: SendDeps): Promise<ApnsResult> {
  const jwt = await providerToken(deps.credentials, deps.now);
  let response: Response;
  try {
    response = await deps.fetch(`${hostFor(deps.environment)}/3/device/${deps.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-topic": deps.topic,
        "apns-expiration": String(Math.floor(deps.now / 1000) + EXPIRATION_SECONDS),
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps: { "content-available": 1 } }),
    });
  } catch (err) {
    return { status: 0, reason: err instanceof Error ? err.constructor.name : "transport", outcome: "failed" };
  }
  let body: unknown = null;
  try {
    const text = await response.text();
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  return readAPNsAnswer(response.status, body);
}

/** Credentials from the function's secrets. Two keys, because Apple scopes a
 *  team key to one environment. A missing value throws an error naming the
 *  variable, never a value. */
export function apnsCredentialsFromEnv(
  environment: ApnsEnvironment,
  env: (key: string) => string | undefined = (k) => Deno.env.get(k),
): ApnsCredentials {
  const suffix = environment === "production" ? "PRODUCTION" : "SANDBOX";
  const need = (name: string): string => {
    const value = env(name);
    if (!value) throw new Error(`missing function secret ${name}`);
    return value;
  };
  return {
    keyPEM: need(`LHF_APNS_KEY_P8_${suffix}`),
    keyID: need(`LHF_APNS_KEY_ID_${suffix}`),
    teamID: need("LHF_APNS_TEAM_ID"),
    topic: env("LHF_APNS_TOPIC") || DEFAULT_TOPIC,
  };
}
