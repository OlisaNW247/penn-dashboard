// Founders' contact lines for the bottom of the page. They live in a
// deploy-time variable (never in git): FOUNDER_CONTACTS, a JSON array of
// {name, phone}. Anything malformed is dropped; at most four survive.
export function parseContacts(env) {
  let raw;
  try { raw = JSON.parse(env.FOUNDER_CONTACTS || ""); } catch { return []; }
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const e of raw) {
    const name = e && typeof e.name === "string" ? e.name.trim() : "";
    const phone = e && typeof e.phone === "string" ? e.phone.trim() : "";
    if (name && phone) out.push({ name, phone });
    if (out.length === 4) break;
  }
  return out;
}
