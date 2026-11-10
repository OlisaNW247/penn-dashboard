// The tools the `mcp` function offers an agent (research §2, §5), and the
// seam they read through. `registerTools` knows the tool names, argument
// shapes, validation and wording; it knows nothing about where the data
// lives. That is `ToolBackend`: `FixtureToolBackend` below serves the tests
// and the local dev server (`backend/scripts/serve-agent.ts`), and a
// PostgREST-backed implementation over the opted-in student's snapshot and
// the pooled course tables replaces it in Phase 1.
//
// Everything a tool returns is plain text, because Claude documents support
// for text and image results only. Long material is paged with a "call again
// with page=N+1" line instead of a link the model would have to fetch, and
// any single result is cut at 120,000 characters, under the roughly 150,000
// that claude.ai and Desktop accept. Execution errors are results with
// `isError: true`; nothing here throws at the protocol.
//
// The caller is whoever the bearer check in `mcp/index.ts` put in
// `ctx.http.authInfo.extra`. Nothing is captured across requests: the
// factory builds a server per request and each tool reads the principal
// from its own call.
import { McpServer } from "npm:@modelcontextprotocol/server@2.4.0";
import { z } from "npm:zod@^4.3.6";
import { DraftLimitError, InvalidBase64Error, MAX_OPEN_DRAFTS } from "./agentDrafts.ts";
import {
  type BeganUpload,
  type BeginInput,
  MemoryUploadStore,
  SHA256_PATTERN,
  sha256Hex,
  UploadError,
  UploadService,
} from "./agentUploads.ts";

// ---------------------------------------------------------------------------
// Entry types: strings and nulls, dates as ISO strings.

export interface CourseEntry {
  code: string;
  name: string;
  canvasId: string;
}

export interface WorkEntry {
  id: string;
  course: string;
  title: string;
  kind: string;
  dueAt: string | null;
  done: boolean;
  noSubmission: boolean;
  url: string | null;
  source: string;
}

export interface FactEntry {
  id: string;
  course: string;
  kind: string;
  text: string;
  /** The work item the fact targets, when it targets one. */
  assignmentId: string | null;
  /** Unix seconds. */
  createdAt: number;
}

/** A file or page the assignment's description names. `text` is the pooled
 *  document's text when the course material holds it, else null. */
export interface AssignmentAttachment {
  name: string;
  url: string | null;
  documentId: string | null;
  text: string | null;
}

export interface AssignmentDetail {
  entry: WorkEntry;
  description: string;
  attachments: AssignmentAttachment[];
  facts: FactEntry[];
}

export interface SearchPage {
  items: { documentId: string; course: string; kind: string; title: string; excerpt: string; postedAt: string | null }[];
  page: number;
  hasMore: boolean;
}

export interface DocumentPage {
  items: { documentId: string; course: string; kind: string; title: string; text: string; postedAt: string | null; url: string | null }[];
  page: number;
  hasMore: boolean;
}

export interface DraftInput {
  assignmentId: string;
  kind: "text" | "url" | "file";
  body?: string;
  url?: string;
  fileBase64?: string;
  fileName?: string;
  mimeType?: string;
  note?: string;
}

export interface ProposedDraft {
  id: string;
  /** Present when a file was decoded: its size and how long the decode took. */
  bytes?: number;
  decodeMs?: number;
}

export interface UploadProgress {
  received: number;
  missing: number[];
}

export type WorkView = "todo" | "all" | "prev";

export interface ToolBackend {
  listCourses(userId: string): Promise<CourseEntry[]>;
  listWork(userId: string, view: WorkView, course?: string, now?: Date): Promise<WorkEntry[]>;
  getAssignment(userId: string, id: string): Promise<AssignmentDetail | null>;
  searchCourseMaterial(userId: string, query: string, course?: string, kind?: string, page?: number): Promise<SearchPage>;
  getFacts(userId: string, course?: string, since?: number): Promise<FactEntry[]>;
  getAnnouncements(userId: string, course?: string, days?: number, page?: number): Promise<DocumentPage>;
  getEdPosts(userId: string, course?: string, page?: number): Promise<DocumentPage>;
  proposeSubmission(userId: string, connectionId: string, clientName: string, draft: DraftInput): Promise<ProposedDraft>;
  draftStatus(userId: string, id: string): Promise<{ id: string; status: string } | null>;
  /** Chunked upload (agentUploads.ts). Refusals are `UploadError`s. */
  beginUpload(userId: string, connectionId: string, input: BeginInput): Promise<BeganUpload>;
  /** `bytes` already match `sha256`; the backend checks index, length and expiry. */
  appendChunk(userId: string, uploadId: string, index: number, bytes: Uint8Array, sha256: string): Promise<UploadProgress>;
  /** Assembles (or reads the staged object), verifies, and makes the draft as `proposeSubmission` would. */
  finishUpload(userId: string, connectionId: string, clientName: string, uploadId: string, note?: string): Promise<ProposedDraft>;
}

// ---------------------------------------------------------------------------
// Limits.

export const MISSING_FILES_NOTE =
  "Files that are not in the course material cannot be read through this connection; the student can open them in Canvas.";
export const MAX_RESULT_CHARS = 120_000;
export const MAX_BODY_CHARS = 100_000;
export const MAX_NOTE_CHARS = 2_000;
export const MAX_FILE_NAME_CHARS = 200;
export const MAX_FILE_BYTES = 1_572_864;

/** The exact decoded size of a base64 string, from its length alone, so a
 *  10 MB argument is refused without being decoded. Null when the length
 *  cannot be valid base64. */
export function decodedSizeOf(base64: string): number | null {
  const len = base64.length;
  if (len === 0 || len % 4 !== 0) return null;
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return (len / 4) * 3 - padding;
}

/** `decodeBase64` for a draft's file: a bad input is an `InvalidBase64Error`,
 *  so the tool can tell "the agent sent junk" from a storage failure (which
 *  must surface as an error, not as a wrong claim about the agent's input). */
export function decodeDraftBytes(base64: string): Uint8Array {
  try {
    return decodeBase64(base64);
  } catch {
    throw new InvalidBase64Error();
  }
}

/** Decodes base64 to bytes; `Uint8Array.fromBase64` where the runtime has it
 *  (Deno 2.9 does), `atob` otherwise. Throws on invalid input. */
export function decodeBase64(base64: string): Uint8Array {
  const native = (Uint8Array as unknown as { fromBase64?: (s: string) => Uint8Array }).fromBase64;
  if (native) return native.call(Uint8Array, base64);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// ---------------------------------------------------------------------------
// Fixture backend.

const DAY_MS = 86_400_000;

interface FixtureDocument {
  documentId: string;
  course: string;
  kind: "syllabus" | "announcement" | "ed";
  title: string;
  text: string;
  postedAt: string | null;
  url: string | null;
}

interface FixtureDraft {
  id: string;
  userId: string;
  connectionId: string;
  clientName: string;
  input: Omit<DraftInput, "fileBase64">;
  bytes: number | null;
  status: string;
}

function sameCourse(a: string, b: string): boolean {
  const squash = (s: string) => s.replace(/\s+/g, "").toLowerCase();
  return squash(a) === squash(b);
}

/** The dashboard's own rules in their simplest form: todo is not done and
 *  overdue or due within 48 hours, all is not done and due later or
 *  undated, prev is done. The real backend ports the dashboard's rules
 *  exactly; this is enough to test the tools. */
export function fixtureView(entry: WorkEntry, view: WorkView, now: Date): boolean {
  if (view === "prev") return entry.done;
  if (entry.done) return false;
  const due = entry.dueAt === null ? null : Date.parse(entry.dueAt);
  const soon = due !== null && due <= now.getTime() + 2 * DAY_MS;
  if (view === "todo") return soon;
  return due === null || due > now.getTime();
}

export class FixtureToolBackend implements ToolBackend {
  readonly drafts = new Map<string, FixtureDraft>();
  private readonly courses: CourseEntry[] = [
    { code: "PHYS 0151", name: "Mechanics and Waves", canvasId: "1001" },
    { code: "CIS 2400", name: "Machine Programming", canvasId: "1002" },
  ];
  private readonly work: WorkEntry[];
  private readonly documents: FixtureDocument[];
  private readonly facts: FactEntry[];

  /** Dates in the fixture are offsets from `anchor`, so a test that fixes
   *  `now` and passes the same value here sees the same world every run. */
  readonly uploadStore: MemoryUploadStore = new MemoryUploadStore();
  private readonly uploads: UploadService;

  constructor(private readonly anchor: Date = new Date(), private readonly pageSize = 10, now: () => Date = () => new Date()) {
    this.uploads = new UploadService(this.uploadStore, now);
    const at = (days: number) => new Date(anchor.getTime() + days * DAY_MS).toISOString();
    this.work = [
      { id: "asg-phys-hw4", course: "PHYS 0151", title: "Homework 4", kind: "assignment", dueAt: at(1), done: false, noSubmission: false, url: "https://canvas.example/courses/1001/assignments/1", source: "canvas" },
      { id: "asg-cis-proj1", course: "CIS 2400", title: "Project 1", kind: "assignment", dueAt: at(-1), done: false, noSubmission: false, url: "https://canvas.example/courses/1002/assignments/2", source: "canvas" },
      { id: "asg-phys-lab5", course: "PHYS 0151", title: "Lab 5 report", kind: "assignment", dueAt: at(10), done: false, noSubmission: false, url: "https://canvas.example/courses/1001/assignments/3", source: "canvas" },
      { id: "asg-cis-read12", course: "CIS 2400", title: "Lecture 12 reading", kind: "reading", dueAt: at(5), done: false, noSubmission: true, url: null, source: "syllabus" },
      { id: "asg-phys-hw3", course: "PHYS 0151", title: "Homework 3", kind: "assignment", dueAt: at(-5), done: true, noSubmission: false, url: "https://canvas.example/courses/1001/assignments/0", source: "canvas" },
    ];
    this.documents = [
      { documentId: "doc-phys-syllabus", course: "PHYS 0151", kind: "syllabus", title: "PHYS 0151 syllabus", text: "Grading: homework 30%, labs 20%, two midterms 15% each, final 20%. Late homework loses 10% per day. The lowest homework score is dropped.", postedAt: null, url: null },
      { documentId: "doc-cis-announce", course: "CIS 2400", kind: "announcement", title: "Project 1 extension", text: "Project 1 is now due Friday at noon. Office hours move to the Levine 307 lab this week.", postedAt: at(-2), url: "https://canvas.example/courses/1002/discussion_topics/9" },
      { documentId: "doc-phys-ed", course: "PHYS 0151", kind: "ed", title: "Question about Homework 4 problem 2", text: "Staff answer: use conservation of energy, not momentum, for problem 2. Friction is negligible on the ramp.", postedAt: at(-1), url: null },
    ];
    this.facts = [
      { id: "fact-1", course: "PHYS 0151", kind: "deadline", text: "Homework 4 is due one day before the lab.", assignmentId: "asg-phys-hw4", createdAt: Math.floor(anchor.getTime() / 1000) - 3600 },
      { id: "fact-2", course: "CIS 2400", kind: "policy", text: "Project 1 may be submitted up to two days late with a 20% penalty.", assignmentId: "asg-cis-proj1", createdAt: Math.floor(anchor.getTime() / 1000) - 7200 },
    ];
  }

  listCourses(_userId: string): Promise<CourseEntry[]> {
    return Promise.resolve(this.courses.map((c) => ({ ...c })));
  }

  listWork(_userId: string, view: WorkView, course?: string, now: Date = this.anchor): Promise<WorkEntry[]> {
    return Promise.resolve(
      this.work
        .filter((w) => (course ? sameCourse(w.course, course) : true) && fixtureView(w, view, now))
        .sort((a, b) => (a.dueAt ?? "9").localeCompare(b.dueAt ?? "9"))
        .map((w) => ({ ...w })),
    );
  }

  getAssignment(_userId: string, id: string): Promise<AssignmentDetail | null> {
    const entry = this.work.find((w) => w.id === id);
    if (!entry) return Promise.resolve(null);
    const attachments: AssignmentAttachment[] = entry.id === "asg-phys-hw4"
      ? [
        { name: "HW4 handout.pdf", url: "https://canvas.example/courses/1001/files/501", documentId: "doc-phys-hw4-handout", text: "Problem 2: a block slides down a frictionless ramp." },
        { name: "HW4 solutions.pdf", url: null, documentId: null, text: null },
      ]
      : [];
    return Promise.resolve({
      entry: { ...entry },
      description: `${entry.title} for ${entry.course}.`,
      attachments,
      facts: this.facts.filter((f) => f.assignmentId === id).map((f) => ({ ...f })),
    });
  }

  searchCourseMaterial(_userId: string, query: string, course?: string, kind?: string, page = 1): Promise<SearchPage> {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const hits = terms.length === 0
      ? []
      : this.documents.filter((d) => {
        if (course && !sameCourse(d.course, course)) return false;
        if (kind && d.kind !== kind) return false;
        const haystack = `${d.title} ${d.text}`.toLowerCase();
        return terms.every((t) => haystack.includes(t));
      });
    const start = (Math.max(1, page) - 1) * this.pageSize;
    const slice = hits.slice(start, start + this.pageSize);
    return Promise.resolve({
      items: slice.map((d) => ({
        documentId: d.documentId,
        course: d.course,
        kind: d.kind,
        title: d.title,
        excerpt: excerptAround(d.text, terms[0] ?? ""),
        postedAt: d.postedAt,
      })),
      page: Math.max(1, page),
      hasMore: start + this.pageSize < hits.length,
    });
  }

  getFacts(_userId: string, course?: string, since?: number): Promise<FactEntry[]> {
    return Promise.resolve(
      this.facts
        .filter((f) => (course ? sameCourse(f.course, course) : true) && (since === undefined || f.createdAt >= since))
        .map((f) => ({ ...f })),
    );
  }

  getAnnouncements(_userId: string, course?: string, days = 14, page = 1): Promise<DocumentPage> {
    const cutoff = this.anchor.getTime() - days * DAY_MS;
    return Promise.resolve(this.documentPage("announcement", course, page, (d) => d.postedAt !== null && Date.parse(d.postedAt) >= cutoff));
  }

  getEdPosts(_userId: string, course?: string, page = 1): Promise<DocumentPage> {
    return Promise.resolve(this.documentPage("ed", course, page, () => true));
  }

  async proposeSubmission(userId: string, connectionId: string, clientName: string, draft: DraftInput): Promise<ProposedDraft> {
    const open = [...this.drafts.values()].filter((d) => d.userId === userId && (d.status === "proposed" || d.status === "seen")).length;
    if (open >= MAX_OPEN_DRAFTS) throw new DraftLimitError();
    let bytes: number | undefined;
    let decodeMs: number | undefined;
    if (draft.fileBase64 !== undefined) {
      const started = performance.now();
      bytes = decodeDraftBytes(draft.fileBase64).byteLength;
      decodeMs = Math.round((performance.now() - started) * 100) / 100;
    }
    const { fileBase64: _dropped, ...input } = draft;
    const id = crypto.randomUUID();
    this.drafts.set(id, { id, userId, connectionId, clientName, input, bytes: bytes ?? null, status: "proposed" });
    return { id, bytes, decodeMs };
  }

  beginUpload(userId: string, connectionId: string, input: BeginInput): Promise<BeganUpload> {
    return this.uploads.begin(userId, connectionId, input);
  }

  appendChunk(userId: string, uploadId: string, index: number, bytes: Uint8Array, sha256: string): Promise<UploadProgress> {
    return this.uploads.append(userId, uploadId, index, bytes, sha256);
  }

  finishUpload(userId: string, connectionId: string, clientName: string, uploadId: string, note?: string): Promise<ProposedDraft> {
    return this.uploads.finish(userId, uploadId, (row, bytes) => {
      const open = [...this.drafts.values()].filter((d) => d.userId === userId && (d.status === "proposed" || d.status === "seen")).length;
      if (open >= MAX_OPEN_DRAFTS) throw new DraftLimitError();
      const id = crypto.randomUUID();
      this.drafts.set(id, {
        id,
        userId,
        connectionId,
        clientName,
        input: { assignmentId: row.assignmentId, kind: "file", fileName: row.fileName, mimeType: row.mimeType, note },
        bytes: bytes.byteLength,
        status: "proposed",
      });
      return Promise.resolve({ id, bytes: bytes.byteLength, decodeMs: 0 });
    });
  }

  draftStatus(userId: string, id: string): Promise<{ id: string; status: string } | null> {
    const draft = this.drafts.get(id);
    if (!draft || draft.userId !== userId) return Promise.resolve(null);
    return Promise.resolve({ id, status: draft.status });
  }

  private documentPage(kind: FixtureDocument["kind"], course: string | undefined, page: number, keep: (d: FixtureDocument) => boolean): DocumentPage {
    const hits = this.documents.filter((d) => d.kind === kind && (course ? sameCourse(d.course, course) : true) && keep(d));
    const p = Math.max(1, page);
    const start = (p - 1) * this.pageSize;
    return {
      items: hits.slice(start, start + this.pageSize).map(({ documentId, course, kind, title, text, postedAt, url }) => ({ documentId, course, kind, title, text, postedAt, url })),
      page: p,
      hasMore: start + this.pageSize < hits.length,
    };
  }
}

function excerptAround(text: string, term: string, radius = 80): string {
  const at = term ? text.toLowerCase().indexOf(term) : -1;
  if (at < 0) return text.slice(0, radius * 2);
  const from = Math.max(0, at - radius);
  const to = Math.min(text.length, at + term.length + radius);
  return `${from > 0 ? "…" : ""}${text.slice(from, to)}${to < text.length ? "…" : ""}`;
}

// ---------------------------------------------------------------------------
// Registry.

export interface ToolOptions {
  /** What `destructiveHint` to publish on `propose_submission`: absent,
   *  false or true. Phase 0 measures what Claude shows for each. */
  proposeHint: "none" | "false" | "true";
  now: () => Date;
}

interface Principal {
  userId: string;
  connectionId: string;
  clientName: string;
  scopes: string[];
}

// deno-lint-ignore no-explicit-any
function principalOf(ctx: any): Principal | null {
  const info = ctx?.http?.authInfo;
  const extra = info?.extra;
  if (!extra || typeof extra.userId !== "string" || typeof extra.connectionId !== "string") return null;
  return {
    userId: extra.userId,
    connectionId: extra.connectionId,
    clientName: typeof extra.clientName === "string" ? extra.clientName : "agent",
    scopes: Array.isArray(info.scopes) ? info.scopes : [],
  };
}

function text(value: string) {
  return { content: [{ type: "text" as const, text: capped(value) }] };
}

function failure(value: string) {
  return { content: [{ type: "text" as const, text: value }], isError: true as const };
}

function capped(value: string): string {
  if (value.length <= MAX_RESULT_CHARS) return value;
  return `${value.slice(0, MAX_RESULT_CHARS)}\n[truncated; narrow with course or page]`;
}

function workLine(w: WorkEntry): string {
  const state = w.noSubmission ? "nothing to submit" : w.done ? "done" : "outstanding";
  return [w.id, w.course, w.title, `due ${w.dueAt ?? "no date"}`, state, w.kind].join(" | ");
}

function pagedFooter(page: number, hasMore: boolean): string {
  return hasMore ? `\npage ${page} of more; call again with page=${page + 1}` : "";
}

// Every read tool states all three hints as explicit booleans. Claude's
// directory only asks for `readOnlyHint` on a read tool, but OpenAI's app
// submission guidelines (read 2026-11-10) require `readOnlyHint`,
// `destructiveHint` and `openWorldHint` on every tool, and an absent hint
// is not the same as `false` to a client that defaults to caution.
// `openWorldHint: false` because these tools read Smooth's own pooled data
// and the student's snapshot, never the open web or Canvas.
const readOnly = { readOnlyHint: true, destructiveHint: false, openWorldHint: false } as const;

export function registerTools(server: McpServer, backend: ToolBackend, options: ToolOptions): void {
  const noAuth = () => failure("not signed in");

  server.registerTool("list_courses", {
    title: "List courses",
    description: "Returns the student's courses, one per line: course code, course name and Canvas course id.",
    annotations: readOnly,
  }, async (ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const courses = await backend.listCourses(who.userId);
    if (courses.length === 0) return text("no courses");
    return text(["code · name · canvas id", ...courses.map((c) => `${c.code} · ${c.name} · ${c.canvasId}`)].join("\n"));
  });

  server.registerTool("list_work", {
    title: "List work",
    description:
      "Returns the student's work items, one per line: id, course, title, due date, state and kind. " +
      "View todo is overdue plus the next two days, all is future work through the term, prev is finished work. " +
      "Course is a course code such as PHYS 0151.",
    inputSchema: z.object({
      view: z.enum(["todo", "all", "prev"]).default("todo"),
      course: z.string().optional(),
    }),
    annotations: readOnly,
  }, async ({ view, course }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const items = await backend.listWork(who.userId, view, course, options.now());
    if (items.length === 0) return text(`no ${view} work`);
    return text(items.map(workLine).join("\n"));
  });

  server.registerTool("get_assignment", {
    title: "Get assignment",
    description: "Returns one work item by id: course, title, due date, state, kind, link, its description, and the course facts that apply to it.",
    inputSchema: z.object({ id: z.string() }),
    annotations: readOnly,
  }, async ({ id }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const found = await backend.getAssignment(who.userId, id);
    if (!found) return failure("no such assignment");
    const lines = [workLine(found.entry), `link: ${found.entry.url ?? "none"}`, `source: ${found.entry.source}`];
    if (found.description) lines.push("", found.description);
    const attachments = found.attachments ?? [];
    if (attachments.length > 0) {
      lines.push("", "attachments:");
      for (const a of attachments) {
        const where = a.text !== null ? `in the course material, ${a.text.length} chars` : "not in the course material";
        lines.push(`- ${a.name} — ${a.url ?? "no link"}; ${where}`);
      }
      for (const a of attachments) if (a.text !== null) lines.push("", `--- ${a.name} ---`, a.text);
    }
    if (found.facts.length > 0) lines.push("", "facts:", ...found.facts.map((f) => `- (${f.kind}) ${f.text}`));
    if (attachments.some((a) => a.text === null)) lines.push("", MISSING_FILES_NOTE);
    return text(lines.join("\n"));
  });

  server.registerTool("search_course_material", {
    title: "Search course material",
    description:
      "Returns excerpts from the student's pooled course material (syllabi, pages, assignments, modules, announcements, Ed posts, files) that contain every word of the query, " +
      "with document id, course, kind, title and posting date. Course is a course code; kind is one of home, syllabus, assignment, module, page, announcement, ed, website, file.",
    inputSchema: z.object({
      query: z.string(),
      course: z.string().optional(),
      kind: z.string().optional(),
      page: z.number().int().min(1).optional(),
    }),
    annotations: readOnly,
  }, async ({ query, course, kind, page }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const result = await backend.searchCourseMaterial(who.userId, query, course, kind, page);
    if (result.items.length === 0) return text("no matches");
    const body = result.items.map((i) =>
      `${i.documentId} | ${i.course} | ${i.kind} | ${i.title} | ${i.postedAt ?? "no date"}\n${i.excerpt}`
    ).join("\n\n");
    return text(body + pagedFooter(result.page, result.hasMore));
  });

  server.registerTool("get_facts", {
    title: "Get course facts",
    description:
      "Returns facts extracted from the course material, one per line: id, course, kind, text and the work item it targets. " +
      "Since is a Unix time in seconds and limits the list to facts recorded at or after it.",
    inputSchema: z.object({ course: z.string().optional(), since: z.number().int().optional() }),
    annotations: readOnly,
  }, async ({ course, since }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const facts = await backend.getFacts(who.userId, course, since);
    if (facts.length === 0) return text("no facts");
    return text(facts.map((f) => `${f.id} | ${f.course} | ${f.kind} | ${f.text} | ${f.assignmentId ?? "course-wide"}`).join("\n"));
  });

  server.registerTool("get_announcements", {
    title: "Get announcements",
    description: "Returns the full text of course announcements posted in the last `days` days (default 14), newest first within each page.",
    inputSchema: z.object({
      course: z.string().optional(),
      days: z.number().int().min(1).max(365).default(14),
      page: z.number().int().min(1).optional(),
    }),
    annotations: readOnly,
  }, async ({ course, days, page }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    return documentResult(await backend.getAnnouncements(who.userId, course, days, page), "no announcements");
  });

  server.registerTool("get_ed_posts", {
    title: "Get Ed posts",
    description: "Returns the full text of the course Ed posts the student's phone has kept, with title, course and posting date.",
    inputSchema: z.object({ course: z.string().optional(), page: z.number().int().min(1).optional() }),
    annotations: readOnly,
  }, async ({ course, page }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    return documentResult(await backend.getEdPosts(who.userId, course, page), "no Ed posts");
  });

  const hint = options.proposeHint === "none" ? {} : { destructiveHint: options.proposeHint === "true" };
  server.registerTool("propose_submission", {
    title: "Propose a submission",
    description:
      "Creates a draft for the student to review and submit from Smooth. Nothing is submitted to Canvas by this tool. " +
      "Files: file_base64 is for files under about 24 KB; larger files (up to 1.5 MB) go through begin_file_upload, append_file_chunk and finish_file_upload.",
    inputSchema: z.object({
      assignment_id: z.string(),
      kind: z.enum(["text", "url", "file"]),
      body: z.string().optional(),
      url: z.string().optional(),
      file_base64: z.string().optional(),
      file_name: z.string().optional(),
      mime_type: z.string().optional(),
      note: z.string().optional(),
    }),
    annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false, ...hint },
  }, async (args, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    if (!who.scopes.includes("draft")) return failure("this connection cannot propose drafts");

    if (args.note !== undefined && args.note.length > MAX_NOTE_CHARS) return failure(`note is longer than ${MAX_NOTE_CHARS} characters`);
    const draft: DraftInput = { assignmentId: args.assignment_id, kind: args.kind, note: args.note };

    if (args.kind === "text") {
      if (!args.body) return failure("kind text needs body");
      if (args.body.length > MAX_BODY_CHARS) return failure(`body is longer than ${MAX_BODY_CHARS} characters`);
      draft.body = args.body;
    } else if (args.kind === "url") {
      let parsed: URL | null = null;
      try {
        parsed = args.url ? new URL(args.url) : null;
      } catch { /* refused below */ }
      if (!parsed || parsed.protocol !== "https:") return failure("kind url needs an https url");
      draft.url = parsed.toString();
    } else {
      const name = args.file_name;
      if (!args.file_base64 || !name || !args.mime_type) return failure("kind file needs file_base64, file_name and mime_type");
      if (name.length > MAX_FILE_NAME_CHARS || /[\\/]/.test(name)) {
        return failure(`file_name must be at most ${MAX_FILE_NAME_CHARS} characters with no path separators`);
      }
      // Size from the length alone: an oversized argument is refused
      // without ever being decoded.
      const size = decodedSizeOf(args.file_base64);
      if (size === null) return failure("file_base64 is not valid base64");
      if (size > MAX_FILE_BYTES) return failure(`file is larger than ${MAX_FILE_BYTES} bytes decoded`);
      draft.fileBase64 = args.file_base64;
      draft.fileName = name;
      draft.mimeType = args.mime_type;
    }

    if (!await backend.getAssignment(who.userId, args.assignment_id)) return failure("no such assignment");

    let made: ProposedDraft;
    try {
      made = await backend.proposeSubmission(who.userId, who.connectionId, who.clientName, draft);
    } catch (err) {
      if (err instanceof DraftLimitError) return failure(err.message);
      if (err instanceof InvalidBase64Error) return failure("file_base64 is not valid base64");
      throw err;
    }
    if (made.bytes !== undefined) return text(`draft ${made.id} proposed (${made.bytes} bytes decoded in ${made.decodeMs ?? 0} ms)`);
    return text(`draft ${made.id} proposed`);
  });

  const uploadAnnotations = { readOnlyHint: false, idempotentHint: false, openWorldHint: false, ...hint };
  const draftScope = (who: Principal) => who.scopes.includes("draft") ? null : failure("this connection cannot propose drafts");
  const uploadFailure = (err: unknown) => {
    if (err instanceof UploadError || err instanceof DraftLimitError) return failure(err.message);
    throw err;
  };

  server.registerTool("begin_file_upload", {
    title: "Begin a file upload",
    description:
      "Starts a chunked upload of a file for a draft (for files over about 24 KB; at most 1.5 MB). Give the assignment id, file name, mime type, exact size in bytes and the sha256 (hex) of the whole file. " +
      "Returns an upload id, the chunk size (16384 bytes) and the chunk count, and for clients with a shell a signed URL to PUT the raw bytes to. " +
      "Then either PUT the file to that URL, or send each chunk with append_file_chunk; then call finish_file_upload. Nothing is submitted to Canvas. An unfinished upload expires after 30 minutes; a new begin replaces it.",
    inputSchema: z.object({
      assignment_id: z.string(),
      file_name: z.string(),
      mime_type: z.string(),
      total_bytes: z.number().int(),
      sha256: z.string(),
    }),
    annotations: uploadAnnotations,
  }, async (args, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const denied = draftScope(who);
    if (denied) return denied;
    const name = args.file_name;
    if (!name || name.length > MAX_FILE_NAME_CHARS || /[\\/]/.test(name)) {
      return failure(`file_name must be at most ${MAX_FILE_NAME_CHARS} characters with no path separators`);
    }
    if (!args.mime_type) return failure("mime_type is required");
    if (args.total_bytes < 1) return failure("total_bytes must be at least 1");
    if (args.total_bytes > MAX_FILE_BYTES) return failure(`file is larger than ${MAX_FILE_BYTES} bytes`);
    if (!SHA256_PATTERN.test(args.sha256)) return failure("sha256 must be 64 hex characters");
    if (!await backend.getAssignment(who.userId, args.assignment_id)) return failure("no such assignment");
    try {
      const began = await backend.beginUpload(who.userId, who.connectionId, {
        assignmentId: args.assignment_id,
        fileName: name,
        mimeType: args.mime_type,
        totalBytes: args.total_bytes,
        sha256: args.sha256,
      });
      const result: Record<string, unknown> = { upload_id: began.uploadId, chunk_bytes: began.chunkBytes, chunks: began.chunks };
      const lines: string[] = [];
      if (began.uploadUrl) {
        result.upload_url = began.uploadUrl;
        result.upload_method = "PUT";
        result.upload_headers = { "content-type": args.mime_type, "x-upsert": "false" };
        lines.push(
          `fastest: PUT the raw bytes to ${began.uploadUrl} (e.g. \`curl -X PUT --upload-file <path> -H 'Content-Type: ${args.mime_type}' '${began.uploadUrl}'\`), then call finish_file_upload; otherwise send chunks with append_file_chunk`,
        );
      } else {
        lines.push("send chunks with append_file_chunk, then call finish_file_upload");
      }
      return text([JSON.stringify(result), ...lines].join("\n"));
    } catch (err) {
      return uploadFailure(err);
    }
  });

  server.registerTool("append_file_chunk", {
    title: "Append a file chunk",
    description:
      "Sends one chunk of an upload started with begin_file_upload: index (from 0), the chunk as base64 (16384 bytes, the last may be shorter) and the sha256 (hex) of the chunk's bytes. " +
      "A chunk whose checksum does not match is refused; resend it. Sending an index again replaces it. Returns how many chunks are received and which indexes are still missing.",
    inputSchema: z.object({
      upload_id: z.string(),
      index: z.number().int(),
      data_base64: z.string(),
      sha256: z.string(),
    }),
    annotations: uploadAnnotations,
  }, async (args, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const denied = draftScope(who);
    if (denied) return denied;
    if (!SHA256_PATTERN.test(args.sha256)) return failure("sha256 must be 64 hex characters");
    const size = decodedSizeOf(args.data_base64);
    if (size === null) return failure("data_base64 is not valid base64");
    if (size > 16_384) return failure("a chunk is at most 16384 bytes");
    let bytes: Uint8Array;
    try {
      bytes = decodeBase64(args.data_base64);
    } catch {
      return failure("data_base64 is not valid base64");
    }
    if (await sha256Hex(bytes) !== args.sha256.toLowerCase()) return failure(`chunk ${args.index} checksum mismatch; resend it`);
    try {
      const progress = await backend.appendChunk(who.userId, args.upload_id, args.index, bytes, args.sha256);
      return text(JSON.stringify(progress));
    } catch (err) {
      return uploadFailure(err);
    }
  });

  server.registerTool("finish_file_upload", {
    title: "Finish a file upload",
    description:
      "Completes an upload: uses the file PUT to the signed URL if there is one, else assembles the chunks in order, checks the size and whole-file sha256, and creates the draft for the student to review in Smooth, as propose_submission would. " +
      "If something is missing or does not match it says what, and the upload is kept so you can fix it and call again. Nothing is submitted to Canvas.",
    inputSchema: z.object({ upload_id: z.string(), note: z.string().optional() }),
    annotations: uploadAnnotations,
  }, async (args, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const denied = draftScope(who);
    if (denied) return denied;
    if (args.note !== undefined && args.note.length > MAX_NOTE_CHARS) return failure(`note is longer than ${MAX_NOTE_CHARS} characters`);
    try {
      const made = await backend.finishUpload(who.userId, who.connectionId, who.clientName, args.upload_id, args.note);
      if (made.bytes !== undefined) return text(`draft ${made.id} proposed (${made.bytes} bytes decoded in ${made.decodeMs ?? 0} ms)`);
      return text(`draft ${made.id} proposed`);
    } catch (err) {
      return uploadFailure(err);
    }
  });

  server.registerTool("draft_status", {
    title: "Draft status",
    description: "Returns the state of a draft made by propose_submission: proposed, seen, submitted, declined or failed.",
    inputSchema: z.object({ id: z.string() }),
    annotations: readOnly,
  }, async ({ id }, ctx) => {
    const who = principalOf(ctx);
    if (!who) return noAuth();
    const found = await backend.draftStatus(who.userId, id);
    if (!found) return failure("no such draft");
    return text(`draft ${found.id}: ${found.status}`);
  });
}

function documentResult(page: DocumentPage, empty: string) {
  if (page.items.length === 0) return text(empty);
  const body = page.items.map((i) =>
    `${i.documentId} | ${i.course} | ${i.title} | ${i.postedAt ?? "no date"}${i.url ? ` | ${i.url}` : ""}\n${i.text}`
  ).join("\n\n");
  // Footer first in the budget: a cut must not remove the instruction to page.
  const footer = pagedFooter(page.page, page.hasMore);
  if (body.length + footer.length <= MAX_RESULT_CHARS) return text(body + footer);
  return text(`${body.slice(0, MAX_RESULT_CHARS - 60)}\n[truncated; narrow with course or page]`);
}
