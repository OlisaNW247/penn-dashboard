// `degree-advisor`: the phone sends a question about the student's degree
// plan, plus a text DOCUMENT it built (Penn's audit per degree, semesters,
// the student's plan) and the course and term codes it will accept. A model
// answers and may return plan edits. See PROTOCOL.md's "degree-advisor".
//
// What leaves the phone for this call: the question, up to six earlier turns,
// the DOCUMENT, the accepted codes and the phone's clock. The owner chose a
// stronger model than the app uses elsewhere and accepted that degree data is
// sent for this. Nothing is stored: no table, no migration, and no log line
// carries the question, the document or the answer (only statuses and model
// ids).
//
// The wrong fix for "the model needs the audit" is a table of audits keyed by
// user: a second copy to delete, protect and explain, for no gain over
// sending the audit with the question.
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { enforceMinimumVersion } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import { limitsFromEnv, reserveUsage } from "../_shared/quota.ts";
import { chatCompletionJSONWithUsage, type JSONCompletion, UpstreamError } from "../_shared/openrouter.ts";
import { verifyPennCourses } from "../_shared/pennCourses.ts";
import {
  buildDegreeAdvice,
  buildDegreeAdvisorMessages,
  finalizeDegreeAdvice,
  DEGREE_ADVISOR_SCHEMA,
  parseDegreeAdvisorBody,
} from "../_shared/degreeAdvisor.ts";

export async function handleDegreeAdvisor(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    await enforceMinimumVersion(req);

    const { userId, serviceClient } = await requireUser(req);
    const body = parseDegreeAdvisorBody(await readJSON<unknown>(req));
    if (!body) {
      return errorResponse("bad_request", "malformed degree-advisor request", 400);
    }

    // Same atomic reserve-then-settle rule as extract-announcement; one unit
    // of the shared daily quota.
    const reservation = await reserveUsage(serviceClient, userId, limitsFromEnv(Deno.env));
    if (reservation.status === "denied") {
      return json(429, { error: "quota_exceeded", resetAt: reservation.resetAt.toISOString() });
    }
    const lease = reservation.lease;
    let keepReservation = false;
    try {
      const apiKey = Deno.env.get("OPENROUTER_API_KEY");
      if (!apiKey) {
        console.error("degree-advisor: OPENROUTER_API_KEY is not configured");
        return errorResponse("upstream", "model backend is not configured", 502);
      }
      const model = Deno.env.get("LHF_DEGREE_MODEL") ?? "anthropic/claude-sonnet-5.5";
      const fallbackModel = Deno.env.get("LHF_DEGREE_FALLBACK_MODEL") ?? "anthropic/claude-haiku-5.5";

      // One request shape for either model. The shared helper only falls back
      // on a 5xx or a network error, which is right for an outage and wrong
      // for this function's own risk: the primary id is a configured string,
      // and a provider that does not know it answers 400 or 404. Without the
      // second try below, a mistyped or retired model id would turn every
      // question into "couldn't reach smooth" until someone read the logs.
      // The retry names the fallback as the only model, so it cannot loop.
      let modelMs = 0;
      const complete = async (primary: string, fallback: string | undefined) => {
        const t0 = Date.now();
        try {
          return await call(primary, fallback);
        } finally {
          modelMs += Date.now() - t0;
        }
      };
      const call = (primary: string, fallback: string | undefined) =>
        chatCompletionJSONWithUsage({
          fetchImpl: fetch,
          apiKey,
          model: primary,
          fallbackModel: fallback,
          provider: providerFromEnv(),
          messages: buildDegreeAdvisorMessages(body),
          jsonSchema: DEGREE_ADVISOR_SCHEMA,
          // Speed: low effort on every round. Completeness of a whole plan
          // comes from the phone's continuation rounds, not from thinking
          // longer (a medium-effort whole-plan request outlived the phone's
          // 60 s timeout).
          reasoning: { effort: "low" },
          maxTokens: 10000,
          temperature: 0.2,
          // The answer is for this phone alone, so when the client leaves
          // the model call is cut off rather than paid for and discarded.
          signal: req.signal,
        });

      let completion: JSONCompletion;
      try {
        try {
          completion = await complete(model, fallbackModel);
        } catch (err) {
          const status = err instanceof UpstreamError ? err.status : undefined;
          const refused = status === 400 || status === 404;
          if (!refused || fallbackModel === model || req.signal.aborted) throw err;
          // Model ids only, never request content.
          console.warn(`degree-advisor: ${model} refused with ${status}, trying ${fallbackModel}`);
          completion = await complete(fallbackModel, undefined);
        }
      } catch (err) {
        const status = err instanceof UpstreamError ? err.status : undefined;
        console.error("degree-advisor: upstream failure, status:", status ?? "network");
        return errorResponse("upstream", "the model backend failed", 502);
      }

      let advice;
      let pickCount = 0;
      try {
        let draft;
        try {
          draft = buildDegreeAdvice(completion.content, body);
        } catch (err) {
          // A truncated or malformed JSON is the likely cause; one retry on
          // the fallback model alone before giving up.
          if (fallbackModel === completion.model || req.signal.aborted) throw err;
          console.warn(`degree-advisor: unusable output from ${completion.model}, trying ${fallbackModel}`);
          completion = await complete(fallbackModel, undefined);
          draft = buildDegreeAdvice(completion.content, body);
        }
        // Picks are courses the model named for requirements Penn lists no
        // courses for; only codes that Penn's catalogue knows survive. Only
        // course codes leave the server for this check. Counts are logged,
        // never codes.
        pickCount = draft.pickCodes.length;
        const verified = pickCount > 0
          ? await verifyPennCourses(draft.pickCodes, { fetchImpl: fetch, now: new Date() })
          : new Map();
        advice = finalizeDegreeAdvice(draft, verified);
        const tokens = completion.usage.completionTokens;
        console.log(
          `degree-advisor: round ${body.round} model ${completion.model} ms ${modelMs} ` +
            `actions ${advice.actions.length} picks ${pickCount} kept ${verified.size} ` +
            `planning ${advice.planning} completion_tokens ${tokens ?? "n/a"}`,
        );
      } catch {
        // Unusable output is a failure: the unit is given back (not kept).
        console.error("degree-advisor: unusable model output");
        return errorResponse("upstream", "the model backend failed", 502);
      }

      keepReservation = true;
      return json(200, { ...advice, model: completion.model });
    } finally {
      if (!keepReservation) {
        await (req.signal.aborted ? lease.settle(0, 0) : lease.release());
      }
    }
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse(err.status === 426 ? err.code : "unauthorized", err.message, err.status);
    }
    console.error("degree-advisor: unhandled failure", err instanceof Error ? err.message : "unknown");
    return errorResponse("bad_request", "request failed", 400);
  }
}

if (import.meta.main) {
  Deno.serve(handleDegreeAdvisor);
}

function providerFromEnv(): { order?: string[] } | undefined {
  const raw = Deno.env.get("LHF_PROVIDER_ORDER");
  if (!raw) return undefined;
  const order = raw.split(",").map((entry) => entry.trim()).filter((entry) => entry.length > 0);
  return order.length > 0 ? { order } : undefined;
}
