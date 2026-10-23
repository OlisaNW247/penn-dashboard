import { test } from "node:test";
import assert from "node:assert/strict";
import {
  collectCourseMaterial, syncCourseMaterial, handleEdTokenMessage, readEdToken, ED_TOKEN_KEY, ACCEPTED_KINDS,
} from "../src/adapters/collector.js";

const NOW = new Date("2026-10-22T15:00:00Z");
const SECRET = "ZZ-SECRET-TITLE";

// ------------------------------------------------------------ fake Canvas

function reply(body, { status = 200, link = null, url = "", raw = false } = {}) {
  const text = raw ? body : "while(1);" + JSON.stringify(body);
  return { status, ok: status >= 200 && status < 300, url, headers: { get: (n) => (n.toLowerCase() === "link" && link ? link : null) }, text: async () => text };
}

const COURSES = [
  { id: 111, name: "CIS 2400-001 Machine Architecture 202630", course_code: "CIS 2400" },
  { id: 222, name: "MATH 1400-001 Calculus 202630", course_code: "MATH 1400" },
];

// A Canvas that answers every endpoint for both courses; `override(url, u)`
// may return a reply to take over one request.
function fakeCanvas({ override, pageCount = 3 } = {}) {
  const log = { urls: [], inflight: 0, maxInflight: 0 };
  const fetchFn = async (url, init) => {
    log.urls.push(url);
    log.inflight += 1;
    log.maxInflight = Math.max(log.maxInflight, log.inflight);
    await Promise.resolve();
    try {
      assert.equal(init.credentials, "include");
      const o = override?.(url, new URL(url));
      if (o) return o;
      const u = new URL(url);
      const p = u.pathname;
      if (p === "/api/v1/courses") {
        if (u.searchParams.get("page") === "2") return reply([COURSES[1]]);
        return reply([COURSES[0]], { link: '<https://canvas.upenn.edu/api/v1/courses?enrollment_state=active&per_page=100&page=2>; rel="next"' });
      }
      const m = /^\/api\/v1\/courses\/(\d+)(?:\/(.*))?$/.exec(p);
      if (m) {
        const [, id, rest] = m;
        if (rest === undefined) return reply({ id: Number(id), syllabus_body: `<p>${SECRET} syllabus ${id}</p>` });
        if (rest === "pages") {
          return reply(Array.from({ length: pageCount }, (_, i) => ({ url: `p${i}`, title: `${SECRET} page ${i}`, published: true, updated_at: "2026-09-01T00:00:00Z" })));
        }
        if (rest.startsWith("pages/")) return reply({ url: rest.slice(6), title: `${SECRET} ${rest}`, body: `<p>body ${rest} <a href="https://example.com/x">link</a></p>`, updated_at: "2026-09-01T00:00:00Z" });
        if (rest === "modules") return reply([{ name: "Week 1", items: [{ id: 5, title: "Reading", type: "Page", content_id: 9 }] }]);
        if (rest === "assignments") return reply([{ id: 70 + Number(id), name: `${SECRET} hw`, due_at: "2026-11-01T04:59:00Z", html_url: `https://canvas.upenn.edu/courses/${id}/assignments/1`, description: "<p>do it</p>", points_possible: 10 }]);
      }
      if (p === "/api/v1/announcements") {
        const code = u.searchParams.get("context_codes[]");
        return reply([{ id: 900, context_code: code, title: `${SECRET} announce`, message: "<p>hi</p>", posted_at: "2026-10-01T12:00:00Z", html_url: "https://canvas.upenn.edu/a/900" }]);
      }
      return reply({}, { status: 404 });
    } finally {
      log.inflight -= 1;
    }
  };
  return { fetch: fetchFn, log };
}

const noSleep = async () => {};
const collect = (canvas, extra = {}) => collectCourseMaterial({ fetch: canvas.fetch, now: NOW, sleep: noSleep, ...extra });

function fakeBackend({ manifest = {}, fail = {} } = {}) {
  const calls = [];
  const callFunction = async (name, body) => {
    calls.push({ name, body: structuredClone(body) });
    const err = fail[body.action];
    if (err) throw Object.assign(new Error(err), { kind: err });
    if (body.action === "manifest") return { coursesFresh: [], serverManifest: [], download: [], catalog: [], profiles: [], ...manifest };
    return { accepted: body.documents.length, profileStale: [], websitesPending: [] };
  };
  return { callFunction, calls };
}

// ---------------------------------------------------------------- tests

test("collect: follows Link pagination for the course list and builds every kind", async () => {
  const canvas = fakeCanvas();
  const c = await collect(canvas);
  assert.equal(c.canvas, "in");
  assert.deepEqual(c.courses.map((x) => x.courseID), ["111", "222"]);
  assert.equal(c.courses[0].code, "CIS 2400");
  assert.equal(c.courses[0].term, "202630");
  const kinds = new Set(c.documents.map((d) => d.kind));
  for (const k of ["syllabus", "page", "module", "assignment", "announcement"]) assert.ok(kinds.has(k), k);
  assert.deepEqual(c.failures, { 111: [], 222: [] });
  assert.ok(c.links.some((l) => l.href === "https://example.com/x" && l.origin === "page"));
  assert.ok(canvas.log.urls.some((u) => u.includes("page=2")));
});

test("collect: every page body is fetched, no cap at 40", async () => {
  const canvas = fakeCanvas({ pageCount: 55 });
  const c = await collect(canvas, { courses: [{ courseID: "111", code: "CIS 2400", name: "CIS 2400-001 x", url: "https://canvas.upenn.edu/courses/111" }] });
  assert.equal(c.documents.filter((d) => d.kind === "page").length, 55);
});

test("collect: announcements ask for a window with both ends, ending tomorrow", async () => {
  const canvas = fakeCanvas();
  await collect(canvas);
  const url = canvas.log.urls.find((u) => u.includes("/announcements"));
  assert.match(url, /start_date=2026-04-05T15:00:00Z/);
  assert.match(url, /end_date=2026-10-23T15:00:00Z/);
});

test("collect: an announcement with no message is skipped, one with no title is titled Announcement", async () => {
  const canvas = fakeCanvas({
    override: (url, u) => u.pathname === "/api/v1/announcements"
      ? reply([
        { id: 1, context_code: u.searchParams.get("context_codes[]"), title: "Image only", message: "", posted_at: "2026-10-01T12:00:00Z" },
        { id: 2, context_code: u.searchParams.get("context_codes[]"), title: "", message: "<p>hello</p>", posted_at: "2026-10-01T12:00:00Z" },
      ])
      : null,
  });
  const c = await collect(canvas);
  const docs = c.documents.filter((d) => d.kind === "announcement" && d.courseID === "111");
  assert.equal(docs.length, 1);
  assert.equal(docs[0].title, "Announcement");
  assert.equal(docs[0].text, "hello");
});

test("collect: one request in flight, 250 ms between requests, none before the first", async () => {
  const canvas = fakeCanvas();
  const sleeps = [];
  const c = await collectCourseMaterial({ fetch: canvas.fetch, now: NOW, sleep: async (ms) => { sleeps.push(ms); } });
  assert.equal(canvas.log.maxInflight, 1);
  assert.equal(sleeps.length, canvas.log.urls.length - 1);
  assert.ok(sleeps.every((ms) => ms === 250));
  assert.equal(c.summary.requests, canvas.log.urls.length);
});

test("collect: a 401 is canvas out and carries nothing", async () => {
  const canvas = fakeCanvas({ override: (url, u) => (u.pathname.endsWith("/assignments") ? reply("", { status: 401, raw: true }) : null) });
  const c = await collect(canvas);
  assert.equal(c.canvas, "out");
  assert.equal(c.documents.length, 0);
  assert.equal(c.courses.length, 0);
  const b = fakeBackend();
  const { summary } = await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: {} });
  assert.equal(b.calls.length, 0);
  assert.equal(summary.uploaded, 0);
});

test("collect: a redirect to the PennKey login, or an HTML 200, is canvas out", async () => {
  for (const o of [
    reply("<html>", { url: "https://weblogin.pennkey.upenn.edu/login", raw: true }),
    reply("<!DOCTYPE html><html><body>Log in</body></html>", { raw: true }),
  ]) {
    const c = await collect(fakeCanvas({ override: (url, u) => (u.pathname === "/api/v1/courses" ? o : null) }));
    assert.equal(c.canvas, "out");
    assert.deepEqual(c.documents, []);
  }
  // mid-run sign-out discards what was already read
  const mid = await collect(fakeCanvas({ override: (url, u) => (/courses\/222\/modules/.test(u.pathname) ? reply("<html>", { raw: true }) : null) }));
  assert.equal(mid.canvas, "out");
  assert.deepEqual(mid.documents, []);
});

test("collect: a rate limit stops the run and leaves later courses unsynced", async () => {
  const canvas = fakeCanvas({ override: (url, u) => (/courses\/111\/modules/.test(u.pathname) ? reply("", { status: 429, raw: true }) : null) });
  const c = await collect(canvas);
  assert.equal(c.summary.rateLimited, true);
  assert.ok(c.failures["111"].includes("modules"));
  assert.deepEqual(c.failures["222"], ["skipped"]);
  assert.ok(!canvas.log.urls.some((u) => u.includes("/courses/222/")));
});

test("sync: a failed endpoint keeps that course out of fullySyncedCourses", async () => {
  const canvas = fakeCanvas({ override: (url, u) => (/courses\/222\/modules/.test(u.pathname) ? reply("", { status: 500, raw: true }) : null) });
  const c = await collect(canvas);
  assert.deepEqual(c.failures["222"], ["modules"]);
  const b = fakeBackend();
  const { summary } = await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: {} });
  const upload = b.calls.filter((x) => x.body.action === "upload").at(-1).body;
  assert.deepEqual(upload.fullySyncedCourses.map((f) => f.courseID), ["111"]);
  assert.equal(upload.client, "extension");
  assert.equal(summary.fullySynced, 1);
  assert.equal(summary.failedEndpoints, 1);
  const manifest = b.calls[0].body;
  assert.equal(manifest.client, "extension");
  assert.deepEqual(manifest.acceptsKinds, ACCEPTED_KINDS);
  assert.ok(manifest.acceptsKinds.includes("file"));
});

test("sync: documentIDs list everything held after download, including website, ed and phone documents", async () => {
  const c = await collect(fakeCanvas());
  const ours = c.documents.filter((d) => d.courseID === "111").map((d) => d.id);
  const down = (id, kind, hash = "h1") => ({ id, courseID: "111", course: "CIS 2400", kind, sourceID: id.split(":")[2], title: SECRET, text: "SERVER TEXT", contentHash: hash, fetchedAt: "2026-10-01T00:00:00Z" });
  const manifest = {
    download: [
      down("website:111:abc", "website"),
      down("ed:111:77", "ed"),
      down("syllabus:111:page-syllabus-pdf", "syllabus"), // the phone's PDF syllabus
      down("home:111:front", "home"),
    ],
    serverManifest: [],
  };
  const b = fakeBackend({ manifest });
  const prior = { 111: [{ id: "website:111:old", contentHash: "w" }], 999: [{ id: "page:999:gone", contentHash: "x" }] };
  const { summary, holdings } = await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: prior });
  const upload = b.calls.filter((x) => x.body.action === "upload").at(-1).body;
  const entry = upload.fullySyncedCourses.find((f) => f.courseID === "111");
  for (const id of [...ours, "website:111:abc", "ed:111:77", "syllabus:111:page-syllabus-pdf", "home:111:front", "website:111:old"]) {
    assert.ok(entry.documentIDs.includes(id), id);
  }
  assert.deepEqual(entry.documentIDs, [...entry.documentIDs].sort());
  assert.equal(summary.downloaded, 4);
  // holdings: ids and hashes only; a course no longer active is pruned
  assert.deepEqual(Object.keys(holdings).sort(), ["111", "222"]);
  assert.ok(holdings["111"].every((h) => Object.keys(h).sort().join() === "contentHash,id"));
  assert.ok(!JSON.stringify(holdings).includes("SERVER TEXT"));
  // downloaded stubs are never re-uploaded (no text)
  assert.ok(upload.documents.every((d) => typeof d.text === "string"));
  assert.ok(!upload.documents.some((d) => d.id.startsWith("website:")));
});

test("sync: a Canvas document that vanished is not held again from the download, so it can retire", async () => {
  const c = await collect(fakeCanvas());
  const stale = { id: "assignment:111:5", courseID: "111", kind: "assignment", contentHash: "old", text: "t" };
  const b = fakeBackend({ manifest: { download: [stale] } });
  const { holdings } = await syncCourseMaterial({
    callFunction: b.callFunction, collected: c, holdings: { 111: [{ id: "assignment:111:5", contentHash: "old" }] },
  });
  const upload = b.calls.at(-1).body;
  assert.ok(!upload.fullySyncedCourses.find((f) => f.courseID === "111").documentIDs.includes("assignment:111:5"));
  assert.ok(!holdings["111"].some((h) => h.id === "assignment:111:5"));
  // ...but in a course that was NOT fully fetched it is held
  const canvas = fakeCanvas({ override: (url, u) => (/courses\/111\/modules/.test(u.pathname) ? reply("", { status: 500, raw: true }) : null) });
  const c2 = await collect(canvas);
  const b2 = fakeBackend({ manifest: { download: [stale] } });
  const r2 = await syncCourseMaterial({ callFunction: b2.callFunction, collected: c2, holdings: {} });
  assert.ok(r2.holdings["111"].some((h) => h.id === "assignment:111:5"));
});

test("sync: documents the server already holds byte for byte are not re-uploaded; changed ones are", async () => {
  const c = await collect(fakeCanvas());
  const a = c.documents.find((d) => d.kind === "assignment" && d.courseID === "111");
  const p = c.documents.find((d) => d.kind === "page" && d.courseID === "111");
  const b = fakeBackend({ manifest: { serverManifest: [{ id: a.id, contentHash: a.contentHash }, { id: p.id, contentHash: "different" }] } });
  await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: {} });
  const ids = b.calls.filter((x) => x.body.action === "upload").flatMap((x) => x.body.documents.map((d) => d.id));
  assert.ok(!ids.includes(a.id));
  assert.ok(ids.includes(p.id));
});

test("sync: notPaired stops quietly after one call, with no error counted and no retry", async () => {
  const c = await collect(fakeCanvas());
  const b = fakeBackend({ fail: { manifest: "notPaired" } });
  const holdings = { 111: [{ id: "page:111:a", contentHash: "h" }] };
  const r = await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings });
  assert.equal(b.calls.length, 1);
  assert.equal(r.summary.stopped, "notPaired");
  assert.deepEqual(r.summary.errors, {});
  assert.equal(r.holdings, holdings);
});

test("sync: quota stops the run, is counted once, and nothing is retried", async () => {
  const c = await collect(fakeCanvas());
  const b = fakeBackend({ fail: { upload: "quota" } });
  const r = await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: {} });
  assert.equal(b.calls.length, 2); // manifest, first upload batch
  assert.equal(r.summary.stopped, "quota");
  assert.deepEqual(r.summary.errors, { quota: 1 });
  assert.equal(r.summary.uploaded, 0);
});

test("sync: fullySyncedCourses ride only the last batch", async () => {
  const c = await collect(fakeCanvas());
  c.documents = c.documents.concat(Array.from({ length: 450 }, (_, i) => ({ ...c.documents[0], id: `page:111:bulk${i}`, sourceID: `bulk${i}` })));
  const b = fakeBackend();
  const { summary } = await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: {} });
  const uploads = b.calls.filter((x) => x.body.action === "upload").map((x) => x.body);
  assert.ok(uploads.length >= 3);
  assert.ok(uploads.slice(0, -1).every((u) => u.fullySyncedCourses.length === 0));
  assert.equal(uploads.at(-1).fullySyncedCourses.length, 2);
  assert.equal(summary.uploaded, c.documents.length);
});

// -------------------------------------------------------------------- Ed

function fakeEd({ canvas, user, threads, status = {} }) {
  const seen = [];
  const fetchFn = async (url, init) => {
    if (!url.startsWith("https://us.edstem.org/api/")) return canvas.fetch(url, init);
    seen.push({ url, init });
    const st = status[new URL(url).pathname];
    if (st) return reply("", { status: st, raw: true });
    const body = new URL(url).pathname === "/api/user" ? user : threads;
    return reply(JSON.stringify(body), { raw: true });
  };
  return { fetch: fetchFn, seen };
}

test("ed: matches by code and term, keeps only announcements, pinned and staff, sends the token as x-token without cookies", async () => {
  const canvas = fakeCanvas();
  const user = { courses: [{ course: { id: 5, code: "CIS 2400", name: "n", year: "2026", session: "Fall" }, role: { role: "student" } }] };
  const t = (id, over) => ({ id, user_id: 1, course_id: 5, type: "post", title: `${SECRET} ed ${id}`, document: "<document><paragraph>x</paragraph></document>", is_pinned: false, is_private: false, created_at: "2026-10-10T12:00:00.000000+00:00", ...over });
  const threads = {
    threads: [t(1, { type: "announcement", user_id: 9 }), t(2, { user_id: 9 }), t(3, { type: "question", user_id: 2, title: "student question" }), t(4, { is_pinned: true, user_id: 9 }), t(5, { user_id: 9, is_private: true })],
    users: [{ id: 1, name: "Prof Name", course_role: "admin" }, { id: 2, name: "A Student", course_role: "student" }, { id: 9, name: "Student", course_role: "student" }],
  };
  const ed = fakeEd({ canvas, user, threads });
  const c = await collectCourseMaterial({ fetch: ed.fetch, now: NOW, sleep: noSleep, edToken: "tok-123" });
  const eds = c.documents.filter((d) => d.kind === "ed");
  assert.deepEqual(eds.map((d) => d.sourceID).sort(), ["1", "4"]);
  assert.ok(eds.every((d) => d.courseID === "111" && !d.text.includes("Student")));
  assert.equal(c.ed, "in");
  assert.deepEqual(c.edReadCourseIDs, ["111"]);
  assert.ok(ed.seen.every((s) => s.init.headers["x-token"] === "tok-123" && s.init.credentials === "omit"));
  assert.ok(!JSON.stringify(c.summary).includes("tok-123"));
});

test("ed: a rejected token is ed out and Canvas still collects", async () => {
  const canvas = fakeCanvas();
  const ed = fakeEd({ canvas, user: {}, threads: {}, status: { "/api/user": 401 } });
  const c = await collectCourseMaterial({ fetch: ed.fetch, now: NOW, sleep: noSleep, edToken: "bad" });
  assert.equal(c.ed, "out");
  assert.equal(c.canvas, "in");
  assert.ok(c.documents.length > 0);
});

test("ed: no token means no Ed request at all", async () => {
  const canvas = fakeCanvas();
  const ed = fakeEd({ canvas, user: {}, threads: {} });
  const c = await collectCourseMaterial({ fetch: ed.fetch, now: NOW, sleep: noSleep });
  assert.equal(ed.seen.length, 0);
  assert.equal(c.ed, "none");
});

test("ed token handler: only edstem.org may deliver it, and it lands in session storage only", async () => {
  const store = {};
  const session = { set: async (o) => Object.assign(store, o), get: async (k) => ({ [k]: store[k] }) };
  const msg = { type: "edToken", token: "abc" };
  for (const origin of ["https://evil.example", "https://canvas.upenn.edu", "https://edstem.org.evil.example", "http://edstem.org", "https://us.edstem.org", undefined]) {
    assert.equal((await handleEdTokenMessage(msg, { origin }, session)).ok, false, String(origin));
  }
  assert.equal((await handleEdTokenMessage(msg, undefined, session)).ok, false);
  assert.deepEqual(store, {});
  assert.equal((await handleEdTokenMessage({ type: "edToken", token: "" }, { origin: "https://edstem.org" }, session)).ok, false);
  assert.equal((await handleEdTokenMessage({ type: "edToken", token: 5 }, { origin: "https://edstem.org" }, session)).ok, false);
  assert.equal((await handleEdTokenMessage({ type: "other", token: "abc" }, { origin: "https://edstem.org" }, session)).ok, false);
  assert.equal((await handleEdTokenMessage(msg, { origin: "https://edstem.org" }, session)).ok, true);
  assert.equal(store[ED_TOKEN_KEY], "abc");
  assert.equal(await readEdToken(session), "abc");
});

// --------------------------------------------------------------- privacy

test("no summary contains a title, id, url or token, success or failure", async () => {
  const canvas = fakeCanvas({ override: (url, u) => (/courses\/222\/modules/.test(u.pathname) ? reply("", { status: 500, raw: true }) : null) });
  const user = { courses: [] };
  const ed = fakeEd({ canvas, user, threads: { threads: [], users: [] } });
  const c = await collectCourseMaterial({ fetch: ed.fetch, now: NOW, sleep: noSleep, edToken: "tok-secret" });
  const runs = [c.summary];
  for (const fail of [{}, { manifest: "notPaired" }, { upload: "quota" }, { upload: "server" }]) {
    const b = fakeBackend({ fail });
    runs.push((await syncCourseMaterial({ callFunction: b.callFunction, collected: c, holdings: {} })).summary);
  }
  const forbidden = [SECRET, "canvas.upenn.edu", "https://", "http", "tok-secret", "CIS 2400", "MATH 1400", "111", "222", "assignment:", "page:", "Machine Architecture"];
  for (const s of runs) {
    const text = JSON.stringify(s);
    for (const f of forbidden) assert.ok(!text.includes(f), `${f} in ${text}`);
    // counts, booleans and words only
    (function walk(v) {
      if (v && typeof v === "object") return Object.values(v).forEach(walk);
      assert.ok(["number", "boolean", "string"].includes(typeof v) || v === null);
      if (typeof v === "string") assert.match(v, /^[A-Za-z-]+$/);
    })(s);
  }
});
