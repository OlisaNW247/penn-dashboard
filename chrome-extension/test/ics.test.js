import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  parseICS, parseICSBytes, splitCourse, classify, calendarItems, assignmentsFromICS,
} from "../src/core/ics.js";
import { canvasAssignmentID, assignmentID, isAssignment } from "../src/core/assignment.js";

// CanvasICSTests.swift:7-42 (sampleICS)
const sampleICS = `BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Instructure//Canvas//EN
BEGIN:VEVENT
UID:event-assignment-12345@canvas.upenn.edu
SUMMARY:Homework 3 [CIS 5050-001 Software Systems]
DTSTART:20260520T235900Z
URL:https://canvas.upenn.edu/courses/1/assignments/12345
END:VEVENT
BEGIN:VEVENT
UID:event-assignment-67890@canvas.upenn.edu
SUMMARY:Final Project Proposal [ENM 5100-001]
DTSTART;VALUE=DATE:20260601
URL:https://canvas.upenn.edu/courses/2/assignments/67890
END:VEVENT
BEGIN:VEVENT
UID:event-quiz-24680@canvas.upenn.edu
SUMMARY:Quiz 2 [CIS 5050-001 Software Systems]
DTSTART:20260522T140000Z
URL:https://canvas.upenn.edu/courses/1/quizzes/24680
END:VEVENT
BEGIN:VEVENT
UID:event-discussion-13579@canvas.upenn.edu
SUMMARY:Week 4 Discussion [ENM 5100-001]
DTSTART:20260523T150000Z
URL:https://canvas.upenn.edu/courses/2/discussion_topics/13579
END:VEVENT
BEGIN:VEVENT
UID:event-calendar-11223@canvas.upenn.edu
SUMMARY:Guest Lecture [CIS 5050-001 Software Systems]
DTSTART:20260524T170000Z
URL:https://canvas.upenn.edu/calendar_events/11223
END:VEVENT
END:VCALENDAR`;

const byID = (items, needle) => items.find((a) => a.sourceID.includes(needle));

// CanvasICSTests.swift:44-64
test("parses both events and splits course suffix", () => {
  const items = calendarItems(sampleICS);
  assert.equal(items.length, 5);
  const hw = byID(items, "12345");
  assert.equal(hw.title, "Homework 3");
  assert.equal(hw.course, "CIS 5050");
  assert.equal(hw.url, "https://canvas.upenn.edu/courses/1/assignments/12345");
  assert.notEqual(hw.dueAt, null);
  assert.equal(hw.source, "canvas");
  assert.equal(hw.kind, "assignment");
  assert.equal(hw.submitted, false);
  const proj = byID(items, "67890");
  assert.equal(proj.title, "Final Project Proposal");
  assert.equal(proj.course, "ENM 5100");
  assert.notEqual(proj.dueAt, null);
});

// CanvasICSTests.swift:66-75
test("classifies Canvas feed entries by URL", () => {
  const items = calendarItems(sampleICS);
  assert.equal(byID(items, "12345").kind, "assignment");
  assert.equal(byID(items, "24680").kind, "quiz");
  assert.equal(byID(items, "13579").kind, "discussion");
  assert.equal(byID(items, "11223").kind, "event");
});

// CanvasICSTests.swift:77-84
test("assignment feed excludes non-assignment events", () => {
  const items = assignmentsFromICS(sampleICS);
  assert.equal(items.length, 2);
  assert.ok(items.every(isAssignment));
});

// CanvasICSTests.swift:86-101
test("DTSTART with Z suffix is parsed as UTC", () => {
  const due = byID(calendarItems(sampleICS), "12345").dueAt;
  assert.equal(due.getUTCFullYear(), 2026);
  assert.equal(due.getUTCMonth(), 4);
  assert.equal(due.getUTCDate(), 20);
  assert.equal(due.getUTCHours(), 23);
  assert.equal(due.getUTCMinutes(), 59);
});

// CanvasICSTests.swift:103-121 (Swift asserts in Calendar.current; so does this, via local getters)
test("date-only DTSTART becomes end-of-day LOCAL time", () => {
  const due = byID(calendarItems(sampleICS), "67890").dueAt;
  assert.deepEqual(
    [due.getFullYear(), due.getMonth() + 1, due.getDate(), due.getHours(), due.getMinutes(), due.getSeconds()],
    [2026, 6, 1, 23, 59, 59],
  );
});

// CanvasICSTests.swift:123-138
test("summary without bracketed course falls back gracefully", () => {
  const items = calendarItems(`BEGIN:VCALENDAR
BEGIN:VEVENT
UID:naked
SUMMARY:Read chapter 4
DTSTART:20260601T120000Z
END:VEVENT
END:VCALENDAR`);
  assert.equal(items.length, 1);
  assert.equal(items[0].title, "Read chapter 4");
  assert.equal(items[0].course, "(unknown course)");
});

// CanvasICSTests.swift:140-164
test("a section-override VEVENT resolves its assignment id from the URL fragment, not the UID", () => {
  const items = calendarItems(`BEGIN:VCALENDAR
BEGIN:VEVENT
UID:event-assignment-override-99@canvas.upenn.edu
SUMMARY:Lab 3 (Section 202) [PHYS 0151-202]
DTSTART:20260601T120000Z
URL:https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#assignment_4242
END:VEVENT
END:VCALENDAR`);
  assert.equal(items.length, 1);
  assert.equal(new URL(items[0].url).hash, "#assignment_4242");
  assert.equal(canvasAssignmentID(items[0]), "4242");
});

// CanvasICSTests.swift:166-174
test("folded continuation lines are unfolded", () => {
  const ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:folded\r\nSUMMARY:Long title that\r\n  continues here [CIS 1200]\r\nDTSTART:20260601T120000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
  const items = calendarItems(ics);
  assert.equal(items.length, 1);
  assert.equal(items[0].title, "Long title that continues here");
  assert.equal(items[0].course, "CIS 1200");
});

// HardeningTests.swift:13-19
test("empty and garbage yield no events", () => {
  assert.deepEqual(parseICSBytes(new Uint8Array()), []);
  assert.deepEqual(parseICS(""), []);
  assert.deepEqual(parseICS("not a calendar at all\njust text"), []);
  assert.deepEqual(parseICS("BEGIN:VEVENT\nSUMMARY:x"), []); // BEGIN with no END is never emitted
});

// HardeningTests.swift:21-26
test("stray END does not break a later event", () => {
  const events = parseICS("END:VEVENT\nBEGIN:VEVENT\nUID:1\nEND:VEVENT");
  assert.equal(events.length, 1);
  assert.equal(events[0].uid, "1");
});

// HardeningTests.swift:28-36
test("missing fields fall back", () => {
  const events = parseICS("BEGIN:VEVENT\nEND:VEVENT");
  assert.equal(events.length, 1);
  assert.notEqual(events[0].uid, "");
  assert.equal(events[0].summary, "(untitled)");
  assert.equal(events[0].dtStart, null);
  assert.equal(events[0].url, null);
});

// HardeningTests.swift:38-52
test("malformed date and URL become null", () => {
  const e = parseICS(`BEGIN:VEVENT
UID:2
SUMMARY:Broken [CIS 1200]
DTSTART:not-a-real-date
URL:ht!tp:// not a url
END:VEVENT`)[0];
  assert.ok(e);
  assert.equal(e.dtStart, null);
  assert.equal(e.url, null);
});

// HardeningTests.swift:54-59
test("CRLF endings and folded lines unfold", () => {
  const e = parseICS("BEGIN:VEVENT\r\nUID:3\r\nSUMMARY:Long titl\r\n e here [C]\r\nEND:VEVENT\r\n")[0];
  assert.equal(e.uid, "3");
  assert.ok(e.summary.includes("Long title here"));
});

// HardeningTests.swift:61-64
test("a field line without a colon is ignored", () => {
  assert.equal(parseICS("BEGIN:VEVENT\nGARBAGE-NO-COLON\nUID:4\nEND:VEVENT")[0].uid, "4");
});

// HardeningTests.swift:68-77
test("splitCourse handles degenerate summaries", () => {
  assert.equal(splitCourse("No brackets here").course, "(unknown course)");
  const only = splitCourse("[JustACourse]");
  assert.equal(only.course, "JustACourse");
  assert.equal(only.title, "");
  assert.equal(splitCourse("Weird [A] [B]").course, "B");
  assert.equal(splitCourse("Weird [A] [B]").title, "Weird [A]");
  assert.equal(splitCourse("").course, "(unknown course)");
});

// HardeningTests.swift:81-89
test("classify by URL then UID", () => {
  const ev = (uid, url) => ({ uid, summary: "s", dtStart: null, url });
  assert.equal(classify(ev("x", "https://canvas.upenn.edu/courses/1/assignments/5")), "assignment");
  assert.equal(classify(ev("x", "https://canvas.upenn.edu/courses/1/quizzes/5")), "quiz");
  assert.equal(classify(ev("event-quiz-9", null)), "quiz");
  assert.equal(classify(ev("mystery", null)), "other");
});

// HardeningTests.swift:163-175
test("a course survives trailing whitespace after the bracket", () => {
  for (const summary of ["HW 3 [CIS 1200] ", "HW 3 [CIS 1200]\r", "HW 3 [CIS 1200]\n", "HW 3 [CIS 1200]\t "]) {
    const parsed = splitCourse(summary);
    assert.equal(parsed.course, "CIS 1200", JSON.stringify(summary));
    assert.equal(parsed.title, "HW 3");
  }
});

// RecordedICSFixtureTests.swift (fixture copied from Tests/.../Fixtures/canvas-calendar.ics)
const fixture = () => new Uint8Array(readFileSync(new URL("./fixtures/canvas-calendar.ics", import.meta.url)));

// RecordedICSFixtureTests.swift:24-28
test("fixture: a recorded export parses into every event it contains", () => {
  assert.equal(calendarItems(fixture()).length, 6);
});

// RecordedICSFixtureTests.swift:30-39
test("fixture: kinds are classified from the real URL paths", () => {
  const items = calendarItems(fixture());
  const kind = (title) => items.find((a) => a.title === title)?.kind;
  assert.equal(kind("Homework 1: Recursion"), "assignment");
  assert.equal(kind("Quiz 2"), "quiz");
  assert.equal(kind("Week 2 Reading Response"), "discussion");
  assert.equal(kind("Lecture 4"), "event");
});

// RecordedICSFixtureTests.swift:41-47
test("fixture: only real coursework survives the assignment filter", () => {
  const items = assignmentsFromICS(fixture());
  assert.ok(!items.some((a) => a.title === "Lecture 4"));
  assert.ok(items.some((a) => a.title === "Homework 1: Recursion"));
});

// RecordedICSFixtureTests.swift:49-56
test("fixture: the trailing [Course] is split off the summary", () => {
  const hw = calendarItems(fixture()).find((a) => a.title === "Homework 1: Recursion");
  assert.equal(hw.course, "CIS 1200");
  assert.ok(!hw.title.includes("["));
});

// RecordedICSFixtureTests.swift:58-66
test("fixture: a summary with no [Course] suffix still yields a usable item", () => {
  const orphan = calendarItems(fixture()).find((a) => a.title.startsWith("Untitled assignment"));
  assert.equal(orphan.kind, "assignment");
  assert.notEqual(orphan.dueAt, null);
  assert.equal(orphan.course, "(unknown course)");
});

// RecordedICSFixtureTests.swift:68-72
test("fixture: every item carries a due date", () => {
  assert.ok(calendarItems(fixture()).every((a) => a.dueAt !== null));
});

// RecordedICSFixtureTests.swift:74-84
test("fixture: ids are stable across two parses and unique", () => {
  const ids = () => calendarItems(fixture()).map(assignmentID).sort();
  const first = ids();
  assert.deepEqual(first, ids());
  assert.equal(new Set(first).size, first.length);
});

// No Swift test; the fixture's folded, escaped DESCRIPTION and `URL;VALUE=URI` parameter must not disturb the fields we read.
test("fixture: parameters on URL, no term stamp in the bracket", () => {
  const hw = calendarItems(fixture()).find((a) => a.title === "Homework 1: Recursion");
  assert.equal(hw.url, "https://canvas.upenn.edu/courses/1740321/assignments/9182736");
  assert.equal(hw.term, null); // "Fall 2026" is words, not a YYYYTT stamp
  assert.equal(hw.dueAt.toISOString(), "2026-09-08T03:59:00.000Z");
});

// No Swift test. ICSParser.swift:124-159 (TZID branch and the unquoted-TZID quirk, hazard #16).
test("TZID resolves a named zone; a quoted TZID falls back to floating local time", () => {
  const ev = (dt) => parseICS(`BEGIN:VEVENT\nUID:z\n${dt}\nEND:VEVENT`)[0].dtStart;
  assert.equal(ev("DTSTART;TZID=America/Los_Angeles:20260601T120000").toISOString(), "2026-06-01T19:00:00.000Z");
  assert.equal(ev("DTSTART;TZID=Asia/Kolkata:20260601T120000").toISOString(), "2026-06-01T06:30:00.000Z");
  const quoted = ev('DTSTART;TZID="America/New_York":20260601T120000');
  const floating = ev("DTSTART:20260601T120000");
  assert.equal(quoted.getTime(), floating.getTime());
  assert.equal(floating.getHours(), 12);
  assert.equal(ev("DTSTART;TZID=Not/AZone:20260601T120000").getTime(), floating.getTime());
});

// No Swift test; DateFormatter is non-lenient, so out-of-range or trailing-garbage values are nil.
test("invalid date values are null", () => {
  const ev = (dt) => parseICS(`BEGIN:VEVENT\nUID:z\n${dt}\nEND:VEVENT`)[0].dtStart;
  assert.equal(ev("DTSTART:20261301T120000Z"), null);
  assert.equal(ev("DTSTART:20260230T120000Z"), null);
  assert.equal(ev("DTSTART:20260601T240000Z"), null);
  assert.equal(ev("DTSTART:20260601T120000Zjunk"), null);
  assert.equal(ev("DTSTART;VALUE=DATE:2026-06-01"), null);
  assert.equal(ev("DTSTART:20260601T1200"), null);
});

// No Swift test; ICSParser.swift:21-40 and :83-104 quirks kept on purpose (hazards #15, #18, last field wins, unescape).
test("parser quirks kept from Swift", () => {
  const [e] = parseICS([
    "BEGIN:VEVENT", "UID:q", "SUMMARY:Outer", "BEGIN:VALARM", "SUMMARY:Alarm", "END:VALARM",
    "SUMMARY:a\\, b\; c\\\\ d\\ne\\x\\", "END:VEVENT",
  ].join("\n"));
  assert.equal(e.summary, "a, b; c\\ d\ne" + "x" + "\\");
  const [f] = parseICS("BEGIN:VEVENT\nUID:q\nSUMMARY:one\n\n two\nEND:VEVENT"); // blank line dropped, fold still joins
  assert.equal(f.summary, "onetwo");
  const [g] = parseICS("BEGIN:VEVENT\nUID:q\nSUMMARY:first\nSUMMARY:second\nEND:VEVENT");
  assert.equal(g.summary, "second");
});

// No Swift test; ICSParser.swift:15 (UTF-8 only) and :111 (random id for a missing UID).
test("invalid UTF-8 gives an empty feed; UID-less events get distinct generated ids", () => {
  assert.deepEqual(parseICSBytes(new Uint8Array([0x42, 0xff, 0xfe])), []);
  const [a] = parseICS("BEGIN:VEVENT\nEND:VEVENT");
  const [b] = parseICS("BEGIN:VEVENT\nEND:VEVENT");
  assert.match(a.uid, /^[0-9A-F]{8}-[0-9A-F]{4}-/);
  assert.notEqual(a.uid, b.uid);
});
