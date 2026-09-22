#!/usr/bin/env node
// A probe harness for the `ask` SSE endpoint (backend/PROTOCOL.md's "ask"
// section is the contract this script is written against). Meant for
// pointing at a canary slug while iterating on the model/max-tokens/
// reasoning knobs that caused the empty-answer incident documented in
// CLAUDE.md ("A thinking model's reasoning counts against `max_tokens`...");
// production `ask` ignores the extra `probe` field this script sends, a
// canary entrypoint that reads it can use it to try different settings
// without a redeploy per experiment.
//
// Usage:
//   node backend/scripts/ask-probe.mjs --slug ask-canary --runs 5 --set exam \
//     [--model X] [--max-tokens N] [--reasoning '<json>'] [--trim N] [--tag mytag]
//
// Exit code is 1 if any run came back empty (a `done` with zero deltas) or
// errored, so this can gate a loop; 0 if every run produced an answer.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const SUPABASE_URL = process.env.LHF_SUPABASE_URL ?? "https://ynetfjixexksxqrrkwsg.supabase.co";
const PUBLISHABLE_KEY =
  process.env.LHF_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt";

function usageAndExit(message) {
  if (message) console.error(message);
  console.error(
    "Usage: node backend/scripts/ask-probe.mjs --slug <slug> --runs <n> --set <exam|policy|short|mixed> " +
      "[--model X] [--max-tokens N] [--reasoning '<json>'] [--trim N] [--probe '<json>'] [--tag mytag]",
  );
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { slug: undefined, runs: 1, set: "exam" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => argv[++i];
    switch (arg) {
      case "--slug":
        opts.slug = next();
        break;
      case "--runs":
        opts.runs = Number.parseInt(next(), 10);
        break;
      case "--set":
        opts.set = next();
        break;
      case "--model":
        opts.model = next();
        break;
      case "--max-tokens":
        opts.maxTokens = Number.parseInt(next(), 10);
        break;
      case "--reasoning":
        opts.reasoning = JSON.parse(next());
        break;
      case "--trim":
        opts.trim = Number.parseInt(next(), 10);
        break;
      case "--probe":
        // Raw JSON merged into the canary's `probe` object -- the escape
        // hatch for fields this script has no dedicated flag for
        // (fallbackModel, disableFallback, hedgeAfterMs, provider...).
        opts.probeExtra = JSON.parse(next());
        break;
      case "--tag":
        opts.tag = next();
        break;
      default:
        usageAndExit(`unknown flag: ${arg}`);
    }
  }
  if (!opts.slug) usageAndExit("--slug is required");
  if (!Number.isInteger(opts.runs) || opts.runs < 1) usageAndExit("--runs must be a positive integer");
  if (!["exam", "policy", "short", "mixed"].includes(opts.set)) {
    usageAndExit(`--set must be one of exam, policy, short, mixed (got "${opts.set}")`);
  }
  return opts;
}

// --- session cache -----------------------------------------------------
// Each new anonymous sign-in is its own quota bucket (PROTOCOL.md: "Identity
// is anonymous... A user id exists so the server can scope... quotas"), so
// reusing one across probe invocations is the polite thing to do rather
// than minting a fresh account (and a fresh 40/day allowance) every run.

function scratchDir() {
  return process.env.LHF_PROBE_SCRATCH ?? os.tmpdir();
}

function sessionCachePath() {
  return path.join(scratchDir(), "ask-probe-session.json");
}

async function signUpAnonymously() {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/signup`, {
    method: "POST",
    headers: { apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
    body: "{}",
  });
  if (!res.ok) {
    throw new Error(`anonymous signup failed: HTTP ${res.status} ${await res.text()}`);
  }
  const data = await res.json();
  return { accessToken: data.access_token, userId: data.user?.id };
}

async function getSession() {
  const cachePath = sessionCachePath();
  if (fs.existsSync(cachePath)) {
    try {
      const cached = JSON.parse(fs.readFileSync(cachePath, "utf8"));
      if (cached.accessToken) return cached;
    } catch {
      // fall through to a fresh sign-in
    }
  }
  const session = await signUpAnonymously();
  fs.mkdirSync(path.dirname(cachePath), { recursive: true });
  fs.writeFileSync(cachePath, JSON.stringify(session, null, 2));
  return session;
}

function dropCachedSession() {
  const cachePath = sessionCachePath();
  if (fs.existsSync(cachePath)) fs.unlinkSync(cachePath);
}

// --- realistic fixture content ------------------------------------------
// Built from the repo's own syllabus fixture (backend/test/fixtures/
// cis2400-syllabus.html) repeated/varied out to a realistic ~14,000-token
// (~55,000-char) contextDocument, the size real syllabi-plus-schedule
// context documents run in production (see CLAUDE.md's account of the
// 2026-09-14 empty-answer incident, which happened on a 14.5k-token real
// prompt). A short synthetic block is appended per "week" so the document
// isn't just N verbatim copies of one 1KB fixture, which would compress
// and tokenize very differently from real course text.

const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..", "..");
const FIXTURE_PATH = path.join(REPO_ROOT, "backend", "test", "fixtures", "cis2400-syllabus.html");

function stripTags(html) {
  return html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function weeklyScheduleLine(weekNumber, date) {
  const iso = date.toISOString().slice(0, 10);
  const topics = [
    "Processes & the process model",
    "Virtual memory & paging",
    "Concurrency & synchronization primitives",
    "Deadlock detection and avoidance",
    "File systems & the VFS layer",
    "I/O subsystems and device drivers",
    "Networking: sockets and the transport layer",
    "Scheduling algorithms and fairness",
    "Security: privilege separation and sandboxing",
    "Distributed systems basics",
    "Case study: a real kernel subsystem",
    "Review and synthesis",
  ];
  const topic = topics[weekNumber % topics.length];
  return `Week ${weekNumber} (${iso}): ${topic}. Reading due before lecture; problem set ${weekNumber} released Friday, due the following Friday at 11:59pm on Gradescope. Office hours as posted on the course calendar.`;
}

function buildContextDocument(targetChars) {
  const base = stripTags(fs.readFileSync(FIXTURE_PATH, "utf8"));
  const header =
    "COURSE MATERIAL CONTEXT DOCUMENT (synthetic probe fixture, built from " +
    "backend/test/fixtures/cis2400-syllabus.html plus generated weekly schedule lines)\n\n";
  const examLine =
    "Midterm Exam #1 — Mon Sep 28, 7:00–8:30 pm, location Towne 100. " +
    "Midterm Exam #2 — Mon Nov 9, 7:00–8:30 pm, location Towne 100. " +
    "Final Exam — during the registrar's final exam period, December 2026, cumulative, location TBA.\n\n";
  const lateePolicy =
    "Late policy: each student has 4 late days for the semester, usable in " +
    "whole-day increments on problem sets only, not on exams or the final " +
    "project; after late days are exhausted, submissions lose 10% per day late.\n\n";

  const parts = [header, base, "\n\n", examLine, lateePolicy];
  let size = parts.join("").length;
  const startDate = new Date("2026-09-08T00:00:00Z");
  let week = 1;
  while (size < targetChars) {
    const date = new Date(startDate.getTime() + (week - 1) * 7 * 24 * 60 * 60 * 1000);
    const line = weeklyScheduleLine(week, date) + "\n";
    parts.push(line);
    size += line.length;
    week += 1;
    // Re-append the base syllabus text periodically so the document isn't
    // just an ever-growing schedule -- real synced course material mixes a
    // syllabus doc, several page docs and many assignment docs together.
    if (week % 12 === 0) {
      parts.push("\n" + base + "\n\n");
      size += base.length + 4;
    }
  }
  return parts.join("").slice(0, targetChars);
}

function buildExcerpts() {
  const base = stripTags(fs.readFileSync(FIXTURE_PATH, "utf8"));
  let text =
    "RETRIEVED EXCERPTS\n\n" +
    "[CIS 2400 | syllabus] " +
    base +
    "\n\n[CIS 2400 | assignment] Problem Set 4 is due Friday Oct 3 at 11:59pm on Gradescope; " +
    "late submissions follow the syllabus's 4-late-day policy.\n\n" +
    "[CIS 2400 | announcement] Midterm Exam #1 is Mon Sep 28, 7:00-8:30pm in Towne 100; " +
    "bring a calculator, no notes.\n\n";
  while (text.length < 2000) {
    text += "[CIS 2400 | page] Office hours: Tue/Thu 3-5pm, Levine 512, or by appointment.\n\n";
  }
  return text.slice(0, 2000);
}

const PROMPT_SETS = {
  exam: ["when's my next exam?"],
  policy: ["what's the late policy in cis 2400?"],
  short: ["what's due tomorrow?"],
  mixed: ["when's my next exam?", "what's the late policy in cis 2400?", "what's due tomorrow?"],
};

function questionForRun(set, runIndex) {
  const pool = PROMPT_SETS[set];
  return pool[runIndex % pool.length];
}

function buildRequestBody({ set, runIndex, trim, model, maxTokens, reasoning, probeExtra }) {
  let contextDocument = buildContextDocument(55000);
  if (Number.isInteger(trim)) contextDocument = contextDocument.slice(0, trim);

  const body = {
    question: questionForRun(set, runIndex),
    contextDocument,
    excerpts: buildExcerpts(),
    askedAt: new Date().toISOString(),
    courseIDs: ["1000001", "1000002", "1000003"],
    history: [],
  };

  const probe = {};
  if (model !== undefined) probe.model = model;
  if (maxTokens !== undefined) probe.maxTokens = maxTokens;
  if (reasoning !== undefined) probe.reasoning = reasoning;
  if (probeExtra !== undefined) Object.assign(probe, probeExtra);
  if (Object.keys(probe).length > 0) body.probe = probe;

  return body;
}

// --- SSE parsing ---------------------------------------------------------
// PROTOCOL.md's "ask" section: `text/event-stream`, one `data: {json}\n\n`
// line per event, types `delta` | `done` | `error`.

async function runOnce({ slug, session, tag, requestBody }) {
  const started = performance.now();
  let firstDeltaMs;
  let deltaCount = 0;
  let contentChars = 0;
  let answerPrefix = "";
  let doneUsage;
  let errorEvent;
  let httpStatus;

  const res = await fetch(`${SUPABASE_URL}/functions/v1/${slug}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.accessToken}`,
      apikey: PUBLISHABLE_KEY,
      "Content-Type": "application/json",
      "x-lhf-probe": tag ?? "probe",
    },
    body: JSON.stringify(requestBody),
  });
  httpStatus = res.status;

  if (!res.ok || !res.body) {
    const text = await res.text().catch(() => "");
    return {
      httpStatus,
      totalMs: performance.now() - started,
      firstDeltaMs: undefined,
      deltaCount: 0,
      contentChars: 0,
      answerPrefix: "",
      doneUsage: undefined,
      errorEvent: { code: "http", message: text.slice(0, 500) },
    };
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // SSE frames are separated by a blank line; a "data: " line's payload
    // is one JSON object per PROTOCOL.md.
    let sepIndex;
    while ((sepIndex = buffer.indexOf("\n\n")) !== -1) {
      const frame = buffer.slice(0, sepIndex);
      buffer = buffer.slice(sepIndex + 2);
      const dataLine = frame.split("\n").find((line) => line.startsWith("data:"));
      if (!dataLine) continue;
      const jsonText = dataLine.slice(dataLine.indexOf(":") + 1).trim();
      let event;
      try {
        event = JSON.parse(jsonText);
      } catch {
        continue;
      }
      if (event.type === "delta") {
        if (firstDeltaMs === undefined) firstDeltaMs = performance.now() - started;
        deltaCount += 1;
        contentChars += event.text?.length ?? 0;
        if (answerPrefix.length < 120) answerPrefix += event.text ?? "";
      } else if (event.type === "done") {
        doneUsage = event.usage;
      } else if (event.type === "error") {
        errorEvent = { code: event.code, message: event.message };
      }
    }
  }

  return {
    httpStatus,
    totalMs: performance.now() - started,
    firstDeltaMs,
    deltaCount,
    contentChars,
    answerPrefix: answerPrefix.slice(0, 120),
    doneUsage,
    errorEvent,
  };
}

function percentile(sorted, p) {
  if (sorted.length === 0) return undefined;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  let session = await getSession();

  const results = [];
  for (let i = 0; i < opts.runs; i++) {
    const requestBody = buildRequestBody({
      set: opts.set,
      runIndex: i,
      trim: opts.trim,
      model: opts.model,
      maxTokens: opts.maxTokens,
      probeExtra: opts.probeExtra,
      reasoning: opts.reasoning,
    });

    let result;
    try {
      result = await runOnce({ slug: opts.slug, session, tag: opts.tag, requestBody });
      if (result.httpStatus === 401) {
        // Cached session expired; sign in fresh once and retry this run.
        dropCachedSession();
        session = await getSession();
        result = await runOnce({ slug: opts.slug, session, tag: opts.tag, requestBody });
      }
    } catch (err) {
      result = {
        httpStatus: undefined,
        totalMs: undefined,
        firstDeltaMs: undefined,
        deltaCount: 0,
        contentChars: 0,
        answerPrefix: "",
        doneUsage: undefined,
        errorEvent: { code: "network", message: err instanceof Error ? err.message : String(err) },
      };
    }
    results.push(result);

    const status = result.errorEvent
      ? `ERROR ${result.errorEvent.code}: ${result.errorEvent.message}`
      : result.deltaCount === 0
        ? "EMPTY (0 deltas)"
        : "OK";
    console.log(
      `run ${i + 1}/${opts.runs}  http=${result.httpStatus ?? "-"}  ` +
        `firstDeltaMs=${result.firstDeltaMs?.toFixed(0) ?? "-"}  totalMs=${result.totalMs?.toFixed(0) ?? "-"}  ` +
        `deltas=${result.deltaCount}  chars=${result.contentChars}  ` +
        `usage=${JSON.stringify(result.doneUsage ?? null)}  ${status}` +
        (result.answerPrefix ? `\n    answer: ${JSON.stringify(result.answerPrefix)}` : ""),
    );
  }

  const answered = results.filter((r) => !r.errorEvent && r.deltaCount > 0).length;
  const empty = results.filter((r) => !r.errorEvent && r.deltaCount === 0).length;
  const errored = results.filter((r) => r.errorEvent).length;
  const latencies = results.map((r) => r.totalMs).filter((n) => typeof n === "number").sort((a, b) => a - b);
  const completionTokens = results
    .map((r) => r.doneUsage?.completionTokens)
    .filter((n) => typeof n === "number");
  const meanCompletion = completionTokens.length
    ? completionTokens.reduce((a, b) => a + b, 0) / completionTokens.length
    : undefined;

  console.log("---");
  console.log(
    `answered=${answered} empty=${empty} errored=${errored}  ` +
      `p50=${percentile(latencies, 50)?.toFixed(0) ?? "-"}ms p95=${percentile(latencies, 95)?.toFixed(0) ?? "-"}ms  ` +
      `meanCompletionTokens=${meanCompletion?.toFixed(0) ?? "-"}`,
  );

  process.exit(empty > 0 || errored > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Probe script failed:", err instanceof Error ? err.stack ?? err.message : err);
  process.exit(1);
});
