import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readCanvas, stripXSSI } from "../src/adapters/canvas.js";
import { readGradescope } from "../src/adapters/gradescope.js";
import { fetchText } from "../src/adapters/http.js";

const fx = (p) => readFileSync(new URL(`./fixtures/${p}`, import.meta.url), "utf8");
const FEED = "https://canvas.upenn.edu/feeds/calendars/user_SECRETTOKEN.ics";

// A fake fetch over a url -> {status, url?, body} table; records every call.
function fakeFetch(table) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init });
    const hit = table[url];
    if (!hit) throw new TypeError("network");
    return { status: hit.status ?? 200, ok: (hit.status ?? 200) < 400, url: hit.url ?? url, text: async () => hit.body };
  };
  fn.calls = calls;
  return fn;
}

test("stripXSSI removes while(1);", () => {
  assert.equal(stripXSSI('while(1);{"a":1}'), '{"a":1}');
  assert.equal(stripXSSI('{"a":1}'), '{"a":1}');
});

test("canvas: profile, then the feed, parsed to the phone's ids", async () => {
  const f = fakeFetch({
    "https://canvas.upenn.edu/api/v1/users/self/profile": { body: `while(1);${JSON.stringify({ calendar: { ics: FEED } })}` },
    [FEED]: { body: fx("canvas-calendar.ics") },
  });
  const r = await readCanvas({ fetchFn: f });
  assert.equal(r.status, "in");
  assert.ok(r.items.some((i) => i.sourceID === "event-assignment-9182736"));
  assert.ok(r.items.every((i) => i.kind === "assignment" || i.kind === "quiz" || /exam|quiz/i.test(i.title)));
  assert.ok(f.calls.every((c) => c.init.credentials === "include" && c.init.redirect === "follow"));
  assert.equal(JSON.stringify(r).includes("SECRETTOKEN"), false);
});

test("canvas: sign-in redirect, 401, and an HTML page all mean out", async () => {
  const P = "https://canvas.upenn.edu/api/v1/users/self/profile";
  assert.equal((await readCanvas({ fetchFn: fakeFetch({ [P]: { url: "https://idp.pennkey.upenn.edu/idp/x", body: "<html>" } }) })).status, "out");
  assert.equal((await readCanvas({ fetchFn: fakeFetch({ [P]: { status: 401, body: "" } }) })).status, "out");
  assert.equal((await readCanvas({ fetchFn: fakeFetch({ [P]: { body: "<html>log in</html>" } }) })).status, "out");
});

test("canvas: network failure and server error are error, not out", async () => {
  assert.equal((await readCanvas({ fetchFn: fakeFetch({}) })).status, "error");
  const P = "https://canvas.upenn.edu/api/v1/users/self/profile";
  assert.equal((await readCanvas({ fetchFn: fakeFetch({ [P]: { status: 500, body: "" } }) })).status, "error");
});

test("fetchText: weblogin host is signed out", async () => {
  const r = await fetchText("https://x", { fetchFn: fakeFetch({ "https://x": { url: "https://weblogin.pennkey.upenn.edu/login", body: "" } }) });
  assert.equal(r.signedOut, true);
});

test("gradescope: login page on /account is out", async () => {
  const f = fakeFetch({ "https://www.gradescope.com/account": { body: fx("gradescope/login-page.html") } });
  assert.equal((await readGradescope({ fetchFn: f })).status, "out");
});

test("gradescope: 403 is out, 500 is error", async () => {
  const U = "https://www.gradescope.com/account";
  assert.equal((await readGradescope({ fetchFn: fakeFetch({ [U]: { status: 403, body: "" } }) })).status, "out");
  assert.equal((await readGradescope({ fetchFn: fakeFetch({ [U]: { status: 500, body: "" } }) })).status, "error");
});

test("gradescope: account, course page, detail pages, one at a time", async () => {
  let inFlight = 0, peak = 0;
  const table = {
    "https://www.gradescope.com/account": fx("gradescope/account-course-links.html"),
  };
  const f = async (url) => {
    inFlight++; peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 1));
    inFlight--;
    const body = table[url] ?? fx("gradescope/course-one-homework.html");
    return { status: 200, ok: true, url, text: async () => body };
  };
  const r = await readGradescope({ fetchFn: f, now: new Date(Date.UTC(2026, 9, 20)) });
  assert.equal(r.status, "in");
  assert.equal(peak, 1);
});
