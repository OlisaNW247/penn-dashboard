// Bundles connector-front/vercel-entry.ts (as deploy.sh does) with esbuild and exercises it under Node against a stub
// upstream. Usage: node backend/connector-front/bundle-check.mjs [scratchDir]
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const dir = process.argv[2] ?? mkdtempSync(join(tmpdir(), "front-"));
const out = join(dir, "front.mjs");
execFileSync("npx", ["--yes", "esbuild@0.24.0", join(here, "vercel-entry.ts"), "--bundle", "--format=esm", "--platform=browser", "--define:import.meta.main=false", `--outfile=${out}`], { stdio: "inherit" });

const seen = [];
const stub = createServer((req, res) => {
  seen.push(`${req.method} ${req.url}`);
  if (req.url === "/functions/v1/mcp" && req.method === "POST") {
    res.writeHead(401, { "WWW-Authenticate": 'Bearer resource_metadata="x"' }).end("{}");
  } else res.writeHead(200, { "content-type": "application/json" }).end('{"ok":true}');
});
await new Promise((r) => stub.listen(0, "127.0.0.1", r));
const port = stub.address().port;
process.env.UPSTREAM_BASE = `http://127.0.0.1:${port}/functions/v1`;
process.env.PUBLIC_BASE = "https://front.example/functions/v1";
const front = (await import(pathToFileURL(out).href)).default;
const call = (path, init) => front(new Request("https://front.example" + path, init));

let r = await call("/.well-known/oauth-protected-resource/functions/v1/mcp");
assert.equal(r.status, 200);
assert.equal((await r.json()).resource, "https://front.example/functions/v1/mcp");
r = await call("/.well-known/oauth-authorization-server/functions/v1/agent-auth");
assert.equal(r.status, 200);
assert.equal((await r.json()).issuer, "https://front.example/functions/v1/agent-auth");
r = await call("/functions/v1/mcp", { method: "POST", body: "{}" });
assert.equal(r.status, 401);
assert.ok(r.headers.get("www-authenticate"));
r = await call("/register", { method: "POST", body: "{}" });
assert.equal(r.status, 200);
assert.ok(seen.includes("POST /functions/v1/agent-auth/register"), seen.join(", "));
console.log("bundle-check ok; upstream saw:", seen.join(" | "));
stub.close();
