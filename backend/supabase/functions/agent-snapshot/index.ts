// The `agent-snapshot` edge function: the phone's side of the agent
// connection (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §7). The phone
// uploads what an agent may see of the student's own state (course list,
// work list, manual tasks), asks what is stored, or deletes it, which also
// revokes every agent connection. Called with the student's own Supabase JWT
// (`verify_jwt = true`); `requireUser` resolves the student, so a linked
// device acts as its owner.
//
// Logs counts and outcome codes only: never ids, titles or bodies.
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { corsHeaders, errorResponse, HttpError, json } from "../_shared/http.ts";
import { enforceMinimumVersion } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import type { AgentStore } from "../_shared/agentStore.ts";
import { PostgrestAgentStore } from "../_shared/agentStorePostgrest.ts";
import {
  type DraftStore,
  isDraftDecision,
  MAX_ERROR_CLASS_CHARS,
  MAX_PHONE_DRAFTS,
  PostgrestDraftStore,
} from "../_shared/agentDrafts.ts";
import { MAX_SNAPSHOT_BYTES, validateSnapshot } from "../_shared/agentSnapshot.ts";

export interface AgentSnapshotDeps {
  store: AgentStore;
  drafts: DraftStore;
  now?: () => Date;
}

function countOf(row: { workList: unknown; manual: unknown }): number {
  const n = (v: unknown) => (Array.isArray(v) ? v.length : 0);
  return n(row.workList) + n(row.manual);
}

export async function handleAgentSnapshot(req: Request, deps: AgentSnapshotDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  try {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed", "agent-snapshot only accepts POST");

    const declared = Number(req.headers.get("content-length") ?? "0");
    if (declared > MAX_SNAPSHOT_BYTES) throw new HttpError(413, "payload_too_large", "snapshot is larger than 1 MB");

    await enforceMinimumVersion(req, { headerOptional: true });
    const { userId } = await requireUser(req);
    const now = (deps.now ?? (() => new Date()))();

    // Chunked bodies carry no length: check what was actually read as well.
    const raw = await req.text();
    if (raw.length > MAX_SNAPSHOT_BYTES) throw new HttpError(413, "payload_too_large", "snapshot is larger than 1 MB");
    let body: unknown;
    try {
      body = JSON.parse(raw);
    } catch {
      throw new HttpError(400, "bad_request", "body is not valid JSON");
    }
    const action = typeof body === "object" && body !== null ? (body as Record<string, unknown>).action : undefined;

    if (action === "put") {
      const checked = validateSnapshot((body as Record<string, unknown>).snapshot);
      if (!checked.ok) {
        console.error(`agent-snapshot: refused (${checked.reason === "forbidden_field" ? "forbidden_field" : "invalid"})`);
        throw new HttpError(400, "bad_request", checked.reason);
      }
      const { courses, workList, manual } = checked.snapshot;
      const writtenAt = now.toISOString();
      await deps.store.upsertSnapshot({ userId, courses, workList, manual, writtenAt });
      const items = workList.length + manual.length;
      console.log(`agent-snapshot: put courses=${courses.length} items=${items}`);
      return json(200, { writtenAt, items });
    }

    if (action === "delete") {
      await deps.store.deleteSnapshot(userId);
      // Opting out takes the drafts and their files too: they are the
      // student's writing, held only for review.
      const draftsDeleted = await deps.drafts.deleteAll(userId);
      const revoked = await deps.store.revokeAllConnections(userId, now.toISOString());
      console.log(`agent-snapshot: delete revoked=${revoked} drafts=${draftsDeleted}`);
      return json(200, { deleted: true, revoked });
    }

    if (action === "status") {
      const row = await deps.store.selectSnapshot(userId);
      return json(200, row ? { hasSnapshot: true, writtenAt: row.writtenAt, items: countOf(row) } : { hasSnapshot: false, writtenAt: null, items: 0 });
    }

    if (action === "drafts") {
      const drafts = await deps.drafts.listOpen(userId, MAX_PHONE_DRAFTS);
      console.log(`agent-snapshot: drafts n=${drafts.length}`);
      return json(200, { drafts });
    }

    if (action === "draft") {
      const b = body as Record<string, unknown>;
      if (typeof b.id !== "string" || b.id === "" || b.id.length > 64) throw new HttpError(400, "bad_request", `"id" must be a draft id`);
      if (!isDraftDecision(b.status)) throw new HttpError(400, "bad_request", `"status" must be seen, declined, submitted or failed`);
      const extra: { canvasSubmissionId?: string; attempt?: number; errorClass?: string } = {};
      if (b.attempt !== undefined) {
        if (!Number.isInteger(b.attempt) || (b.attempt as number) < 0 || (b.attempt as number) > 1000) {
          throw new HttpError(400, "bad_request", `"attempt" must be a small non-negative integer`);
        }
        extra.attempt = b.attempt as number;
      }
      if (b.status === "submitted") {
        if (typeof b.canvas_submission_id !== "string" || b.canvas_submission_id === "" || b.canvas_submission_id.length > 64) {
          throw new HttpError(400, "bad_request", `"canvas_submission_id" is required for submitted`);
        }
        extra.canvasSubmissionId = b.canvas_submission_id;
      }
      if (b.status === "failed") {
        if (typeof b.error_class !== "string" || b.error_class === "" || b.error_class.length > MAX_ERROR_CLASS_CHARS) {
          throw new HttpError(400, "bad_request", `"error_class" is required for failed (at most ${MAX_ERROR_CLASS_CHARS} characters)`);
        }
        extra.errorClass = b.error_class;
      }
      const result = await deps.drafts.transition(userId, b.id, b.status, extra, now);
      console.log(`agent-snapshot: draft ${b.status} ${result}`);
      if (result === "not_found") throw new HttpError(404, "not_found", "no such draft");
      if (result === "conflict") throw new HttpError(409, "conflict", "the draft cannot move to that state");
      return json(200, { id: b.id, status: b.status });
    }

    throw new HttpError(400, "bad_request", `"action" must be put, delete, status, drafts or draft`);
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`agent-snapshot error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("agent-snapshot error: unexpected", err instanceof Error ? err.constructor.name : typeof err);
    return errorResponse("internal_error", "unexpected server error", 500);
  }
}

function productionDeps(): AgentSnapshotDeps {
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { store: new PostgrestAgentStore(client), drafts: new PostgrestDraftStore(client) };
}

if (import.meta.main) Deno.serve((req) => handleAgentSnapshot(req, productionDeps()));
