import { strict as assert } from "node:assert";
import {
  CACHE_TTL_MS,
  compareVersions,
  enforceMinimumVersion,
  FAILURE_RETRY_MS,
  parseVersion,
  resetVersionCache,
} from "../supabase/functions/_shared/version.ts";
import { HttpError } from "../supabase/functions/_shared/http.ts";

function req(version?: string): Request {
  return new Request("https://example.test/fn", {
    method: "POST",
    headers: version === undefined ? {} : { "X-Smooth-Version": version },
  });
}

function manifest(minimumVersion: unknown) {
  let calls = 0;
  const fetchFn = ((_u: string | URL | Request) => {
    calls++;
    return Promise.resolve(new Response(JSON.stringify({ minimumVersion, latestVersion: minimumVersion })));
  }) as typeof fetch;
  return { fetchFn, calls: () => calls };
}

const noEnv = () => undefined;
const requireEnv = (k: string) => (k === "LHF_REQUIRE_VERSION_HEADER" ? "true" : undefined);

async function refused(p: Promise<void>): Promise<HttpError> {
  try {
    await p;
  } catch (e) {
    assert.ok(e instanceof HttpError);
    return e;
  }
  throw new Error("expected HttpError");
}

Deno.test("parseVersion accepts dotted digits and rejects everything else", () => {
  assert.deepEqual(parseVersion("3.3.0"), [3, 3, 0]);
  assert.deepEqual(parseVersion("2"), [2]);
  assert.deepEqual(parseVersion(" 3.3 "), [3, 3]);
  for (const bad of ["", " ", "abc", "2.x", "-1.0", "2..0", ".1", "1.", "3.3.0-beta", "+1", "1_0", "١.٢"]) {
    assert.equal(parseVersion(bad), null, bad);
  }
  assert.equal(parseVersion(null), null);
  assert.equal(parseVersion(undefined), null);
});

Deno.test("compareVersions treats missing trailing components as zero", () => {
  assert.equal(compareVersions([3, 3], [3, 3, 0]), 0);
  assert.equal(compareVersions([3, 2, 9], [3, 3, 0]), -1);
  assert.equal(compareVersions([3, 10], [3, 9]), 1);
  assert.equal(compareVersions([3, 3, 0, 1], [3, 3]), 1);
  assert.equal(compareVersions([2], [3, 0, 0]), -1);
});

Deno.test("below the floor is refused with 426 update_required", async () => {
  resetVersionCache();
  const m = manifest("3.3.0");
  const e = await refused(enforceMinimumVersion(req("3.2.9"), { fetchFn: m.fetchFn, env: noEnv }));
  assert.equal(e.status, 426);
  assert.equal(e.code, "update_required");
});

Deno.test("equal to or above the floor is allowed", async () => {
  resetVersionCache();
  const m = manifest("3.3.0");
  await enforceMinimumVersion(req("3.3.0"), { fetchFn: m.fetchFn, env: noEnv });
  await enforceMinimumVersion(req("3.3"), { fetchFn: m.fetchFn, env: noEnv });
  await enforceMinimumVersion(req("4.0.0"), { fetchFn: m.fetchFn, env: noEnv });
});

Deno.test("missing or unparseable header: allowed with switch off, 426 with it on", async () => {
  resetVersionCache();
  const m = manifest("3.3.0");
  await enforceMinimumVersion(req(), { fetchFn: m.fetchFn, env: noEnv });
  await enforceMinimumVersion(req("garbage"), { fetchFn: m.fetchFn, env: noEnv });
  assert.equal((await refused(enforceMinimumVersion(req(), { fetchFn: m.fetchFn, env: requireEnv }))).status, 426);
  assert.equal(
    (await refused(enforceMinimumVersion(req("garbage"), { fetchFn: m.fetchFn, env: requireEnv }))).code,
    "update_required",
  );
});

Deno.test("headerOptional ignores a missing header even with the switch on, but still refuses below floor", async () => {
  resetVersionCache();
  const m = manifest("3.3.0");
  await enforceMinimumVersion(req(), { fetchFn: m.fetchFn, env: requireEnv, headerOptional: true });
  await refused(enforceMinimumVersion(req("3.0.0"), { fetchFn: m.fetchFn, env: requireEnv, headerOptional: true }));
});

Deno.test("manifest failures fail open", async () => {
  const cases: Array<typeof fetch> = [
    (() => Promise.reject(new Error("network down"))) as typeof fetch,
    (() => Promise.resolve(new Response("nope", { status: 500 }))) as typeof fetch,
    (() => Promise.resolve(new Response("not json"))) as typeof fetch,
    manifest("2..0").fetchFn, // unparseable floor
    manifest(undefined).fetchFn, // field missing
  ];
  const origError = console.error;
  console.error = () => {};
  try {
    for (const fetchFn of cases) {
      resetVersionCache();
      await enforceMinimumVersion(req("1.0.0"), { fetchFn, env: noEnv });
    }
  } finally {
    console.error = origError;
  }
});

Deno.test("floor is cached for 5 minutes then refetched", async () => {
  resetVersionCache();
  const m = manifest("3.3.0");
  let t = 1_000_000;
  const opts = { fetchFn: m.fetchFn, env: noEnv, now: () => t };
  await enforceMinimumVersion(req("3.3.0"), opts);
  t += CACHE_TTL_MS - 1;
  await enforceMinimumVersion(req("3.3.0"), opts);
  assert.equal(m.calls(), 1);
  t += 2;
  await enforceMinimumVersion(req("3.3.0"), opts);
  assert.equal(m.calls(), 2);
});

Deno.test("a failed fetch is not retried for a minute, and the last known floor survives it", async () => {
  resetVersionCache();
  let t = 0;
  const good = manifest("3.3.0");
  await enforceMinimumVersion(req("3.3.0"), { fetchFn: good.fetchFn, env: noEnv, now: () => t });
  t += CACHE_TTL_MS + 1;
  let failCalls = 0;
  const failing = (() => {
    failCalls++;
    return Promise.reject(new Error("down"));
  }) as typeof fetch;
  const origError = console.error;
  console.error = () => {};
  try {
    const opts = { fetchFn: failing, env: noEnv, now: () => t };
    await refused(enforceMinimumVersion(req("3.0.0"), opts)); // last known floor still applies
    t += FAILURE_RETRY_MS - 1;
    await refused(enforceMinimumVersion(req("3.0.0"), opts));
    assert.equal(failCalls, 1);
    t += 2;
    await refused(enforceMinimumVersion(req("3.0.0"), opts));
    assert.equal(failCalls, 2);
  } finally {
    console.error = origError;
  }
});

Deno.test("no fetch happens when the header is absent", async () => {
  resetVersionCache();
  const m = manifest("3.3.0");
  await enforceMinimumVersion(req(), { fetchFn: m.fetchFn, env: noEnv });
  assert.equal(m.calls(), 0);
});
