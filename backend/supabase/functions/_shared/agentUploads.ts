// Chunked, checksummed file uploads for the agent connection. A model types a
// tool argument token by token and cannot verify it, so one 144,000-character
// base64 string (a 108 KB PDF) is refused by claude.ai in practice. Instead:
// `begin_file_upload` fixes the name, size and whole-file sha256;
// `append_file_chunk` sends 16 KB pieces, each with its own sha256, and says
// which are still missing; `finish_file_upload` assembles, checks the whole
// file and creates the draft exactly as `propose_submission(kind: "file")`.
// A client that has a shell can instead PUT the raw bytes to the signed
// upload URL `begin` hands back (a staging object in the private
// `agent-drafts` bucket), then call finish.
//
// State is durable (`agent_uploads`, `agent_upload_chunks`, migration
// 20261110090000) because the function runs in many stateless isolates. An
// upload not finished within 30 minutes is garbage: refused, and swept by
// `agent_sweep_expired`. One open upload per connection; a new begin replaces
// an unfinished one. Never logged: names, bytes, urls.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import { base64url } from "./agentTokens.ts";
import { DRAFT_BUCKET, sanitizeFileName } from "./agentDrafts.ts";
import type { ProposedDraft } from "./agentTools.ts";

export const CHUNK_BYTES = 16_384;
export const MAX_UPLOAD_CHUNKS = 100;
export const UPLOAD_TTL_MS = 30 * 60_000;
export const SHA256_PATTERN = /^[0-9a-fA-F]{64}$/;

/** A refusal whose message is safe and useful to show the agent. */
export class UploadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UploadError";
  }
}

export function newUploadId(randomBytes: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
  return `smu_${base64url(randomBytes(16))}`;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  return bytesToHex(digest);
}

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

/** PostgREST's bytea text form: `\x` then hex. */
export function toBytea(bytes: Uint8Array): string {
  return `\\x${bytesToHex(bytes)}`;
}

export function fromBytea(value: string): Uint8Array {
  if (!value.startsWith("\\x") || (value.length - 2) % 2 !== 0) throw new Error("not a bytea hex string");
  const hex = value.slice(2);
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function stagingPath(userId: string, uploadId: string, fileName: string): string {
  return `${userId}/uploads/${uploadId}/${sanitizeFileName(fileName)}`;
}

export interface UploadRow {
  id: string;
  userId: string;
  connectionId: string;
  assignmentId: string;
  fileName: string;
  mimeType: string;
  totalBytes: number;
  sha256: string;
  chunkBytes: number;
  chunks: number;
  createdAt: string;
  expiresAt: string;
}

export interface UploadStore {
  /** Removes the connection's earlier unfinished uploads (rows, chunks and
   *  staged objects), then inserts this one. */
  replaceForConnection(row: UploadRow): Promise<void>;
  get(userId: string, id: string): Promise<UploadRow | null>;
  /** Inserts or replaces one chunk. */
  putChunk(uploadId: string, index: number, bytes: Uint8Array, sha256: string): Promise<void>;
  chunkIndexes(uploadId: string): Promise<number[]>;
  /** Every stored chunk, ascending by index. */
  chunks(uploadId: string): Promise<Array<{ index: number; bytes: Uint8Array }>>;
  /** A signed URL to PUT the raw file to, or null when none could be made. */
  signedUploadUrl(path: string): Promise<string | null>;
  /** The staged object's bytes, or null when nothing is there. */
  readStaged(path: string): Promise<Uint8Array | null>;
  removeStaged(path: string): Promise<void>;
  /** The row, its chunks and its staged object. */
  remove(row: UploadRow): Promise<void>;
  /** Every upload of the student (opt-out), and every staged object under
   *  the student's `uploads/` prefix. Returns the row count. */
  deleteAll(userId: string): Promise<number>;
  /** Removes staged objects under `<user>/uploads/<id>/` whose upload row is
   *  gone (see `UploadService.sweepStrays`). Returns how many objects went. */
  removeStrayStaged(userId: string): Promise<number>;
}

export interface BeganUpload {
  uploadId: string;
  chunkBytes: number;
  chunks: number;
  uploadUrl?: string;
}

export interface BeginInput {
  assignmentId: string;
  fileName: string;
  mimeType: string;
  totalBytes: number;
  sha256: string;
}

export function chunkLength(row: Pick<UploadRow, "totalBytes" | "chunkBytes" | "chunks">, index: number): number {
  return index < row.chunks - 1 ? row.chunkBytes : row.totalBytes - (row.chunks - 1) * row.chunkBytes;
}

function missingOf(chunks: number, have: number[]): number[] {
  const present = new Set(have);
  const out: number[] = [];
  for (let i = 0; i < chunks; i++) if (!present.has(i)) out.push(i);
  return out;
}

/** The rules, over any store. The backends own the draft creation. */
export class UploadService {
  constructor(private readonly store: UploadStore, private readonly now: () => Date = () => new Date(), private readonly makeId: () => string = newUploadId) {}

  async begin(userId: string, connectionId: string, input: BeginInput): Promise<BeganUpload> {
    const chunks = Math.ceil(input.totalBytes / CHUNK_BYTES);
    if (chunks > MAX_UPLOAD_CHUNKS) throw new UploadError(`file needs more than ${MAX_UPLOAD_CHUNKS} chunks`);
    const created = this.now();
    const row: UploadRow = {
      id: this.makeId(),
      userId,
      connectionId,
      assignmentId: input.assignmentId,
      fileName: input.fileName,
      mimeType: input.mimeType,
      totalBytes: input.totalBytes,
      sha256: input.sha256.toLowerCase(),
      chunkBytes: CHUNK_BYTES,
      chunks,
      createdAt: created.toISOString(),
      expiresAt: new Date(created.getTime() + UPLOAD_TTL_MS).toISOString(),
    };
    await this.store.replaceForConnection(row);
    await this.sweepStrays(userId);
    let uploadUrl: string | null = null;
    try {
      uploadUrl = await this.store.signedUploadUrl(stagingPath(userId, row.id, row.fileName));
    } catch {
      // The direct path is a convenience; chunks still work.
    }
    return { uploadId: row.id, chunkBytes: row.chunkBytes, chunks, uploadUrl: uploadUrl ?? undefined };
  }

  private async live(userId: string, uploadId: string): Promise<UploadRow> {
    const row = await this.store.get(userId, uploadId);
    if (!row) throw new UploadError("no such upload; call begin_file_upload");
    if (Date.parse(row.expiresAt) <= this.now().getTime()) {
      await this.store.remove(row);
      throw new UploadError("upload expired; call begin_file_upload again");
    }
    return row;
  }

  /** `bytes` and `sha256` were already checked against each other by the tool. */
  async append(userId: string, uploadId: string, index: number, bytes: Uint8Array, sha256: string) {
    const row = await this.live(userId, uploadId);
    if (!Number.isInteger(index) || index < 0 || index >= row.chunks) {
      throw new UploadError(`chunk index ${index} is out of range; this upload has chunks 0 to ${row.chunks - 1}`);
    }
    const want = chunkLength(row, index);
    if (bytes.byteLength !== want) throw new UploadError(`chunk ${index} must be ${want} bytes, got ${bytes.byteLength}`);
    await this.store.putChunk(uploadId, index, bytes, sha256.toLowerCase());
    const have = await this.store.chunkIndexes(uploadId);
    return { received: have.length, missing: missingOf(row.chunks, have) };
  }

  /** Verifies and hands the whole file to `create`. On any refusal or
   *  failure the staging is kept so the agent can fix and call again; on
   *  success it is deleted. */
  async finish(
    userId: string,
    uploadId: string,
    create: (row: UploadRow, bytes: Uint8Array) => Promise<ProposedDraft>,
  ): Promise<ProposedDraft & { fromStaged: boolean }> {
    const row = await this.live(userId, uploadId);
    const path = stagingPath(userId, row.id, row.fileName);
    let bytes: Uint8Array;
    let fromStaged = false;
    const staged = await this.store.readStaged(path);
    if (staged) {
      fromStaged = true;
      bytes = staged;
      const problem = bytes.byteLength !== row.totalBytes
        ? `uploaded object is ${bytes.byteLength} bytes but begin_file_upload said ${row.totalBytes}`
        : await sha256Hex(bytes) !== row.sha256
        ? "uploaded object does not match the sha256 given to begin_file_upload"
        : null;
      if (problem) {
        // Removed so the signed URL (which refuses to overwrite) can be used again.
        await this.store.removeStaged(path);
        throw new UploadError(`${problem}; PUT the file again or send chunks, then call finish_file_upload`);
      }
    } else {
      const stored = await this.store.chunks(uploadId);
      const missing = missingOf(row.chunks, stored.map((c) => c.index));
      if (missing.length > 0) {
        throw new UploadError(`nothing uploaded to the signed URL and chunks missing: ${missing.join(", ")}; send them with append_file_chunk, then call finish_file_upload`);
      }
      bytes = new Uint8Array(row.totalBytes);
      let at = 0;
      for (const c of stored) {
        if (at + c.bytes.byteLength > bytes.byteLength) throw new UploadError("chunks add up to more than total_bytes; call begin_file_upload again");
        bytes.set(c.bytes, at);
        at += c.bytes.byteLength;
      }
      if (at !== row.totalBytes) throw new UploadError(`chunks add up to ${at} bytes but total_bytes is ${row.totalBytes}; resend the short chunk`);
      if (await sha256Hex(bytes) !== row.sha256) {
        throw new UploadError("file sha256 does not match; resend the chunks (the same indexes replace) and call finish_file_upload again");
      }
    }
    const made = await create(row, bytes);
    await this.store.remove(row);
    await this.sweepStrays(userId);
    return { ...made, fromStaged };
  }

  /** Found 2026-11-11 against production (docs/V11_TEST_BACKEND_2026-11-11.md):
   *  Supabase's signed upload URL lives about two hours and cannot be
   *  revoked, while the upload behind it ends at finish, at a replacing
   *  begin, or after 30 minutes. A PUT after that (a retried curl, a
   *  confused agent) answers 200 and stores the file again under the old
   *  upload id, which no row names any more: nothing removed it, not the
   *  opt-out (which went by rows) and not the sweeper (rows only), so the
   *  student's file outlived both. Every begin and finish therefore removes
   *  the student's staged objects that have no upload row, and the opt-out
   *  removes all of them. The wrong fix is a shorter URL: supabase-js fixes
   *  its validity, and any length leaves the same window. A stray made after
   *  the student's last upload waits for the next upload, the opt-out or
   *  account deletion. Best effort: a sweep failure never fails the call. */
  private async sweepStrays(userId: string): Promise<void> {
    try {
      await this.store.removeStrayStaged(userId);
    } catch {
      console.error("agent-uploads: stray sweep failed (open)");
    }
  }
}

// ---------------------------------------------------------------------------

interface UploadDbRow {
  id: string;
  user_id: string;
  connection_id: string;
  assignment_id: string;
  file_name: string;
  mime_type: string;
  total_bytes: number;
  sha256: string;
  chunk_bytes: number;
  chunks: number;
  created_at: string;
  expires_at: string;
}

function fromDb(r: UploadDbRow): UploadRow {
  return {
    id: r.id,
    userId: r.user_id,
    connectionId: r.connection_id,
    assignmentId: r.assignment_id,
    fileName: r.file_name,
    mimeType: r.mime_type,
    totalBytes: r.total_bytes,
    sha256: r.sha256,
    chunkBytes: r.chunk_bytes,
    chunks: r.chunks,
    createdAt: r.created_at,
    expiresAt: r.expires_at,
  };
}

export class PostgrestUploadStore implements UploadStore {
  constructor(private readonly client: SupabaseClient) {}

  async replaceForConnection(row: UploadRow): Promise<void> {
    const { data, error } = await this.client
      .from("agent_uploads")
      .delete()
      .eq("user_id", row.userId)
      .eq("connection_id", row.connectionId)
      .select("id, user_id, file_name");
    if (error) throw error;
    await this.removeObjects((data ?? []).map((r: { id: string; user_id: string; file_name: string }) => stagingPath(r.user_id, r.id, r.file_name)));
    const ins = await this.client.from("agent_uploads").insert({
      id: row.id,
      user_id: row.userId,
      connection_id: row.connectionId,
      assignment_id: row.assignmentId,
      file_name: row.fileName,
      mime_type: row.mimeType,
      total_bytes: row.totalBytes,
      sha256: row.sha256,
      chunk_bytes: row.chunkBytes,
      chunks: row.chunks,
      created_at: row.createdAt,
      expires_at: row.expiresAt,
    });
    if (ins.error) throw ins.error;
  }

  async get(userId: string, id: string): Promise<UploadRow | null> {
    const { data, error } = await this.client.from("agent_uploads").select("*").eq("user_id", userId).eq("id", id).limit(1);
    if (error) throw error;
    const row = (data ?? [])[0] as UploadDbRow | undefined;
    return row ? fromDb(row) : null;
  }

  async putChunk(uploadId: string, index: number, bytes: Uint8Array, sha256: string): Promise<void> {
    const { error } = await this.client
      .from("agent_upload_chunks")
      .upsert({ upload_id: uploadId, index, data: toBytea(bytes), sha256 }, { onConflict: "upload_id,index" });
    if (error) throw error;
  }

  async chunkIndexes(uploadId: string): Promise<number[]> {
    const { data, error } = await this.client.from("agent_upload_chunks").select("index").eq("upload_id", uploadId).order("index");
    if (error) throw error;
    return ((data ?? []) as Array<{ index: number }>).map((r) => r.index);
  }

  async chunks(uploadId: string): Promise<Array<{ index: number; bytes: Uint8Array }>> {
    const { data, error } = await this.client.from("agent_upload_chunks").select("index, data").eq("upload_id", uploadId).order("index");
    if (error) throw error;
    return ((data ?? []) as Array<{ index: number; data: string }>).map((r) => ({ index: r.index, bytes: fromBytea(r.data) }));
  }

  async signedUploadUrl(path: string): Promise<string | null> {
    const { data, error } = await this.client.storage.from(DRAFT_BUCKET).createSignedUploadUrl(path);
    if (error || !data) return null;
    return data.signedUrl;
  }

  async readStaged(path: string): Promise<Uint8Array | null> {
    const slash = path.lastIndexOf("/");
    const bucket = this.client.storage.from(DRAFT_BUCKET);
    const listed = await bucket.list(path.slice(0, slash), { limit: 10, search: path.slice(slash + 1) });
    if (listed.error) throw listed.error;
    if (!(listed.data ?? []).some((f) => f.name === path.slice(slash + 1))) return null;
    const down = await bucket.download(path);
    if (down.error) throw down.error;
    return new Uint8Array(await down.data.arrayBuffer());
  }

  async removeStaged(path: string): Promise<void> {
    await this.removeObjects([path]);
  }

  async remove(row: UploadRow): Promise<void> {
    const { error } = await this.client.from("agent_uploads").delete().eq("user_id", row.userId).eq("id", row.id);
    if (error) throw error;
    await this.removeObjects([stagingPath(row.userId, row.id, row.fileName)]);
  }

  async deleteAll(userId: string): Promise<number> {
    const { data, error } = await this.client.from("agent_uploads").delete().eq("user_id", userId).select("id, user_id, file_name");
    if (error) throw error;
    const rows = (data ?? []) as Array<{ id: string; user_id: string; file_name: string }>;
    if (rows.length > 0) await this.removeObjects(rows.map((r) => stagingPath(r.user_id, r.id, r.file_name)));
    // With every row gone, every staged object is a stray: this also takes
    // the ones a late PUT left under an upload that had already ended.
    try {
      await this.removeStrayStaged(userId);
    } catch {
      console.error("agent-uploads: stray sweep failed (open)");
    }
    return rows.length;
  }

  async removeStrayStaged(userId: string): Promise<number> {
    const bucket = this.client.storage.from(DRAFT_BUCKET);
    // Folders first, rows second: a folder can only exist after its row was
    // inserted (begin inserts before it hands out the URL), so a row read
    // after the listing can only be missing because the upload ended.
    const folders = await bucket.list(`${userId}/uploads`, { limit: 1000 });
    if (folders.error) throw folders.error;
    const ids = (folders.data ?? []).filter((f) => f.id === null).map((f) => f.name);
    if (ids.length === 0) return 0;
    const { data, error } = await this.client.from("agent_uploads").select("id").eq("user_id", userId).in("id", ids);
    if (error) throw error;
    const live = new Set(((data ?? []) as Array<{ id: string }>).map((r) => r.id));
    const paths: string[] = [];
    for (const id of ids) {
      if (live.has(id)) continue;
      const files = await bucket.list(`${userId}/uploads/${id}`, { limit: 100 });
      if (files.error) throw files.error;
      for (const f of files.data ?? []) paths.push(`${userId}/uploads/${id}/${f.name}`);
    }
    await this.removeObjects(paths);
    return paths.length;
  }

  /** Best effort: a missing staged object is the normal case. */
  private async removeObjects(paths: string[]): Promise<void> {
    if (paths.length === 0) return;
    try {
      const { error } = await this.client.storage.from(DRAFT_BUCKET).remove(paths);
      if (error) console.error(`agent-uploads: could not remove ${paths.length} staged object(s)`);
    } catch {
      console.error(`agent-uploads: could not remove ${paths.length} staged object(s)`);
    }
  }
}

export class MemoryUploadStore implements UploadStore {
  readonly rows = new Map<string, UploadRow>();
  readonly chunkRows = new Map<string, Map<number, { bytes: Uint8Array; sha256: string }>>();
  /** Staged objects by path; a test puts bytes here to play the client's PUT. */
  readonly staged = new Map<string, Uint8Array>();
  signing = true;

  replaceForConnection(row: UploadRow): Promise<void> {
    for (const old of [...this.rows.values()]) {
      if (old.userId === row.userId && old.connectionId === row.connectionId) this.drop(old);
    }
    this.rows.set(row.id, row);
    this.chunkRows.set(row.id, new Map());
    return Promise.resolve();
  }

  get(userId: string, id: string): Promise<UploadRow | null> {
    const row = this.rows.get(id);
    return Promise.resolve(row && row.userId === userId ? row : null);
  }

  putChunk(uploadId: string, index: number, bytes: Uint8Array, sha256: string): Promise<void> {
    const chunks = this.chunkRows.get(uploadId);
    if (!chunks) return Promise.reject(new Error("no such upload"));
    chunks.set(index, { bytes, sha256 });
    return Promise.resolve();
  }

  chunkIndexes(uploadId: string): Promise<number[]> {
    return Promise.resolve([...(this.chunkRows.get(uploadId)?.keys() ?? [])].sort((a, b) => a - b));
  }

  chunks(uploadId: string): Promise<Array<{ index: number; bytes: Uint8Array }>> {
    return Promise.resolve([...(this.chunkRows.get(uploadId)?.entries() ?? [])].sort((a, b) => a[0] - b[0]).map(([index, c]) => ({ index, bytes: c.bytes })));
  }

  signedUploadUrl(path: string): Promise<string | null> {
    return Promise.resolve(this.signing ? `https://storage.test/object/upload/sign/${DRAFT_BUCKET}/${path}?token=t` : null);
  }

  readStaged(path: string): Promise<Uint8Array | null> {
    return Promise.resolve(this.staged.get(path) ?? null);
  }

  removeStaged(path: string): Promise<void> {
    this.staged.delete(path);
    return Promise.resolve();
  }

  remove(row: UploadRow): Promise<void> {
    this.drop(row);
    return Promise.resolve();
  }

  deleteAll(userId: string): Promise<number> {
    let n = 0;
    for (const row of [...this.rows.values()]) {
      if (row.userId !== userId) continue;
      this.drop(row);
      n++;
    }
    void this.removeStrayStaged(userId);
    return Promise.resolve(n);
  }

  removeStrayStaged(userId: string): Promise<number> {
    let n = 0;
    for (const path of [...this.staged.keys()]) {
      const m = new RegExp(`^${userId}/uploads/([^/]+)/`).exec(path);
      if (m && !this.rows.has(m[1])) {
        this.staged.delete(path);
        n++;
      }
    }
    return Promise.resolve(n);
  }

  private drop(row: UploadRow) {
    this.rows.delete(row.id);
    this.chunkRows.delete(row.id);
    this.staged.delete(stagingPath(row.userId, row.id, row.fileName));
  }
}
