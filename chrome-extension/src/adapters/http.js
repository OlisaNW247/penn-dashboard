// One fetch, as the service worker makes it: the browser attaches the
// student's own session (credentials: "include"); the extension never reads a
// cookie. A sign-in redirect or a 401 comes back as `signedOut`.

const LOGIN_HOSTS = new Set(["weblogin.pennkey.upenn.edu", "idp.pennkey.upenn.edu"]);

// Returns { ok, signedOut, status, text }. Never throws for HTTP outcomes; a
// network failure rejects (the caller turns it into a status word). The url
// is never logged or stored by this module.
export async function fetchText(url, { fetchFn = fetch, accept } = {}) {
  const res = await fetchFn(url, {
    credentials: "include",
    redirect: "follow",
    headers: accept ? { Accept: accept } : undefined,
  });
  let host = "";
  try { host = new URL(res.url).host; } catch { /* keep "" */ }
  const signedOut = res.status === 401 || LOGIN_HOSTS.has(host);
  if (signedOut) return { ok: false, signedOut: true, status: res.status, text: "" };
  return { ok: res.ok, signedOut: false, status: res.status, text: res.ok ? await res.text() : "" };
}
