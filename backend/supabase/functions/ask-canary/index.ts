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
// This function still counts against the caller's quota and still writes
// `ask_outcomes` rows (tag them with the `x-lhf-probe` header to tell a
// harness run apart from a real question -- see `_shared/probe.ts`'s
// `readProbeTag`) -- it is not a free, unmetered side door, only an
// overridable one. Deploy it alongside `ask`, never in place of it.
import { handleAsk } from "../ask/index.ts";

Deno.serve((req) => handleAsk(req, { allowProbeOverrides: true }));
