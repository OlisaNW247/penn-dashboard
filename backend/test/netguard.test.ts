// The fetch rules behind `discover-websites` (hardening BE-F): which URLs
// and addresses are refused, that every redirect hop is held to the same
// rules, and that a body is read with a byte cap and a deadline. Nothing
// here touches the network; names resolve through an injected table.
import { strict as assert } from "node:assert";
import {
  assertSafeURL,
  BlockedURLError,
  checkURLShape,
  guardedFetch,
  isBlockedAddress,
  isFetchableURL,
  type NetGuard,
  productionNetGuard,
  readCapped,
  readTextCapped,
  ResolverUnavailableError,
} from "../supabase/functions/_shared/netguard.ts";

/** A guard whose "DNS" is a table. Names not in it do not resolve. */
function guardWith(table: Record<string, string[]>, overrides: Partial<NetGuard> = {}): NetGuard {
  return {
    allowedHostSuffixes: ["upenn.edu"],
    resolve: (hostname) => {
      const answer = table[hostname];
      return answer ? Promise.resolve(answer) : Promise.reject(new Error("does not resolve"));
    },
    maxRedirects: 5,
    resolveTimeoutMs: 500,
    ...overrides,
  };
}

const PUBLIC = "130.91.1.1";
const GUARD = guardWith({
  "www.seas.upenn.edu": [PUBLIC],
  "www.cis.upenn.edu": [PUBLIC, "2607:f470:6:1::1"],
  "rebind.upenn.edu": ["10.0.0.5"],
  "mixed.upenn.edu": [PUBLIC, "169.254.169.254"],
  "v6.upenn.edu": ["fd00:ec2::254"],
});

// ---------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------

Deno.test("isBlockedAddress: private, loopback, link-local, metadata and reserved IPv4 ranges", () => {
  for (
    const ip of [
      "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.255", "127.0.0.1", "127.255.255.254",
      "169.254.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.0.2.1", "192.168.0.1",
      "192.168.255.255", "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9", "224.0.0.1", "239.255.255.255",
      "240.0.0.1", "255.255.255.255",
    ]
  ) {
    assert.equal(isBlockedAddress(ip), true, ip);
  }
});

Deno.test("isBlockedAddress: public IPv4 addresses next to those ranges are allowed", () => {
  for (
    const ip of ["8.8.8.8", "130.91.1.1", "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "169.253.0.1", "11.0.0.1"]
  ) {
    assert.equal(isBlockedAddress(ip), false, ip);
  }
});

Deno.test("isBlockedAddress: IPv6 loopback, unspecified, unique-local, link-local and multicast", () => {
  for (
    const ip of ["::", "::1", "fe80::1", "fe80::abcd%eth0", "febf::1", "fc00::1", "fd00:ec2::254", "fdff::1", "ff02::1", "fec0::1"]
  ) {
    assert.equal(isBlockedAddress(ip), true, ip);
  }
});

Deno.test("isBlockedAddress: IPv6 forms that carry an IPv4 address are judged by that address", () => {
  assert.equal(isBlockedAddress("::ffff:10.0.0.1"), true);
  assert.equal(isBlockedAddress("::ffff:127.0.0.1"), true);
  assert.equal(isBlockedAddress("::ffff:a00:1"), true); // the same, in hex
  assert.equal(isBlockedAddress("::ffff:169.254.169.254"), true);
  assert.equal(isBlockedAddress("::ffff:8.8.8.8"), false);
  assert.equal(isBlockedAddress("64:ff9b::a00:1"), true); // NAT64 of 10.0.0.1
  assert.equal(isBlockedAddress("64:ff9b::808:808"), false); // NAT64 of 8.8.8.8
  assert.equal(isBlockedAddress("::10.0.0.1"), true); // deprecated IPv4-compatible
  assert.equal(isBlockedAddress("2002:a00:1::"), true); // 6to4
  assert.equal(isBlockedAddress("2001:0:4136:e378:8000:63bf:3fff:fdd2"), true); // Teredo
  assert.equal(isBlockedAddress("2001:db8::1"), true); // documentation
});

Deno.test("isBlockedAddress: public IPv6 addresses are allowed", () => {
  for (const ip of ["2607:f470:6:1::1", "2001:4860:4860::8888", "2606:4700:4700::1111"]) {
    assert.equal(isBlockedAddress(ip), false, ip);
  }
});

Deno.test("isBlockedAddress: anything that is not an address is blocked", () => {
  for (const text of ["", "not-an-ip", "999.1.1.1", "1.2.3", "1.2.3.4.5", "2130706433", "0x7f.0.0.1", "1::2::3", "gggg::1", ":::"]) {
    assert.equal(isBlockedAddress(text), true, text);
  }
});

// ---------------------------------------------------------------------
// URL shape
// ---------------------------------------------------------------------

function blocked(url: string, guard: NetGuard = GUARD): void {
  assert.throws(() => checkURLShape(new URL(url), guard), BlockedURLError, url);
  assert.equal(isFetchableURL(url, guard), false, url);
}

Deno.test("checkURLShape: https URLs on allow-listed names pass", () => {
  for (
    const url of [
      "https://www.seas.upenn.edu/~cis2400/current/",
      "https://upenn.edu/",
      "https://WWW.SEAS.UPENN.EDU/x",
      "https://www.seas.upenn.edu./x", // fully-qualified form
      "https://cis5550.seas.upenn.edu:443/",
    ]
  ) {
    checkURLShape(new URL(url), GUARD);
    assert.equal(isFetchableURL(url, GUARD), true, url);
  }
});

Deno.test("checkURLShape: plain http, other schemes, credentials and other ports are refused", () => {
  blocked("http://www.seas.upenn.edu/");
  blocked("ftp://www.seas.upenn.edu/");
  blocked("file:///etc/passwd");
  blocked("https://user:pw@www.seas.upenn.edu/");
  blocked("https://user@www.seas.upenn.edu/");
  blocked("https://www.seas.upenn.edu:8443/");
  blocked("https://www.seas.upenn.edu:22/");
});

Deno.test("checkURLShape: IP literals are refused however they are written", () => {
  blocked("https://127.0.0.1/");
  blocked("https://169.254.169.254/latest/meta-data/");
  blocked("https://10.0.0.5/");
  blocked("https://[::1]/");
  blocked("https://[fd00:ec2::254]/");
  blocked("https://[::ffff:10.0.0.1]/");
  blocked("https://2130706433/"); // the URL parser turns this into 127.0.0.1
  blocked("https://0x7f000001/");
  blocked("https://0177.0.0.1/");
});

Deno.test("checkURLShape: local names and names off the allow-list are refused", () => {
  blocked("https://localhost/");
  blocked("https://intranet/");
  blocked("https://metadata.google.internal/");
  blocked("https://example.org/");
  blocked("https://evilupenn.edu/"); // suffix match is on a label boundary
  blocked("https://upenn.edu.evil.example/");
  blocked("https://www.upenn.edu.evil.example/");
  blocked("https://github.com/just-the-docs/just-the-docs");
});

Deno.test("productionNetGuard: upenn.edu by default, extended by LHF_DISCOVERY_HOSTS", () => {
  const plain = productionNetGuard({ get: () => undefined });
  assert.deepEqual(plain.allowedHostSuffixes, ["upenn.edu"]);
  assert.equal(isFetchableURL("https://cis1912.org/", plain), false);

  const env = new Map([["LHF_DISCOVERY_HOSTS", " CIS1912.org, *.github.io ,,.example.edu"]]);
  const extended = productionNetGuard({ get: (name) => env.get(name) });
  assert.deepEqual(extended.allowedHostSuffixes, ["upenn.edu", "cis1912.org", "github.io", "example.edu"]);
  assert.equal(isFetchableURL("https://cis1912.org/syllabus", extended), true);
  assert.equal(isFetchableURL("https://someone.github.io/cis1912/", extended), true);
  assert.equal(isFetchableURL("https://notgithub.io/", extended), false);
});

// ---------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------

Deno.test("assertSafeURL: a name that resolves to public addresses passes, v4 and v6", async () => {
  await assertSafeURL(new URL("https://www.seas.upenn.edu/"), GUARD);
  await assertSafeURL(new URL("https://www.cis.upenn.edu/"), GUARD);
});

Deno.test("assertSafeURL: an allow-listed name that resolves to a private address is refused", async () => {
  await assert.rejects(() => assertSafeURL(new URL("https://rebind.upenn.edu/"), GUARD), BlockedURLError);
  await assert.rejects(() => assertSafeURL(new URL("https://v6.upenn.edu/"), GUARD), BlockedURLError);
});

Deno.test("assertSafeURL: one private address among public ones is enough to refuse", async () => {
  await assert.rejects(() => assertSafeURL(new URL("https://mixed.upenn.edu/"), GUARD), BlockedURLError);
});

Deno.test("assertSafeURL: a name that does not resolve, or resolves to nothing, is refused", async () => {
  await assert.rejects(() => assertSafeURL(new URL("https://nowhere.upenn.edu/"), GUARD), BlockedURLError);
  const empty = guardWith({ "empty.upenn.edu": [] });
  await assert.rejects(() => assertSafeURL(new URL("https://empty.upenn.edu/"), empty), BlockedURLError);
});

Deno.test("assertSafeURL: a lookup that hangs is cut off and refused", async () => {
  const hung = guardWith({}, { resolve: () => new Promise(() => {}), resolveTimeoutMs: 30 });
  const started = Date.now();
  await assert.rejects(() => assertSafeURL(new URL("https://www.seas.upenn.edu/"), hung), BlockedURLError);
  assert.ok(Date.now() - started < 1000);
});

Deno.test("assertSafeURL: a runtime with no DNS API falls back to the hostname rules, which still apply", async () => {
  const noDNS = guardWith({}, { resolve: () => Promise.reject(new ResolverUnavailableError("no dns")) });
  await assertSafeURL(new URL("https://www.seas.upenn.edu/"), noDNS);
  await assert.rejects(() => assertSafeURL(new URL("https://127.0.0.1/"), noDNS), BlockedURLError);
  await assert.rejects(() => assertSafeURL(new URL("https://example.org/"), noDNS), BlockedURLError);
});

// ---------------------------------------------------------------------
// guardedFetch
// ---------------------------------------------------------------------

type Hop = { status: number; location?: string; body?: string };

/** A fetch that serves hops by URL, records what it was asked, and fails on
 *  any request that should never have been made. */
function hopFetch(hops: Record<string, Hop>) {
  const calls: Array<{ url: string; redirect: RequestRedirect | undefined }> = [];
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, redirect: init?.redirect });
    const hop = hops[url];
    if (!hop) throw new Error(`unexpected request to ${url}`);
    const headers = new Headers();
    if (hop.location) headers.set("location", hop.location);
    return new Response(hop.status === 204 ? null : hop.body ?? "", { status: hop.status, headers });
  }) as typeof fetch;
  return { fetchImpl, calls };
}

Deno.test("guardedFetch: a plain response comes back as is, fetched with redirect: manual", async () => {
  const { fetchImpl, calls } = hopFetch({ "https://www.seas.upenn.edu/a": { status: 200, body: "hello" } });
  const res = await guardedFetch(fetchImpl, "https://www.seas.upenn.edu/a", { timeoutMs: 500 }, GUARD);
  assert.equal(await res.text(), "hello");
  assert.deepEqual(calls, [{ url: "https://www.seas.upenn.edu/a", redirect: "manual" }]);
  assert.equal(res.url, "https://www.seas.upenn.edu/a", "the landing URL is reported when the runtime did not set one");
});

Deno.test("guardedFetch: follows redirects itself, resolving relative Locations, and reports the last URL", async () => {
  const { fetchImpl, calls } = hopFetch({
    "https://www.seas.upenn.edu/~cis2400/current/": { status: 302, location: "../26fa/" },
    "https://www.seas.upenn.edu/~cis2400/26fa/": { status: 301, location: "https://www.cis.upenn.edu/x/" },
    "https://www.cis.upenn.edu/x/": { status: 200, body: "landed" },
  });
  const res = await guardedFetch(fetchImpl, "https://www.seas.upenn.edu/~cis2400/current/", { timeoutMs: 500 }, GUARD);
  assert.equal(await res.text(), "landed");
  assert.equal(res.url, "https://www.cis.upenn.edu/x/");
  assert.equal(calls.length, 3);
  assert.ok(calls.every((call) => call.redirect === "manual"));
});

Deno.test("guardedFetch: every redirect hop is held to the rules, and a refused hop is never requested", async () => {
  const targets = [
    "http://www.seas.upenn.edu/downgrade", // plain http
    "https://example.org/offsite", // off the allow-list
    "https://169.254.169.254/latest/meta-data/", // metadata service
    "https://127.0.0.1/", // loopback
    "https://[::1]/",
    "https://rebind.upenn.edu/", // allowed name, private address
    "https://user:pw@www.seas.upenn.edu/", // credentials
    "https://www.seas.upenn.edu:8443/", // other port
  ];
  for (const target of targets) {
    const { fetchImpl, calls } = hopFetch({
      "https://www.seas.upenn.edu/start": { status: 302, location: target },
      [target]: { status: 200, body: "should never be fetched" },
    });
    await assert.rejects(
      () => guardedFetch(fetchImpl, "https://www.seas.upenn.edu/start", { timeoutMs: 500 }, GUARD),
      BlockedURLError,
      target,
    );
    assert.deepEqual(calls.map((call) => call.url), ["https://www.seas.upenn.edu/start"], `${target} must not be requested`);
  }
});

Deno.test("guardedFetch: a start URL that breaks the rules is refused before any request", async () => {
  const { fetchImpl, calls } = hopFetch({});
  for (const url of ["http://www.seas.upenn.edu/", "https://127.0.0.1/", "https://example.org/", "not a url"]) {
    await assert.rejects(() => guardedFetch(fetchImpl, url, { timeoutMs: 500 }, GUARD), BlockedURLError, url);
  }
  assert.equal(calls.length, 0);
});

Deno.test("guardedFetch: a redirect loop or a long chain stops at maxRedirects", async () => {
  const { fetchImpl, calls } = hopFetch({
    "https://www.seas.upenn.edu/a": { status: 302, location: "/b" },
    "https://www.seas.upenn.edu/b": { status: 302, location: "/a" },
  });
  await assert.rejects(
    () => guardedFetch(fetchImpl, "https://www.seas.upenn.edu/a", { timeoutMs: 500 }, guardWith({ "www.seas.upenn.edu": [PUBLIC] }, { maxRedirects: 3 })),
    BlockedURLError,
  );
  assert.equal(calls.length, 4, "the first request plus three hops");
});

Deno.test("guardedFetch: a redirect status with no Location is returned as is", async () => {
  const { fetchImpl } = hopFetch({ "https://www.seas.upenn.edu/a": { status: 302 } });
  const res = await guardedFetch(fetchImpl, "https://www.seas.upenn.edu/a", { timeoutMs: 500 }, GUARD);
  assert.equal(res.status, 302);
});

Deno.test("guardedFetch: a hop that never answers is aborted at the timeout", async () => {
  let aborted = false;
  const fetchImpl = ((_input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        aborted = true;
        reject(new DOMException("aborted", "AbortError"));
      });
    })) as typeof fetch;
  const started = Date.now();
  await assert.rejects(() => guardedFetch(fetchImpl, "https://www.seas.upenn.edu/slow", { timeoutMs: 40 }, GUARD));
  assert.ok(Date.now() - started < 1000);
  assert.equal(aborted, true);
});

// ---------------------------------------------------------------------
// Bodies
// ---------------------------------------------------------------------

/** A body that produces `chunk` forever, one pull at a time, recording how
 *  much was pulled and whether the consumer cancelled it. */
function endlessBody(chunk: Uint8Array) {
  const state = { pulled: 0, cancelled: false };
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      state.pulled += chunk.byteLength;
      controller.enqueue(chunk);
    },
    cancel() {
      state.cancelled = true;
    },
  });
  return { body, state };
}

Deno.test("readCapped: a body under the cap is returned whole and not truncated", async () => {
  const res = new Response("hello world");
  const read = await readCapped(res, { maxBytes: 100, deadlineMs: 500 });
  assert.equal(new TextDecoder().decode(read!.bytes), "hello world");
  assert.equal(read!.truncated, false);
});

Deno.test("readCapped: an endless body is cut at the cap and the connection is cancelled", async () => {
  const { body, state } = endlessBody(new Uint8Array(1000).fill(65));
  const read = await readCapped(new Response(body), { maxBytes: 2500, deadlineMs: 2000 });
  assert.equal(read!.bytes.byteLength, 2500);
  assert.equal(read!.truncated, true);
  assert.equal(state.cancelled, true, "the unread remainder must be cancelled, not left open");
  assert.ok(state.pulled < 100_000, `read far past the cap: ${state.pulled}`);
});

Deno.test("readCapped: a body exactly at the cap is not truncated", async () => {
  const read = await readCapped(new Response(new Uint8Array(500)), { maxBytes: 500, deadlineMs: 500 });
  assert.equal(read!.bytes.byteLength, 500);
  assert.equal(read!.truncated, false);
});

Deno.test("readCapped: a body that stalls is abandoned at the deadline and cancelled", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("a few bytes, then silence"));
    },
    cancel() {
      cancelled = true;
    },
  });
  const started = Date.now();
  const read = await readCapped(new Response(body), { maxBytes: 1_000_000, deadlineMs: 60 });
  assert.equal(read, undefined);
  assert.ok(Date.now() - started < 1000);
  assert.equal(cancelled, true);
});

Deno.test("readCapped: a body that errors mid-read is undefined, not a throw", async () => {
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("partial"));
      controller.error(new Error("connection reset"));
    },
  });
  assert.equal(await readCapped(new Response(body), { maxBytes: 100, deadlineMs: 500 }), undefined);
});

Deno.test("readTextCapped: decodes UTF-8, and a character cut by the cap does not throw", async () => {
  const text = "café ☕ "; // multi-byte characters
  const whole = await readTextCapped(new Response(text), { maxBytes: 1000, deadlineMs: 500 });
  assert.equal(whole!.text, text);
  const cutMidCharacter = await readTextCapped(new Response("a☕b"), { maxBytes: 2, deadlineMs: 500 });
  assert.equal(cutMidCharacter!.truncated, true);
  assert.equal(cutMidCharacter!.text.startsWith("a"), true);
});
