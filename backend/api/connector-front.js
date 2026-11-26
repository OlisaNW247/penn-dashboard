// The Vercel Edge Function. Kept as a literal, unbundled file because Vercel
// reads `export const config` statically: when esbuild rewrote it to
// `export { config }` on 2026-11-08, Vercel ran the file on Node as CommonJS
// and every request died on `import.meta`. deploy.sh bundles
// connector-front/vercel-entry.ts into connector-front/dist/front.mjs first.
export const config = { runtime: "edge" };
import handler from "../connector-front/dist/front.mjs";
export default handler;
