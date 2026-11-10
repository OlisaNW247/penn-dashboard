#!/usr/bin/env node
// Plays an OAuth client AND the student's phone against the LIVE agent
// connection (agent-auth, mcp), end to end, with no real phone or Claude and
// no Management API token. A throwaway anonymous user approves the sign-in
// and is deleted through `delete-account` at the end (which also revokes its
// connections and snapshot). Never prints tokens, codes, cookies or the JWT.
//
//   node backend/scripts/agent-e2e.mjs [--base <url>] [--dry-run]
//
// Since 2026-11-10 it also walks the drafts: the throwaway puts a one-item
// snapshot, the agent proposes a text and a 20 KB file draft, the phone lists
// them (downloading the file through its signed URL and comparing bytes),
// moves them to seen, declined and submitted, sees 409 on a second move, and
// finally opts out, which must delete the snapshot, every draft and the open
// draft's Storage object.
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const DEFAULT_BASE = "https://smooth-agent.vercel.app/functions/v1";
const SUPABASE_URL = process.env.LHF_SUPABASE_URL ?? "https://ynetfjixexksxqrrkwsg.supabase.co";
const PUBLISHABLE_KEY = process.env.LHF_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt";
const REDIRECT = "http://127.0.0.1:19876/cb";

export const STEPS = [
  "discovery: 401 challenge, protected-resource and authorization-server metadata",
  "register a client (RFC 7591)",
  "authorize page: code, match number, pending id, nonce cookie",
  "throwaway anonymous user",
  "phone: lookup and approve",
  "status?go=1 redirects with code, state, iss",
  "token exchange and refresh rotation",
  "mcp: initialize, tools/list, list_work",
  "phone: list connections, revoke, mcp refuses",
  "cleanup: delete-account",
  "phone: put a snapshot with one test assignment",
  "drafts: propose text and a 20 KB file, list, download, seen, declined, submitted, 409",
  "phone: opt out (delete) removes the snapshot, the drafts and the connection",
];
// STEPS[10..12] were added later and sit at the end only so the older indices
// keep their meaning; RUN_ORDER is the order they actually run in.
export const RUN_ORDER = [0, 1, 2, 3, 4, 5, 6, 10, 7, 11, 8, 12, 9];

// ---- pure parts -----------------------------------------------------

export function b64url(buf) {
  return Buffer.from(buf).toString("base64url");
}

export function makePKCE(bytes = crypto.randomBytes(32)) {
  const verifier = b64url(bytes);
  const challenge = b64url(crypto.createHash("sha256").update(verifier).digest());
  return { verifier, challenge };
}

/** `Bearer resource_metadata="...", scope="..."` -> { resource_metadata, scope, error, ... } */
export function parseChallenge(header) {
  const out = {};
  if (typeof header !== "string") return out;
  for (const m of header.matchAll(/([a-z_]+)="([^"]*)"/g)) out[m[1]] = m[2];
  return out;
}

/** A Streamable HTTP body: plain JSON, or SSE `data:` lines. Returns the last JSON-RPC message. */
export function parseMcpBody(text) {
  const trimmed = (text ?? "").trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) return JSON.parse(trimmed);
  let last = null;
  for (const line of trimmed.split(/\r?\n/)) {
    if (line.startsWith("data:")) {
      const data = line.slice(5).trim();
      if (data) last = JSON.parse(data);
    }
  }
  if (!last) throw new Error("no JSON-RPC message in response");
  return last;
}

/** Reads the pending id, user code and match number out of `authorizePage`'s HTML. */
export function parseAuthorizePage(html) {
  const link = /smooth:\/\/link\?c=([A-Za-z0-9_%-]+)/.exec(html);
  const code = /<div class="code">([^<]+)<\/div>/.exec(html);
  const num = /<div class="num">(\d+)<\/div>/.exec(html);
  if (!link || !code || !num) throw new Error("authorize page did not have the expected code, number and link");
  return { pendingId: decodeURIComponent(link[1]), userCode: code[1].trim(), matchNumber: Number(num[1]) };
}

/** Value of cookie `name` from a Set-Cookie header (or list of them). */
export function cookieFrom(setCookie, name) {
  const list = Array.isArray(setCookie) ? setCookie : [setCookie ?? ""];
  for (const entry of list) {
    const m = new RegExp(`(?:^|,\\s*)${name}=([^;]+)`).exec(entry);
    if (m) return m[1];
  }
  return null;
}

/** The draft id out of `propose_submission`'s text result. */
export function draftIdFrom(text) {
  const m = /draft (smd_[A-Za-z0-9_-]+) proposed/.exec(text ?? "");
  return m ? m[1] : null;
}

/** A deterministic test file of `n` bytes (no randomness, so a mismatch is a real one). */
export function testFileBytes(n = 20 * 1024) {
  const out = Buffer.alloc(n);
  for (let i = 0; i < n; i++) out[i] = (i * 31 + 7) & 0xff;
  return out;
}

/** The throwaway's snapshot: one course, one assignment the drafts point at. */
export const TEST_ASSIGNMENT_ID = "e2e-assignment-1";
export function testSnapshot(now = new Date()) {
  return {
    courses: [{ courseID: "9999001", code: "E2E 0001", name: "E2E 0001 probe course" }],
    workList: [{
      id: TEST_ASSIGNMENT_ID, course: "E2E 0001", title: "Probe assignment", kind: "assignment",
      dueAt: new Date(now.getTime() + 86_400_000).toISOString(), done: false, noSubmission: false,
      url: null, source: "canvas",
    }],
  };
}

export function mask(token) {
  return typeof token === "string" ? `${token.slice(0, 6)}… (${token.length} chars)` : String(token);
}

export function parseArgs(argv) {
  const opts = { base: DEFAULT_BASE, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dry-run") opts.dryRun = true;
    else if (argv[i] === "--base") opts.base = String(argv[++i] ?? "").replace(/\/+$/, "");
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  return opts;
}

// ---- the run --------------------------------------------------------

class StepFailure extends Error {}
const must = (cond, detail) => {
  if (!cond) throw new StepFailure(detail);
};

export async function run(argv, { fetchImpl = fetch, log = console.log } = {}) {
  const opts = parseArgs(argv);
  const base = opts.base;
  if (opts.dryRun) {
    log(`dry run against ${base}; nothing is sent`);
    RUN_ORDER.forEach((i, n) => log(`${n + 1}. ${STEPS[i]}`));
    return 0;
  }
  let failed = false;
  let user = null;
  const step = async (name, fn) => {
    try {
      const note = await fn();
      log(`ok: ${name}${note ? ` (${note})` : ""}`);
    } catch (err) {
      failed = true;
      log(`FAIL: ${name}: ${err instanceof Error ? err.message : err}`);
      throw err;
    }
  };
  const bodyOf = async (res) => {
    const text = await res.text();
    try { return { text, json: JSON.parse(text) }; } catch { return { text, json: undefined }; }
  };
  const phone = async (payload) => {
    const res = await fetchImpl(`${base}/agent-auth/phone`, {
      method: "POST",
      headers: { Authorization: `Bearer ${user.jwt}`, apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const b = await bodyOf(res);
    return { status: res.status, ...b };
  };
  const snap = async (payload) => {
    const res = await fetchImpl(`${SUPABASE_URL}/functions/v1/agent-snapshot`, {
      method: "POST",
      headers: { Authorization: `Bearer ${user.jwt}`, apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    return { status: res.status, ...(await bodyOf(res)) };
  };
  const callTool = async (id, name, args) => {
    const r = await mcp(s.access, { jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
    must(r.res.status === 200, `${name} HTTP ${r.res.status} ${r.text.slice(0, 300)}`);
    const msg = parseMcpBody(r.text);
    const text = (msg.result?.content ?? []).map((c) => c.text ?? "").join(" ");
    must(msg.result && !msg.result.isError, `${name} result: ${text.slice(0, 300) || r.text.slice(0, 300)}`);
    return text;
  };
  const mcp = async (token, message) => {
    const res = await fetchImpl(`${base}/mcp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        "MCP-Protocol-Version": "2025-06-18",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(message),
    });
    return { res, text: await res.text() };
  };
  const tokenPost = async (params) => {
    const res = await fetchImpl(`${base}/agent-auth/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params).toString(),
    });
    return { status: res.status, ...(await bodyOf(res)) };
  };

  const s = {};
  try {
    await step(STEPS[0], async () => {
      const r = await mcp(null, {});
      must(r.res.status === 401, `mcp without token: HTTP ${r.res.status} ${r.text.slice(0, 200)}`);
      const ch = parseChallenge(r.res.headers.get("www-authenticate"));
      must(ch.resource_metadata, "no resource_metadata in WWW-Authenticate");
      const prm = await fetchImpl(ch.resource_metadata);
      must(prm.status === 200, `PRM HTTP ${prm.status}`);
      const prmJson = await prm.json();
      must(prmJson.resource === `${base}/mcp`, `PRM resource is ${prmJson.resource}`);
      const issuer = prmJson.authorization_servers?.[0];
      must(issuer === `${base}/agent-auth`, `PRM authorization_servers[0] is ${issuer}`);
      const asRes = await fetchImpl(`${issuer}/.well-known/oauth-authorization-server`);
      must(asRes.status === 200, `AS metadata HTTP ${asRes.status}`);
      s.as = await asRes.json();
      must(s.as.issuer === issuer, `AS issuer is ${s.as.issuer}`);
      for (const k of ["authorization_endpoint", "token_endpoint", "registration_endpoint"]) must(s.as[k], `AS metadata lacks ${k}`);
    });

    await step(STEPS[1], async () => {
      const res = await fetchImpl(s.as.registration_endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_name: "Smooth e2e", redirect_uris: [REDIRECT], token_endpoint_auth_method: "none" }),
      });
      const b = await bodyOf(res);
      must(res.status === 201, `register HTTP ${res.status} ${b.text.slice(0, 300)}`);
      must(/^smc_/.test(b.json.client_id), "client_id is not smc_");
      s.clientId = b.json.client_id;
    });

    s.pkce = makePKCE();
    s.state = b64url(crypto.randomBytes(12));
    await step(STEPS[2], async () => {
      const u = new URL(s.as.authorization_endpoint);
      u.search = new URLSearchParams({
        response_type: "code", client_id: s.clientId, redirect_uri: REDIRECT,
        code_challenge: s.pkce.challenge, code_challenge_method: "S256", state: s.state,
        scope: "read draft offline_access", resource: `${base}/mcp`,
      }).toString();
      const res = await fetchImpl(u, { redirect: "manual" });
      const html = await res.text();
      must(res.status === 200, `authorize HTTP ${res.status} ${html.slice(0, 300)}`);
      Object.assign(s, parseAuthorizePage(html));
      const sc = res.headers.getSetCookie ? res.headers.getSetCookie() : res.headers.get("set-cookie");
      s.nonce = cookieFrom(sc, `sa_${s.pendingId}`);
      must(s.nonce, "no sa_<id> cookie");
      must(/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/.test(s.userCode), "user code has an unexpected shape");
    });

    await step(STEPS[3], async () => {
      const res = await fetchImpl(`${SUPABASE_URL}/auth/v1/signup`, {
        method: "POST", headers: { apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" }, body: "{}",
      });
      must(res.ok, `signup HTTP ${res.status}`);
      const j = await res.json();
      must(j.access_token, "signup returned no access_token");
      user = { jwt: j.access_token };
      return `jwt ${j.access_token.length} chars`;
    });

    await step(STEPS[4], async () => {
      const look = await phone({ action: "lookup", code: s.userCode });
      must(look.status === 200, `lookup HTTP ${look.status} ${look.text.slice(0, 300)}`);
      must(look.json.id === s.pendingId, "lookup returned a different pending id");
      must(look.json.clientName === "Smooth e2e", `clientName ${look.json.clientName}`);
      must(Array.isArray(look.json.choices) && look.json.choices.includes(s.matchNumber), "choices lack the page's number");
      const ap = await phone({ action: "approve", c: s.pendingId, picked: s.matchNumber });
      must(ap.status === 200 && ap.json?.approved === true, `approve HTTP ${ap.status} ${ap.text.slice(0, 300)}`);
    });

    await step(STEPS[5], async () => {
      const res = await fetchImpl(`${base}/agent-auth/status?p=${encodeURIComponent(s.pendingId)}&go=1`, {
        redirect: "manual", headers: { Cookie: `sa_${s.pendingId}=${s.nonce}` },
      });
      must(res.status === 302, `status HTTP ${res.status} ${(await res.text()).slice(0, 300)}`);
      const loc = new URL(res.headers.get("location"));
      must(`${loc.origin}${loc.pathname}` === REDIRECT, "redirect target is not the registered URI");
      must(loc.searchParams.get("state") === s.state, "state does not round-trip");
      must(loc.searchParams.get("iss") === `${base}/agent-auth`, `iss is ${loc.searchParams.get("iss")}`);
      s.code = loc.searchParams.get("code");
      must(/^smt_c_/.test(s.code ?? ""), "no smt_c_ code");
    });

    await step(STEPS[6], async () => {
      const t = await tokenPost({
        grant_type: "authorization_code", code: s.code, redirect_uri: REDIRECT, client_id: s.clientId,
        code_verifier: s.pkce.verifier, resource: `${base}/mcp`,
      });
      must(t.status === 200, `token HTTP ${t.status} ${t.text.slice(0, 300)}`);
      must(/^smt_a_/.test(t.json.access_token) && /^smt_r_/.test(t.json.refresh_token), "token shapes");
      const oldRefresh = t.json.refresh_token;
      const r = await tokenPost({ grant_type: "refresh_token", refresh_token: oldRefresh, client_id: s.clientId });
      must(r.status === 200, `refresh HTTP ${r.status} ${r.text.slice(0, 300)}`);
      must(r.json.refresh_token !== oldRefresh, "refresh token did not rotate");
      s.access = r.json.access_token;
      s.refresh = r.json.refresh_token;
      const reuse = await tokenPost({ grant_type: "refresh_token", refresh_token: oldRefresh, client_id: s.clientId });
      must(reuse.status === 400 && reuse.json?.error === "invalid_grant", `old refresh: HTTP ${reuse.status} ${reuse.text.slice(0, 200)}`);
      // Reuse detection revokes the whole connection; sign in again so later steps have one.
      return `access ${mask(s.access)}, expires_in ${r.json.expires_in}; old refresh refused (connection revoked by reuse detection)`;
    });

    // Reuse detection revoked the connection above (by design); run a second sign-in
    // for the MCP and revoke steps.
    await step("second sign-in after reuse detection", async () => {
      const pkce = makePKCE();
      const u = new URL(s.as.authorization_endpoint);
      u.search = new URLSearchParams({
        response_type: "code", client_id: s.clientId, redirect_uri: REDIRECT, code_challenge: pkce.challenge,
        code_challenge_method: "S256", state: "s2", scope: "read draft offline_access", resource: `${base}/mcp`,
      }).toString();
      const res = await fetchImpl(u, { redirect: "manual" });
      const page = parseAuthorizePage(await res.text());
      const nonce = cookieFrom(res.headers.getSetCookie ? res.headers.getSetCookie() : res.headers.get("set-cookie"), `sa_${page.pendingId}`);
      // Like the phone: look the request up first; approve is bound to it.
      const look2 = await phone({ action: "lookup", c: page.pendingId });
      must(look2.status === 200, `lookup HTTP ${look2.status}`);
      const ap = await phone({ action: "approve", c: page.pendingId, picked: page.matchNumber });
      must(ap.json?.approved === true, `approve HTTP ${ap.status}`);
      const go = await fetchImpl(`${base}/agent-auth/status?p=${encodeURIComponent(page.pendingId)}&go=1`, {
        redirect: "manual", headers: { Cookie: `sa_${page.pendingId}=${nonce}` },
      });
      must(go.status === 302, `status HTTP ${go.status}`);
      const code = new URL(go.headers.get("location")).searchParams.get("code");
      const t = await tokenPost({
        grant_type: "authorization_code", code, redirect_uri: REDIRECT, client_id: s.clientId,
        code_verifier: pkce.verifier, resource: `${base}/mcp`,
      });
      must(t.status === 200, `token HTTP ${t.status} ${t.text.slice(0, 200)}`);
      s.access = t.json.access_token;
    });

    await step(STEPS[10], async () => {
      const put = await snap({ action: "put", snapshot: testSnapshot() });
      must(put.status === 200 && put.json?.items === 1, `put HTTP ${put.status} ${put.text.slice(0, 300)}`);
    });

    await step(STEPS[7], async () => {
      const init = await mcp(s.access, {
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "smooth-e2e", version: "1" } },
      });
      must(init.res.status === 200, `initialize HTTP ${init.res.status} ${init.text.slice(0, 300)}`);
      must(parseMcpBody(init.text).result, "initialize had no result");
      const list = await mcp(s.access, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
      must(list.res.status === 200, `tools/list HTTP ${list.res.status} ${list.text.slice(0, 300)}`);
      const names = (parseMcpBody(list.text).result?.tools ?? []).map((t) => t.name);
      must(names.includes("list_work"), "tools/list lacks list_work");
      const call = await mcp(s.access, {
        jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_work", arguments: { view: "todo" } },
      });
      must(call.res.status === 200, `list_work HTTP ${call.res.status} ${call.text.slice(0, 300)}`);
      const msg = parseMcpBody(call.text);
      must(msg.result && !msg.result.isError, `list_work result: ${call.text.slice(0, 300)}`);
      const text = (msg.result.content ?? []).map((c) => c.text ?? "").join(" ");
      return `tools: ${names.join(", ")}; list_work says: ${text.slice(0, 80).replace(/\s+/g, " ")}`;
    });

    await step(STEPS[11], async () => {
      const textMade = await callTool(10, "propose_submission", {
        assignment_id: TEST_ASSIGNMENT_ID, kind: "text", body: "e2e probe text draft", note: "from agent-e2e",
      });
      const textId = draftIdFrom(textMade);
      must(textId, `no draft id in: ${textMade.slice(0, 200)}`);
      const bytes = testFileBytes();
      const fileMade = await callTool(11, "propose_submission", {
        assignment_id: TEST_ASSIGNMENT_ID, kind: "file", file_base64: bytes.toString("base64"),
        file_name: "probe.pdf", mime_type: "application/pdf",
      });
      const fileId = draftIdFrom(fileMade);
      must(fileId, `no draft id in: ${fileMade.slice(0, 200)}`);
      must(/\(20480 bytes decoded/.test(fileMade), `file result does not report 20480 bytes: ${fileMade.slice(0, 200)}`);

      const list = await snap({ action: "drafts" });
      must(list.status === 200 && Array.isArray(list.json?.drafts), `drafts HTTP ${list.status} ${list.text.slice(0, 300)}`);
      const byId = new Map(list.json.drafts.map((d) => [d.id, d]));
      must(byId.size === 2 && byId.has(textId) && byId.has(fileId), `drafts lists ${byId.size}, expected both`);
      // Newest first (PROTOCOL.md): the file was proposed second.
      must(list.json.drafts[0].id === fileId, "drafts are not newest first");
      const t = byId.get(textId), f = byId.get(fileId);
      must(t.kind === "text" && t.body === "e2e probe text draft" && t.status === "proposed" && t.client_name === "Smooth e2e", "text draft fields");
      must(!("file_url" in t) || t.file_url == null, "a text draft carries a file_url");
      must(f.kind === "file" && f.file_bytes === bytes.length && f.file_name === "probe.pdf" && typeof f.file_url === "string", "file draft fields");
      const dl = await fetchImpl(f.file_url);
      must(dl.status === 200, `signed URL HTTP ${dl.status}`);
      must(Buffer.from(await dl.arrayBuffer()).equals(bytes), "downloaded file differs from what was proposed");

      const status0 = await callTool(12, "draft_status", { id: fileId });
      must(status0.includes(": proposed"), `draft_status says ${status0}`);
      const seen = await snap({ action: "draft", id: fileId, status: "seen" });
      must(seen.status === 200 && seen.json?.status === "seen", `seen HTTP ${seen.status} ${seen.text.slice(0, 200)}`);
      const declined = await snap({ action: "draft", id: textId, status: "declined" });
      must(declined.status === 200 && declined.json?.status === "declined", `declined HTTP ${declined.status} ${declined.text.slice(0, 200)}`);
      const noId = await snap({ action: "draft", id: fileId, status: "submitted" });
      must(noId.status === 400, `submitted without canvas_submission_id: HTTP ${noId.status}`);
      const submitted = await snap({ action: "draft", id: fileId, status: "submitted", canvas_submission_id: "e2e-0000", attempt: 1 });
      must(submitted.status === 200 && submitted.json?.status === "submitted", `submitted HTTP ${submitted.status} ${submitted.text.slice(0, 200)}`);
      const again = await snap({ action: "draft", id: fileId, status: "declined" });
      must(again.status === 409, `second move out of submitted: HTTP ${again.status} ${again.text.slice(0, 200)}`);
      const status1 = await callTool(13, "draft_status", { id: fileId });
      must(status1.includes(": submitted"), `draft_status after submit says ${status1}`);
      // The finished draft's object is deleted from Storage at this move, but
      // the signed URL handed out above keeps serving the file until it
      // expires (120 s): measured 2026-11-10, a URL fetched 20 s after the
      // object left `storage.objects` still answered 200, and 400 at 135 s.
      // So the probe cannot see the deletion from outside within its run,
      // and does not pretend to; `select name from storage.objects where
      // bucket_id = 'agent-drafts'` with the Management API is the check.
      const after = await snap({ action: "drafts" });
      must(after.status === 200 && after.json.drafts.length === 0, `drafts after both moves: ${after.json?.drafts?.length}`);
      s.draftIds = [textId, fileId];
      // One draft left open, with a file, for the opt-out step to remove.
      const openMade = await callTool(14, "propose_submission", {
        assignment_id: TEST_ASSIGNMENT_ID, kind: "file", file_base64: testFileBytes(1024).toString("base64"),
        file_name: "left-open.pdf", mime_type: "application/pdf",
      });
      s.openDraftId = draftIdFrom(openMade);
      must(s.openDraftId, `no draft id in: ${openMade.slice(0, 200)}`);
      return "2 drafts, file bytes equal, 400 without canvas_submission_id, 409 on a second move; 1 left open";
    });

    await step(STEPS[8], async () => {
      const list = await phone({ action: "list" });
      must(list.status === 200, `list HTTP ${list.status} ${list.text.slice(0, 200)}`);
      const live = list.json.connections;
      must(Array.isArray(live) && live.length === 1, `expected 1 live connection, got ${live?.length}`);
      const rv = await phone({ action: "revoke", id: live[0].id });
      must(rv.status === 200 && rv.json?.revoked === true, `revoke HTTP ${rv.status} ${rv.text.slice(0, 200)}`);
      const after = await mcp(s.access, { jsonrpc: "2.0", id: 4, method: "tools/list", params: {} });
      must(after.res.status === 401, `mcp after revoke: HTTP ${after.res.status}`);
      must(JSON.parse(after.text).error === "invalid_token", `mcp after revoke body: ${after.text.slice(0, 200)}`);
    });
    await step(STEPS[12], async () => {
      // The open draft (and its file) outlived the revoke in STEPS[8]:
      // revoking a connection does not decide the student's drafts.
      const before = await snap({ action: "drafts" });
      const open = (before.json?.drafts ?? []).find((d) => d.id === s.openDraftId);
      must(open && typeof open.file_url === "string", "the open draft is not listed before the opt-out");
      must(open.status === "proposed", `the open draft is ${open.status} after the revoke`);
      const del = await snap({ action: "delete" });
      must(del.status === 200 && del.json?.deleted === true, `delete HTTP ${del.status} ${del.text.slice(0, 200)}`);
      const st = await snap({ action: "status" });
      must(st.status === 200 && st.json?.hasSnapshot === false, `status after delete: ${st.text.slice(0, 200)}`);
      const left = await snap({ action: "drafts" });
      must(left.status === 200 && left.json.drafts.length === 0, "drafts remain after delete");
      // A terminal draft is not listed by `drafts`; it must be gone, not hidden.
      for (const id of [...s.draftIds, s.openDraftId]) {
        const moved = await snap({ action: "draft", id, status: "declined" });
        must(moved.status === 404, `a deleted draft answers HTTP ${moved.status}, expected 404`);
      }
      return `revoked ${del.json.revoked}`;
    });
  } catch {
    // already reported by step()
  } finally {
    if (user) {
      try {
        const res = await fetchImpl(`${SUPABASE_URL}/functions/v1/delete-account`, {
          method: "POST",
          headers: { Authorization: `Bearer ${user.jwt}`, apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
          body: "{}",
        });
        if (res.status === 200) log(`ok: ${STEPS[9]}`);
        else { failed = true; log(`FAIL: ${STEPS[9]}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}; delete the anonymous user by hand`); }
      } catch (err) {
        failed = true;
        log(`FAIL: ${STEPS[9]}: ${err instanceof Error ? err.message : err}; delete the anonymous user by hand`);
      }
    }
  }
  return failed ? 1 : 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  run(process.argv.slice(2)).then((code) => process.exit(code), (err) => { console.error(err.message); process.exit(1); });
}
