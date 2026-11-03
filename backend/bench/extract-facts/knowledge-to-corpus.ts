// Turns the iPhone's CourseKnowledgeBase JSON (Swift Codable, ISO 8601 dates)
// into unlabelled corpus files for the extract-facts bench, so real Penn
// documents can be hand-labelled (add an `expected` block) and scored.
//
// Field names come from LowHangingFruitKit/.../Models/CourseDocument.swift and
// CourseCatalogEntry.swift: documents[] {courseID, course, kind, sourceID,
// title, text, updatedAt, fetchedAt, dueAt}, courses[] {courseID, code},
// catalog[] {courseID, meetings[] {weekday 1=Sunday..7, startMinutes,
// endMinutes}}, lastSyncedAt.
//
// The output is real course text. It is written with `expected: null` and
// `source: "phone"` and must stay untracked (corpus/phone/ is in .gitignore).
// Personal state is stripped on the way: the "Status: submitted" line that the
// assignment uploader appends (research doc, Part 2.2) is removed from every
// document, and assignments are never emitted, only used as the item index,
// so a student's submission state cannot reach a model prompt or a file.

interface KDoc {
  courseID: string;
  course: string;
  kind: string;
  sourceID: string;
  title: string;
  text: string;
  updatedAt?: string | null;
  fetchedAt: string;
  dueAt?: string | null;
}
interface KCourse { courseID: string; code: string }
interface KMeeting { weekday: number; startMinutes: number; endMinutes: number }
interface KCatalog { courseID: string; meetings?: KMeeting[] }
interface KnowledgeBase {
  courses: KCourse[];
  documents: KDoc[];
  catalog?: KCatalog[];
  lastSyncedAt?: string | null;
}

/** An Ed document's `updatedAt` is the thread's last edit, not its post
 *  date, and the two can be a week apart on a thread that staff keep
 *  touching ("Midterm date -- October 12" read as posted 2026-10-19 on
 *  Marco's phone). The collector writes the real date into the text's
 *  first line as `posted YYYY-MM-DD`, so read it back from there. Noon in
 *  New York rather than midnight, so a "tomorrow" in the post lands on
 *  the right side of the DST switch either way. The proper fix is a
 *  `posted_at` on the document (Phase 2, item 13); this is the bench's
 *  stand-in. */
function edPostedAt(d: { kind: string; text: string }): string | undefined {
  if (d.kind !== "ed") return undefined;
  const m = /posted (\d{4}-\d{2}-\d{2})/.exec(d.text.split("\n", 1)[0] ?? "");
  if (!m) return undefined;
  const offset = m[1] >= "2026-11-01" && m[1] < "2027-03-08" ? "-05:00" : "-04:00";
  return `${m[1]}T12:00:00${offset}`;
}

const EMIT_KINDS = new Set(["announcement", "ed", "page", "syllabus", "module"]);
// Calendar convention in the Kit: 1 = Sunday.
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

const hhmm = (m: number) =>
  `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;

export function stripPersonalState(text: string): string {
  return text.split("\n").filter((l) => !/^\s*Status:\s*/i.test(l)).join("\n");
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "course";

function arg(name: string): string | undefined {
  const i = Deno.args.indexOf(name);
  return i >= 0 ? Deno.args[i + 1] : undefined;
}

if (import.meta.main) {
  const knowledge = arg("--knowledge");
  const out = arg("--out");
  if (!knowledge || !out) {
    console.error("usage: knowledge-to-corpus.ts --knowledge <course-knowledge.json> --out <dir> [--now <ISO>] [--timezone America/New_York]");
    Deno.exit(2);
  }
  const timezone = arg("--timezone") ?? "America/New_York";
  const kb = JSON.parse(await Deno.readTextFile(knowledge)) as KnowledgeBase;
  const now = arg("--now") ?? kb.lastSyncedAt ?? new Date().toISOString();

  for (const course of kb.courses) {
    const docs = kb.documents.filter((d) => d.courseID === course.courseID);
    const index = docs.filter((d) => d.kind === "assignment").map((d) => ({
      sourceID: d.sourceID,
      title: d.title,
      ...(d.dueAt ? { dueAt: d.dueAt } : {}),
      kind: "assignment" as const,
    }));
    const meetings = (kb.catalog?.find((c) => c.courseID === course.courseID)?.meetings ?? [])
      .filter((m) => m.weekday >= 1 && m.weekday <= 7)
      .map((m) => ({ weekday: WEEKDAYS[m.weekday - 1], start: hhmm(m.startMinutes), end: hhmm(m.endMinutes) }));
    const dir = `${out}/${slug(course.code)}`;
    let n = 0;
    for (const d of docs) {
      if (!EMIT_KINDS.has(d.kind)) continue;
      if (n === 0) await Deno.mkdir(dir, { recursive: true });
      const file = {
        id: `${d.kind}:${d.courseID}:${d.sourceID}`,
        course: course.code,
        kind: d.kind,
        title: d.title,
        postedAt: edPostedAt(d) ?? d.updatedAt ?? d.fetchedAt,
        text: stripPersonalState(d.text),
        index,
        meetings,
        timezone,
        now,
        source: "phone",
        expected: null,
      };
      await Deno.writeTextFile(`${dir}/${d.kind}-${slug(d.sourceID)}.json`, JSON.stringify(file, null, 2) + "\n");
      n++;
    }
    console.log(`${course.code}: ${n} documents, ${index.length} index items, ${meetings.length} meetings`);
  }
  console.log("\nThese files hold real course text. Keep them under corpus/phone/ (untracked); never commit them.");
}
