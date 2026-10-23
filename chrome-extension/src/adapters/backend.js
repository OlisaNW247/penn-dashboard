// Backend client (backend/PROTOCOL.md "Auth"). One interface for other
// modules: callFunction(name, body). Storage and fetch are injected so the
// logic runs in node. Never logs tokens, codes, keys or ciphertext.

export const SUPABASE_URL = "https://ynetfjixexksxqrrkwsg.supabase.co";
// Publishable key: public by design (it ships in the phone app too).
export const PUBLISHABLE_KEY = "sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt";
export const SESSION_KEY = "backendSessionV1";

export class BackendError extends Error {
  constructor(kind, status, code, message) {
    super(message || code || kind);
    this.name = "BackendError";
    this.kind = kind; // unauthorized | notPaired | pairingNotFound | conflict | tooLarge | quota | network | server
    this.status = status; // HTTP status, 0 for network
    this.code = code; // server's error code string, or null
  }
}

function kindFor(status, code) {
  if (status === 401) return "unauthorized";
  if (code === "not_paired") return "notPaired";
  if (code === "pairing_not_found") return "pairingNotFound";
  if (status === 409) return "conflict";
  if (status === 413) return "tooLarge";
  if (status === 429) return "quota";
  return "server";
}

async function readJSON(res) {
  try {
    const text = await res.text();
    return text ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

function errorCode(json) {
  if (json && typeof json.error === "string") return json.error;
  if (json && typeof json.error_code === "string") return json.error_code;
  if (json && typeof json.code === "string") return json.code;
  return null;
}

export function createBackend({ fetch: fetchFn, storage, now = () => Date.now(), url = SUPABASE_URL, apiKey = PUBLISHABLE_KEY } = {}) {
  let session = null;
  let loaded = false;
  let inflight = null; // single-flight session establishment (refresh tokens rotate)

  async function load() {
    if (loaded) return session;
    const got = (await storage.get(SESSION_KEY))[SESSION_KEY];
    session = got && got.accessToken && got.refreshToken ? got : null;
    loaded = true;
    return session;
  }

  async function save(s) {
    session = s;
    loaded = true;
    if (s) await storage.set({ [SESSION_KEY]: s });
    else await storage.remove(SESSION_KEY);
  }

  async function raw(path, init) {
    try {
      return await fetchFn(url + path, init);
    } catch {
      throw new BackendError("network", 0, null, "network error");
    }
  }

  function toSession(json) {
    if (!json || !json.access_token || !json.refresh_token) throw new BackendError("server", 0, "bad_session", "malformed session response");
    const expiresAt = typeof json.expires_at === "number" ? json.expires_at : Math.floor(now() / 1000) + (Number(json.expires_in) || 3600);
    return { accessToken: json.access_token, refreshToken: json.refresh_token, expiresAt, userId: json.user && json.user.id ? json.user.id : null };
  }

  async function authPost(path, body) {
    const res = await raw(path, {
      method: "POST",
      headers: { apikey: apiKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = await readJSON(res);
    if (!res.ok) throw new BackendError(kindFor(res.status, errorCode(json)), res.status, errorCode(json));
    return toSession(json);
  }

  const signUp = async () => save(await authPost("/auth/v1/signup", {}));

  async function refresh() {
    const cur = await load();
    if (!cur) return signUp();
    try {
      await save(await authPost("/auth/v1/token?grant_type=refresh_token", { refresh_token: cur.refreshToken }));
    } catch (e) {
      // A refresh the server rejects (revoked user, reused token) cannot be
      // retried; the caller sees unauthorized and decides (re-pair).
      if (e instanceof BackendError && (e.status === 400 || e.status === 401 || e.status === 403)) {
        throw new BackendError("unauthorized", e.status, e.code);
      }
      throw e;
    }
    return session;
  }

  function single(fn) {
    if (!inflight) inflight = fn().finally(() => { inflight = null; });
    return inflight;
  }

  // Signed in with a token good for at least 30 more seconds.
  async function ensureSession() {
    const cur = await load();
    if (!cur) return single(signUp);
    if (cur.expiresAt - 30 <= Math.floor(now() / 1000)) return single(refresh);
    return cur;
  }

  async function post(name, body) {
    const s = session;
    const res = await raw(`/functions/v1/${encodeURIComponent(name)}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${s.accessToken}`, apikey: apiKey, "Content-Type": "application/json" },
      body: JSON.stringify(body ?? {}),
    });
    return { res, json: await readJSON(res) };
  }

  async function callFunction(name, body) {
    await ensureSession();
    let { res, json } = await post(name, body);
    if (res.status === 401) {
      await single(refresh);
      ({ res, json } = await post(name, body));
    }
    if (!res.ok) throw new BackendError(kindFor(res.status, errorCode(json)), res.status, errorCode(json));
    return json;
  }

  return {
    callFunction,
    ensureSession,
    async userId() { return (await ensureSession()).userId; },
    async clearSession() { await save(null); },
  };
}

// Default wiring for the extension (service worker and popup).
let shared = null;
export function defaultBackend() {
  if (!shared) shared = createBackend({ fetch: (...a) => globalThis.fetch(...a), storage: globalThis.chrome.storage.local });
  return shared;
}
export const callFunction = (name, body) => defaultBackend().callFunction(name, body);
export default { callFunction, defaultBackend };
