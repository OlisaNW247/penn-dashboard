// Drafts (Phase 3 of the agent connection): a submission an agent proposed
// for the student to review in Smooth and submit from the app. Two callers
// share this store: the `mcp` tools (`propose_submission`, `draft_status`,
// through `PostgrestToolBackend`) and the phone's `agent-snapshot` actions
// (`drafts`, `draft`).
//
// Files are private Storage objects at `<user id>/<draft id>/<file name>` in
// the bucket `agent-drafts`; only the service role touches the bucket, and
// the phone is handed a signed URL good for two minutes. Retention: an
// object is deleted the moment the student decides (declined, submitted or
// failed), because keeping a sent or refused file serves nobody; the row
// stays (without its file) so the agent's `draft_status` can still answer.
//
// Never logged: bodies, urls, file names, file contents, signed URLs.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import { base64url } from "./agentTokens.ts";

export const DRAFT_BUCKET = "agent-drafts";
export const MAX_OPEN_DRAFTS = 20;
export const MAX_PHONE_DRAFTS = 50;
export const SIGNED_URL_SECONDS = 120;
export const MAX_ERROR_CLASS_CHARS = 64;

export type DraftStatus = "proposed" | "seen" | "submitted" | "declined" | "failed";
export type DraftDecision = "seen" | "declined" | "submitted" | "failed";

/** The states a draft may move to, and from which. Terminal states have no
 *  way out. Conditional on the row's current state in the UPDATE itself, so
 *  two phones racing cannot both win. */
export const TRANSITIONS: Record<DraftDecision, DraftStatus[]> = {
  seen: ["proposed"],
  declined: ["proposed", "seen"],
  submitted: ["proposed", "seen"],
  failed: ["proposed", "seen"],
};

export function isDraftDecision(value: unknown): value is DraftDecision {
  return typeof value === "string" && Object.hasOwn(TRANSITIONS, value);
}

/** Thrown when the student already has `MAX_OPEN_DRAFTS` open drafts. */
export class DraftLimitError extends Error {
  constructor() {
    super("too many open drafts; the student must review them in Smooth first");
    this.name = "DraftLimitError";
  }
}

/** Thrown when a file draft's `file_base64` does not decode. */
export class InvalidBase64Error extends Error {
  constructor() {
    super("file_base64 is not valid base64");
    this.name = "InvalidBase64Error";
  }
}

/** `smd_` plus 22 base64url characters (128 random bits). */
export function newDraftId(randomBytes: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
  return `smd_${base64url(randomBytes(16))}`;
}

/** A name safe to use as the last segment of a Storage key: letters, digits,
 *  dot, dash, underscore; everything else becomes `_`; no leading dot; at
 *  most 120 characters, keeping the extension. The student sees the original
 *  name (`file_name` column); this only names the object. */
export function sanitizeFileName(name: string): string {
  let clean = name.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^\.+/, "").replace(/_+/g, "_");
  if (clean.length > 120) {
    const dot = clean.lastIndexOf(".");
    const ext = dot > 0 && clean.length - dot <= 16 ? clean.slice(dot) : "";
    clean = clean.slice(0, 120 - ext.length) + ext;
  }
  return clean === "" || clean === "_" ? "file" : clean;
}

export function draftObjectPath(userId: string, draftId: string, fileName: string): string {
  return `${userId}/${draftId}/${sanitizeFileName(fileName)}`;
}

export interface NewDraft {
  assignmentId: string;
  connectionId: string;
  clientName: string;
  kind: "text" | "url" | "file";
  body?: string;
  url?: string;
  note?: string;
  file?: { bytes: Uint8Array; name: string; mimeType?: string };
}

/** What the phone sees of a draft. `fileUrl` is a signed URL, present only
 *  for a file draft that still has its object. */
export interface PhoneDraft {
  id: string;
  assignment_id: string;
  kind: "text" | "url" | "file";
  body: string | null;
  url: string | null;
  file_name: string | null;
  mime_type: string | null;
  file_bytes: number | null;
  note: string | null;
  client_name: string | null;
  status: DraftStatus;
  created_at: string;
  file_url?: string;
}

export interface DecisionExtra {
  canvasSubmissionId?: string;
  attempt?: number;
  errorClass?: string;
}

export type TransitionResult = "ok" | "not_found" | "conflict";

export interface DraftStore {
  countOpen(userId: string): Promise<number>;
  /** Uploads the file (if any), then inserts the row; removes the object if
   *  the insert fails. Returns the new id. */
  create(userId: string, draft: NewDraft): Promise<string>;
  status(userId: string, id: string): Promise<{ id: string; status: string } | null>;
  listOpen(userId: string, limit: number): Promise<PhoneDraft[]>;
  transition(userId: string, id: string, to: DraftDecision, extra: DecisionExtra, now: Date): Promise<TransitionResult>;
  /** Every draft of the student and its objects (opt-out). Returns the row count. */
  deleteAll(userId: string): Promise<number>;
}

// ---------------------------------------------------------------------------

interface DraftRow {
  id: string;
  assignment_id: string;
  kind: "text" | "url" | "file";
  body: string | null;
  url: string | null;
  file_path: string | null;
  file_name: string | null;
  mime_type: string | null;
  file_bytes: number | null;
  note: string | null;
  client_name: string | null;
  status: DraftStatus;
  created_at: string;
}

const PHONE_COLUMNS = "id, assignment_id, kind, body, url, file_path, file_name, mime_type, file_bytes, note, client_name, status, created_at";

export class PostgrestDraftStore implements DraftStore {
  constructor(private readonly client: SupabaseClient, private readonly makeId: () => string = newDraftId) {}

  async countOpen(userId: string): Promise<number> {
    const { count, error } = await this.client
      .from("agent_drafts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .in("status", ["proposed", "seen"]);
    if (error) throw error;
    return count ?? 0;
  }

  async create(userId: string, draft: NewDraft): Promise<string> {
    const id = this.makeId();
    let path: string | null = null;
    if (draft.file) {
      path = draftObjectPath(userId, id, draft.file.name);
      const up = await this.client.storage.from(DRAFT_BUCKET).upload(path, draft.file.bytes, {
        contentType: draft.file.mimeType || "application/octet-stream",
        upsert: false,
      });
      if (up.error) throw up.error;
    }
    const { error } = await this.client.from("agent_drafts").insert({
      id,
      user_id: userId,
      connection_id: draft.connectionId,
      client_name: draft.clientName,
      assignment_id: draft.assignmentId,
      kind: draft.kind,
      status: "proposed",
      body: draft.body ?? null,
      url: draft.url ?? null,
      note: draft.note ?? null,
      file_path: path,
      file_name: draft.file?.name ?? null,
      mime_type: draft.file?.mimeType ?? null,
      file_bytes: draft.file?.bytes.byteLength ?? null,
    });
    if (error) {
      if (path) await this.removeObjects([path]);
      throw error;
    }
    return id;
  }

  async status(userId: string, id: string): Promise<{ id: string; status: string } | null> {
    const { data, error } = await this.client.from("agent_drafts").select("id, status").eq("user_id", userId).eq("id", id).limit(1);
    if (error) throw error;
    const row = (data ?? [])[0] as { id: string; status: string } | undefined;
    return row ? { id: row.id, status: row.status } : null;
  }

  async listOpen(userId: string, limit: number): Promise<PhoneDraft[]> {
    const { data, error } = await this.client
      .from("agent_drafts")
      .select(PHONE_COLUMNS)
      .eq("user_id", userId)
      .in("status", ["proposed", "seen"])
      .order("created_at", { ascending: false })
      .limit(limit);
    if (error) throw error;
    const out: PhoneDraft[] = [];
    for (const row of (data ?? []) as DraftRow[]) {
      const { file_path, ...rest } = row;
      const view: PhoneDraft = rest;
      if (row.kind === "file" && file_path) {
        const signed = await this.client.storage.from(DRAFT_BUCKET).createSignedUrl(file_path, SIGNED_URL_SECONDS);
        if (signed.error) throw signed.error;
        view.file_url = signed.data.signedUrl;
      }
      out.push(view);
    }
    return out;
  }

  async transition(userId: string, id: string, to: DraftDecision, extra: DecisionExtra, now: Date): Promise<TransitionResult> {
    const stamp = now.toISOString();
    const patch: Record<string, unknown> = { status: to, updated_at: stamp };
    if (to === "seen") patch.seen_at = stamp;
    else patch.decided_at = stamp;
    if (extra.canvasSubmissionId !== undefined) patch.canvas_submission_id = extra.canvasSubmissionId;
    if (extra.attempt !== undefined) patch.attempt = extra.attempt;
    if (extra.errorClass !== undefined) patch.error_class = extra.errorClass;

    // Conditional on the current state, so the check and the write are one
    // statement: a read-then-write would let two phones both pass.
    const { data, error } = await this.client
      .from("agent_drafts")
      .update(patch)
      .eq("user_id", userId)
      .eq("id", id)
      .in("status", TRANSITIONS[to])
      .select("id, file_path");
    if (error) throw error;
    const updated = (data ?? []) as Array<{ id: string; file_path: string | null }>;
    if (updated.length === 0) {
      return (await this.status(userId, id)) ? "conflict" : "not_found";
    }
    const path = updated[0].file_path;
    if (to !== "seen" && path) {
      await this.removeObjects([path]);
      // Best effort above; the column is cleared either way so a signed URL
      // is never made for an object we meant to delete.
      await this.client.from("agent_drafts").update({ file_path: null }).eq("user_id", userId).eq("id", id);
    }
    return "ok";
  }

  async deleteAll(userId: string): Promise<number> {
    const { data, error } = await this.client.from("agent_drafts").delete().eq("user_id", userId).select("id, file_path");
    if (error) throw error;
    const rows = (data ?? []) as Array<{ id: string; file_path: string | null }>;
    const paths = rows.map((r) => r.file_path).filter((p): p is string => !!p);
    if (paths.length > 0) await this.removeObjects(paths);
    return rows.length;
  }

  /** Best effort: a failed delete must never fail the decision or the
   *  opt-out. Logs the count only. */
  private async removeObjects(paths: string[]): Promise<void> {
    try {
      const { error } = await this.client.storage.from(DRAFT_BUCKET).remove(paths);
      if (error) console.error(`agent-drafts: could not remove ${paths.length} object(s)`);
    } catch {
      console.error(`agent-drafts: could not remove ${paths.length} object(s)`);
    }
  }
}

/** Removes everything under `agent-drafts/<userId>/` (account deletion).
 *  Lists `<userId>/` for draft folders, then each folder, then removes.
 *  Best effort and never throws. */
export async function removeUserDraftObjects(client: SupabaseClient, userId: string): Promise<void> {
  try {
    const bucket = client.storage.from(DRAFT_BUCKET);
    const folders = await bucket.list(userId, { limit: 1000 });
    if (folders.error) throw folders.error;
    const paths: string[] = [];
    for (const folder of folders.data ?? []) {
      const files = await bucket.list(`${userId}/${folder.name}`, { limit: 1000 });
      if (files.error) throw files.error;
      for (const file of files.data ?? []) paths.push(`${userId}/${folder.name}/${file.name}`);
    }
    if (paths.length > 0) {
      const removed = await bucket.remove(paths);
      if (removed.error) throw removed.error;
    }
  } catch {
    console.error("agent-drafts: could not remove a deleted account's draft objects");
  }
}

// ---------------------------------------------------------------------------
// In memory: the handler tests' store, and the same rules as the real one.

interface MemoryDraft extends DraftRow {
  user_id: string;
  fileBytes?: Uint8Array;
}

export class MemoryDraftStore implements DraftStore {
  readonly rows = new Map<string, MemoryDraft>();
  readonly objects = new Map<string, Uint8Array>();
  private n = 0;

  countOpen(userId: string): Promise<number> {
    return Promise.resolve([...this.rows.values()].filter((r) => r.user_id === userId && (r.status === "proposed" || r.status === "seen")).length);
  }

  create(userId: string, draft: NewDraft): Promise<string> {
    const id = `smd_mem${++this.n}`;
    let path: string | null = null;
    if (draft.file) {
      path = draftObjectPath(userId, id, draft.file.name);
      this.objects.set(path, draft.file.bytes);
    }
    this.rows.set(id, {
      id,
      user_id: userId,
      assignment_id: draft.assignmentId,
      kind: draft.kind,
      body: draft.body ?? null,
      url: draft.url ?? null,
      file_path: path,
      file_name: draft.file?.name ?? null,
      mime_type: draft.file?.mimeType ?? null,
      file_bytes: draft.file?.bytes.byteLength ?? null,
      note: draft.note ?? null,
      client_name: draft.clientName,
      status: "proposed",
      created_at: new Date(Date.UTC(2026, 10, 10, 12, 0, this.n)).toISOString(),
    });
    return Promise.resolve(id);
  }

  status(userId: string, id: string): Promise<{ id: string; status: string } | null> {
    const row = this.rows.get(id);
    return Promise.resolve(row && row.user_id === userId ? { id, status: row.status } : null);
  }

  listOpen(userId: string, limit: number): Promise<PhoneDraft[]> {
    const open = [...this.rows.values()]
      .filter((r) => r.user_id === userId && (r.status === "proposed" || r.status === "seen"))
      .sort((a, b) => b.created_at.localeCompare(a.created_at))
      .slice(0, limit);
    return Promise.resolve(open.map(({ file_path, user_id: _u, fileBytes: _f, ...rest }) => {
      const view: PhoneDraft = rest;
      if (rest.kind === "file" && file_path) view.file_url = `https://storage.test/sign/${file_path}?token=t`;
      return view;
    }));
  }

  transition(userId: string, id: string, to: DraftDecision, _extra: DecisionExtra, _now: Date): Promise<TransitionResult> {
    const row = this.rows.get(id);
    if (!row || row.user_id !== userId) return Promise.resolve("not_found");
    if (!TRANSITIONS[to].includes(row.status)) return Promise.resolve("conflict");
    row.status = to;
    if (to !== "seen" && row.file_path) {
      this.objects.delete(row.file_path);
      row.file_path = null;
    }
    return Promise.resolve("ok");
  }

  deleteAll(userId: string): Promise<number> {
    let n = 0;
    for (const [id, row] of this.rows) {
      if (row.user_id !== userId) continue;
      if (row.file_path) this.objects.delete(row.file_path);
      this.rows.delete(id);
      n++;
    }
    return Promise.resolve(n);
  }
}
