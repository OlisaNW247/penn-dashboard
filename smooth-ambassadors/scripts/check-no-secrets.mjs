#!/usr/bin/env node
// Refuses to commit files that look like they carry people's contact details,
// tokens or secrets. Runs as a pre-commit hook (scripts/install-hooks.sh) and
// in CI. Usage: node scripts/check-no-secrets.mjs [files...]  (default: staged)
import { execSync } from "node:child_process";
import { readFileSync, existsSync, statSync } from "node:fs";

const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : execSync("git diff --cached --name-only --diff-filter=ACMR", { encoding: "utf8" })
      .split("\n")
      .filter(Boolean);

const FORBIDDEN_PATHS = [
  /(^|\/)\.dev\.vars$/,
  /(^|\/)\.env(\..*)?$/,
  /(^|\/)(roster|contacts)[^/]*$/i,
  /\.(csv|sqlite3?|db)$/i,
  /(^|\/)backups\/.+\.sql$/,
  /(^|\/)wrangler\.toml\.bak$/,
];

const PATTERNS = [
  // US phone numbers, except the public founder line in docs/templates.
  { re: /(\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b/g, name: "phone number", allow: (m) => { const d = m.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, ""); return d === "2023203802" || d.startsWith("555") || d === "0123456789"; } },
  { re: /\b[\w.+-]+@(?!example\.|anthropic\.com)[\w-]+\.[\w.-]+\b/g, name: "email address", allow: (m) => /noreply@|@users\.noreply/.test(m) },
  { re: /\bFOUNDER_TOKEN\s*=\s*["']?[A-Za-z0-9_\-]{12,}/g, name: "founder token value", allow: (m) => /change-me/.test(m) },
  { re: /\bAPPLE_PROVIDER_TOKEN\s*=\s*["']?\d{3,}/g, name: "apple provider token value" },
  { re: /\b(sk|pk|ghp|gho|xox[abp])_[A-Za-z0-9]{16,}\b/g, name: "api key" },
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g, name: "private key" },
  { re: /\bCLOUDFLARE_API_TOKEN\s*=\s*["']?[A-Za-z0-9_\-]{20,}/g, name: "cloudflare api token" },
];

let bad = 0;
for (const f of files) {
  if (!existsSync(f) || statSync(f).isDirectory()) continue;
  if (f.startsWith("node_modules/")) continue;
  if (FORBIDDEN_PATHS.some((re) => re.test(f))) {
    console.error(`✗ ${f}: this kind of file never goes in git`);
    bad++;
    continue;
  }
  if (f === "scripts/check-no-secrets.mjs") continue;
  let text;
  try {
    text = readFileSync(f, "utf8");
  } catch {
    continue;
  }
  if (text.includes("\u0000")) continue; // binary
  for (const p of PATTERNS) {
    for (const m of text.match(p.re) || []) {
      if (p.allow && p.allow(m)) continue;
      console.error(`✗ ${f}: looks like a ${p.name}: ${m}`);
      bad++;
    }
  }
}
if (bad) {
  console.error(`\n${bad} problem(s). ambassador contacts live in D1, secrets in wrangler secrets / .dev.vars. commit refused.`);
  process.exit(1);
}
console.log(`✓ ${files.length} file(s) clean`);
