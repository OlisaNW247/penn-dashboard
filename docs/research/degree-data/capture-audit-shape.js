// Capture 1.1 of OPEN-QUESTIONS.md: what does Path@Penn's answer for YOUR
// audit carry that Smooth does not read yet (Penn's block codes, rule ids,
// sharing markers)? Paste this whole file into the browser console on
// https://courses.upenn.edu/ while signed in. It asks the page for your
// audit the way the page itself does, and prints (and copies to the
// clipboard) an inventory of FIELD NAMES only:
//
//   node[type=course].courseCode   x212   string   (values hidden)
//   blocks[].id                    x9     string   e.g. RA002291, RA001672
//
// What it never prints: your name, ids, the token, any course code, title,
// grade, number, sentence or HTML. A value is shown as an example only when
// it is a short ALL-CAPS code with no spaces (a block id, a rule tag), is
// not a course code, is not purely numeric, and contains none of the
// strings in your own record. Everything else is reduced to its type and
// length. For long text it reports only WHICH of a fixed list of Degree
// Works words occur in it (NONEXCLUSIVE, ShareWith, Rule_id, ...).
//
// Nothing is sent anywhere: the output is text in your console. Read it
// before you paste it into a chat.
(async () => {
  const WATCH = ["NONEXCLUSIVE", "ShareWith", "SHARE", "Rule_id", "RuleId", "ruleId", "Req_id", "Req_value",
    "reqValue", "LabelTag", "labelTag", "Qualifier", "qualifier", "MAXCLASS", "MAXCREDIT", "MINRES", "MAXPASSFAIL",
    "Exception", "exception", "applied", "Applied", "insufficient", "Insufficient", "over the limit", "OTL",
    "fallthrough", "Fallthrough", "FALLTHROUGH", "with attribute", "ATTRIBUTE", "DWTERM", "Per_complete", "Cat_yr"];
  if (typeof sam === "undefined" || typeof foseDgwClient === "undefined") {
    console.log("Not ready: open Path@Penn, sign in, open Degree Audit once, then paste again."); return;
  }
  if (!sam.user.getProperty("pers")) { await sam.user.fetch(); }
  const pers = sam.user.getProperty("pers") || {};

  // Every string in your record is a secret for this print, except the
  // curriculum entries (`cur`: program, degree and college codes), which
  // are what the audit is about and are no more than you have already said.
  const secrets = new Set();
  (function gather(v, depth) {
    if (depth > 6 || v == null) return;
    if (typeof v === "string") { if (v.length >= 2) secrets.add(v.toLowerCase()); return; }
    if (typeof v === "number") { secrets.add(String(v)); return; }
    if (Array.isArray(v)) { v.slice(0, 400).forEach((x) => gather(x, depth + 1)); return; }
    if (typeof v === "object") { for (const k in v) if (k !== "cur") gather(v[k], depth + 1); }
  })({ token: sam.auth && sam.auth.token, pers: pers }, 0);

  const COURSE = /^[A-Z]{2,5}\s?\d{3,4}[A-Z]?$/;
  const CODE = /^[A-Z][A-Z0-9_\-:.]{2,23}$/;
  const safeSample = (s) => typeof s === "string" && CODE.test(s) && !COURSE.test(s) && !/^\d+$/.test(s) &&
    !secrets.has(s.toLowerCase());
  const keyName = (k) => COURSE.test(k) ? "{course}" : /^\d+$/.test(k) ? "{n}" : /\d{4,}/.test(k) ? "{id}" : k.length > 40 ? "{long}" : k;

  // Which degrees to ask for: the entries of your latest term that have not
  // ended, the same rule the app uses.
  const degrees = [];
  let bestTerm = "", best = [];
  for (const holder of (Array.isArray(pers.cur) ? pers.cur : [])) {
    for (const term in (holder || {})) {
      if (Array.isArray(holder[term]) && holder[term].length && String(term) > bestTerm) { bestTerm = String(term); best = holder[term]; }
    }
  }
  for (const e of best) {
    if (!e || typeof e !== "object" || !e.major) continue;
    if (e.end_term && e.end_term <= bestTerm) continue;
    const d = {}; for (const k in e) if (typeof e[k] === "string") d[k] = e[k];
    if (!degrees.some((x) => x.program === d.program && x.major === d.major)) degrees.push(d);
  }

  const lines = [];
  const inventory = (root, label) => {
    const seen = new Map();
    const note = (path, v) => {
      let e = seen.get(path);
      if (!e) { e = { n: 0, types: new Set(), samples: new Set(), watch: new Set(), maxLen: 0 }; seen.set(path, e); }
      e.n++;
      const t = v === null ? "null" : Array.isArray(v) ? "array" : typeof v;
      e.types.add(t);
      if (t === "string") {
        e.maxLen = Math.max(e.maxLen, v.length);
        if (safeSample(v) && e.samples.size < 6) e.samples.add(v);
        for (const w of WATCH) if (v.includes(w)) e.watch.add(w);
        if (/<[a-z][^>]*>/i.test(v)) {
          for (const m of v.matchAll(/\s(data-[a-z0-9-]+)=/gi)) e.watch.add("attr:" + m[1].toLowerCase());
        }
      }
      if (t === "array") e.maxLen = Math.max(e.maxLen, v.length);
    };
    const walk = (v, path, depth) => {
      if (depth > 14) return;
      note(path, v);
      if (Array.isArray(v)) { v.forEach((x) => walk(x, path + "[]", depth + 1)); return; }
      if (v && typeof v === "object") {
        // A requirement node: name it by its type and forget how deep it sits.
        let base = path;
        if (typeof v.type === "string" && /members\[\]$/.test(path)) base = "node[type=" + (safeSample(v.type.toUpperCase()) || /^[a-z]{2,12}$/.test(v.type) ? v.type : "?") + "]";
        for (const k in v) walk(v[k], base + "." + keyName(k), depth + 1);
      }
    };
    walk(root, label, 0);
    for (const [path, e] of [...seen].sort((a, b) => a[0] < b[0] ? -1 : 1)) {
      let line = path + "  x" + e.n + "  " + [...e.types].join("|");
      if (e.maxLen) line += "  maxlen " + e.maxLen;
      if (e.samples.size) line += "  e.g. " + [...e.samples].join(", ");
      if (e.watch.size) line += "  CONTAINS " + [...e.watch].join(", ");
      lines.push(line);
    }
  };

  lines.push("smooth audit-shape capture v1; degrees asked: " + degrees.length + "; latest term digits: " + bestTerm.length);
  for (let i = 0; i < degrees.length; i++) {
    for (const explain of [false, true]) {
      lines.push("");
      lines.push("=== degree " + (i + 1) + " explain=" + explain + " (degc " + (CODE.test(degrees[i].degc || "") ? degrees[i].degc : "?") + ")");
      try {
        const result = await foseDgwClient.fetchStudentAudit({ method: "whatif", degree: degrees[i], explain: explain });
        inventory(result, "audit");
        const types = (result.blocks || []).map((b) => (typeof b.type === "string" && safeSample(b.type) ? b.type : "?") + ":" + (safeSample(b.id) ? b.id : "(id hidden)"));
        lines.push("blocks in order: " + types.join("  "));
      } catch (err) {
        lines.push("failed: " + String((err && err.message) || err).slice(0, 80).replace(/[^a-zA-Z :]/g, "?"));
      }
    }
  }
  const text = lines.join("\n");
  console.log(text);
  try { copy(text); console.log("\n(copied to the clipboard; read it, then paste it into the chat)"); } catch (e) { /* copy() exists only in the console */ }
})();
