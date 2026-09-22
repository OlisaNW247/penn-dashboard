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
// No Authorization header is set here: this environment's outbound proxy
// injects the Supabase management token for api.supabase.com.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..", ".."); // backend/scripts -> repo root
const FUNCTIONS_ROOT = path.join(REPO_ROOT, "backend", "supabase", "functions");
const PROJECT_REF = process.env.LHF_SUPABASE_PROJECT_REF ?? "ynetfjixexksxqrrkwsg";

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

async function main() {
  const { slug, from, also: alsoSlugs } = parseArgs(process.argv.slice(2));

  // If `functions/<slug>/index.ts` already exists, that directory is the
  // source regardless of `--from` -- `--from` exists only to stand in for a
  // slug that has no directory of its own yet.
  const ownDir = path.join(FUNCTIONS_ROOT, slug);
  const ownEntrypoint = path.join(ownDir, "index.ts");
  const sourceSlug = fs.existsSync(ownEntrypoint) ? slug : (from ?? slug);
  const sourceDir = path.join(FUNCTIONS_ROOT, sourceSlug);

  if (!fs.existsSync(path.join(sourceDir, "index.ts"))) {
    usageAndExit(
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

  console.log(
    `Deploying slug "${slug}" from source "${sourceSlug}" (${files.length} files) to project ${PROJECT_REF}...`,
  );

  const metadata = {
    entrypoint_path: `functions/${slug}/index.ts`,
    name: slug,
    verify_jwt: true,
  };

  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }));
  for (const file of files) {
    const bytes = fs.readFileSync(file.abs);
    form.append("file", new Blob([bytes]), file.rel);
  }

  const url = `https://api.supabase.com/v1/projects/${PROJECT_REF}/functions/deploy?slug=${encodeURIComponent(slug)}`;
  const res = await fetch(url, { method: "POST", body: form });
  const bodyText = await res.text();

  if (!res.ok) {
    console.error(`Deploy failed: HTTP ${res.status}`);
    console.error(bodyText);
    process.exit(1);
  }

  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    parsed = undefined;
  }

  if (parsed) {
    console.log(
      `Deployed "${slug}": version ${parsed.version}, status ${parsed.status}, id ${parsed.id}`,
    );
    console.log(JSON.stringify(parsed, null, 2));
  } else {
    console.log(bodyText);
  }
}

main().catch((err) => {
  console.error("Deploy script failed:", err instanceof Error ? err.stack ?? err.message : err);
  process.exit(1);
});
