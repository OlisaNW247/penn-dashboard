// Loads Penn's published program packs (pack.ts) for the planner.
//
// Packs are static JSON built from Penn's public requirement templates:
// `<base>/programs.json` and `<base>/packs/<CODE>.json`. The ref in
// PENN_DATA_REF is PINNED (a commit hash in production, not a moving branch)
// so that newly published packs reach students only when a person moves the
// pin after looking at what changed; a branch name would let a bad publish
// change every student's plan the moment it lands.
//
// Nothing here may hurt a plan: loadPacks never throws, never takes more than
// MAX_PACK_MS in total or runs past the engine's deadline, and on any failure
// (network, non-200, bad JSON, timeout, wrong shape) returns what it has with
// `error` set, and the engine proceeds with the hand policy.

import { findProgram } from "./packJoin.ts";
import type { PackBlock, ProgramIndexEntry, ProgramPack } from "./pack.ts";
import type { Degree } from "./types.ts";

export const PENN_DATA_REF = "94f31d7f8b991ce7fb2e91be3f588a8e00d5c0df";
export const PENN_DATA_BASE = "https://raw.githubusercontent.com/OlisaNW247/penn-dashboard/" + PENN_DATA_REF;

export const MAX_PACK_MS = 4_000;
const MAX_CACHE = 50;
const MAX_BYTES = 8_000_000;

const cache = new Map<string, unknown>();
export function clearPackCache(): void {
  cache.clear();
}
function cacheSet(url: string, v: unknown) {
  if (cache.size >= MAX_CACHE && !cache.has(url)) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(url, v);
}

export interface LoadPacksInput {
  baseUrl: string;
  degrees: Degree[];
  fetchImpl: typeof fetch;
  deadline?: number;
  signal?: AbortSignal;
  clock?: () => number;
}
export interface LoadedPacks {
  packs: Record<string, ProgramPack>;
  programs: Record<string, { code: string; exactMajor: boolean }>;
  error?: string;
}

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

function validIndex(v: unknown): v is { programs: ProgramIndexEntry[] } {
  return isObj(v) && Array.isArray(v.programs) &&
    v.programs.every((p) => isObj(p) && typeof p.code === "string" && isObj(p.goals));
}
function validPack(v: unknown): v is ProgramPack {
  if (!isObj(v) || typeof v.code !== "string" || !Array.isArray(v.blocks)) return false;
  return (v.blocks as unknown[]).every((b) =>
    isObj(b) && typeof b.reqId === "string" && typeof b.type === "string" && typeof b.code === "string" &&
    typeof b.title === "string" && Array.isArray(b.share) && Array.isArray(b.overlays) && Array.isArray(b.rules)
  ) && (v.blocks as PackBlock[]).length < 200;
}

export async function loadPacks(input: LoadPacksInput): Promise<LoadedPacks> {
  const out: LoadedPacks = { packs: {}, programs: {} };
  try {
    const clock = input.clock ?? Date.now;
    const end = Math.min(input.deadline ?? Infinity, clock() + MAX_PACK_MS);
    const base = input.baseUrl.replace(/\/+$/, "");
    const errors: string[] = [];

    const getJson = async (url: string, valid: (v: unknown) => boolean): Promise<unknown | null> => {
      if (cache.has(url)) return cache.get(url);
      const ms = end - clock();
      if (ms <= 0 || input.signal?.aborted) {
        errors.push("deadline");
        return null;
      }
      const ctl = new AbortController();
      const onAbort = () => ctl.abort();
      input.signal?.addEventListener("abort", onAbort, { once: true });
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const timeout = new Promise<null>((resolve) => {
          timer = setTimeout(() => {
            errors.push("timeout");
            ctl.abort();
            resolve(null);
          }, ms);
        });
        const work = (async () => {
          const res = await input.fetchImpl(url, { signal: ctl.signal });
          if (res.status !== 200) {
            errors.push(`http ${res.status}`);
            return null;
          }
          const text = await res.text();
          if (text.length > MAX_BYTES) {
            errors.push("too large");
            return null;
          }
          const json = JSON.parse(text);
          if (!valid(json)) {
            errors.push("bad shape");
            return null;
          }
          cacheSet(url, json);
          return json as unknown;
        })();
        const got = await Promise.race([work.catch(() => {
          errors.push("failed");
          return null;
        }), timeout]);
        return got;
      } catch {
        errors.push("failed");
        return null;
      } finally {
        if (timer) clearTimeout(timer);
        input.signal?.removeEventListener("abort", onAbort);
      }
    };

    const wanted = input.degrees.filter((d) => d.goals);
    if (wanted.length === 0) return out;
    const idx = await getJson(`${base}/programs.json`, validIndex) as { programs: ProgramIndexEntry[] } | null;
    if (!idx) {
      out.error = errors[0] ?? "no index";
      return out;
    }
    const picks = new Map<string, string>(); // degreeId -> code
    for (const d of wanted) {
      const p = findProgram(idx.programs, d.goals);
      if (p) {
        out.programs[d.id] = p;
        picks.set(d.id, p.code);
      }
    }
    const codes = [...new Set(picks.values())];
    const loaded = new Map<string, ProgramPack>();
    await Promise.all(codes.map(async (code) => {
      const pack = await getJson(`${base}/packs/${encodeURIComponent(code)}.json`, validPack) as ProgramPack | null;
      if (pack) loaded.set(code, pack);
    }));
    for (const [id, code] of picks) {
      const pack = loaded.get(code);
      if (pack) out.packs[id] = pack;
      else delete out.programs[id];
    }
    if (errors.length) out.error = errors[0];
  } catch {
    out.error = "failed";
  }
  return out;
}
