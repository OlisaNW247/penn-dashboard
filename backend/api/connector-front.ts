// Vercel Edge Function entry for the connector front. vercel.json rewrites
// every path here, so the root discovery paths Claude Code needs are answered
// by connector-front/main.ts's `handle`, exactly as under Deno.
import { envFromDeno, handle } from "../connector-front/main.ts";

declare const process: { env: Record<string, string | undefined> };

export const config = { runtime: "edge" };

export default async function (req: Request): Promise<Response> {
  const res = await handle(req, envFromDeno((k) => process.env[k]));
  console.log(`${req.method} ${new URL(req.url).pathname} ${res.status}`);
  return res;
}
