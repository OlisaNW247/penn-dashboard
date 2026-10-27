// Server-side replacement for the iOS `ClaudeAnnouncementExtractor`. See
// PROTOCOL.md's "extract-announcement" section for the wire contract.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { limitsFromEnv, reserveUsage } from "../_shared/quota.ts";
import { chatCompletionJSON, UpstreamError } from "../_shared/openrouter.ts";
import {
  ANNOUNCEMENT_INSTRUCTIONS,
  buildAnnouncementUserContent,
  buildExtractionResult,
  courseCodesMatch,
} from "../_shared/announcement.ts";
import { selectCatalogCoursesByCodes, selectCoursesForDiscovery, selectEnrolledCourseIDs } from "../_shared/db.ts";
import type { CatalogCourseRow } from "../_shared/catalog.ts";

interface ExtractAnnouncementBody {
  announcementID: string;
  courseCode: string;
  title: string;
  message: string;
  postedAt?: string;
  now: string;
}

function parseBody(value: unknown): ExtractAnnouncementBody | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const body = value as Record<string, unknown>;
  if (
    typeof body.announcementID !== "string" ||
    typeof body.courseCode !== "string" ||
    typeof body.title !== "string" ||
    typeof body.message !== "string" ||
    typeof body.now !== "string" ||
    (body.postedAt !== undefined && typeof body.postedAt !== "string")
  ) {
    return undefined;
  }
  return {
    announcementID: body.announcementID,
    courseCode: body.courseCode,
    title: body.title,
    message: body.message,
    postedAt: body.postedAt as string | undefined,
    now: body.now,
  };
}

export async function handleExtractAnnouncement(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { userId, serviceClient } = await requireUser(req);
    const body = parseBody(await readJSON<unknown>(req));
    if (!body) {
      return errorResponse("bad_request", "malformed extract-announcement request", 400);
    }
    const now = new Date(body.now);
    if (Number.isNaN(now.getTime())) {
      return errorResponse("bad_request", "malformed extract-announcement request", 400);
    }

    // Reserved before the model call, atomically (`reserveUsage`: the check
    // and the charge are one statement), where this used to read the count,
    // call the model, and only then record: parallel requests all passed one
    // stale count, and a request the client abandoned was never charged
    // although the model had been called. The reservation is kept once the
    // model has answered or the client has left, and given back only when
    // the request fails while the client is still here (see `finally`).
    // A counter that stalls fails open (unmetered), as in `ask`.
    const reservation = await reserveUsage(serviceClient, userId, limitsFromEnv(Deno.env));
    if (reservation.status === "denied") {
      return json(429, { error: "quota_exceeded", resetAt: reservation.resetAt.toISOString() });
    }
    const lease = reservation.lease;
    let keepReservation = false;
    try {
      const apiKey = Deno.env.get("OPENROUTER_API_KEY");
      if (!apiKey) {
        console.error("extract-announcement: OPENROUTER_API_KEY is not configured");
        return errorResponse("upstream", "model backend is not configured", 502);
      }
      const model = Deno.env.get("LHF_MODEL") ?? "z-ai/glm-5.3-flash";
      const fallbackModel = Deno.env.get("LHF_FALLBACK_MODEL") ?? "openai/gpt-5.6-luna";

      const context = await resolveAnnouncementContext(serviceClient, userId, body.courseCode);

      const userContent = buildAnnouncementUserContent({
        courseCode: body.courseCode,
        title: body.title,
        message: body.message,
        postedAt: body.postedAt,
        now: body.now,
        catalog: context.catalog,
        profile: context.profile,
      });

      let text: string;
      try {
        text = await chatCompletionJSON({
          fetchImpl: fetch,
          apiKey,
          model,
          fallbackModel,
          provider: providerFromEnv(),
          messages: [
            { role: "system", content: ANNOUNCEMENT_INSTRUCTIONS },
            { role: "user", content: userContent },
          ],
          maxTokens: 1024,
          temperature: 0,
          // The result is for this phone alone and nothing else uses it, so
          // when the client leaves the model call is cut off rather than
          // paid for and discarded.
          signal: req.signal,
        });
      } catch (err) {
        const status = err instanceof UpstreamError ? err.status : undefined;
        console.error("extract-announcement: upstream failure, status:", status ?? "network");
        return errorResponse("upstream", "the model backend failed", 502);
      }

      // A real answer keeps the unit, as it always did.
      keepReservation = true;
      return json(200, buildExtractionResult(text, now));
    } finally {
      // A request that never got an answer shouldn't burn quota, as before
      // (the phone retries a failed announcement, and a deterministic
      // failure must not drain the student's asks). The exception is a
      // client that left: the model was called, the unit stays counted, and
      // refunding it would make "send, hang up, get the unit back" a free
      // loop. `lease` is once-only, so this is safe on every exit.
      if (!keepReservation) {
        await (req.signal.aborted ? lease.settle(0, 0) : lease.release());
      }
    }
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse("unauthorized", err.message, err.status);
    }
    console.error("extract-announcement: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
}

// Guarded by `import.meta.main`, like `ask/index.ts`, so a test can import
// `handleExtractAnnouncement` without starting a second server. Deployed,
// this file is the entry point the runtime executes, so `import.meta.main`
// is true there and the function serves exactly as before.
if (import.meta.main) {
  Deno.serve(handleExtractAnnouncement);
}

interface AnnouncementResolvedContext {
  catalog?: CatalogCourseRow;
  profile?: unknown;
}

/**
 * Resolves the request's free-text `courseCode` against the caller's own
 * enrollments -- per PROTOCOL.md, "among the caller's enrollments, the
 * `courses` row whose `code` equals `courseCode` (case-insensitive,
 * space/dash normalised)" -- and, when found, loads that course's
 * registrar catalog row and syllabus-derived profile for
 * `buildAnnouncementUserContent`'s COURSE STRUCTURE, CLASS MEETINGS and
 * COURSE PROFILE blocks. Every failure mode here -- no enrollments, no
 * matching code, no resolved catalog code, no fetched catalog row, no
 * profile row, or an outright database error -- degrades to "proceed
 * without that context" rather than failing the whole request: none of
 * this context is required to extract a task, it only makes a date
 * resolve better when it's available, the same posture `ask/index.ts`
 * takes toward its own catalog/profile lookups failing.
 */
async function resolveAnnouncementContext(
  serviceClient: SupabaseClient,
  userId: string,
  courseCode: string,
): Promise<AnnouncementResolvedContext> {
  try {
    const enrolledCourseIDs = await selectEnrolledCourseIDs(serviceClient, userId);
    if (enrolledCourseIDs.size === 0) return {};

    const courseInfos = await selectCoursesForDiscovery(serviceClient, [...enrolledCourseIDs]);
    const match = courseInfos.find((info) => courseCodesMatch(info.code, courseCode));
    if (!match) return {};

    let catalog: CatalogCourseRow | undefined;
    if (match.catalogCode) {
      const byCode = await selectCatalogCoursesByCodes(serviceClient, [match.catalogCode]);
      catalog = byCode.get(match.catalogCode);
    }

    const { data: profileRow, error: profileError } = await serviceClient
      .from("course_profiles")
      .select("profile")
      .eq("course_id", match.courseID)
      .maybeSingle();
    if (profileError) {
      console.error("extract-announcement: course_profiles lookup failed", profileError.message);
    }
    const profile = (profileRow as { profile: unknown } | null)?.profile;

    return { catalog, profile };
  } catch (err) {
    console.error(
      "extract-announcement: course context resolution failed",
      err instanceof Error ? err.message : String(err),
    );
    return {};
  }
}

function providerFromEnv(): { order?: string[] } | undefined {
  const raw = Deno.env.get("LHF_PROVIDER_ORDER");
  if (!raw) return undefined;
  const order = raw.split(",").map((entry) => entry.trim()).filter((entry) => entry.length > 0);
  return order.length > 0 ? { order } : undefined;
}
