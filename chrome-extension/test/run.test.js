import { test } from "node:test";
import assert from "node:assert/strict";
import { refresh } from "../src/run.js";
import { emptySnapshot, recordCompletion } from "../src/core/syncSnapshot.js";

const FEED = "https://canvas.upenn.edu/feeds/calendars/user_SECRETTOKEN.ics";
const ics = `BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20260920T035900Z
UID:event-assignment-777
SUMMARY:Problem Set 7 [CIS 1200 Fall 2026]
URL;VALUE=URI:https://canvas.upenn.edu/calendar?include_contexts=course_1&month=9&year=2026#assignment_777
END:VEVENT
BEGIN:VEVENT
DTSTART:20260921T035900Z
UID:event-assignment-override-55
SUMMARY:Problem Set 8 (Section 2) [CIS 1200 Fall 2026]
URL;VALUE=URI:https://canvas.upenn.edu/calendar?include_contexts=course_1&month=9&year=2026#assignment_888
END:VEVENT
BEGIN:VEVENT
DTSTART:20260922T035900Z
UID:event-assignment-999
SUMMARY:Problem Set 9 [CIS 1200 Fall 2026]
URL;VALUE=URI:https://canvas.upenn.edu/calendar?include_contexts=course_1&month=9&year=2026#assignment_999
END:VEVENT
END:VCALENDAR
`;
const reply = (body, status = 200) => ({
  status, ok: status < 400, url: "", headers: { get: () => null }, text: async () => "while(1);" + JSON.stringify(body),
});

function fakeFetch(submitted, at = null) {
  return async (url) => {
    if (url === FEED) return { status: 200, ok: true, url, headers: { get: () => null }, text: async () => ics };
    const u = new URL(url);
    if (u.pathname === "/api/v1/users/self/profile") return reply({ calendar: { ics: FEED } });
    if (u.pathname === "/api/v1/courses") return reply([{ id: 1, name: "CIS 1200-001 X 202630" }]);
    if (/\/courses\/1\/assignments/.test(u.pathname)) return reply(submitted.map((id) => ({ id, submission: at ? { submitted_at: at } : { workflow_state: "submitted" } })));
    return { status: 404, ok: false, url, headers: { get: () => null }, text: async () => "" };
  };
}

async function drive(fetchFn, now, prior, snap = emptySnapshot("dev", new Date("2026-11-01T00:00:00Z")), box = {}) {
  let saved = null;
  await refresh({ fetchFn, now, load: async () => prior, save: async (v) => { saved = v; }, loadSnap: async () => snap, saveSnap: async (v) => { box.snap = v; }, sleep: async () => {}, delayMs: 0 });
  return saved;
}
const byTitle = (rec, t) => rec.items.find((i) => i.title.startsWith(t));

test("a Canvas item Canvas shows as submitted becomes submitted, override rows too", async () => {
  const rec = await drive(fakeFetch(["777", "888"]), new Date("2026-11-05T15:00:00Z"), null);
  assert.equal(rec.canvasSubmissions, "in");
  assert.equal(byTitle(rec, "Problem Set 7").submitted, true);
  assert.equal(byTitle(rec, "Problem Set 8").submitted, true);
  assert.equal(byTitle(rec, "Problem Set 9").submitted, false);
  assert.deepEqual(Object.keys(rec.submissions).sort(), ["at", "submitted"]);
});

test("a throttled read still applies the prior map", async () => {
  const now = new Date("2026-11-05T15:00:00Z");
  const prior = { submissions: { at: new Date(now.getTime() - 60_000).toISOString(), submitted: { 777: { submittedAt: null } } } };
  const rec = await drive(fakeFetch([]), now, prior);
  assert.equal(rec.canvasSubmissions, "throttled");
  assert.equal(byTitle(rec, "Problem Set 7").submitted, true);
  assert.equal(byTitle(rec, "Problem Set 9").submitted, false);
});

const ID777 = "canvas:event-assignment-777";

test("feed the phone: a newly submitted id gets a completion at submitted_at", async () => {
  const box = {};
  await drive(fakeFetch(["777"], "2026-11-03T12:00:00Z"), new Date("2026-11-05T15:00:00Z"), null, undefined, box);
  const rec = box.snap.completions[ID777];
  assert.equal(rec.done, true);
  assert.equal(rec.at, "2026-11-03T12:00:00.000Z");
  assert.equal(box.snap.completions["canvas:event-assignment-999"], undefined);
});

test("feed the phone: an existing done:false record is left alone", async () => {
  const box = {};
  const snap = recordCompletion(emptySnapshot("dev", new Date("2026-11-01T00:00:00Z")), ID777, false, new Date("2026-11-04T00:00:00Z"));
  await drive(fakeFetch(["777"], "2026-11-03T12:00:00Z"), new Date("2026-11-05T15:00:00Z"), null, snap, box);
  assert.equal(box.snap, undefined);
  assert.equal(snap.completions[ID777].done, false);
});

test("feed the phone: an id already done is not re-recorded", async () => {
  const box = {};
  const snap = recordCompletion(emptySnapshot("dev", new Date("2026-11-01T00:00:00Z")), ID777, true, new Date("2026-11-04T00:00:00Z"));
  await drive(fakeFetch(["777"], "2026-11-03T12:00:00Z"), new Date("2026-11-05T15:00:00Z"), null, snap, box);
  assert.equal(box.snap, undefined);
  assert.equal(snap.completions[ID777].at, "2026-11-04T00:00:00.000Z");
});
