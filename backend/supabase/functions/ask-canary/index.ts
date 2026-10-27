// A harness-only twin of `ask` (`../ask/index.ts`), for trying a different
// model, token cap, reasoning shape, provider order or trimmed context
// against the exact same prompt-building and streaming code production
// `ask` runs. The only difference from production is
// `allowProbeOverrides: true`, which is what makes a `probe` field in the
// request body do anything at all (`_shared/probe.ts`'s
// `extractProbeOverrides`) -- everything else, including quota
// enforcement, enrollment checks, and `ask_outcomes` recording, runs
// unchanged, so a result from this function predicts what production
// `ask` would have done with the same overrides rather than exercising a
// parallel implementation that could quietly drift from it.
//
// Closed by default (hardening BE-A, 2026-10-27): it answers only a request
// carrying `x-lhf-probe-secret` equal to the `LHF_PROBE_SECRET` secret, and
// 404s everyone when that secret is unset; the overrides it honours are
// clamped to an allow-list (`_shared/probe.ts`'s `ProbePolicy`). Before
// that, any anonymous Supabase JWT could pick the model, token cap and
// provider on LHF's own OpenRouter key through this door.
//
// This function still counts against the caller's quota and still writes
// `ask_outcomes` rows (tag them with the `x-lhf-probe` header to tell a
// harness run apart from a real question -- see `_shared/probe.ts`'s
// `readProbeTag`) -- it is not a free, unmetered side door, only an
// overridable one. Deploy it alongside `ask`, never in place of it.
import { handleAsk } from "../ask/index.ts";
import { gateCanary } from "../_shared/probe.ts";

Deno.serve((req) =>
  gateCanary(req, Deno.env.get("LHF_PROBE_SECRET"), (gated) => handleAsk(gated, { allowProbeOverrides: true }))
);
