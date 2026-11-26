// The APNs client: the provider token is a real ES256 JWS (checked against
// the public key of a key generated here), the request is exactly Apple's
// (headers, host, body), every answer in the design's §3.4 table maps to its
// outcome, and the token cache holds for 50 minutes and can be forgotten.
import { strict as assert } from "node:assert";
import {
  apnsCredentialsFromEnv,
  forgetProviderToken,
  hostFor,
  iatFor,
  providerToken,
  readAPNsAnswer,
  sendSweepPush,
  signProviderToken,
} from "../supabase/functions/_shared/apns.ts";

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function unb64url(s: string): Uint8Array {
  const std = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(std);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

async function makeKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const lines = b64(der).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----`, publicKey: pair.publicKey };
}

const NOW = Date.UTC(2026, 10, 20, 4, 30, 0);
const TOKEN = "ab".repeat(32);

Deno.test("apns: the provider token is a valid ES256 JWS with kid, iss and iat", async () => {
  const { pem, publicKey } = await makeKey();
  const jwt = await signProviderToken({ keyPEM: pem, keyID: "ABC123DEFG", teamID: "24A3TDB277", now: NOW });
  const [h, c, sig] = jwt.split(".");
  assert.deepStrictEqual(JSON.parse(new TextDecoder().decode(unb64url(h))), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepStrictEqual(JSON.parse(new TextDecoder().decode(unb64url(c))), { iss: "24A3TDB277", iat: iatFor(NOW) });
  const raw = unb64url(sig);
  assert.strictEqual(raw.length, 64); // raw r||s, not DER
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw.buffer as ArrayBuffer, new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok);
  assert.ok(!/[+/=]/.test(jwt), "base64url, unpadded");
  // A PEM pasted into a secret with literal \n still imports.
  const escaped = pem.replace(/\n/g, "\\n");
  assert.ok((await signProviderToken({ keyPEM: escaped, keyID: "K", teamID: "T", now: NOW })).split(".").length === 3);
});

Deno.test("apns: the request is Apple's, header for header", async () => {
  const { pem } = await makeKey();
  const credentials = { keyPEM: pem, keyID: "KEYID00001", teamID: "TEAM000001", topic: "com.lhf.lowhangingfruit" };
  forgetProviderToken("KEYID00001");
  const seen: Array<{ url: string; init: RequestInit }> = [];
  const fakeFetch = ((url: string, init: RequestInit) => {
    seen.push({ url, init });
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;

  const prod = await sendSweepPush({ token: TOKEN, environment: "production", topic: credentials.topic, now: NOW, fetch: fakeFetch, credentials });
  assert.deepStrictEqual(prod, { status: 200, outcome: "ok" });
  assert.strictEqual(seen[0].url, `https://api.push.apple.com/3/device/${TOKEN}`);
  const headers = seen[0].init.headers as Record<string, string>;
  assert.deepStrictEqual(Object.keys(headers).sort(), ["apns-expiration", "apns-priority", "apns-push-type", "apns-topic", "authorization", "content-type"]);
  assert.match(headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.strictEqual(headers["apns-push-type"], "alert");
  assert.strictEqual(headers["apns-priority"], "10");
  assert.strictEqual(headers["apns-topic"], "com.lhf.lowhangingfruit");
  assert.strictEqual(headers["apns-expiration"], String(Math.floor(NOW / 1000) + 120));
  assert.strictEqual(headers["content-type"], "application/json");
  assert.strictEqual(seen[0].init.method, "POST");
  assert.strictEqual(seen[0].init.body, '{"aps":{"alert":{"title":"smooth","body":"checking your next deadline"},"mutable-content":1,"content-available":1,"interruption-level":"passive","thread-id":"sweeper"},"lhf":"sweep"}');

  await sendSweepPush({ token: TOKEN, environment: "development", topic: credentials.topic, now: NOW, fetch: fakeFetch, credentials });
  assert.strictEqual(seen[1].url, `https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
  assert.strictEqual(hostFor("production"), "https://api.push.apple.com");
});

Deno.test("apns: Apple's answers map to outcomes (design 3.4)", () => {
  const out = (status: number, reason?: string) => readAPNsAnswer(status, reason ? { reason } : null).outcome;
  assert.strictEqual(out(200), "ok");
  assert.strictEqual(out(400, "BadDeviceToken"), "badToken");
  assert.strictEqual(out(400, "DeviceTokenNotForTopic"), "badToken");
  assert.strictEqual(out(400, "PayloadEmpty"), "failed");
  assert.strictEqual(out(403, "ExpiredProviderToken"), "remint");
  assert.strictEqual(out(403, "InvalidProviderToken"), "remint");
  for (const r of ["BadTopic", "TopicDisallowed", "MissingTopic", "BadCertificate", "BadCertificateEnvironment"]) assert.strictEqual(out(400, r), "config", r);
  for (const r of ["Forbidden", "MissingProviderToken"]) assert.strictEqual(out(403, r), "config", r);
  assert.strictEqual(out(403, "SomethingNew"), "failed");
  assert.strictEqual(out(410, "Unregistered"), "unregistered");
  assert.strictEqual(out(429, "TooManyRequests"), "tooMany");
  assert.strictEqual(out(429, "TooManyProviderTokenUpdates"), "providerTokenAbuse");
  assert.strictEqual(out(500, "InternalServerError"), "serverError");
  assert.strictEqual(out(503, "ServiceUnavailable"), "serverError");
  assert.strictEqual(out(404), "failed");
  // A 410's timestamp is milliseconds; it is carried nowhere.
  assert.deepStrictEqual(readAPNsAnswer(410, { reason: "Unregistered", timestamp: 1769000000000 }), { status: 410, reason: "Unregistered", outcome: "unregistered" });
});

Deno.test("apns: a transport failure is status 0 and never carries the url", async () => {
  const { pem } = await makeKey();
  const credentials = { keyPEM: pem, keyID: "KEYID00002", teamID: "T", topic: "t" };
  const boom = (() => Promise.reject(new TypeError(`connect failed ${TOKEN}`))) as unknown as typeof fetch;
  const r = await sendSweepPush({ token: TOKEN, environment: "production", topic: "t", now: NOW, fetch: boom, credentials });
  assert.deepStrictEqual(r, { status: 0, reason: "TypeError", outcome: "failed" });
  assert.ok(!JSON.stringify(r).includes(TOKEN));
});

Deno.test("apns: iat is the 20-minute window's start, so two mints in one window agree", async () => {
  const { pem } = await makeKey();
  const claimsOf = (jwt: string) => JSON.parse(new TextDecoder().decode(unb64url(jwt.split(".")[1])));
  const a = await signProviderToken({ keyPEM: pem, keyID: "K", teamID: "T", now: Date.UTC(2026, 10, 20, 4, 21, 5) });
  const b = await signProviderToken({ keyPEM: pem, keyID: "K", teamID: "T", now: Date.UTC(2026, 10, 20, 4, 39, 59) });
  const c = await signProviderToken({ keyPEM: pem, keyID: "K", teamID: "T", now: Date.UTC(2026, 10, 20, 4, 40, 0) });
  assert.strictEqual(claimsOf(a).iat, claimsOf(b).iat);
  assert.strictEqual(claimsOf(a).iat, Date.UTC(2026, 10, 20, 4, 20, 0) / 1000);
  assert.strictEqual(claimsOf(c).iat, Date.UTC(2026, 10, 20, 4, 40, 0) / 1000);
  assert.strictEqual(iatFor(Date.UTC(2026, 10, 20, 4, 20, 0)), Date.UTC(2026, 10, 20, 4, 20, 0) / 1000);
});

Deno.test("apns: the provider token is cached for 50 minutes of its own age, shared, and forgettable", async () => {
  const { pem } = await makeKey();
  const credentials = { keyPEM: pem, keyID: "KEYID00003", teamID: "T", topic: "t" };
  forgetProviderToken("KEYID00003");
  const [a, b] = await Promise.all([providerToken(credentials, NOW), providerToken(credentials, NOW)]);
  assert.strictEqual(a, b);
  // NOW is 04:30; the token's iat is the 04:20 window start, so it is 50 minutes old at 05:10.
  assert.strictEqual(await providerToken(credentials, NOW + 39 * 60_000), a);
  const later = await providerToken(credentials, NOW + 41 * 60_000);
  assert.notStrictEqual(later, a);
  const again = await providerToken(credentials, NOW + 42 * 60_000);
  assert.strictEqual(again, later);
  forgetProviderToken("KEYID00003");
  // A remint inside the same 20-minute window carries the same claims (and
  // so tells Apple of no token "update"), whatever the signature does.
  const reminted = await providerToken(credentials, NOW + 43 * 60_000);
  assert.strictEqual(reminted.split(".")[1], later.split(".")[1]);
  forgetProviderToken("KEYID00003");
  const nextWindow = await providerToken(credentials, NOW + 60 * 60_000);
  assert.notStrictEqual(nextWindow.split(".")[1], later.split(".")[1]);
});

Deno.test("apns: credentials come from the environment and a missing one is named, not shown", () => {
  const vars: Record<string, string> = {
    LHF_APNS_KEY_P8_PRODUCTION: "PEM-PROD",
    LHF_APNS_KEY_ID_PRODUCTION: "PRODKEYID1",
    LHF_APNS_TEAM_ID: "24A3TDB277",
  };
  const env = (k: string) => vars[k];
  assert.deepStrictEqual(apnsCredentialsFromEnv("production", env), {
    keyPEM: "PEM-PROD",
    keyID: "PRODKEYID1",
    teamID: "24A3TDB277",
    topic: "com.lhf.lowhangingfruit",
  });
  assert.throws(() => apnsCredentialsFromEnv("development", env), /LHF_APNS_KEY_P8_SANDBOX/);
  vars.LHF_APNS_KEY_P8_SANDBOX = "SECRET-PEM";
  assert.throws(() => apnsCredentialsFromEnv("development", env), (e: Error) => /LHF_APNS_KEY_ID_SANDBOX/.test(e.message) && !e.message.includes("SECRET-PEM"));
  vars.LHF_APNS_KEY_ID_SANDBOX = "SANDKEYID1";
  vars.LHF_APNS_TOPIC = "com.example.other";
  assert.strictEqual(apnsCredentialsFromEnv("development", env).topic, "com.example.other");
});
