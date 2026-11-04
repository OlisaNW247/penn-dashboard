// The `extract-facts` Edge Function end to end over the stubbed `fetch`
// (`support/edgeStub.ts`): who may call it, what a bad body gets, and one
// full pass with counts. The extraction logic itself is tested in
// `factsExtraction.test.ts`; this pins the handler around it.
import { strict as assert } from "node:assert";
import { handleExtractFacts } from "../supabase/functions/extract-facts/index.ts";
import { GRANTED, installStub } from "./support/edgeStub.ts";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const request = (body: unknown, headers: Record<string, string> = { Authorization: "Bearer test-jwt" }) =>
  new Request("http://functions.test/extract-facts", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });

const TEXT = "Hi all, we are cancelling HW3 entirely. Please do not submit it.";
const FACT = {
  type: "cancel",
  target: "41803",
  title: null,
  due_at: null,
  kind: null,
  quote: "we are cancelling HW3 entirely",
  confidence: "high",
};

interface Recorded {
  claims: number;
  factInserts: number;
  extractionUpdates: Array<Record<string, unknown>>;
}

function install(enrolled: string[], options: { unauthorized?: boolean } = {}) {
  const recorded: Recorded = { claims: 0, factInserts: 0, extractionUpdates: [] };
  const stub = installStub({
    reserve: () => GRANTED,
    openrouter: { kind: "json", content: JSON.stringify({ facts: [FACT] }) },
    route: ({ method, url, body }) => {
      if (options.unauthorized && url.pathname === "/auth/v1/user") {
        return json(401, { message: "invalid JWT" });
      }
      const rpc = /^\/rest\/v1\/rpc\/(.+)$/.exec(url.pathname);
      if (rpc?.[1] === "claim_fact_extraction") {
        recorded.claims += 1;
        return json(200, "claimed");
      }
      if (!url.pathname.startsWith("/rest/v1/")) return undefined;
      const table = url.pathname.replace("/rest/v1/", "");
      const select = url.searchParams.get("select") ?? "";
      if (table === "enrollments") return json(200, enrolled.map((course_id) => ({ course_id })));
      if (table === "course_documents" && method === "GET") {
        if (select.startsWith("text")) return json(200, { text: TEXT, content_hash: "h1" });
        return json(200, [
          {
            id: "announcement:100:7", course_id: "100", course_code: "CIS 2400", kind: "announcement", source_id: "7",
            title: "HW3 is cancelled", content_hash: "h1", updated_at: "2026-10-06T13:12:00Z",
            fetched_at: "2026-10-06T14:00:00Z", due_at: null, posted_at: null,
          },
          {
            id: "assignment:100:41803", course_id: "100", course_code: "CIS 2400", kind: "assignment", source_id: "41803",
            title: "HW3", content_hash: "ha", updated_at: null, fetched_at: "2026-10-06T14:00:00Z",
            due_at: "2026-10-13T03:59:00Z", posted_at: null,
          },
        ]);
      }
      if (table === "course_fact_extractions") {
        if (method === "GET") return select.startsWith("id") ? json(200, { id: 5 }) : json(200, []);
        if (method === "PATCH") {
          recorded.extractionUpdates.push(JSON.parse(body));
          return new Response(null, { status: 204 });
        }
      }
      if (table === "course_facts") {
        if (method === "POST") recorded.factInserts += 1;
        return new Response(null, { status: method === "POST" ? 201 : 204 });
      }
      if (table === "courses") return json(200, []);
      return undefined;
    },
  });
  return { recorded, stub };
}

Deno.test("extract-facts: no Authorization header is a 401", async () => {
  const { stub } = install(["100"]);
  try {
    const res = await handleExtractFacts(request({}, {}));
    assert.equal(res.status, 401);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-facts: a token GoTrue rejects is a 401", async () => {
  const { stub } = install(["100"], { unauthorized: true });
  try {
    assert.equal((await handleExtractFacts(request({}))).status, 401);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-facts: a course the caller is not enrolled in is a 403 and starts no work", async () => {
  const { recorded, stub } = install(["100"]);
  try {
    const res = await handleExtractFacts(request({ courseId: "999" }));
    assert.equal(res.status, 403);
    assert.equal(recorded.claims, 0);
    assert.ok(!stub.log.includes("openrouter"));
  } finally {
    stub.restore();
  }
});

Deno.test("extract-facts: a courseId that is not a non-empty string is a 400", async () => {
  const { stub } = install(["100"]);
  try {
    for (const bad of [123, "", {}, ["100"]]) {
      assert.equal((await handleExtractFacts(request({ courseId: bad }))).status, 400, JSON.stringify(bad));
    }
    assert.equal((await handleExtractFacts(request([1, 2]))).status, 400);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-facts: a pass for the caller's course extracts the announcement and answers with counts", async () => {
  const { recorded, stub } = install(["100"]);
  try {
    const res = await handleExtractFacts(request({ courseId: "100" }));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { attempted: 1, done: 1, failed: 0, skippedBudget: 0, facts: 1, remaining: 0 });
    assert.equal(recorded.claims, 1, "only the announcement is a candidate; the assignment is index, not source");
    assert.equal(recorded.factInserts, 1);
    assert.equal(recorded.extractionUpdates.at(-1)?.status, "done");
    assert.equal(recorded.extractionUpdates.at(-1)?.fact_count, 1);
    assert.equal(stub.log.filter((e) => e === "openrouter").length, 1);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-facts: with no courseId it covers every enrolled course", async () => {
  const { recorded, stub } = install(["100"]);
  try {
    const res = await handleExtractFacts(request({}));
    assert.equal(res.status, 200);
    assert.equal((await res.json()).done, 1);
    assert.equal(recorded.claims, 1);
  } finally {
    stub.restore();
  }
});
