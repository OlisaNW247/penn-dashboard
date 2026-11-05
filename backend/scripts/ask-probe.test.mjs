import test from "node:test";
import assert from "node:assert/strict";
import {
  buildRequestBody,
  gradeHistoryAnswer,
  gradeMeetingAnswer,
  parseHistory,
  questionForRun,
} from "./ask-probe.mjs";

// Importing the script must not start a run (it would sign in over the
// network); reaching these tests at all is that check.

test("history set carries the recorded pair, the correction and the fixed moment", () => {
  const body = buildRequestBody({ set: "history", runIndex: 0 });
  assert.equal(body.question, "you should've said that in my original question");
  assert.deepEqual(body.history.map((t) => t.role), ["user", "assistant"]);
  assert.equal(body.history[0].content, "Do I not have cis 2620 class today?");
  assert.equal(body.askedAt, "2026-11-02T18:12:00Z");
  assert.match(body.excerpts, /No lectures this week but quiz on Monday\./);
  assert.match(body.excerpts, /Monday, November 2, 2026, 1:12 PM \(America\/New_York, UTC-05:00\)/);
});

test("meeting set has empty history and the class question", () => {
  const body = buildRequestBody({ set: "meeting", runIndex: 3 });
  assert.deepEqual(body.history, []);
  assert.equal(body.question, "Do I not have cis 2620 class today?");
  assert.equal(body.askedAt, "2026-11-02T18:12:00Z");
});

test("--asked-at, --history-file history and --model apply to any set", () => {
  const history = parseHistory([{ role: "user", content: "hi" }]);
  const body = buildRequestBody({ set: "exam", runIndex: 0, history, model: "x/y", askedAt: "2026-01-01T00:00:00Z" });
  assert.deepEqual(body.history, [{ role: "user", content: "hi" }]);
  assert.equal(body.probe.model, "x/y");
  assert.equal(body.askedAt, "2026-01-01T00:00:00Z");
  assert.deepEqual(buildRequestBody({ set: "exam", runIndex: 0 }).history, []);
  assert.equal(questionForRun("exam", 0), "when's my next exam?");
});

test("parseHistory rejects a wrong shape", () => {
  assert.throws(() => parseHistory({}));
  assert.throws(() => parseHistory([{ role: "system", content: "x" }]));
});

test("history grading", () => {
  assert.deepEqual(gradeHistoryAnswer("You're right, sorry: no lectures this week."), {
    acknowledged: true, confused: false, mentionsPost: true,
  });
  assert.equal(gradeHistoryAnswer("I'm not sure what you mean, can you clarify?").confused, true);
});

test("meeting grading: schedule only counts when the post is absent", () => {
  assert.deepEqual(gradeMeetingAnswer("No lectures this week, but a quiz Monday."), { fromPost: true, fromSchedule: false });
  assert.deepEqual(gradeMeetingAnswer("It meets today at 10:15 in Towne."), { fromPost: false, fromSchedule: true });
});
