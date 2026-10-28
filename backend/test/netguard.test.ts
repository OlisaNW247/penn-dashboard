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
  isSafeToFetch,
  type NetGuard,
  productionNetGuard,
  readCapped,
  readTextCapped,
  ResolverUnavailableError,
  upgradeToHTTPS,
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

/** The default production shape: no host restriction, any public name. */
const OPEN_GUARD = guardWith({
  "www.seas.upenn.edu": [PUBLIC],
  "cis1912.org": [PUBLIC],
  "someone.github.io": ["185.199.108.153"],
  "lab.example.edu": [PUBLIC],
  "evil.example.com": ["10.0.0.5"], // an attacker's name pointed at the inside of a network
  "metadata-alias.example.com": ["169.254.169.254"],
  "dual.example.com": [PUBLIC, "fd00:ec2::254"],
}, { allowedHostSuffixes: null });

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
  // The shape check itself stays strict. A URL we were handed is upgraded to
  // https before it gets here (upgradeToHTTPS, below); a redirect hop is not.
  assert.throws(() => checkURLShape(new URL("http://www.seas.upenn.edu/"), GUARD), BlockedURLError);
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

// The host allow-list is opt-in. Course sites live on their own domains
// (cis1912.org, *.github.io, a lab's own site) and finding those is what
// discovery is for, so with nothing configured any public name is allowed;
// LHF_DISCOVERY_HOSTS narrows it.
Deno.test("productionNetGuard: with LHF_DISCOVERY_HOSTS unset, any public https host is allowed", () => {
  for (const env of [new Map<string, string>(), new Map([["LHF_DISCOVERY_HOSTS", ""]]), new Map([["LHF_DISCOVERY_HOSTS", " , ,"]])]) {
    const open = productionNetGuard({ get: (name) => env.get(name) });
    assert.equal(open.allowedHostSuffixes, null, "unset, blank and only-commas all mean no restriction");
    for (
      const url of [
        "https://cis1912.org/syllabus",
        "https://someone.github.io/cis1912/",
        "https://www.seas.upenn.edu/~cis2400/current/",
        "https://lab.example.edu/course/",
        "https://example.org/",
      ]
    ) {
      assert.equal(isFetchableURL(url, open), true, url);
    }
  }
});

Deno.test("productionNetGuard: with LHF_DISCOVERY_HOSTS set, only upenn.edu and the listed suffixes are allowed", () => {
  const env = new Map([["LHF_DISCOVERY_HOSTS", " CIS1912.org, *.github.io ,,.example.edu"]]);
  const restricted = productionNetGuard({ get: (name) => env.get(name) });
  assert.deepEqual(restricted.allowedHostSuffixes, ["upenn.edu", "cis1912.org", "github.io", "example.edu"]);
  for (
    const url of [
      "https://cis1912.org/syllabus",
      "https://someone.github.io/cis1912/",
      "https://lab.example.edu/",
      "https://www.seas.upenn.edu/~cis2400/",
    ]
  ) {
    assert.equal(isFetchableURL(url, restricted), true, url);
  }
  for (const url of ["https://example.org/", "https://notgithub.io/", "https://evilupenn.edu/", "https://other-course-site.com/"]) {
    assert.equal(isFetchableURL(url, restricted), false, url);
  }
});

Deno.test("with no allow-list, every other rule still holds: scheme, port, credentials, IP literals, internal names", () => {
  for (
    const url of [
      "http://cis1912.org:8080/",
      "https://cis1912.org:8443/",
      "https://user:pw@cis1912.org/",
      "https://127.0.0.1/",
      "https://169.254.169.254/latest/meta-data/",
      "https://[::1]/",
      "https://2130706433/",
      "https://localhost/",
      "https://printer/",
      "https://metadata.google.internal/computeMetadata/v1/",
      "https://nas.local/",
      "https://wiki.intranet/",
      "https://router.lan/",
      "https://thing.home.arpa/",
      "https://app.corp/",
      "https://site.localhost/",
      "https://x.onion/",
    ]
  ) {
    assert.equal(isFetchableURL(url, OPEN_GUARD), false, url);
  }
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

Deno.test("assertSafeURL, no allow-list: public names pass, and the address check is what stops a name pointed inward", async () => {
  await assertSafeURL(new URL("https://cis1912.org/"), OPEN_GUARD);
  await assertSafeURL(new URL("https://someone.github.io/x/"), OPEN_GUARD);
  for (const name of ["evil.example.com", "metadata-alias.example.com", "dual.example.com"]) {
    await assert.rejects(() => assertSafeURL(new URL(`https://${name}/`), OPEN_GUARD), BlockedURLError, name);
  }
  await assert.rejects(() => assertSafeURL(new URL("https://nowhere.example.com/"), OPEN_GUARD), BlockedURLError);
});

Deno.test("assertSafeURL: a runtime with no DNS API is refused when there is no allow-list, and tolerated when there is one", async () => {
  const noDNS = (allowed: readonly string[] | null) =>
    guardWith({}, { allowedHostSuffixes: allowed, resolve: () => Promise.reject(new ResolverUnavailableError("no dns")) });
  // Nothing else would stop an attacker's name resolving to a private address.
  await assert.rejects(() => assertSafeURL(new URL("https://cis1912.org/"), noDNS(null)), BlockedURLError);
  await assert.rejects(() => assertSafeURL(new URL("https://www.seas.upenn.edu/"), noDNS(null)), BlockedURLError);
  // With an allow-list the hostname rules are the main control, so they stand.
  await assertSafeURL(new URL("https://www.seas.upenn.edu/"), noDNS(["upenn.edu"]));
  await assert.rejects(() => assertSafeURL(new URL("https://cis1912.org/"), noDNS(["upenn.edu"])), BlockedURLError);
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

Deno.test("guardedFetch, no allow-list: follows a redirect to another public host, and still refuses one that resolves inward", async () => {
  const ok = hopFetch({
    "https://www.seas.upenn.edu/~cis1912/": { status: 301, location: "https://cis1912.org/" },
    "https://cis1912.org/": { status: 200, body: "the course's own site" },
  });
  const res = await guardedFetch(ok.fetchImpl, "https://www.seas.upenn.edu/~cis1912/", { timeoutMs: 500 }, OPEN_GUARD);
  assert.equal(await res.text(), "the course's own site");
  assert.equal(res.url, "https://cis1912.org/");

  for (const target of ["https://evil.example.com/", "https://metadata-alias.example.com/", "https://127.0.0.1/", "https://metadata.google.internal/"]) {
    const bad = hopFetch({
      "https://cis1912.org/start": { status: 302, location: target },
      [target]: { status: 200, body: "should never be fetched" },
    });
    await assert.rejects(
      () => guardedFetch(bad.fetchImpl, "https://cis1912.org/start", { timeoutMs: 500 }, OPEN_GUARD),
      BlockedURLError,
      target,
    );
    assert.deepEqual(bad.calls.map((call) => call.url), ["https://cis1912.org/start"], `${target} must not be requested`);
  }
});

// A Canvas link spelled `http://` is the same page over https, and most Penn
// hosts redirect to it anyway, so a link we were handed is upgraded before the
// guard looks at it rather than refused.
Deno.test("upgradeToHTTPS: http on the default port becomes https for the same host, path, query and fragment", () => {
  assert.equal(upgradeToHTTPS(new URL("http://www.seas.upenn.edu/~cis2400/current/?a=1#top")).toString(), "https://www.seas.upenn.edu/~cis2400/current/?a=1#top");
  assert.equal(upgradeToHTTPS(new URL("http://www.seas.upenn.edu:80/x")).toString(), "https://www.seas.upenn.edu/x");
  // Unchanged: already https, another port, another scheme.
  assert.equal(upgradeToHTTPS(new URL("https://www.seas.upenn.edu/x")).toString(), "https://www.seas.upenn.edu/x");
  assert.equal(upgradeToHTTPS(new URL("http://www.seas.upenn.edu:8080/x")).toString(), "http://www.seas.upenn.edu:8080/x");
  assert.equal(upgradeToHTTPS(new URL("ftp://www.seas.upenn.edu/x")).toString(), "ftp://www.seas.upenn.edu/x");
});

Deno.test("an http link is upgraded and judged as https: fetchable when its https form is, refused when it breaks any other rule", async () => {
  assert.equal(isFetchableURL("http://www.seas.upenn.edu/~cis2400/", GUARD), true);
  assert.equal(isFetchableURL("http://cis1912.org/", OPEN_GUARD), true);
  assert.equal(await isSafeToFetch("http://www.seas.upenn.edu/~cis2400/", GUARD), true);
  // Upgrading never lets a URL past a rule it would otherwise break.
  for (const url of ["http://example.org/", "http://127.0.0.1/", "http://169.254.169.254/latest/", "http://localhost/", "http://www.seas.upenn.edu:8080/", "http://user:pw@www.seas.upenn.edu/", "http://rebind.upenn.edu/"]) {
    assert.equal(isFetchableURL(url, GUARD) && (await isSafeToFetch(url, GUARD)), false, url);
  }
});

Deno.test("guardedFetch: an http start URL is requested as https, never as http, and reports the https URL", async () => {
  const { fetchImpl, calls } = hopFetch({ "https://www.seas.upenn.edu/~cis2400/current/": { status: 200, body: "hello" } });
  const res = await guardedFetch(fetchImpl, "http://www.seas.upenn.edu/~cis2400/current/", { timeoutMs: 500 }, GUARD);
  assert.equal(await res.text(), "hello");
  assert.deepEqual(calls.map((call) => call.url), ["https://www.seas.upenn.edu/~cis2400/current/"]);
  assert.equal(res.url, "https://www.seas.upenn.edu/~cis2400/current/");
});

Deno.test("guardedFetch: a redirect DOWN to http is still refused and never requested (only the URL we were handed is upgraded)", async () => {
  const { fetchImpl, calls } = hopFetch({
    "https://www.seas.upenn.edu/a": { status: 302, location: "http://www.seas.upenn.edu/b" },
    "http://www.seas.upenn.edu/b": { status: 200, body: "downgraded" },
    "https://www.seas.upenn.edu/b": { status: 200, body: "should not be reached by upgrading a hop" },
  });
  await assert.rejects(() => guardedFetch(fetchImpl, "https://www.seas.upenn.edu/a", { timeoutMs: 500 }, GUARD), BlockedURLError);
  assert.deepEqual(calls.map((call) => call.url), ["https://www.seas.upenn.edu/a"]);
});

Deno.test("guardedFetch: a start URL that breaks the rules is refused before any request", async () => {
  const { fetchImpl, calls } = hopFetch({});
  for (const url of ["http://127.0.0.1/", "https://127.0.0.1/", "https://example.org/", "http://example.org/", "http://www.seas.upenn.edu:8080/", "not a url"]) {
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
