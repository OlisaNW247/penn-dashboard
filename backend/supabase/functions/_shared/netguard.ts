// What `discover-websites` is allowed to fetch, and how much of it to read
// (hardening BE-F, 2026-10-27).
//
// Why this exists. The function fetches URLs it was handed, not URLs it
// chose: a `canvas-link` candidate is any link the phone reported from a
// course page (`sync`'s `candidateFromLink` accepts any http or https host),
// and `discover-websites` then verified it, crawled it, followed up to forty
// of its links, and read every body whole. An account can enrol in any
// course id (BE-04), so anyone holding an anonymous JWT could have made
// LHF's Edge Function fetch `http://169.254.169.254/...` (a cloud metadata
// service), an internal host, or a multi-gigabyte response held open to
// exhaust its memory, and a redirect from an innocent-looking page did the
// same, because `fetch` followed redirects itself.
//
// Four rules, each of which is a different attack:
//
//   1. https only, on the default port, with no credentials in the URL, and
//      the host must be a NAME, not an IP literal and not a name that only
//      means something inside a network (`localhost`, `*.local`,
//      `*.internal`, a single label). So `https://127.0.0.1/` and
//      `https://[::1]/` fail here without a lookup. Course sites live on
//      their own domains (`cis1912.org`, `*.github.io`, a lab's own site),
//      and finding exactly those is what discovery is for, so by default
//      ANY public name is allowed. Setting the function secret
//      `LHF_DISCOVERY_HOSTS` turns on an allow-list instead: only
//      `upenn.edu` and the listed suffixes. That is the switch for
//      narrowing the function if it is ever abused; rules 2 to 4 hold
//      either way.
//   2. The name must resolve, and every address it resolves to must be
//      public. With no allow-list this is the control that matters: any
//      attacker-chosen name can be pointed at a private address, so a
//      runtime that cannot resolve names at all cannot be trusted to fetch
//      (see `assertSafeURL`).
//   3. Redirects are followed here, one hop at a time, and every hop is
//      held to rules 1 and 2 before it is requested. `fetch`'s own
//      `redirect: "follow"` checks nothing, so a page on an allowed host
//      could bounce the request anywhere.
//   4. A body is read as a stream with a byte cap and a deadline, and the
//      connection is cancelled when either is hit. `response.text()` reads
//      until the server stops talking.
//
// Known limit, stated so nobody assumes more: rule 2 resolves the name
// itself and `fetch` then resolves it again, so a DNS answer that changes
// between the two (rebinding) is not caught. Deno offers no way to pin the
// address `fetch` connects to. With no allow-list an attacker who controls
// the DNS for a name they hand us can try it; setting `LHF_DISCOVERY_HOSTS`
// narrows that to names under suffixes they would have to control.

/** Thrown when a URL, a redirect hop or a resolved address breaks a rule
 *  above. Never carries the URL's query string or credentials. */
export class BlockedURLError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BlockedURLError";
  }
}

/** Thrown by a resolver that cannot answer at all (the runtime has no DNS
 *  API), as opposed to one that answered "no such name". See
 *  `assertSafeURL` for the difference it makes. */
export class ResolverUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ResolverUnavailableError";
  }
}

export interface NetGuard {
  /** Host suffixes a URL's host must end in (matched on a label boundary:
   *  `upenn.edu` allows `www.seas.upenn.edu` and `upenn.edu`, never
   *  `evilupenn.edu`), or `null` for no restriction: any public name. */
  allowedHostSuffixes: readonly string[] | null;
  /** Resolves a name to its A and AAAA addresses as text. Rejects when the
   *  name does not resolve; rejects with `ResolverUnavailableError` when the
   *  runtime cannot do lookups at all. Injected so tests never touch the
   *  network. */
  resolve: (hostname: string) => Promise<string[]>;
  /** Redirect hops followed before giving up. */
  maxRedirects: number;
  /** Deadline for one name lookup. */
  resolveTimeoutMs: number;
}

/** Always in the list once an allow-list is configured, so setting
 *  `LHF_DISCOVERY_HOSTS=cis1912.org` narrows discovery to Penn plus that site
 *  rather than silently dropping every Penn-hosted course site. Not used when
 *  the secret is unset. */
const PENN_HOST_SUFFIX = "upenn.edu";
const DEFAULT_MAX_REDIRECTS = 5;
const DEFAULT_RESOLVE_TIMEOUT_MS = 3000;

/** The production guard. With the function secret `LHF_DISCOVERY_HOSTS`
 *  unset, blank, or only commas there is no host restriction (any public
 *  name, `allowedHostSuffixes: null`); a blank value is read as unset, not as
 *  "allow nothing", so a typo cannot switch discovery off. With it set to a
 *  comma-separated suffix list, hosts are restricted to `upenn.edu` plus those
 *  suffixes. Names are resolved with `Deno.resolveDns` either way. */
export function productionNetGuard(env: { get(name: string): string | undefined } = Deno.env): NetGuard {
  const extra = (env.get("LHF_DISCOVERY_HOSTS") ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase().replace(/^\*?\./, ""))
    .filter((entry) => entry.length > 0);
  return {
    allowedHostSuffixes: extra.length > 0 ? [...new Set([PENN_HOST_SUFFIX, ...extra])] : null,
    resolve: resolveWithDeno,
    maxRedirects: DEFAULT_MAX_REDIRECTS,
    resolveTimeoutMs: DEFAULT_RESOLVE_TIMEOUT_MS,
  };
}

async function resolveWithDeno(hostname: string): Promise<string[]> {
  const resolveDns = (Deno as { resolveDns?: (name: string, type: "A" | "AAAA") => Promise<string[]> }).resolveDns;
  if (typeof resolveDns !== "function") {
    throw new ResolverUnavailableError("Deno.resolveDns is not available in this runtime");
  }
  const [a, aaaa] = await Promise.allSettled([resolveDns(hostname, "A"), resolveDns(hostname, "AAAA")]);
  const addresses = [
    ...(a.status === "fulfilled" ? a.value : []),
    ...(aaaa.status === "fulfilled" ? aaaa.value : []),
  ];
  if (addresses.length > 0) return addresses;
  for (const result of [a, aaaa]) {
    if (result.status === "rejected" && looksUnsupported(result.reason)) {
      throw new ResolverUnavailableError("the runtime cannot resolve DNS");
    }
  }
  throw new Error("does not resolve");
}

function looksUnsupported(reason: unknown): boolean {
  if (!(reason instanceof Error)) return false;
  return reason.name === "NotSupported" || reason.name === "TypeError" ||
    /not (supported|implemented|available)|unsupported/i.test(reason.message);
}

// ---------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------

function parseIPv4(text: string): [number, number, number, number] | undefined {
  const parts = text.split(".");
  if (parts.length !== 4) return undefined;
  const octets: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return undefined;
    const value = Number(part);
    if (value > 255) return undefined;
    octets.push(value);
  }
  return octets as [number, number, number, number];
}

/** Eight 16-bit groups, or `undefined` for anything that is not an IPv6
 *  address. Accepts `::` compression, a trailing dotted IPv4 part, brackets
 *  and a zone id. */
function parseIPv6(raw: string): number[] | undefined {
  let text = raw.trim();
  if (text.startsWith("[") && text.endsWith("]")) text = text.slice(1, -1);
  const zone = text.indexOf("%");
  if (zone >= 0) text = text.slice(0, zone);
  if (!text.includes(":")) return undefined;

  let tail: number[] = [];
  const lastColon = text.lastIndexOf(":");
  const maybeV4 = text.slice(lastColon + 1);
  if (maybeV4.includes(".")) {
    const v4 = parseIPv4(maybeV4);
    if (!v4) return undefined;
    tail = [(v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]];
    text = text.slice(0, lastColon + 1) + "0:0";
  }

  const halves = text.split("::");
  if (halves.length > 2) return undefined;
  const parseGroups = (part: string): number[] | undefined => {
    if (part === "") return [];
    const groups: number[] = [];
    for (const group of part.split(":")) {
      if (!/^[0-9a-fA-F]{1,4}$/.test(group)) return undefined;
      groups.push(parseInt(group, 16));
    }
    return groups;
  };
  const head = parseGroups(halves[0]);
  if (!head) return undefined;
  let groups: number[];
  if (halves.length === 2) {
    const back = parseGroups(halves[1]);
    if (!back) return undefined;
    const missing = 8 - head.length - back.length;
    if (missing < 1) return undefined;
    groups = [...head, ...new Array<number>(missing).fill(0), ...back];
  } else {
    groups = head;
  }
  if (groups.length !== 8) return undefined;
  if (tail.length === 2) {
    groups[6] = tail[0];
    groups[7] = tail[1];
  }
  return groups;
}

/** [base, prefix length]. Every range here is one a public web host never
 *  uses, so an answer inside it means the name points at the inside of
 *  somebody's network (or at nothing routable). */
const BLOCKED_IPV4: ReadonlyArray<readonly [string, number]> = [
  ["0.0.0.0", 8], // "this network"
  ["10.0.0.0", 8], // private
  ["100.64.0.0", 10], // carrier-grade NAT
  ["127.0.0.0", 8], // loopback
  ["169.254.0.0", 16], // link-local, including the 169.254.169.254 metadata service
  ["172.16.0.0", 12], // private
  ["192.0.0.0", 24], // IETF protocol assignments
  ["192.0.2.0", 24], // documentation
  ["192.88.99.0", 24], // 6to4 relay anycast
  ["192.168.0.0", 16], // private
  ["198.18.0.0", 15], // benchmarking
  ["198.51.100.0", 24], // documentation
  ["203.0.113.0", 24], // documentation
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // reserved, including the 255.255.255.255 broadcast
];

function ipv4ToNumber(octets: readonly number[]): number {
  return ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>> 0;
}

function isBlockedIPv4(octets: readonly number[]): boolean {
  const value = ipv4ToNumber(octets);
  return BLOCKED_IPV4.some(([base, prefix]) => {
    const baseValue = ipv4ToNumber(parseIPv4(base)!);
    const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
    return (value & mask) >>> 0 === (baseValue & mask) >>> 0;
  });
}

function isBlockedIPv6(groups: readonly number[]): boolean {
  const [g0, g1, g2, g3, g4, g5, g6, g7] = groups;
  const embedded = [g6 >> 8, g6 & 0xff, g7 >> 8, g7 & 0xff];
  const zeroFirst5 = g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0;

  if (zeroFirst5 && g5 === 0xffff) return isBlockedIPv4(embedded); // ::ffff:a.b.c.d, IPv4-mapped
  if (zeroFirst5 && g5 === 0) return true; // ::, ::1 and the deprecated IPv4-compatible ::a.b.c.d
  if (g0 === 0x64 && g1 === 0xff9b && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0) return isBlockedIPv4(embedded); // NAT64
  if (g0 === 0x64 && g1 === 0xff9b && g2 === 1) return true; // local-use NAT64
  if (g0 === 0x2002) return true; // 6to4: embeds an arbitrary IPv4 and nothing here needs it
  if (g0 === 0x2001 && g1 === 0) return true; // Teredo
  if (g0 === 0x2001 && g1 === 0xdb8) return true; // documentation
  if (g0 === 0x100 && g1 === 0 && g2 === 0 && g3 === 0) return true; // discard-only
  if ((g0 & 0xfe00) === 0xfc00) return true; // fc00::/7 unique local (AWS's fd00:ec2::254 metadata lives here)
  if ((g0 & 0xffc0) === 0xfe80) return true; // fe80::/10 link-local
  if ((g0 & 0xffc0) === 0xfec0) return true; // fec0::/10 site-local, deprecated
  if ((g0 & 0xff00) === 0xff00) return true; // multicast
  return false;
}

/** Whether `ip` (as text) is an address a public course site never has.
 *  Anything that does not parse as an IPv4 or IPv6 address counts as
 *  blocked: a resolver answer this function cannot read is not one it can
 *  vouch for. */
export function isBlockedAddress(ip: string): boolean {
  const v4 = parseIPv4(ip.trim());
  if (v4) return isBlockedIPv4(v4);
  const v6 = parseIPv6(ip);
  if (v6) return isBlockedIPv6(v6);
  return true;
}

// ---------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------

function normalizedHost(url: URL): string {
  return url.hostname.toLowerCase().replace(/\.$/, "");
}

function hostIsAllowed(host: string, suffixes: readonly string[]): boolean {
  return suffixes.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}

/** Top-level names that only mean something inside a network (RFC 6761,
 *  RFC 6762, RFC 8375 and the usual private conventions). A public resolver
 *  never answers for these, but a runtime inside a cloud network can (the
 *  `metadata.google.internal` host answers with a metadata address there), so
 *  they are refused by name as well as by address: the address check is the
 *  second layer, and on a runtime that cannot resolve names it is absent. */
const INTERNAL_TLDS: ReadonlySet<string> = new Set([
  "localhost", "local", "internal", "intranet", "lan", "home", "corp", "private", "invalid", "test", "example", "onion",
]);

function isInternalName(host: string): boolean {
  if (host === "home.arpa" || host.endsWith(".home.arpa")) return true;
  const labels = host.split(".");
  return INTERNAL_TLDS.has(labels[labels.length - 1]);
}

/** The checks that need no lookup: https, the default port, no credentials,
 *  a public-looking name (not an IP literal, not an internal name) with a dot
 *  in it, and, when an allow-list is configured, ending in an allowed suffix.
 *  Throws `BlockedURLError`. Cheap enough to run on every candidate before
 *  deciding whether to try it at all. */
export function checkURLShape(url: URL, guard: Pick<NetGuard, "allowedHostSuffixes">): void {
  if (url.protocol !== "https:") throw new BlockedURLError("only https URLs are fetched");
  if (url.username !== "" || url.password !== "") throw new BlockedURLError("URLs with credentials are not fetched");
  if (url.port !== "" && url.port !== "443") throw new BlockedURLError("only the default https port is fetched");
  const host = normalizedHost(url);
  if (host.startsWith("[") || /^\d+(\.\d+){0,3}$/.test(host) || /^0x[0-9a-f]+$/i.test(host)) {
    throw new BlockedURLError("IP-address hosts are not fetched");
  }
  if (!host.includes(".") || isInternalName(host)) throw new BlockedURLError("host is not a public name");
  if (guard.allowedHostSuffixes !== null && !hostIsAllowed(host, guard.allowedHostSuffixes)) {
    throw new BlockedURLError("host is not on the allow-list");
  }
}

/** `checkURLShape` as a yes/no for a URL held as text. */
export function isFetchableURL(raw: string, guard: Pick<NetGuard, "allowedHostSuffixes">): boolean {
  try {
    checkURLShape(new URL(raw), guard);
    return true;
  } catch {
    return false;
  }
}

let warnedResolverUnavailable = false;

/** `assertSafeURL` as a yes/no for a URL held as text: true when a fetch of it
 *  would be allowed right now (shape, then the name's addresses). For a caller
 *  that wants to decide "skip this site and try again next time" before it
 *  changes any state, rather than discover the refusal inside a fetch. */
export async function isSafeToFetch(raw: string, guard: NetGuard): Promise<boolean> {
  try {
    await assertSafeURL(new URL(raw), guard);
    return true;
  } catch (err) {
    if (err instanceof BlockedURLError || err instanceof TypeError) return false;
    throw err;
  }
}

/** The full check for one URL: its shape, then its name's addresses. A name
 *  that does not resolve is refused (the fetch would fail anyway).
 *
 *  A resolver that cannot answer at all, because the runtime has no DNS API,
 *  is handled by whether an allow-list is configured. With one, the allow-list
 *  is the main control and the address check the second layer, so the shape
 *  check alone stands, with a warning so the gap is visible. With none, any
 *  name an attacker hands us could point at a private address and the address
 *  check is the only thing standing between it and the fetch, so the URL is
 *  refused: on such a runtime discovery stays off until `LHF_DISCOVERY_HOSTS`
 *  is set. */
export async function assertSafeURL(url: URL, guard: NetGuard): Promise<void> {
  checkURLShape(url, guard);
  const host = normalizedHost(url);

  let addresses: string[];
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    addresses = await Promise.race([
      guard.resolve(host),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("lookup timed out")), guard.resolveTimeoutMs);
      }),
    ]);
  } catch (err) {
    if (err instanceof ResolverUnavailableError) {
      if (guard.allowedHostSuffixes === null) {
        throw new BlockedURLError("addresses cannot be checked on this runtime and no host allow-list is set");
      }
      if (!warnedResolverUnavailable) {
        warnedResolverUnavailable = true;
        console.warn("netguard: this runtime cannot resolve DNS, checking hostnames only");
      }
      return;
    }
    throw new BlockedURLError("host does not resolve");
  } finally {
    clearTimeout(timer);
  }

  if (addresses.length === 0) throw new BlockedURLError("host does not resolve");
  if (addresses.some(isBlockedAddress)) throw new BlockedURLError("host resolves to a private or reserved address");
}

// ---------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

export interface GuardedFetchOptions {
  headers?: Record<string, string>;
  /** Per hop, covering the wait for response headers. A body is bounded
   *  separately by `readCapped`. */
  timeoutMs: number;
}

/**
 * `fetchImpl(url)` with the guard applied to the URL and to every redirect
 * hop, followed here with `redirect: "manual"`. Resolves to the final
 * (non-redirect) response, whose `url` is the last hop's URL. Throws
 * `BlockedURLError` when a hop breaks a rule or the chain is too long, and
 * whatever `fetchImpl` throws for a network failure or timeout, so callers
 * keep treating "could not fetch" as one case.
 */
export async function guardedFetch(
  fetchImpl: typeof fetch,
  startURL: string,
  options: GuardedFetchOptions,
  guard: NetGuard,
): Promise<Response> {
  let current: URL;
  try {
    current = new URL(startURL);
  } catch {
    throw new BlockedURLError("not a URL");
  }

  for (let hop = 0; hop <= guard.maxRedirects; hop++) {
    await assertSafeURL(current, guard);

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs);
    let response: Response;
    try {
      response = await fetchImpl(current.toString(), {
        method: "GET",
        headers: options.headers,
        redirect: "manual",
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }

    const location = response.headers.get("location");
    if (!REDIRECT_STATUSES.has(response.status) || location === null) {
      // A runtime sets `url` itself; a stand-in `fetch` may not, and every
      // caller reads it as "where this landed".
      if (!response.url) Object.defineProperty(response, "url", { value: current.toString(), configurable: true });
      return response;
    }

    await response.body?.cancel().catch(() => {});
    try {
      current = new URL(location, current);
    } catch {
      throw new BlockedURLError("redirect to a URL that does not parse");
    }
  }
  throw new BlockedURLError("too many redirects");
}

export interface CappedBody {
  bytes: Uint8Array;
  /** The body was longer than `maxBytes`; `bytes` is the first `maxBytes`. */
  truncated: boolean;
}

/**
 * Reads at most `maxBytes` of `response`'s body, giving up after
 * `deadlineMs`, and cancels the connection in either case (an unread
 * remainder keeps a socket and a server's work alive). `undefined` when the
 * body cannot be read in time or at all; a body over the cap is not a
 * failure, it is returned truncated, and the caller decides whether a
 * truncated body is still useful.
 */
export async function readCapped(
  response: Response,
  options: { maxBytes: number; deadlineMs: number },
): Promise<CappedBody | undefined> {
  const body = response.body;
  if (!body) return { bytes: new Uint8Array(0), truncated: false };

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let truncated = false;
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    reader.cancel().catch(() => {});
  }, options.deadlineMs);

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (timedOut) return undefined;
      if (done) break;
      if (!value) continue;
      if (total + value.byteLength > options.maxBytes) {
        chunks.push(value.subarray(0, options.maxBytes - total));
        total = options.maxBytes;
        truncated = true;
        await reader.cancel().catch(() => {});
        break;
      }
      chunks.push(value);
      total += value.byteLength;
    }
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { bytes, truncated };
}

/** `readCapped` decoded as UTF-8. A multi-byte character cut in half by the
 *  cap decodes to U+FFFD at the very end rather than throwing. */
export async function readTextCapped(
  response: Response,
  options: { maxBytes: number; deadlineMs: number },
): Promise<{ text: string; truncated: boolean } | undefined> {
  const capped = await readCapped(response, options);
  if (!capped) return undefined;
  return { text: new TextDecoder("utf-8").decode(capped.bytes), truncated: capped.truncated };
}
