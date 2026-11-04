// Runs fact extraction (`_shared/factsExtraction.ts`) for the courses the
// caller is enrolled in. See PROTOCOL.md's "Facts" section for the wire
// contract. `sync` already schedules this work after an upload that changed
// course material; this endpoint is the manual and retry path (a failed or
// budget-skipped document is picked up by the next call), and what a client
// can call to ask "anything new?" for one course.
//
// It does NOT charge the student's `ask` quota. The cost here is bounded per
// course and per month by `claim_fact_extraction` (60 a day per course, 5000
// a month overall), and the work is shared by every classmate, so metering
// it against whichever student happened to call would be both wrong and
// beside the point. A caller who loops on this endpoint spends the course's
// daily budget once and then gets `skippedBudget` counts, nothing more.
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { enforceMinimumVersion } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import { runPendingFactExtractions } from "../_shared/factsExtraction.ts";

// Re-exported so `sync` can import the scheduler from the same name the
// brief and PROTOCOL.md use, while the code lives in `_shared/` (a function
// importing another function's entry point would bundle its server).
export { runPendingFactExtractions };

const MAX_COURSES = 60;

export async function handleExtractFacts(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    await enforceMinimumVersion(req, { headerOptional: true });
    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "extract-facts only accepts POST");
    }

    const { userId, serviceClient } = await requireUser(req);
    const body = await readJSON<unknown>(req);
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      throw new HttpError(400, "bad_request", "malformed extract-facts request");
    }
    const courseId = (body as Record<string, unknown>)["courseId"];
    if (courseId !== undefined && courseId !== null && (typeof courseId !== "string" || courseId.length === 0)) {
      throw new HttpError(400, "bad_request", "\"courseId\" must be a non-empty string when present");
    }

    const { data, error } = await serviceClient.from("enrollments").select("course_id").eq("user_id", userId);
    if (error || !data) {
      console.error("extract-facts: enrollments lookup failed");
      throw new HttpError(502, "upstream", "could not read enrollments");
    }
    const enrolled = (data as Array<{ course_id: string }>).map((row) => row.course_id);

    let courseIDs = enrolled;
    if (typeof courseId === "string") {
      if (!enrolled.includes(courseId)) {
        throw new HttpError(403, "not_enrolled", `not enrolled in course ${courseId}`);
      }
      courseIDs = [courseId];
    }
    courseIDs = courseIDs.slice(0, MAX_COURSES);

    const stats = await runPendingFactExtractions(serviceClient, courseIDs);
    return json(200, stats);
  } catch (err) {
    if (err instanceof HttpError) {
      // 426 keeps its own code: the app keys its update wall on "update_required".
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("extract-facts: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleExtractFacts);
}
