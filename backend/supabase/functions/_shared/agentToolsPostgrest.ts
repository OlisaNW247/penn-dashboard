// The production `ToolBackend`: the student's snapshot (`agent_snapshots`,
// through `AgentStore`) for their work list and course list, and the pooled
// tables for course material. Rules it keeps, matching `FixtureToolBackend`:
//
// - The service role bypasses RLS, so `is_enrolled` (PROTOCOL.md) is applied
//   here: every pooled read is `course_id in (the caller's enrolled ids)`,
//   and a course the caller names that they are not enrolled in resolves to
//   nothing, not an error. The only column read from `enrollments` is
//   `course_id`.
// - Live documents only (`gone_at is null`) with the window kinds' 120-day
//   age-out (`windowAgeOutFilter`) as in `pagedLiveRows`.
// - `collector` is never selected.
// - Text is cut per item; the tool layer cuts the whole result.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import type { AgentStore } from "./agentStore.ts";
import { decodeDraftBytes } from "./agentTools.ts";
import type {
  AssignmentAttachment,
  AssignmentDetail,
  CourseEntry,
  DocumentPage,
  DraftInput,
  FactEntry,
  ProposedDraft,
  SearchPage,
  ToolBackend,
  WorkEntry,
  WorkView,
} from "./agentTools.ts";
import { type DraftStore, DraftLimitError, MAX_OPEN_DRAFTS, PostgrestDraftStore } from "./agentDrafts.ts";
import { type BeganUpload, type BeginInput, PostgrestUploadStore, UploadService, type UploadStore } from "./agentUploads.ts";
import { sameCourse, type WorkItem, workView } from "./agentSnapshot.ts";
import { selectEnrolledCourseIDs } from "./db.ts";
import { factsResponse, type FactRowWithDocument, isWindowKind, windowAgeOutFilter } from "./manifest.ts";

export const PAGE_SIZE = 10;
export const EXCERPT_CHARS = 600;
export const ASSIGNMENT_TEXT_CHARS = 12_000;
export const ATTACHMENT_TEXT_CHARS = 12_000;
export const MAX_ATTACHMENTS = 4;
export const POST_TEXT_CHARS = 8_000;
export const MAX_FACTS = 200;

const DAY_MS = 86_400_000;

interface CourseLookup {
  course_id: string;
  code: string;
  name: string;
}

interface DocumentRow {
  id: string;
  course_id: string;
  course_code: string;
  kind: string;
  title: string;
  text: string;
  url: string | null;
  posted_at: string | null;
  updated_at: string | null;
  fetched_at: string;
}

const DOCUMENT_COLUMNS = "id, course_id, course_code, kind, title, text, url, posted_at, updated_at, fetched_at";

export class PostgrestToolBackend implements ToolBackend {
  private readonly client: SupabaseClient;
  private readonly store: AgentStore;
  private readonly now: () => Date;
  private readonly drafts: DraftStore;
  private readonly uploads: UploadService;

  constructor(options: { client: SupabaseClient; store: AgentStore; now?: () => Date; drafts?: DraftStore; uploads?: UploadStore }) {
    this.client = options.client;
    this.store = options.store;
    this.drafts = options.drafts ?? new PostgrestDraftStore(options.client);
    this.now = options.now ?? (() => new Date());
    this.uploads = new UploadService(options.uploads ?? new PostgrestUploadStore(options.client), this.now);
  }

  async listCourses(userId: string): Promise<CourseEntry[]> {
    const snapshot = await this.store.selectSnapshot(userId);
    if (snapshot) {
      return (snapshot.courses as Array<{ courseID: string; code: string; name: string }>).map((c) => ({
        code: c.code,
        name: c.name,
        canvasId: c.courseID,
      }));
    }
    const { ids } = await this.scope(userId, {});
    return [...(await this.courseRows(ids)).values()].map((c) => ({ code: c.code, name: c.name, canvasId: c.course_id }));
  }

  async listWork(userId: string, view: WorkView, course?: string, now: Date = this.now()): Promise<WorkEntry[]> {
    const snapshot = await this.store.selectSnapshot(userId);
    if (!snapshot) return [];
    return workView(allItems(snapshot.workList, snapshot.manual), view, now, course);
  }

  async getAssignment(userId: string, id: string): Promise<AssignmentDetail | null> {
    const snapshot = await this.store.selectSnapshot(userId);
    if (!snapshot) return null;
    const item = allItems(snapshot.workList, snapshot.manual).find((i) => i.id === id);
    if (!item) return null;
    const entry: WorkEntry = {
      id: item.id,
      course: item.course,
      title: item.title,
      kind: item.kind,
      dueAt: item.dueAt,
      done: item.done,
      noSubmission: item.noSubmission,
      url: item.url,
      source: item.source,
    };
    const bare = { entry, description: "", attachments: [] as AssignmentAttachment[], facts: [] as FactEntry[] };

    const canvasID = canvasAssignmentID(item);
    if (canvasID === null) return bare;

    // The course: the item's own course id, else the link's, else every
    // enrolled site with the item's course code (a code can have two sites,
    // lecture and lab).
    const scope = await this.scope(userId, {});
    const rows = await this.courseRows(scope.ids);
    const named = item.canvasCourseID ?? (item.url ? /\/courses\/(\d+)/.exec(item.url)?.[1] : undefined);
    const ids = scope.ids.filter((c) => (named ? c === named : sameCourse(rows.get(c)?.code ?? "", item.course)));
    if (ids.length === 0) return bare;

    const doc = await this.client
      .from("course_documents")
      .select("text")
      .in("course_id", ids)
      .eq("kind", "assignment")
      .eq("source_id", canvasID)
      .is("gone_at", null)
      .limit(1);
    if (doc.error) throw doc.error;
    const full = String((doc.data?.[0] as { text?: string } | undefined)?.text ?? "");
    const description = full.slice(0, ASSIGNMENT_TEXT_CHARS);

    // Attachments are looked up in every enrolled site of the same course
    // code, since a file is often pooled under the other site.
    const siblings = scope.ids.filter((c) => sameCourse(rows.get(c)?.code ?? "", item.course));
    const lookIn = siblings.length > 0 ? siblings : ids;
    const attachments: AssignmentAttachment[] = [];
    for (const ref of attachmentRefs(full)) {
      attachments.push(await this.findAttachment(lookIn, ref));
    }

    const facts = await this.factRows(ids, { target: canvasID });
    return { entry, description, attachments, facts: facts.map((f) => factEntry(f, rows)) };
  }

  private async findAttachment(ids: string[], ref: AttachmentRef): Promise<AssignmentAttachment> {
    let q = this.client
      .from("course_documents")
      .select("id, title, url, text")
      .in("course_id", ids)
      .is("gone_at", null);
    if (ref.fileID) q = q.ilike("url", `%/files/${ref.fileID}%`);
    else if (ref.pageSlug) q = q.ilike("url", `%/pages/${likeEscape(ref.pageSlug)}%`);
    else q = q.eq("kind", "file").ilike("title", likeEscape(ref.name));
    const { data, error } = await q.limit(1);
    if (error) throw error;
    const hit = (data?.[0] ?? null) as { id: string; title: string; url: string | null; text: string } | null;
    if (!hit) return { name: ref.name, url: ref.url, documentId: null, text: null };
    return {
      name: ref.fileID || ref.pageSlug ? (hit.title || ref.name) : ref.name,
      url: (hit.url ?? ref.url)?.replace(/[?#].*$/, "") ?? null,
      documentId: hit.id,
      text: String(hit.text ?? "").slice(0, ATTACHMENT_TEXT_CHARS),
    };
  }

  async searchCourseMaterial(userId: string, query: string, course?: string, kind?: string, page = 1): Promise<SearchPage> {
    const p = Math.max(1, page);
    const { ids } = await this.scope(userId, { course });
    if (ids.length === 0 || query.trim() === "") return { items: [], page: p, hasMore: false };
    let q = this.client
      .from("course_documents")
      .select(DOCUMENT_COLUMNS)
      .textSearch("text", query, { type: "websearch", config: "english" })
      .in("course_id", ids)
      .is("gone_at", null)
      .or(windowAgeOutFilter(this.now()));
    if (kind) q = q.eq("kind", kind);
    const { data, error } = await q
      .order("updated_at", { ascending: false, nullsFirst: false })
      .range((p - 1) * PAGE_SIZE, p * PAGE_SIZE); // one extra row answers hasMore
    if (error) throw error;
    const rows = (data ?? []) as unknown as DocumentRow[];
    const word = firstQueryWord(query);
    return {
      items: rows.slice(0, PAGE_SIZE).map((d) => ({
        documentId: d.id,
        course: d.course_code,
        kind: d.kind,
        title: d.title,
        excerpt: excerptAround(d.text, word),
        postedAt: postedOf(d),
      })),
      page: p,
      hasMore: rows.length > PAGE_SIZE,
    };
  }

  /** `since` is Unix seconds against `posted_at` (when the post was made,
   *  copied onto the fact); a fact with no `posted_at` is always included,
   *  because dropping it would hide it from an agent that asks "since
   *  yesterday". Facts whose document has gone or changed are dropped, as
   *  the manifest does (`factsResponse`). */
  async getFacts(userId: string, course?: string, since?: number): Promise<FactEntry[]> {
    const { ids } = await this.scope(userId, { course });
    if (ids.length === 0) return [];
    const rows = await this.factRows(ids, { since });
    return await this.withCodes(rows);
  }

  getAnnouncements(userId: string, course?: string, days = 14, page = 1): Promise<DocumentPage> {
    return this.documentPage(userId, "announcement", course, page, days);
  }

  getEdPosts(userId: string, course?: string, page = 1): Promise<DocumentPage> {
    return this.documentPage(userId, "ed", course, page);
  }

  /** Writes a draft for the student to review in Smooth. The open-draft cap
   *  is a count then an insert, so two simultaneous proposals can overshoot
   *  it by one; the cap is about a runaway agent, not an exact quota. The
   *  assignment-exists check is the tool's, before this. A file is decoded
   *  here (its size was already judged from the base64 length), uploaded to
   *  private Storage, and only then is the row inserted; a failed insert
   *  removes the object. */
  async proposeSubmission(userId: string, connectionId: string, clientName: string, draft: DraftInput): Promise<ProposedDraft> {
    if (await this.drafts.countOpen(userId) >= MAX_OPEN_DRAFTS) throw new DraftLimitError();
    let file: { bytes: Uint8Array; name: string; mimeType?: string } | undefined;
    let decodeMs: number | undefined;
    if (draft.kind === "file" && draft.fileBase64 !== undefined) {
      const started = performance.now();
      const bytes = decodeDraftBytes(draft.fileBase64);
      decodeMs = Math.round((performance.now() - started) * 100) / 100;
      file = { bytes, name: draft.fileName ?? "file", mimeType: draft.mimeType };
    }
    return await this.insertDraft(userId, connectionId, clientName, draft, file, decodeMs);
  }

  private async insertDraft(
    userId: string,
    connectionId: string,
    clientName: string,
    draft: Omit<DraftInput, "fileBase64">,
    file: { bytes: Uint8Array; name: string; mimeType?: string } | undefined,
    decodeMs: number | undefined,
  ): Promise<ProposedDraft> {
    const id = await this.drafts.create(userId, {
      assignmentId: draft.assignmentId,
      connectionId,
      clientName,
      kind: draft.kind,
      body: draft.body,
      url: draft.url,
      note: draft.note,
      file,
    });
    return { id, bytes: file?.bytes.byteLength, decodeMs };
  }

  beginUpload(userId: string, connectionId: string, input: BeginInput): Promise<BeganUpload> {
    return this.uploads.begin(userId, connectionId, input);
  }

  appendChunk(userId: string, uploadId: string, index: number, bytes: Uint8Array, sha256: string) {
    return this.uploads.append(userId, uploadId, index, bytes, sha256);
  }

  /** The same row, object path, cap and result as `proposeSubmission` for a file. */
  finishUpload(userId: string, connectionId: string, clientName: string, uploadId: string, note?: string): Promise<ProposedDraft> {
    return this.uploads.finish(userId, uploadId, async (row, bytes) => {
      if (await this.drafts.countOpen(userId) >= MAX_OPEN_DRAFTS) throw new DraftLimitError();
      return await this.insertDraft(
        userId,
        connectionId,
        clientName,
        { assignmentId: row.assignmentId, kind: "file", note },
        { bytes, name: row.fileName, mimeType: row.mimeType },
        0,
      );
    });
  }

  draftStatus(userId: string, id: string): Promise<{ id: string; status: string } | null> {
    return this.drafts.status(userId, id);
  }

  // -------------------------------------------------------------------------

  private async documentPage(
    userId: string,
    kind: "announcement" | "ed",
    course: string | undefined,
    page: number,
    days?: number,
  ): Promise<DocumentPage> {
    const p = Math.max(1, page);
    const { ids } = await this.scope(userId, { course });
    if (ids.length === 0) return { items: [], page: p, hasMore: false };
    const now = this.now();
    let q = this.client
      .from("course_documents")
      .select(DOCUMENT_COLUMNS)
      .in("course_id", ids)
      .eq("kind", kind)
      .is("gone_at", null)
      .or(windowAgeOutFilter(now));
    if (days !== undefined) {
      // Posted within `days`, by the first date the row has.
      const cutoff = new Date(now.getTime() - days * DAY_MS).toISOString();
      q = q.or(`posted_at.gte.${cutoff},and(posted_at.is.null,updated_at.gte.${cutoff}),and(posted_at.is.null,updated_at.is.null,fetched_at.gte.${cutoff})`);
    }
    // PostgREST cannot order by coalesce(); posted_at then updated_at is the
    // same order for every row that has a posted_at.
    const { data, error } = await q
      .order("posted_at", { ascending: false, nullsFirst: false })
      .order("updated_at", { ascending: false, nullsFirst: false })
      .range((p - 1) * PAGE_SIZE, p * PAGE_SIZE);
    if (error) throw error;
    const rows = (data ?? []) as unknown as DocumentRow[];
    return {
      items: rows.slice(0, PAGE_SIZE).map((d) => ({
        documentId: d.id,
        course: d.course_code,
        kind: d.kind,
        title: d.title,
        text: d.text.slice(0, POST_TEXT_CHARS),
        postedAt: postedOf(d),
        url: d.url,
      })),
      page: p,
      hasMore: rows.length > PAGE_SIZE,
    };
  }

  /** The caller's enrolled course ids (sorted), narrowed to one course when
   *  `course` is given (a code such as "PHYS 0151", or the Canvas course id).
   *  Never returns an id outside `enrollments`. */
  private async scope(userId: string, options: { course?: string }): Promise<{ ids: string[] }> {
    const enrolled = [...await selectEnrolledCourseIDs(this.client, userId)].sort();
    if (enrolled.length === 0 || !options.course) return { ids: enrolled };
    const wanted = options.course.trim();
    const rows = await this.courseRows(enrolled);
    return { ids: enrolled.filter((id) => id === wanted || sameCourse(rows.get(id)?.code ?? "", wanted)) };
  }

  private async courseRows(ids: string[]): Promise<Map<string, CourseLookup>> {
    if (ids.length === 0) return new Map();
    const { data, error } = await this.client.from("courses").select("course_id, code, name").in("course_id", ids);
    if (error) throw error;
    return new Map(((data ?? []) as CourseLookup[]).map((c) => [c.course_id, c]));
  }

  private async withCodes(rows: FactRow[]): Promise<FactEntry[]> {
    const codes = await this.courseRows([...new Set(rows.map((r) => r.course_id))]);
    return rows.map((r) => factEntry(r, codes));
  }

  private async factRows(ids: string[], filter: { target?: string; since?: number }): Promise<FactRow[]> {
    let q = this.client
      .from("course_facts")
      .select(
        "seq, course_id, document_id, content_hash, fact_type, target_source_id, title, due_at, kind, quote, confidence, posted_at, created_at, course_documents(content_hash, gone_at)",
      )
      .in("course_id", ids);
    if (filter.target !== undefined) q = q.eq("target_source_id", filter.target);
    if (filter.since !== undefined) {
      q = q.or(`posted_at.is.null,posted_at.gte.${new Date(filter.since * 1000).toISOString()}`);
    }
    const { data, error } = await q.order("seq", { ascending: true }).limit(MAX_FACTS);
    if (error) throw error;
    const raw = (data ?? []) as unknown as FactRow[];
    // Drop facts of a gone or since-edited document, as the manifest does.
    const live = new Set(factsResponse(raw, 0).facts.map((f) => f.seq));
    return raw.filter((r) => live.has(Number(r.seq)));
  }
}

type FactRow = FactRowWithDocument & { created_at: string };

function factEntry(row: FactRow, codes: Map<string, CourseLookup>): FactEntry {
  const stamp = Date.parse(row.posted_at ?? row.created_at);
  return {
    id: `fact-${row.seq}`,
    course: codes.get(row.course_id)?.code ?? row.course_id,
    kind: row.fact_type,
    text: `${row.fact_type}: ${row.title ?? row.quote}`,
    assignmentId: row.target_source_id,
    createdAt: Number.isNaN(stamp) ? 0 : Math.floor(stamp / 1000),
  };
}

function allItems(workList: unknown, manual: unknown): WorkItem[] {
  const work = (workList as WorkItem[]) ?? [];
  const mine = ((manual as Array<{ id: string; course: string; title: string; dueAt: string | null }>) ?? []).map((m): WorkItem => ({
    id: m.id,
    course: m.course,
    title: m.title,
    kind: "other",
    dueAt: m.dueAt,
    done: false,
    noSubmission: false,
    url: null,
    source: "manual",
  }));
  return [...work, ...mine];
}

interface AttachmentRef {
  name: string;
  url: string | null;
  fileID?: string;
  pageSlug?: string;
}

function likeEscape(value: string): string {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}

const FILE_URL = /(?:https?:\/\/[^\s)\]<>"']*)?\/(?:courses\/\d+\/)?files\/(\d+)[^\s)\]<>"']*/g;
const PAGE_URL = /(?:https?:\/\/[^\s)\]<>"']*)?\/courses\/\d+\/pages\/([A-Za-z0-9%._-]+)[^\s)\]<>"']*/g;
const FILE_NAME = /\.(?:pdf|docx|pptx|xlsx|zip)$/i;

/** The files and pages an assignment description names, in order, at most
 *  `MAX_ATTACHMENTS`: Canvas file and page links in the text, and bare lines
 *  that end in a document extension (the phone's older text form). */
export function attachmentRefs(text: string): AttachmentRef[] {
  const all: AttachmentRef[] = [];
  const cleanURL = (m: string) => (m.startsWith("http") ? m.replace(/[?#].*$/, "") : null);
  for (const line of text.split(/\r?\n/)) {
    let linked = false;
    for (const m of line.matchAll(FILE_URL)) {
      linked = true;
      // The label before the link ("Problem Set 7.pdf: https://...") is the
      // file's name; it is what a bare line of the same file is matched on.
      const label = line.slice(0, m.index).trim().replace(/^[-*\u2022]\s+/, "").replace(/[:\s]+$/, "");
      const named = label.length > 0 && label.length <= 200 && FILE_NAME.test(label);
      all.push({ name: named ? label : `file ${m[1]}`, url: cleanURL(m[0]), fileID: m[1] });
    }
    for (const m of line.matchAll(PAGE_URL)) {
      linked = true;
      all.push({ name: m[1], url: cleanURL(m[0]), pageSlug: m[1] });
    }
    if (linked) continue;
    const bare = line.trim().replace(/^[-*\u2022]\s+/, "");
    if (bare.length > 0 && bare.length <= 200 && FILE_NAME.test(bare)) all.push({ name: bare, url: null });
  }
  // Dedupe before the cap: a file id (or page slug) is one entry; a bare name
  // is dropped when a linked entry carries the same name, since the link has
  // the id.
  const linkedNames = new Set(all.filter((r) => r.fileID || r.pageSlug).map((r) => r.name.toLowerCase()));
  const out: AttachmentRef[] = [];
  const seen = new Set<string>();
  for (const ref of all) {
    const key = ref.fileID ? `f:${ref.fileID}` : ref.pageSlug ? `p:${ref.pageSlug}` : `n:${ref.name.toLowerCase()}`;
    if (seen.has(key)) continue;
    if (!ref.fileID && !ref.pageSlug && linkedNames.has(ref.name.toLowerCase())) continue;
    seen.add(key);
    out.push(ref);
    if (out.length >= MAX_ATTACHMENTS) break;
  }
  return out;
}

/** The Canvas assignment id of a work item: the phone's own field, else the
 *  link (`/assignments/123`), else an id `canvas:123` or
 *  `canvas:event-assignment-123` (the calendar row, whose number is the
 *  assignment's), else a trailing digits run after a colon. An
 *  `event-assignment-override-<n>` id is an override id, a different id
 *  space, and never matches. */
export function canvasAssignmentID(item: { id: string; url: string | null; canvasAssignmentID?: string | null }): string | null {
  if (item.canvasAssignmentID && /^\d{1,20}$/.test(item.canvasAssignmentID)) return item.canvasAssignmentID;
  const fromURL = item.url ? /\/assignments\/(\d+)/.exec(item.url)?.[1] : undefined;
  if (fromURL) return fromURL;
  if (/event-assignment-override-/.test(item.id)) return null;
  const fromID = /^(?:canvas:)(\d+)$/.exec(item.id) ?? /event-assignment-(\d+)$/.exec(item.id) ?? /:(\d+)$/.exec(item.id);
  return fromID ? fromID[1] : null;
}

function postedOf(row: DocumentRow): string | null {
  if (isWindowKind(row.kind)) return row.posted_at ?? row.updated_at ?? row.fetched_at;
  return row.posted_at;
}

/** The first word of a websearch query that is a plain term (not `or`, not a
 *  `-negation`), quotes stripped. */
function firstQueryWord(query: string): string {
  for (const w of query.replace(/"/g, " ").split(/\s+/)) {
    if (w && !w.startsWith("-") && w.toLowerCase() !== "or") return w;
  }
  return "";
}

/** 600 characters, starting a third of the way before the first hit of
 *  `word` (case-insensitive), or the first 600 when it is not found. */
export function excerptAround(text: string, word: string): string {
  const at = word ? text.toLowerCase().indexOf(word.toLowerCase()) : -1;
  if (at < 0) return text.slice(0, EXCERPT_CHARS);
  const from = Math.max(0, Math.min(at - Math.floor(EXCERPT_CHARS / 3), text.length - EXCERPT_CHARS));
  return text.slice(from, from + EXCERPT_CHARS);
}
