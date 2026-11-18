import test from "node:test";
import assert from "node:assert/strict";
import {
  cronQuery, fakeToken, findClaimingTick, judgeTick, logsQuery, logsURL, manyMoments, momentAhead, parseArgs, parseTickLine, run, STEPS,
} from "./sweeper-wake-e2e.mjs";

const LINE = 'sweeper-wake tick 2026-11-20T04:34:00.000Z: claimed 1, sent 1, status {"400":1}, deleted 0, took 212 ms';

test("momentAhead is a whole minute at least the lead away", () => {
  const m = momentAhead(new Date("2026-11-20T04:30:20.000Z"));
  assert.equal(m.toISOString(), "2026-11-20T04:32:00.000Z");
  assert.equal(momentAhead(new Date("2026-11-20T04:30:10.000Z")).toISOString(), "2026-11-20T04:31:00.000Z");
  assert.equal(momentAhead(new Date("2026-11-20T04:30:16.000Z")).toISOString(), "2026-11-20T04:32:00.000Z");
  assert.equal(momentAhead(new Date("2026-11-20T04:30:16.000Z"), 30).toISOString(), "2026-11-20T04:31:00.000Z");
  assert.equal(momentAhead(new Date("2026-11-20T04:30:40.000Z")).toISOString(), "2026-11-20T04:32:00.000Z");
});

test("fakeToken is 64 lowercase hex; manyMoments are distinct whole minutes", () => {
  assert.match(fakeToken(), /^[0-9a-f]{64}$/);
  assert.notEqual(fakeToken(), fakeToken());
  const ms = manyMoments(new Date("2026-11-20T04:30:20.000Z"), 25);
  assert.equal(ms.length, 25);
  assert.equal(new Set(ms).size, 25);
  assert.ok(ms.every((m) => m.endsWith(":00.000Z")));
});

test("the tick line parses, and a different line does not", () => {
  assert.deepEqual(parseTickLine(LINE), { minute: "2026-11-20T04:34:00.000Z", claimed: 1, sent: 1, status: { 400: 1 }, deleted: 0, took: 212 });
  assert.equal(parseTickLine("sweeper-wake: put stored=1"), null);
  assert.equal(parseTickLine(undefined), null);
});

test("findClaimingTick picks a claiming tick at or after the moment", () => {
  const rows = { result: [
    { event_message: 'sweeper-wake tick 2026-11-20T04:35:00.000Z: claimed 0, sent 0, status {}, deleted 0, took 3 ms' },
    { event_message: LINE },
    { event_message: LINE.replace("04:34", "04:20") },
  ] };
  assert.equal(findClaimingTick(rows, new Date("2026-11-20T04:34:00Z")).claimed, 1);
  assert.equal(findClaimingTick(rows, new Date("2026-11-20T04:36:00Z")), null);
  assert.equal(findClaimingTick({}, new Date()), null);
});

test("judgeTick: 400 proves HTTP/2 and the JWT; 0, 403 and errors are named", () => {
  assert.equal(judgeTick(parseTickLine(LINE)).ok, true);
  assert.equal(judgeTick(null).ok, false);
  assert.match(judgeTick({ status: { 0: 1 } }).detail, /HTTP\/2|connection-level/);
  assert.match(judgeTick({ status: { 403: 1 } }).detail, /key/);
  assert.match(judgeTick({ status: { error: 1 } }).detail, /secret/);
  assert.equal(judgeTick({ status: { 503: 1 } }).ok, false);
});

test("the queries read counts and log lines, never user data", () => {
  assert.match(logsQuery(), /function_logs/);
  assert.ok(!/select \*/.test(logsQuery()));
  const url = new URL(logsURL("proj", new Date("2026-11-20T05:00:00Z")));
  assert.equal(url.pathname, "/v1/projects/proj/analytics/endpoints/logs");
  assert.equal(url.searchParams.get("iso_timestamp_start"), "2026-11-20T04:00:00.000Z");
  assert.match(cronQuery(), /sweeper-wake-tick/);
  assert.ok(!/sweeper_wakes/.test(cronQuery()));
});

test("parseArgs and the dry run", async () => {
  assert.deepEqual(parseArgs([]), { dryRun: false, logs: true });
  assert.equal(parseArgs(["--no-logs"]).logs, false);
  assert.throws(() => parseArgs(["--x"]));
  const lines = [];
  assert.equal(await run(["--dry-run"], { log: (l) => lines.push(l), fetchImpl: () => { throw new Error("no network"); } }), 0);
  assert.equal(lines.length, STEPS.length + 1);
});

test("a full run against a fake backend passes, never prints the jwt or the token, and cleans up", async () => {
  const sent = [];
  let t = new Date("2026-11-20T04:30:20.000Z").getTime();
  let storedToken = "";
  const fetchImpl = async (url, init = {}) => {
    url = String(url);
    const body = init.body ? JSON.parse(init.body) : null;
    const reply = (status, json) => new Response(JSON.stringify(json), { status });
    sent.push(`${init.method ?? "GET"} ${url.replace(/\?.*/, "")}`);
    if (url.endsWith("/auth/v1/signup")) return reply(200, { access_token: "SECRET-JWT" });
    if (url.endsWith("/sweeper-wake/tick")) return reply(403, { error: "forbidden" });
    if (url.endsWith("/sweeper-wake")) {
      if (!init.headers["x-smooth-version"]) return reply(426, { error: "update_required" });
      if (body.action === "delete") return reply(200, { deleted: storedToken ? 1 : 0 }, (storedToken = ""));
      if (body.assignment_id) return reply(400, { error: "bad_request", message: "forbidden_field" });
      if (body.moments.length > 24) return reply(400, { error: "bad_request", message: "too_many_moments" });
      if (body.moments.length === 1 && Date.parse(body.moments[0]) > t + 2 * 24 * 3600 * 1000) return reply(400, { error: "bad_request", message: "moment_beyond_horizon" });
      if (body.moments.length === 1) { storedToken = body.token; return reply(200, { stored: 1, nextMoment: body.moments[0] }); }
      return reply(200, { stored: 0, nextMoment: null });
    }
    if (url.includes("analytics/endpoints/logs")) return reply(200, { result: [{ event_message: LINE.replace("04:34", "04:32") }] });
    if (url.endsWith("/database/query")) return reply(200, [{ runs: 5, succeeded: 5 }]);
    if (url.endsWith("/delete-account")) return reply(200, { deleted: true });
    throw new Error(`unexpected ${url}`);
  };
  const lines = [];
  const code = await run([], { fetchImpl, log: (l) => lines.push(l), now: () => new Date(t), sleep: async (ms) => { t += ms; }, managementToken: "MGMT-TOKEN" });
  assert.equal(code, 0, lines.join("\n"));
  const text = lines.join("\n");
  assert.ok(!text.includes("SECRET-JWT") && !text.includes("MGMT-TOKEN") && !text.includes(storedToken || "zzzz"));
  assert.ok(sent.at(-1).endsWith("/delete-account"));
  assert.match(text, /ok: delete-account|ok: cleanup: delete-account/);
});

test("without a management token the log steps are skipped, not failed", async () => {
  const lines = [];
  const fetchImpl = async (url) => {
    url = String(url);
    const reply = (status, json) => new Response(JSON.stringify(json), { status });
    if (url.endsWith("/auth/v1/signup")) return reply(200, { access_token: "J" });
    if (url.endsWith("/delete-account")) return reply(200, {});
    if (url.endsWith("/tick")) return reply(403, {});
    return reply(400, { message: "x" });
  };
  const code = await run([], { fetchImpl, log: (l) => lines.push(l), managementToken: undefined });
  assert.equal(code, 1); // the put is refused by this fake, which is the point: a failure still cleans up
  assert.ok(lines.some((l) => /cleanup: delete-account/.test(l)));
});
