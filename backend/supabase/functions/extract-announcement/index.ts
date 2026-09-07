// Server-side replacement for the iOS `ClaudeAnnouncementExtractor`. See
// PROTOCOL.md's "extract-announcement" section for the wire contract.
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { checkQuota, limitsFromEnv } from "../_shared/quota.ts";
import { chatCompletionJSON, UpstreamError } from "../_shared/openrouter.ts";
import { ANNOUNCEMENT_INSTRUCTIONS, buildAnnouncementUserContent, parseAssignments } from "../_shared/announcement.ts";

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

Deno.serve(async (req) => {
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

    const { data: counts, error: countsError } = await serviceClient.rpc("ask_usage_counts", {
      p_user_id: userId,
    });
    if (countsError) {
      console.error("extract-announcement: ask_usage_counts failed", countsError.message);
      return errorResponse("upstream", "usage lookup failed", 502);
    }
    const row = Array.isArray(counts) ? counts[0] : counts;
    const limits = limitsFromEnv(Deno.env);
    const quota = checkQuota({
      todayRequests: row?.today_requests ?? 0,
      monthRequests: row?.month_requests ?? 0,
      dailyLimit: limits.dailyLimit,
      monthlyGlobalLimit: limits.monthlyGlobalLimit,
      now: new Date(),
    });
    if (!quota.allowed) {
      return json(429, { error: "quota_exceeded", resetAt: quota.resetAt.toISOString() });
    }

    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      console.error("extract-announcement: OPENROUTER_API_KEY is not configured");
      return errorResponse("upstream", "model backend is not configured", 502);
    }
    const model = Deno.env.get("LHF_MODEL") ?? "z-ai/glm-5.3-flash";
    const fallbackModel = Deno.env.get("LHF_FALLBACK_MODEL") ?? "openai/gpt-5.6-luna";

    const userContent = buildAnnouncementUserContent({
      courseCode: body.courseCode,
      title: body.title,
      message: body.message,
      postedAt: body.postedAt,
      now: body.now,
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
      });
    } catch (err) {
      const status = err instanceof UpstreamError ? err.status : undefined;
      console.error("extract-announcement: upstream failure, status:", status ?? "network");
      return errorResponse("upstream", "the model backend failed", 502);
    }

    // Recorded only on a successful model call -- a request that never
    // reached the model (quota check itself, or a validation failure
    // above) shouldn't burn quota, but one that got a real answer should,
    // same as `ask` records after a stream actually completes.
    const { error: recordError } = await serviceClient.rpc("record_ask_usage", {
      p_user_id: userId,
      p_prompt_tokens: 0,
      p_completion_tokens: 0,
    });
    if (recordError) {
      console.error("extract-announcement: record_ask_usage failed", recordError.message);
    }

    return json(200, { assignments: parseAssignments(text, now) });
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse("unauthorized", err.message, err.status);
    }
    console.error("extract-announcement: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
});

function providerFromEnv(): { order?: string[] } | undefined {
  const raw = Deno.env.get("LHF_PROVIDER_ORDER");
  if (!raw) return undefined;
  const order = raw.split(",").map((entry) => entry.trim()).filter((entry) => entry.length > 0);
  return order.length > 0 ? { order } : undefined;
}
