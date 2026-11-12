// A local fake of everything the extension talks to: Ed, Canvas, Gradescope and
// the Smooth backend, all on one HTTPS server routed by Host header. Chromium is
// pointed at it with --host-resolver-rules, so the real hostnames never leave
// the machine. Every request is recorded in `world.log`.
import https from "node:https";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, existsSync } from "node:fs";
import path from "node:path";

export const HOSTS = ["edstem.org", "us.edstem.org", "canvas.upenn.edu", "www.gradescope.com", "ynetfjixexksxqrrkwsg.supabase.co"];

// ---------------------------------------------------------------- Ed data

const pad = (n, w = 2) => String(n).padStart(w, "0");

// Ed's timestamp style: microseconds and a US Eastern UTC offset, e.g.
// "2026-10-12T11:30:00.123456-04:00" (GUESS on the offset: the recorded fixture
// uses +10:00/-04:00 style offsets; Eastern keeps it realistic).
export function edDate(date) {
  const f = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const p = {};
  for (const x of f.formatToParts(date)) p[x.type] = x.value;
  const wallAsUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute, +p.second);
  const offMin = Math.round((wallAsUTC - Math.floor(date.getTime() / 1000) * 1000) / 60000);
  const sign = offMin < 0 ? "-" : "+";
  const a = Math.abs(offMin);
  const micro = pad(date.getUTCMilliseconds(), 3) + "123";
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}.${micro}${sign}${pad(Math.floor(a / 60))}:${pad(a % 60)}`;
}

const doc = (inner) => `<document version="2.0"><paragraph>${inner}</paragraph></document>`;

// Course 101: 250 threads, newest first. Returns { threads, keep:Set<id>, drop:Set<id>, byIndex }.
export function buildCourse101(now) {
  const threads = [];
  const keep = new Set();
  const drop = new Set();
  const byIndex = {};
  for (let i = 0; i < 250; i += 1) {
    const updated = new Date(now - (3600e3 + 6 * 3600e3 * i));
    const created = new Date(updated.getTime() - 20 * 60e3);
    const id = 9000 + i;
    const t = {
      id, user_id: 9, course_id: 101, type: i % 3 === 0 ? "question" : "post",
      title: `Student thread ${i}`, document: doc(`Student body ${i}`), content: `<p>Student body ${i}</p>`,
      category: "General", subcategory: "", is_pinned: false, is_private: false, is_anonymous: false,
      is_endorsed: false, created_at: edDate(created), updated_at: edDate(updated), number: i + 1,
      reply_count: i % 5, vote_count: i % 7,
    };
    const set = (patch, verdict) => { Object.assign(t, patch); (verdict === "keep" ? keep : drop).add(id); byIndex[i] = { id, created, verdict }; };
    if (i === 0) set({ user_id: 7, type: "announcement", title: "Midterm room", document: doc("The midterm is in <bold>Towne 100</bold> &amp; starts at 10."), category: "Exams", subcategory: "Midterm" }, "keep");
    if (i === 3) set({ user_id: 8, type: "post", title: "Staff note" }, "keep");
    if (i === 5) set({ is_pinned: true, title: "Pinned student post" }, "keep");
    if (i === 7) set({ user_id: 7, type: "announcement", is_private: true, title: "Private announcement" }, "drop");
    if (i === 9) set({ user_id: 7, type: "announcement", is_anonymous: true, title: "Anonymous announcement" }, "drop");
    if (i === 11) set({ user_id: 7, type: "question", title: "Staff question" }, "drop");
    if (i === 13) set({ user_id: 10, type: "post", title: "TA post" }, "keep");
    if (i === 15) set({ user_id: 7, type: "post", title: "Html only", document: null, content: "<p>only &amp; html</p>" }, "keep");
    if (i === 150) set({ user_id: 7, type: "announcement", title: "Page two announcement" }, "keep");
    if (i === 180) set({ user_id: 7, type: "announcement", is_pinned: true, title: "Page two pinned announcement" }, "keep");
    if (i === 230) set({ user_id: 8, type: "post", title: "Page three staff post" }, "keep");
    threads.push(t);
  }
  return { threads, keep, drop, byIndex };
}

export function buildCourse202(now) {
  const threads = [];
  const keep = new Set();
  for (let i = 0; i < 30; i += 1) {
    const updated = new Date(now - (3600e3 + 6 * 3600e3 * i));
    const id = 7000 + i;
    const t = {
      id, user_id: 9, course_id: 202, type: "post", title: `Student thread ${i}`, document: doc(`Body ${i}`),
      content: `<p>Body ${i}</p>`, category: "General", subcategory: "", is_pinned: false, is_private: false,
      is_anonymous: false, is_endorsed: false, created_at: edDate(new Date(updated.getTime() - 20 * 60e3)),
      updated_at: edDate(updated), number: i + 1, reply_count: 0, vote_count: 0,
    };
    if (i === 0) { t.type = "announcement"; t.user_id = 7; t.title = "Automata announcement"; keep.add(id); }
    threads.push(t);
  }
  return { threads, keep };
}

const USERS = [
  { id: 7, name: "Fixture Instructorname", course_role: "admin" },
  { id: 8, name: "Fixture Staffname", course_role: "staff" },
  { id: 9, name: "Fixture Studentname", course_role: "student" },
  { id: 10, name: "Fixture Taname", course_role: "ta" },
];

// ------------------------------------------------------------------ cert

export function makeCert(dir) {
  mkdirSync(dir, { recursive: true });
  const key = path.join(dir, "key.pem");
  const crt = path.join(dir, "cert.pem");
  const san = HOSTS.map((h) => `DNS:${h}`).join(",") + ",IP:127.0.0.1";
  execFileSync("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt, "-days", "2", "-subj", "/CN=smooth-e2e", "-addext", `subjectAltName=${san}`], { stdio: "ignore" });
  return { key: readFileSync(key), cert: readFileSync(crt) };
}

// ----------------------------------------------------------------- world

export async function startWorld({ token, certDir }) {
  const now = Date.now();
  const c101 = buildCourse101(now);
  const c202 = buildCourse202(now);
  const log = [];
  const uploads = [];
  const deviceSyncUploads = []; // bodies of device-sync `put` (the sealed snapshot)
  const submittedAt = new Date(now - 2 * 3600e3).toISOString();
  const t0 = Date.now();

  const send = (res, status, body, type = "application/json") => {
    res.writeHead(status, { "content-type": type, "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" });
    res.end(typeof body === "string" ? body : JSON.stringify(body));
  };

  const server = https.createServer(makeCert(certDir), (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const host = (req.headers.host || "").split(":")[0];
      const u = new URL(req.url, `https://${host}`);
      const raw = Buffer.concat(chunks).toString("utf8");
      let body;
      if (raw) { try { body = JSON.parse(raw); } catch { body = raw; } }
      log.push({ t: Date.now() - t0, method: req.method, host, path: u.pathname, query: Object.fromEntries(u.searchParams), headers: req.headers, body });
      if (req.method === "OPTIONS") return send(res, 204, "");
      try { route(host, u, req, body, res); } catch (e) { send(res, 500, { error: String(e) }); }
    });
  });

  const authed = (req) => req.headers["x-token"] === token;

  function route(host, u, req, body, res) {
    const p = u.pathname;
    if (host === "edstem.org") {
      return send(res, 200, `<!doctype html><html><head><meta charset="utf-8"><title>Ed</title></head><body><p>Fake Ed discussion page.</p><script>localStorage.setItem("authToken", ${JSON.stringify(token)});</script></body></html>`, "text/html");
    }
    if (host === "us.edstem.org") {
      if (!authed(req)) return send(res, 401, { error: "bad_token" });
      if (p === "/api/user") {
        return send(res, 200, { user: { id: 1, name: "Sam" }, courses: [
          { course: { id: 101, code: "CIS 2400", name: "Machine Organization", year: "2026", session: "Fall", status: "active", created_at: edDate(new Date(now - 90 * 86400e3)) }, role: { role: "student" } },
          { course: { id: 202, code: "CIS 2620", name: "Automata", year: "2026", session: "Fall", status: "active", created_at: edDate(new Date(now - 90 * 86400e3)) }, role: { role: "student" } },
        ] });
      }
      const m = p.match(/^\/api\/courses\/(\d+)\/threads$/);
      if (m) {
        const set = m[1] === "101" ? c101.threads : m[1] === "202" ? c202.threads : null;
        if (!set) return send(res, 404, { error: "no_course" });
        const limit = Math.min(Number(u.searchParams.get("limit") || 30), 100);
        const offset = Number(u.searchParams.get("offset") || 0);
        return send(res, 200, { threads: set.slice(offset, offset + limit), users: USERS });
      }
      return send(res, 404, { error: "not_found" });
    }
    if (host === "canvas.upenn.edu") {
      // The collector strips Canvas's anti-hijack prefix (stripAntiHijackPrefix).
      const canvas = (v) => send(res, 200, "while(1);" + JSON.stringify(v));
      if (p === "/api/v1/users/self") return canvas({ id: 1 });
      if (p === "/api/v1/users/self/profile") return canvas({ id: 1, calendar: { ics: "https://canvas.upenn.edu/feeds/calendars/user_fake.ics" } });
      if (p === "/feeds/calendars/user_fake.ics") {
        const d = new Date(now + 86400e3);
        const stamp = `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
        const ev = (n, summary) => ["BEGIN:VEVENT", `UID:assignment-${n}`, `SUMMARY:${summary}`, `DTSTART:${stamp}`,
          `URL:https://canvas.upenn.edu/calendar?include_contexts=course_111&month=11&year=2026#assignment_${n}`, "END:VEVENT"];
        const ics = ["BEGIN:VCALENDAR", "VERSION:2.0", ...ev(5001, "Homework 6 [CIS 2400]"), ...ev(5002, "Homework 7"), "END:VCALENDAR"].join("\r\n") + "\r\n";
        return send(res, 200, ics, "text/calendar");
      }
      if (p === "/api/v1/courses/111/assignments") {
        const a = (id, name, submission) => ({ id, name, html_url: `https://canvas.upenn.edu/courses/111/assignments/${id}`, due_at: new Date(now + 86400e3).toISOString(), points_possible: 10, description: `<p>${name}</p>`, course_id: 111, submission });
        return canvas([
          a(5001, "Homework 6", { submitted_at: submittedAt, workflow_state: "submitted", missing: false }),
          a(5002, "Homework 7", { submitted_at: null, workflow_state: "unsubmitted", missing: false }),
        ]);
      }
      if (p === "/api/v1/courses/222/assignments") return canvas([]);
      if (p === "/api/v1/courses") return canvas([
        { id: 111, name: "CIS 2400-001 202630 Machine Organization", course_code: "CIS 2400-001 202630" },
        { id: 222, name: "CIS 2620-001 202630 Automata", course_code: "CIS 2620-001 202630" },
      ]);
      const c = p.match(/^\/api\/v1\/courses\/(\d+)$/);
      if (c) return canvas({ id: Number(c[1]), syllabus_body: "<p>syllabus</p>" });
      if (p.startsWith("/api/v1/")) return canvas([]);
      return send(res, 200, "<html><body>fake canvas</body></html>", "text/html");
    }
    if (host === "www.gradescope.com") return send(res, 200, "<html><body>fake gradescope</body></html>", "text/html");
    if (host === "ynetfjixexksxqrrkwsg.supabase.co") {
      const session = { access_token: "fake-access", refresh_token: "fake-refresh", expires_in: 3600, user: { id: "00000000-0000-4000-8000-000000000001" } };
      if (p === "/auth/v1/signup" || p === "/auth/v1/token") return send(res, 200, session);
      if (p === "/functions/v1/sync") {
        if (body?.action === "manifest") return send(res, 200, { serverManifest: [], download: [], profileStale: [], websitesPending: [] });
        if (body?.action === "upload") { uploads.push(body); return send(res, 200, { profileStale: [], websitesPending: [] }); }
        return send(res, 400, { error: "bad_action" });
      }
      if (p === "/functions/v1/pair") return send(res, 200, { paired: true });
      if (p === "/functions/v1/device-sync") {
        if (body?.action === "put") { deviceSyncUploads.push(body); return send(res, 200, { deviceId: body.deviceId, updatedAt: new Date().toISOString() }); }
        return send(res, 200, { blobs: [] }); // get: nothing from a peer yet
      }
      return send(res, 200, {}); // extract-profile, discover-websites, pair, extract-profile, discover-websites
    }
    return send(res, 404, { error: "unknown_host", host });
  }

  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  return {
    port, token, log, uploads, deviceSyncUploads, submittedAt, c101, c202, now,
    hostRules: HOSTS.map((h) => `MAP ${h} 127.0.0.1:${port}`).join(", "),
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
  };
}
