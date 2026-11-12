// Packs an edited Sites repository for the hand-back to the session that deploys it.
//
//   node scripts/package-sites.mjs <original-extract-dir> <edited-dir> <zip-path>
//
// <original-extract-dir> is the archive as it was received (DEPLOYMENT_README.md,
// SOURCE_MANIFEST.json, repository/). <edited-dir> holds the edited repository/
// (after scripts/build-sites.mjs). The zip gets the same layout as the one that
// came in, so the receiving side finds everything where it left it:
//
//   DEPLOYMENT_README.md         as received
//   CHANGES_FOR_DEPLOYMENT.md    what changed and how to deploy it
//   SOURCE_MANIFEST.json         base commit, project id, new file hashes
//   WORKER_LOGIC_FOR_REVIEW.txt  worker/index.js without the embedded images
//   worker-index.diff            original against edited, images left out
//   repository/                  the edited repository, without dist/
//
// The image line is megabytes of base64 on one line. It is never printed, and the
// reading aid and the diff replace it with a placeholder, exactly as the received
// reading aid did.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const [original, edited, zipPath] = process.argv.slice(2).map((p) => p && resolve(p));
if (!original || !edited || !zipPath) {
  console.error("usage: node scripts/package-sites.mjs <original-extract-dir> <edited-dir> <zip-path>");
  process.exit(2);
}

const IMAGE_PREFIX = "const imageData = ";
const PLACEHOLDER = "const imageData = /* embedded image dictionary omitted from this reading aid */ {};";
const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");
const withoutImages = (text) =>
  text.split("\n").map((line) => (line.startsWith(IMAGE_PREFIX) ? PLACEHOLDER : line)).join("\n");
const imageLine = (text) => text.split("\n").find((line) => line.startsWith(IMAGE_PREFIX));

const originalWorker = readFileSync(join(original, "repository/worker/index.js"), "utf8");
const editedWorker = readFileSync(join(edited, "repository/worker/index.js"), "utf8");
if (sha256(imageLine(originalWorker)) !== sha256(imageLine(editedWorker))) {
  console.error("package-sites: the embedded image line differs from the original (nothing written)");
  process.exit(1);
}

const stage = mkdtempSync(join(tmpdir(), "smooth-sites-"));
try {
  cpSync(join(edited, "repository"), join(stage, "repository"), {
    recursive: true,
    filter: (src) => !/(^|\/)(dist|node_modules|\.git)(\/|$)/.test(relative(join(edited, "repository"), src)),
  });
  cpSync(join(original, "DEPLOYMENT_README.md"), join(stage, "DEPLOYMENT_README.md"));
  cpSync(join(root, "sites/CHANGES_FOR_DEPLOYMENT.md"), join(stage, "CHANGES_FOR_DEPLOYMENT.md"));
  writeFileSync(join(stage, "WORKER_LOGIC_FOR_REVIEW.txt"), withoutImages(editedWorker));

  // The diff, images left out. `diff` exits 1 when the files differ, which is the point.
  const a = join(stage, ".a.js");
  const b = join(stage, ".b.js");
  writeFileSync(a, withoutImages(originalWorker));
  writeFileSync(b, withoutImages(editedWorker));
  let diff = "";
  try {
    diff = execFileSync("diff", ["-u", "--label", "a/worker/index.js", "--label", "b/worker/index.js", a, b], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (err) {
    if (err.status !== 1) throw err;
    diff = err.stdout;
  }
  rmSync(a);
  rmSync(b);
  writeFileSync(join(stage, "worker-index.diff"), diff);

  const files = [];
  (function walk(dir) {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else files.push({ path: relative(join(stage, "repository"), path), sha256: sha256(readFileSync(path)) });
    }
  })(join(stage, "repository"));
  const received = JSON.parse(readFileSync(join(original, "SOURCE_MANIFEST.json"), "utf8"));
  const before = new Map(received.files.map((f) => [f.path, f.sha256]));
  writeFileSync(
    join(stage, "SOURCE_MANIFEST.json"),
    JSON.stringify(
      {
        base_commit: received.source_commit,
        project_id: received.project_id,
        note: "Edited from base_commit. `changed` is false where the file is byte-identical to the base.",
        files: files.map((f) => ({ ...f, changed: before.get(f.path) !== f.sha256 })),
      },
      null,
      2,
    ) + "\n",
  );

  if (existsSync(zipPath)) rmSync(zipPath);
  execFileSync("zip", ["-q", "-r", "-X", zipPath, "."], { cwd: stage });
  console.log(`package-sites: wrote ${zipPath}`);
  for (const f of files) console.log(`  ${f.path}${before.get(f.path) === f.sha256 ? "" : "  (changed)"}`);
} finally {
  rmSync(stage, { recursive: true, force: true });
}
