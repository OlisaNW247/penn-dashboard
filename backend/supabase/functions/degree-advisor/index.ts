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
  DEGREE_ADVISOR_EXPLAIN_SCHEMA,
  DEGREE_ADVISOR_SCHEMA,
  DEGREE_ADVISOR_STRUCTURED_SCHEMA,
  buildDegreeExplainMessages,
  parseDegreeAdvisorBody,
  parseDegreeExplanation,
  plainPlanSummary,
  readDegreeIntent,
  type AdvisorMessage,
  type DegreeAdvice,
  type DegreeExplanation,
  type DegreeIntentReading,
} from "../_shared/degreeAdvisor.ts";
import { type EngineOutput, runEngine } from "../_shared/degreePlanner/engine.ts";

/** Test seam: tests replace `run` to force an engine failure. */
export const engineHooks: { run: typeof runEngine } = { run: runEngine };

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
      interface CallSpec {
        messages: AdvisorMessage[];
        schema: { name: string; schema: Record<string, unknown> };
        maxTokens: number;
      }
      let modelMs = 0;
      const complete = async (primary: string, fallback: string | undefined, spec: CallSpec) => {
        const t0 = Date.now();
        try {
          return await call(primary, fallback, spec);
        } finally {
          modelMs += Date.now() - t0;
        }
      };
      const call = (primary: string, fallback: string | undefined, spec: CallSpec) =>
        chatCompletionJSONWithUsage({
          fetchImpl: fetch,
          apiKey,
          model: primary,
          fallbackModel: fallback,
          provider: providerFromEnv(),
          messages: spec.messages,
          jsonSchema: spec.schema,
          // Speed: low effort on every round. Completeness of a whole plan
          // comes from the phone's continuation rounds, not from thinking
          // longer (a medium-effort whole-plan request outlived the phone's
          // 60 s timeout).
          reasoning: { effort: "low" },
          maxTokens: spec.maxTokens,
          temperature: 0.2,
          // The answer is for this phone alone, so when the client leaves
          // the model call is cut off rather than paid for and discarded.
          signal: req.signal,
        });
      const completeWithRetry = async (spec: CallSpec): Promise<JSONCompletion> => {
        try {
          return await complete(model, fallbackModel, spec);
        } catch (err) {
          const status = err instanceof UpstreamError ? err.status : undefined;
          const refused = status === 400 || status === 404;
          if (!refused || fallbackModel === model || req.signal.aborted) throw err;
          // Model ids only, never request content.
          console.warn(`degree-advisor: ${model} refused with ${status}, trying ${fallbackModel}`);
          return await complete(fallbackModel, undefined, spec);
        }
      };

      const firstSpec: CallSpec = {
        messages: buildDegreeAdvisorMessages(body),
        schema: body.structured ? DEGREE_ADVISOR_STRUCTURED_SCHEMA : DEGREE_ADVISOR_SCHEMA,
        maxTokens: 10000,
      };

      let completion: JSONCompletion;
      try {
        completion = await completeWithRetry(firstSpec);
      } catch (err) {
        const status = err instanceof UpstreamError ? err.status : undefined;
        console.error("degree-advisor: upstream failure, status:", status ?? "network");
        return errorResponse("upstream", "the model backend failed", 502);
      }

      // What the first call decided (structured phones only).
      let reading: DegreeIntentReading | undefined;
      let advice;
      let pickCount = 0;
      let keptCount = 0;
      try {
        let draft: DegreeAdvice | undefined;
        const interpret = (content: string) => {
          if (!body.structured) {
            reading = undefined;
            draft = buildDegreeAdvice(content, body);
            return;
          }
          const r = readDegreeIntent(content, body);
          const needsDraft = r.intent === "question" || r.intent === "edit" || r.whatIf !== null;
          draft = needsDraft ? buildDegreeAdvice(content, body) : undefined;
          reading = r;
        };
        try {
          interpret(completion.content);
        } catch (err) {
          // A truncated or malformed JSON is the likely cause; one retry on
          // the fallback model alone before giving up.
          if (fallbackModel === completion.model || req.signal.aborted) throw err;
          console.warn(`degree-advisor: unusable output from ${completion.model}, trying ${fallbackModel}`);
          completion = await complete(fallbackModel, undefined, firstSpec);
          interpret(completion.content);
        }

        const intent = reading as DegreeIntentReading | undefined;
        if (body.structured && intent && draft === undefined) {
          // Plan or email: the planner decides, a second call explains.
          const firstMs = modelMs;
          const wantsEmail = intent.intent === "email";
          const e0 = Date.now();
          let out: EngineOutput | undefined;
          try {
            out = await engineHooks.run({
              structured: body.structured,
              intent: intent.params,
              fetchImpl: fetch,
              now: new Date(),
            });
          } catch {
            console.error("degree-advisor: engine failed");
          }
          const engineMs = Date.now() - e0;

          if (!out) {
            // Fall back to the first call's own words and no plan.
            let answer = "I couldn't build the plan just now. Try again in a moment.";
            try {
              answer = buildDegreeAdvice(completion.content, body).answer;
            } catch { /* keep the default */ }
            keepReservation = true;
            console.log(
              `degree-advisor: round ${body.round} intent ${intent.intent} model ${completion.model} ` +
                `ms ${firstMs} engine_ms ${engineMs} engine failed`,
            );
            return json(200, {
              answer, actions: [], whatIf: null, planning: false, dropped: [], model: completion.model,
            });
          }

          const plan = out.plan;
          const explainSpec: CallSpec = {
            messages: buildDegreeExplainMessages(body, plan, intent.params, wantsEmail),
            schema: DEGREE_ADVISOR_EXPLAIN_SCHEMA,
            maxTokens: 4000,
          };
          let explained: DegreeExplanation | undefined;
          let explainModel = completion.model;
          try {
            let c = await completeWithRetry(explainSpec);
            try {
              explained = parseDegreeExplanation(c.content, wantsEmail);
            } catch (err) {
              if (fallbackModel === c.model || req.signal.aborted) throw err;
              c = await complete(fallbackModel, undefined, explainSpec);
              explained = parseDegreeExplanation(c.content, wantsEmail);
            }
            explainModel = c.model;
          } catch {
            // The plan is real; only the prose failed. Say it with numbers.
            console.error("degree-advisor: explanation failed");
          }
          const chosen = plan.scenarios.find((sc) => sc.id === plan.chosen);
          keepReservation = true;
          console.log(
            `degree-advisor: round ${body.round} intent ${intent.intent} model ${completion.model}` +
              `${explainModel !== completion.model ? `+${explainModel}` : ""} ` +
              `ms ${firstMs} explain_ms ${modelMs - firstMs} engine_ms ${engineMs} slots ${out.slots} ` +
              `remaining ${plan.remainingCredits} chosen ${plan.chosen} finish ${chosen?.finishTerm ?? "none"}`,
          );
          const response: Record<string, unknown> = {
            answer: explained?.answer ?? plainPlanSummary(plan),
            actions: [],
            whatIf: null,
            planning: false,
            dropped: [],
            model: explainModel,
            plan,
          };
          if (wantsEmail && explained?.email) response.email = explained.email;
          return json(200, response);
        }

        // Picks are courses the model named for requirements Penn lists no
        // courses for; only codes that Penn's catalogue knows survive. Only
        // course codes leave the server for this check. Counts are logged,
        // never codes.
        const d = draft!;
        pickCount = d.pickCodes.length;
        const verified = pickCount > 0
          ? await verifyPennCourses(d.pickCodes, { fetchImpl: fetch, now: new Date() })
          : new Map();
        keptCount = verified.size;
        advice = finalizeDegreeAdvice(d, verified);
        if (body.structured && intent) {
          console.log(
            `degree-advisor: round ${body.round} intent ${intent.intent} model ${completion.model} ms ${modelMs} ` +
              `actions ${advice.actions.length} picks ${pickCount} kept ${keptCount}`,
          );
        } else {
          const tokens = completion.usage.completionTokens;
          console.log(
            `degree-advisor: round ${body.round} model ${completion.model} ms ${modelMs} ` +
              `actions ${advice.actions.length} picks ${pickCount} kept ${keptCount} ` +
              `planning ${advice.planning} completion_tokens ${tokens ?? "n/a"}`,
          );
        }
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
