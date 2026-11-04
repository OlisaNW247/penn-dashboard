#!/usr/bin/env node
// Deploys one Edge Function from this repo's `backend/supabase/functions/`
// straight to the live Supabase project via the Management API, bypassing
// the Supabase CLI (which isn't installed here). This is a scripting tool
// for ad-hoc/canary deploys during development, not a release mechanism --
// the real deploy story, if this project settles on one, belongs in CI.
//
// Usage:
//   node backend/scripts/deploy-function.mjs <slug> [--from <source-slug>]
//
// `<slug>` is the function slug on the server. Normally the source
// directory is `backend/supabase/functions/<slug>/`. `--from <source-slug>`
// deploys a *different* directory's source under `<slug>` instead -- this
// is how a canary (`ask-canary`) gets deployed from an existing function's
// source (`ask`) before a dedicated `functions/ask-canary/index.ts` exists.
// Once that directory exists, plain `node deploy-function.mjs ask-canary`
// (no `--from`) deploys it directly, same as any other slug.
//
// Every deploy also carries `backend/supabase/functions/_shared/`, since
// every function in this repo imports from it by a fixed relative path
// (`../_shared/...`) and the Management API has no separate "shared files"
// concept -- each deploy is a self-contained bundle.
//
// ## The multipart shape (reverse-engineered against the live API)
//
// `POST /v1/projects/{ref}/functions/deploy?slug={slug}` wants
// `multipart/form-data` with:
//   - one `metadata` part: JSON, `{ entrypoint_path, name, verify_jwt }`.
//     `entrypoint_path` is relative to the bundle root this call uploads,
//     NOT to `backend/supabase/` -- i.e. `functions/<slug>/index.ts`, not
//     `supabase/functions/<slug>/index.ts`. (A first attempt tried the
//     `supabase/`-prefixed form the brief for this script guessed at,
//     modelled on `entrypoint_path` as it appears in a function's *listing*
//     response, e.g. ".../source/supabase/functions/ask/index.ts" for
//     functions deployed some other way (CLI/CI). That listing path is a
//     historical artifact of how those functions were originally uploaded,
//     not the contract this endpoint enforces on new deploys: this script's
///    own deploys land as ".../source/functions/<slug>/index.ts" -- no
//     `supabase/` segment -- and still resolve and run, so the endpoint's
//     actual root is the directory whose relative paths are the `file`
//     parts' own filenames.)
//   - one `file` part per source file, each with its `filename` set to the
//     path relative to that same bundle root, e.g. `functions/ask/index.ts`,
//     `functions/_shared/quota.ts`.
// A bare `POST` with no body returns 400 "Invalid multipart boundary" (not
// 404), confirming the endpoint exists and is multipart-only -- there is no
// JSON body form to fall back to.
//
// ## Authorization
//
// `resolveManagementToken()` reads the Management API token from
// `SUPABASE_ACCESS_TOKEN`, or else from the file named by
// `LHF_SUPABASE_TOKEN_FILE` (default `~/lhf-bench/supabase.token`, trimmed;
// mode 600 expected, a looser mode is warned about, never fatal). When found
// it is sent as `Authorization: Bearer`. When neither exists NO header is set:
// that is the old cloud environment, whose outbound proxy injected the token
// for api.supabase.com. The log line says which case ran; the token itself
// is never printed. Create one at supabase.com/dashboard/account/tokens.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..", ".."); // backend/scripts -> repo root
const FUNCTIONS_ROOT = path.join(REPO_ROOT, "backend", "supabase", "functions");
export const PROJECT_REF = process.env.LHF_SUPABASE_PROJECT_REF ?? "ynetfjixexksxqrrkwsg";


/** Returns `{ token, source }` where source is "env", "file" or "none". The
 *  token is trimmed; an empty value counts as absent. Never logs the token. */
export function resolveManagementToken(env = process.env) {
  const fromEnv = (env.SUPABASE_ACCESS_TOKEN ?? "").trim();
  if (fromEnv) return { token: fromEnv, source: "env" };
  const file = env.LHF_SUPABASE_TOKEN_FILE ?? path.join(os.homedir(), "lhf-bench", "supabase.token");
  try {
    const mode = fs.statSync(file).mode & 0o777;
    if (mode & 0o077) {
      console.warn(`warning: ${file} has mode ${mode.toString(8)}; run chmod 600 on it`);
    }
    const fromFile = fs.readFileSync(file, "utf8").trim();
    if (fromFile) return { token: fromFile, source: "file" };
  } catch {
    // no file: fall through to the proxy case
  }
  return { token: undefined, source: "none" };
}

/** Headers for a Management API call; `Authorization` only when a token exists. */
export function managementHeaders(token, extra = {}) {
  return token ? { Authorization: `Bearer ${token}`, ...extra } : { ...extra };
}

export function describeTokenSource(source) {
  return source === "env"
    ? "auth: Bearer token from SUPABASE_ACCESS_TOKEN"
    : source === "file"
    ? "auth: Bearer token from the token file"
    : "auth: no token found, sending no Authorization header (assuming a proxy injects it)";
}

function usageAndExit(message) {
  if (message) console.error(message);
  console.error("Usage: node backend/scripts/deploy-function.mjs <slug> [--from <source-slug>] [--also <slug>]...");
  process.exit(1);
}

function parseArgs(argv) {
  const positional = [];
  let from;
  const also = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--from") {
      from = argv[++i];
      if (!from) usageAndExit("--from requires a value");
    } else if (arg === "--also") {
      const extra = argv[++i];
      if (!extra) usageAndExit("--also requires a value");
      also.push(extra);
    } else if (arg.startsWith("--")) {
      usageAndExit(`unknown flag: ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  if (positional.length !== 1) usageAndExit("expected exactly one <slug> argument");
  return { slug: positional[0], from, also };
}

/** Recursively lists every file under `dir`, returning `{ abs, rel }` pairs
 *  where `rel` is `dir`'s own path joined onto `relPrefix` -- e.g. walking
 *  `.../functions/ask` with `relPrefix = "functions/ask-canary"` yields
 *  `functions/ask-canary/index.ts`, which is how `--from` re-parents a
 *  source directory's files under the target slug's name without touching
 *  disk. */
function collectFiles(dir, relPrefix) {
  const out = [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    throw new Error(`cannot read ${dir}: ${err.message}`);
  }
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    const rel = `${relPrefix}/${entry.name}`;
    if (entry.isDirectory()) {
      out.push(...collectFiles(abs, rel));
    } else if (entry.isFile()) {
      out.push({ abs, rel });
    }
  }
  return out;
}

/** Deploys one function bundle. Returns the parsed response (or `{ raw }`).
 *  Throws on any failure (the CLI wrapper turns that into exit 1). With
 *  `dryRun` it builds the bundle and returns the plan without sending.
 *  opts: { from, also = [], dryRun = false, fetchImpl = fetch, log = console.log, env = process.env } */
export async function deployFunction(slug, opts = {}) {
  const { from, also: alsoSlugs = [], dryRun = false, fetchImpl = fetch, log = console.log, env = process.env } = opts;

  // If `functions/<slug>/index.ts` already exists, that directory is the
  // source regardless of `--from` -- `--from` exists only to stand in for a
  // slug that has no directory of its own yet.
  const ownDir = path.join(FUNCTIONS_ROOT, slug);
  const ownEntrypoint = path.join(ownDir, "index.ts");
  const sourceSlug = fs.existsSync(ownEntrypoint) ? slug : (from ?? slug);
  const sourceDir = path.join(FUNCTIONS_ROOT, sourceSlug);

  if (!fs.existsSync(path.join(sourceDir, "index.ts"))) {
    throw new Error(
      `no index.ts found for source "${sourceSlug}" (looked in ${sourceDir}); ` +
        `pass --from <source-slug> if "${slug}" has no directory of its own yet`,
    );
  }

  const sharedDir = path.join(FUNCTIONS_ROOT, "_shared");

  // `--also <slug>` (repeatable) ships another function's directory in the
  // same bundle, at its own path. `ask-canary/index.ts` imports
  // `../ask/index.ts`, so without `--also ask` the canary bundle has a
  // dangling import and the deploy fails at bundle time.
  const alsoDirs = alsoSlugs.map((s) => [path.join(FUNCTIONS_ROOT, s), `functions/${s}`]);
  const files = [
    ...collectFiles(sourceDir, `functions/${slug}`),
    ...alsoDirs.flatMap(([dir, rel]) => (fs.existsSync(dir) ? collectFiles(dir, rel) : [])),
    ...(fs.existsSync(sharedDir) ? collectFiles(sharedDir, "functions/_shared") : []),
  ];

  log(`Deploying slug "${slug}" from source "${sourceSlug}" (${files.length} files) to project ${PROJECT_REF}...`);

  const metadata = {
    entrypoint_path: `functions/${slug}/index.ts`,
    name: slug,
    verify_jwt: true,
  };

  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }));
  let bytesTotal = 0;
  for (const file of files) {
    const bytes = fs.readFileSync(file.abs);
    bytesTotal += bytes.length;
    form.append("file", new Blob([bytes]), file.rel);
  }

  const url = `https://api.supabase.com/v1/projects/${PROJECT_REF}/functions/deploy?slug=${encodeURIComponent(slug)}`;
  const { token, source } = resolveManagementToken(env);
  log(describeTokenSource(source));

  if (dryRun) {
    log(`[dry-run] POST ${url} (multipart, ${files.length} files, ${bytesTotal} bytes)`);
    return { dryRun: true, url, files: files.map((f) => f.rel), bytes: bytesTotal };
  }

  const res = await fetchImpl(url, { method: "POST", headers: managementHeaders(token), body: form });
  const bodyText = await res.text();

  if (!res.ok) {
    throw new Error(`Deploy of "${slug}" failed: HTTP ${res.status} ${bodyText}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    parsed = undefined;
  }

  if (parsed) {
    log(`Deployed "${slug}": version ${parsed.version}, status ${parsed.status}, id ${parsed.id}`);
    return parsed;
  }
  log(bodyText);
  return { raw: bodyText };
}

async function main() {
  const { slug, from, also } = parseArgs(process.argv.slice(2));
  const result = await deployFunction(slug, { from, also });
  console.log(JSON.stringify(result, null, 2));
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === __filename;
if (invokedDirectly) {
  main().catch((err) => {
    console.error("Deploy script failed:", err instanceof Error ? err.message : err);
    process.exit(1);
  });
}
