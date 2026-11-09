// Vercel Edge Function entry for the connector front. deploy.sh bundles it with
// esbuild into connector-front/dist/front.mjs, imported by api/connector-front.js (Vercel's
// own bundler refuses the explicit .ts import extensions Deno requires, seen on the first
// deploy, and reads `export const config` only as a literal); vercel.json rewrites
// every path here, so the root discovery paths Claude Code needs are answered
// by connector-front/main.ts's `handle`, exactly as under Deno.
import { envFromDeno, handle } from "./main.ts";

declare const process: { env: Record<string, string | undefined> };


export default async function (req: Request): Promise<Response> {
  const res = await handle(req, envFromDeno((k) => process.env[k]));
  console.log(`${req.method} ${new URL(req.url).pathname} ${res.status}`);
  return res;
}
