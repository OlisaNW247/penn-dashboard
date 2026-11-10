import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { handleMcp, type McpDeps } from "../supabase/functions/mcp/index.ts";
import { MemoryAgentStore } from "../supabase/functions/_shared/agentStoreMemory.ts";
import { FixtureToolBackend } from "../supabase/functions/_shared/agentTools.ts";
import { generateToken, hashToken } from "../supabase/functions/_shared/agentTokens.ts";

const BASE = "https://example.test/functions/v1";
const MCP = `${BASE}/mcp`;
const NOW = new Date("2026-11-08T12:00:00Z");

function makeDeps(proposeHint: McpDeps["proposeHint"] = "false") {
  const store = new MemoryAgentStore();
  const backend = new FixtureToolBackend(NOW);
  const deps: McpDeps = { store, backend, publicBase: BASE, now: () => NOW, proposeHint };
  return { store, backend, deps };
}

async function seed(
  store: MemoryAgentStore,
  o: { scopes?: string[]; resource?: string; expiresAt?: string; revoked?: boolean; kind?: "access" | "refresh" } = {},
) {
  const connectionId = crypto.randomUUID();
  const scopes = o.scopes ?? ["read", "draft", "offline_access"];
  const token = generateToken(o.kind ?? "access");
  await store.insertConnection({
    id: connectionId,
    userId: "user-1",
    clientId: "https://claude.ai/client.json",
    clientName: "Claude",
    scopes,
    createdAt: NOW.toISOString(),
    lastUsedAt: null,
    revokedAt: o.revoked ? NOW.toISOString() : null,
  });
  await store.insertTokens([{
    hash: await hashToken(token),
    kind: o.kind ?? "access",
    connectionId,
    resource: o.resource ?? MCP,
    scopes,
    expiresAt: o.expiresAt ?? new Date(NOW.getTime() + 3_600_000).toISOString(),
    rotatedFrom: null,
    usedAt: null,
    createdAt: NOW.toISOString(),
  }]);
  return { token, connectionId };
}

function post(deps: McpDeps, token: string | null, body: unknown, extra: Record<string, string> = {}) {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
    "mcp-protocol-version": "2025-06-18",
    ...extra,
  };
  if (token) headers.authorization = `Bearer ${token}`;
  return handleMcp(new Request(MCP, { method: "POST", headers, body: JSON.stringify(body) }), deps);
}

// The reply is JSON or a one-event SSE stream depending on the SDK's mood.
async function rpc(res: Response): Promise<any> {
  const body = await res.text();
  if ((res.headers.get("content-type") ?? "").includes("text/event-stream")) {
    const data = body.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).pop();
    return JSON.parse(data ?? "null");
  }
  return JSON.parse(body);
}

let nextId = 1;
const call = (deps: McpDeps, token: string, name: string, args: unknown = {}) =>
  post(deps, token, { jsonrpc: "2.0", id: nextId++, method: "tools/call", params: { name, arguments: args } }).then(rpc);
const toolText = (r: any): string => r.result.content[0].text;

Deno.test("protected resource metadata at both paths", async () => {
  const { deps } = makeDeps();
  for (const path of ["/mcp/oauth-protected-resource", "/mcp/.well-known/oauth-protected-resource"]) {
    const res = await handleMcp(new Request(`${BASE}${path}`), deps);
    assertEquals(res.status, 200);
    assertEquals(res.headers.get("cache-control"), "public, max-age=300");
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
    const doc = await res.json();
    assertEquals(doc.resource, MCP);
    assertEquals(doc.authorization_servers[0], `${BASE}/agent-auth`);
  }
});

Deno.test("POST without a token is a bare challenge", async () => {
  const { deps } = makeDeps();
  const res = await post(deps, null, {});
  assertEquals(res.status, 401);
  const challenge = res.headers.get("www-authenticate") ?? "";
  assertStringIncludes(challenge, `resource_metadata="${MCP}/oauth-protected-resource"`);
  assertStringIncludes(challenge, `scope="read draft"`);
  assert(!challenge.includes("error="));
  assertEquals((await res.json()).error, "unauthorized");
});

Deno.test("a garbage token is invalid_token", async () => {
  const { deps } = makeDeps();
  const res = await post(deps, "not-a-token", {});
  assertEquals(res.status, 401);
  assertStringIncludes(res.headers.get("www-authenticate") ?? "", `error="invalid_token"`);
});

Deno.test("wrong audience, expired, revoked and refresh-as-bearer are all 401", async () => {
  const { store, deps } = makeDeps();
  const cases = [
    await seed(store, { resource: "https://other.example/mcp" }),
    await seed(store, { expiresAt: new Date(NOW.getTime() - 1000).toISOString() }),
    await seed(store, { expiresAt: NOW.toISOString() }),
    await seed(store, { revoked: true }),
    await seed(store, { kind: "refresh" }),
    { token: generateToken("access"), connectionId: "" }, // well-formed, unknown
  ];
  for (const c of cases) {
    const res = await post(deps, c.token, {});
    assertEquals(res.status, 401);
    const header = res.headers.get("www-authenticate") ?? "";
    assertStringIncludes(header, `error="invalid_token"`);
    assertStringIncludes(header, "token is not valid for this server");
    await res.body?.cancel();
  }
});

Deno.test("a token without read is 403 insufficient_scope", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store, { scopes: ["draft"] });
  const res = await post(deps, token, {});
  assertEquals(res.status, 403);
  assertStringIncludes(res.headers.get("www-authenticate") ?? "", `error="insufficient_scope"`);
});

Deno.test("initialize, then tools/list with titles and annotations", async () => {
  const { store, deps } = makeDeps();
  const { token, connectionId } = await seed(store);

  const init = await rpc(
    await post(deps, token, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } },
    }),
  );
  assertEquals(init.result.serverInfo.name, "smooth");
  assertEquals((await store.selectConnection(connectionId))?.lastUsedAt, NOW.toISOString());

  const list = await rpc(await post(deps, token, { jsonrpc: "2.0", id: 2, method: "tools/list" }));
  const tools: any[] = list.result.tools;
  assertEquals(tools.map((t) => t.name).sort(), [
    "draft_status", "get_announcements", "get_assignment", "get_ed_posts", "get_facts",
    "list_courses", "list_work", "propose_submission", "search_course_material",
  ]);
  for (const t of tools) {
    assert(typeof t.title === "string" && t.title.length > 0, `${t.name} has a title`);
    if (t.name === "propose_submission") {
      assertEquals(t.annotations.readOnlyHint, false);
      assertEquals(t.annotations.idempotentHint, false);
      assertEquals(t.annotations.openWorldHint, false);
    } else {
      // All three as explicit booleans: OpenAI's submission guidelines
      // require them on every tool.
      assertEquals(t.annotations.readOnlyHint, true, t.name);
      assertEquals(t.annotations.destructiveHint, false, t.name);
      assertEquals(t.annotations.openWorldHint, false, t.name);
    }
  }
});

Deno.test("tools/list works without an initialize first (stateless)", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const res = await post(deps, token, { jsonrpc: "2.0", id: 1, method: "tools/list" });
  assertEquals(res.status, 200);
  assertEquals((await rpc(res)).result.tools.length, 9);
});

Deno.test("destructiveHint follows the proposeHint knob", async () => {
  for (const [hint, expected] of [["none", undefined], ["false", false], ["true", true]] as const) {
    const { store, deps } = makeDeps(hint);
    const { token } = await seed(store);
    const list = await rpc(await post(deps, token, { jsonrpc: "2.0", id: 1, method: "tools/list" }));
    const propose = list.result.tools.find((t: any) => t.name === "propose_submission");
    assertEquals("destructiveHint" in propose.annotations, expected !== undefined, hint);
    assertEquals(propose.annotations.destructiveHint, expected, hint);
  }
});

Deno.test("read tools answer from the fixture", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  assertStringIncludes(toolText(await call(deps, token, "list_courses")), "PHYS 0151");

  const prev = toolText(await call(deps, token, "list_work", { view: "prev" }));
  assertEquals(prev.split("\n").length, 1);
  assertStringIncludes(prev, "Homework 3");

  const todo = toolText(await call(deps, token, "list_work", {}));
  assertStringIncludes(todo, "Homework 4");
  assertStringIncludes(todo, "Project 1");
  assert(!todo.includes("Homework 3"));

  const missing = await call(deps, token, "get_assignment", { id: "nope" });
  assertEquals(missing.result.isError, true);
});

Deno.test("get_assignment renders attachments, their text, and the not-readable line", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const out = toolText(await call(deps, token, "get_assignment", { id: "asg-phys-hw4" }));
  assertStringIncludes(out, "attachments:\n- HW4 handout.pdf — https://canvas.example/courses/1001/files/501; in the course material, 51 chars");
  assertStringIncludes(out, "- HW4 solutions.pdf — no link; not in the course material");
  assertStringIncludes(out, "--- HW4 handout.pdf ---\nProblem 2: a block slides down a frictionless ramp.");
  assert(!out.includes("--- HW4 solutions.pdf ---"));
  assert(out.indexOf("attachments:") < out.indexOf("facts:"));
  assert(out.trimEnd().endsWith("Files that are not in the course material cannot be read through this connection; the student can open them in Canvas."));
  // No attachments, no note.
  const plain = toolText(await call(deps, token, "get_assignment", { id: "asg-phys-lab5" }));
  assert(!plain.includes("attachments:") && !plain.includes("cannot be read"));
});

Deno.test("search_course_material describes every kind", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const list = await rpc(await post(deps, token, { jsonrpc: "2.0", id: 1, method: "tools/list" }));
  const search = list.result.tools.find((t: any) => t.name === "search_course_material");
  assertStringIncludes(search.description, "kind is one of home, syllabus, assignment, module, page, announcement, ed, website, file");
});

Deno.test("propose_submission: file, oversize, status, scope", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const file = { assignment_id: "asg-phys-hw4", kind: "file", file_name: "hw4.pdf", mime_type: "application/pdf" };

  // 262,144 bytes decoded: 87,381 full groups plus one byte ("AA==").
  const ok = await call(deps, token, "propose_submission", { ...file, file_base64: "A".repeat(349_526) + "==" });
  assert(!ok.result.isError, toolText(ok));
  assertStringIncludes(toolText(ok), "262144 bytes");
  const id = /draft (\S+) proposed/.exec(toolText(ok))![1];

  // Just over 1.5 MB decoded is refused from its length alone.
  const started = performance.now();
  const big = await call(deps, token, "propose_submission", { ...file, file_base64: "A".repeat(2_200_000) });
  assertEquals(big.result.isError, true);
  assertStringIncludes(toolText(big), "larger than");
  assert(performance.now() - started < 2000);

  // A 14 MB argument never reaches the tools: the SDK answers 413 at 4 MiB.
  const huge = await post(deps, token, { jsonrpc: "2.0", id: 99, method: "tools/call", params: { name: "propose_submission", arguments: { ...file, file_base64: "A".repeat(14_000_000) } } });
  assertEquals(huge.status, 413);
  await huge.body?.cancel();

  assertStringIncludes(toolText(await call(deps, token, "draft_status", { id })), "proposed");
  assertEquals((await call(deps, token, "draft_status", { id: "nope" })).result.isError, true);

  // Text and url drafts, and their validation.
  assertEquals(toolText(await call(deps, token, "propose_submission", { assignment_id: "asg-phys-hw4", kind: "text", body: "answer" })).startsWith("draft "), true);
  const http = await call(deps, token, "propose_submission", { assignment_id: "asg-phys-hw4", kind: "url", url: "http://x.example" });
  assertEquals(http.result.isError, true);
  const noBody = await call(deps, token, "propose_submission", { assignment_id: "asg-phys-hw4", kind: "text" });
  assertEquals(noBody.result.isError, true);
  const path = await call(deps, token, "propose_submission", { ...file, file_name: "../x.pdf", file_base64: "AAAA" });
  assertEquals(path.result.isError, true);
  const noAsg = await call(deps, token, "propose_submission", { assignment_id: "zzz", kind: "text", body: "x" });
  assertEquals(noAsg.result.isError, true);
});

Deno.test("a token without draft scope cannot propose", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store, { scopes: ["read"] });
  const res = await call(deps, token, "propose_submission", { assignment_id: "asg-phys-hw4", kind: "text", body: "x" });
  assertEquals(res.result.isError, true);
  assertStringIncludes(toolText(res), "cannot propose drafts");
});

Deno.test("GET and DELETE on the endpoint are 405 with Allow: POST", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  for (const method of ["GET", "DELETE"]) {
    const res = await handleMcp(new Request(MCP, { method, headers: { authorization: `Bearer ${token}` } }), deps);
    assertEquals(res.status, 405);
    assertEquals(res.headers.get("allow"), "POST");
    assertEquals((await res.json()).error, "method_not_allowed");
  }
});

Deno.test("OPTIONS preflight allows the MCP headers", async () => {
  const { deps } = makeDeps();
  const res = await handleMcp(new Request(MCP, { method: "OPTIONS" }), deps);
  assertEquals(res.status, 204);
  assertStringIncludes(res.headers.get("access-control-allow-headers") ?? "", "mcp-protocol-version");
  assertStringIncludes(res.headers.get("access-control-allow-methods") ?? "", "DELETE");
});

Deno.test("a non-https Origin is 403, an https one passes", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const bad = await post(deps, token, { jsonrpc: "2.0", id: 1, method: "tools/list" }, { origin: "http://evil.example" });
  assertEquals(bad.status, 403);
  await bad.body?.cancel();
  const good = await post(deps, token, { jsonrpc: "2.0", id: 1, method: "tools/list" }, { origin: "https://claude.ai" });
  assertEquals(good.status, 200);
  await good.body?.cancel();
});

Deno.test("2026-07-28 modern envelope (informational)", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const res = await post(deps, token, {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/list",
    params: {
      _meta: {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" },
      },
    },
  }, { "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list" });
  const text = await res.text();
  console.log("modern envelope:", res.status, text.slice(0, 160));
  assertEquals(res.status, 200);
  assertStringIncludes(text, "list_courses");
});

Deno.test("an unexpected throw is a bare 500", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  store.selectConnection = () => Promise.reject(new TypeError("secret detail"));
  const res = await post(deps, token, {});
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { error: "internal_error" });
});
