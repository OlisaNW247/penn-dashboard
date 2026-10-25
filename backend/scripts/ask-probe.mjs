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
//     [--model X] [--max-tokens N] [--reasoning '<json>'] [--trim N] [--tag mytag] \
//     [--temperature N] [--asked-at <ISO>]
//
// The `citations` set (2026-10-25) measures the citation contract in
// `_shared/prompt.ts`: it sends excerpts in the exact line format the phone
// sends (`BackendAssistantResponder.retrievedExcerpts`), prints every answer
// in full with its parsed `<sources>` line, and ends with counts of how many
// answers carried a block, how many `detail`s held a known title verbatim
// (the phone links a chip only then), how many used kind `ed`, and how many
// "where is the midterm" answers named the newer post's room.
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
    "Usage: node backend/scripts/ask-probe.mjs --slug <slug> --runs <n> --set <exam|policy|short|mixed|citations> " +
      "[--model X] [--max-tokens N] [--reasoning '<json>'] [--trim N] [--probe '<json>'] [--tag mytag] " +
      "[--temperature N] [--asked-at <ISO>]",
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
      case "--temperature":
        opts.temperature = Number.parseFloat(next());
        break;
      case "--asked-at":
        opts.askedAt = next();
        break;
      default:
        usageAndExit(`unknown flag: ${arg}`);
    }
  }
  if (!opts.slug) usageAndExit("--slug is required");
  if (!Number.isInteger(opts.runs) || opts.runs < 1) usageAndExit("--runs must be a positive integer");
  if (!["exam", "policy", "short", "mixed", "citations"].includes(opts.set)) {
    usageAndExit(`--set must be one of exam, policy, short, mixed, citations (got "${opts.set}")`);
  }
  if (opts.temperature !== undefined && !Number.isFinite(opts.temperature)) {
    usageAndExit("--temperature must be a number");
  }
  if (opts.askedAt !== undefined && Number.isNaN(Date.parse(opts.askedAt))) {
    usageAndExit("--asked-at must be an ISO 8601 timestamp");
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

// The `citations` set's excerpts, in the phone's exact line format
// (`BackendAssistantResponder.retrievedExcerpts`, read 2026-10-25):
//   [n] COURSE · kind label · posted Mon D · "Title": body
// under the header line, then the Ed note (`edExcerptNote`, copied word for
// word) because an Ed post is among the hits. The two Ed posts disagree on
// the midterm room on purpose, so the newest-post rule in the system prompt
// is exercised: the right answer to "where is the midterm" is Meyerson B1,
// and says the newer post changed it.
const CITATION_TITLES = ["Course Syllabus", "Midterm 1 logistics", "Midterm room change", "Welcome to CIS 2400"];

function buildCitationExcerpts() {
  const syllabusBody =
    "Late work loses 10% per day up to three days; after that it is not accepted. " +
    "Each student has two grace days for the semester, usable on problem sets only and " +
    "never on exams or the final project. Requests for an extension must reach the " +
    "instructors before the deadline, with documentation from the dean's office for " +
    "medical or family emergencies. Regrade requests are open for one week after grades " +
    "are released on Gradescope, and the whole assignment is regraded, so a score can go " +
    "down as well as up. Office hours are Tuesday and Thursday 3 to 5 pm in Levine 512.";
  const lines = [
    `[1] CIS 2400 · syllabus · "Course Syllabus": ${syllabusBody}`,
    '[2] CIS 2400 · ed discussion · posted Oct 3 · "Midterm 1 logistics": ' +
      "The midterm is on Wednesday, October 15 in Towne 100, 7:00 to 8:30 pm. Bring your " +
      "PennCard and a pencil; one double-sided handwritten cheat sheet is allowed and no " +
      "calculators. Seating is assigned by the last digit of your Penn ID and the seating " +
      "chart will be posted the night before. Conflict exams must be requested by Friday.",
    '[3] CIS 2400 · ed discussion · posted Oct 12 · "Midterm room change": ' +
      "The midterm has moved to Meyerson B1; same date and time (Wednesday, October 15, " +
      "7:00 to 8:30 pm). Towne 100 is being used for another exam that evening. Seating " +
      "is still assigned by the last digit of your Penn ID. Everything else in the " +
      "logistics post stands, including the cheat sheet rule.",
    '[4] CIS 2400 · announcement · posted Sep 2 · "Welcome to CIS 2400": ' +
      "Welcome to the course! Lectures meet Monday and Wednesday, recitations start next " +
      "week, and the first problem set goes out on Friday. Please join the class Ed board " +
      "and check Canvas for announcements. We are looking forward to a great semester " +
      "together and are happy to answer questions in office hours.",
  ];
  const edNote =
    'Excerpts labelled "ed discussion" are posts by course staff on the class\'s Ed board, and carry the date they were posted.';
  return [
    "RETRIEVED EXCERPTS (from the student's synced course materials):",
    edNote,
    ...lines,
  ].join("\n");
}

const PROMPT_SETS = {
  exam: ["when's my next exam?"],
  policy: ["what's the late policy in cis 2400?"],
  short: ["what's due tomorrow?"],
  mixed: ["when's my next exam?", "what's the late policy in cis 2400?", "what's due tomorrow?"],
  citations: [
    "what's the late policy in cis 2400?",
    "where is the cis 2400 midterm?",
    "what did staff post recently in cis 2400?",
  ],
};

function questionForRun(set, runIndex) {
  const pool = PROMPT_SETS[set];
  return pool[runIndex % pool.length];
}

function buildRequestBody({ set, runIndex, trim, model, maxTokens, reasoning, probeExtra, temperature, askedAt }) {
  let contextDocument = buildContextDocument(55000);
  if (Number.isInteger(trim)) contextDocument = contextDocument.slice(0, trim);

  const body = {
    question: questionForRun(set, runIndex),
    contextDocument,
    excerpts: set === "citations" ? buildCitationExcerpts() : buildExcerpts(),
    askedAt: askedAt ?? new Date().toISOString(),
    courseIDs: ["1000001", "1000002", "1000003"],
    history: [],
  };

  const probe = {};
  if (model !== undefined) probe.model = model;
  if (maxTokens !== undefined) probe.maxTokens = maxTokens;
  if (reasoning !== undefined) probe.reasoning = reasoning;
  if (temperature !== undefined) probe.temperature = temperature;
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
  let fullText = "";
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
      fullText: "",
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
        fullText += event.text ?? "";
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
    fullText,
    doneUsage,
    errorEvent,
  };
}

// Pulls the trailing `<sources>COURSE|kind|detail; …</sources>` block out of
// an answer the way the phone's splitter reads it: returns the raw inner
// text and the parsed entries, or null when there is no block.
function parseSources(text) {
  const match = /<sources>([\s\S]*?)<\/sources>/.exec(text ?? "");
  if (!match) return null;
  const entries = match[1]
    .split(";")
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .map((part) => {
      const [course = "", kind = "", ...rest] = part.split("|");
      return { course: course.trim(), kind: kind.trim().toLowerCase(), detail: rest.join("|").trim() };
    });
  return { raw: match[1].trim(), entries };
}

function answerBody(text) {
  return (text ?? "").replace(/<sources>[\s\S]*?<\/sources>/, "").trim();
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
      temperature: opts.temperature,
      askedAt: opts.askedAt,
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
        fullText: "",
        doneUsage: undefined,
        errorEvent: { code: "network", message: err instanceof Error ? err.message : String(err) },
      };
    }
    result.runIndex = i;
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
        (opts.set !== "citations" && result.answerPrefix
          ? `\n    answer: ${JSON.stringify(result.answerPrefix)}`
          : ""),
    );
    if (opts.set === "citations") {
      const sources = parseSources(result.fullText);
      console.log(`    question: ${questionForRun(opts.set, i)}`);
      console.log(`    answer (full):\n${answerBody(result.fullText).replace(/^/gm, "      ")}`);
      console.log(`    sources: ${sources ? sources.raw : "(none)"}`);
    }
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

  if (opts.set === "citations") {
    const ok = results.filter((r) => !r.errorEvent && r.deltaCount > 0);
    const parsed = ok.map((r) => ({ r, sources: parseSources(r.fullText) }));
    const withBlock = parsed.filter((p) => p.sources);
    const withTitle = withBlock.filter((p) =>
      // Case-folded, as the phone's `CitationLinks.title(_:matches:)` folds
      // before it looks for the title as whole words (2026-10-25: the first
      // baseline run wrote "Oct 12 midterm room change", which links on the
      // phone and a case-sensitive count missed).
      p.sources.entries.some((e) => CITATION_TITLES.some((title) => e.detail.toLowerCase().includes(title.toLowerCase()))),
    );
    const withEd = withBlock.filter((p) => p.sources.entries.some((e) => e.kind === "ed"));
    // "where is the midterm" is the second question of the cycle.
    const midterm = ok.filter((r) => r.runIndex % PROMPT_SETS.citations.length === 1);
    const meyerson = midterm.filter((r) => /meyerson/i.test(answerBody(r.fullText)));
    const towne = midterm.filter((r) => /towne/i.test(answerBody(r.fullText)));
    console.log("--- citations");
    console.log(`answers with a <sources> block: ${withBlock.length}/${ok.length}`);
    console.log(`blocks whose detail held a known title verbatim: ${withTitle.length}/${withBlock.length}`);
    console.log(`blocks using kind ed: ${withEd.length}/${withBlock.length}`);
    console.log(
      `midterm answers naming Meyerson (the newer post): ${meyerson.length}/${midterm.length}  ` +
        `(also mentioning Towne: ${towne.length})`,
    );
  }

  process.exit(empty > 0 || errored > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Probe script failed:", err instanceof Error ? err.stack ?? err.message : err);
  process.exit(1);
});
