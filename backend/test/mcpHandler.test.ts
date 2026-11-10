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
    "append_file_chunk", "begin_file_upload", "draft_status", "finish_file_upload", "get_announcements", "get_assignment",
    "get_ed_posts", "get_facts", "list_courses", "list_work", "propose_submission", "search_course_material",
  ]);
  for (const t of tools) {
    assert(typeof t.title === "string" && t.title.length > 0, `${t.name} has a title`);
    if (["propose_submission", "begin_file_upload", "append_file_chunk", "finish_file_upload"].includes(t.name)) {
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
  assertEquals((await rpc(res)).result.tools.length, 12);
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

// ---- chunked upload through the handler -------------------------------------

async function sha256(bytes: Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource))).map((b) => b.toString(16).padStart(2, "0")).join("");
}
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

function randomFile(n: number): Uint8Array {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i += 65536) crypto.getRandomValues(out.subarray(i, Math.min(n, i + 65536)));
  return out;
}

async function begin(deps: McpDeps, token: string, file: Uint8Array, over: Record<string, unknown> = {}) {
  return await call(deps, token, "begin_file_upload", {
    assignment_id: "asg-phys-hw4",
    file_name: "hw4.pdf",
    mime_type: "application/pdf",
    total_bytes: file.length,
    sha256: await sha256(file),
    ...over,
  });
}

async function chunk(deps: McpDeps, token: string, id: string, file: Uint8Array, index: number) {
  const part = file.subarray(index * 16384, (index + 1) * 16384);
  return await call(deps, token, "append_file_chunk", { upload_id: id, index, data_base64: b64(part), sha256: await sha256(part) });
}

Deno.test("chunked upload: begin, a wrong chunk refused and resent, finish makes the draft", async () => {
  const { store, backend, deps } = makeDeps();
  const { token } = await seed(store);
  const file = randomFile(40_000); // 3 chunks: 16384, 16384, 7232
  const began = await begin(deps, token, file);
  assert(!began.result.isError, toolText(began));
  const info = JSON.parse(toolText(began).split("\n")[0]);
  assertEquals(info.chunk_bytes, 16384);
  assertEquals(info.chunks, 3);
  assertEquals(info.upload_method, "PUT");
  assertEquals(info.upload_headers["x-upsert"], "false");
  assertStringIncludes(toolText(began), "fastest: PUT the raw bytes to ");
  assertStringIncludes(toolText(began), "otherwise send chunks with append_file_chunk");

  // Chunk 0 with the wrong bytes under its checksum.
  const bad = await call(deps, token, "append_file_chunk", {
    upload_id: info.upload_id, index: 0, data_base64: b64(file.subarray(1, 16385)), sha256: await sha256(file.subarray(0, 16384)),
  });
  assertEquals(bad.result.isError, true);
  assertEquals(toolText(bad), "chunk 0 checksum mismatch; resend it");

  assertEquals(JSON.parse(toolText(await chunk(deps, token, info.upload_id, file, 2))), { received: 1, missing: [0, 1] });
  assertEquals(JSON.parse(toolText(await chunk(deps, token, info.upload_id, file, 0))), { received: 2, missing: [1] });
  // Finishing early names what is missing and keeps the staging.
  const early = await call(deps, token, "finish_file_upload", { upload_id: info.upload_id });
  assertEquals(early.result.isError, true);
  assertStringIncludes(toolText(early), "chunks missing: 1");
  assertEquals(JSON.parse(toolText(await chunk(deps, token, info.upload_id, file, 1))), { received: 3, missing: [] });
  // Re-sending an index replaces it.
  assertEquals(JSON.parse(toolText(await chunk(deps, token, info.upload_id, file, 1))).received, 3);

  const done = await call(deps, token, "finish_file_upload", { upload_id: info.upload_id, note: "n" });
  assert(!done.result.isError, toolText(done));
  assertStringIncludes(toolText(done), "40000 bytes");
  const id = /draft (\S+) proposed/.exec(toolText(done))![1];
  assertStringIncludes(toolText(await call(deps, token, "draft_status", { id })), "proposed");
  assertEquals(backend.drafts.get(id)!.input.fileName, "hw4.pdf");
  assertEquals(backend.uploadStore.rows.size, 0); // staging deleted
  assertEquals(backend.uploadStore.chunkRows.size, 0);
  assertEquals((await call(deps, token, "finish_file_upload", { upload_id: info.upload_id })).result.isError, true);
});

Deno.test("chunked upload: out of range, wrong length, bad base64, replace by a new begin", async () => {
  const { store, backend, deps } = makeDeps();
  const { token } = await seed(store);
  const file = randomFile(20_000);
  const a = JSON.parse(toolText(await begin(deps, token, file)).split("\n")[0]);
  const oob = await call(deps, token, "append_file_chunk", { upload_id: a.upload_id, index: 2, data_base64: "AAAA", sha256: await sha256(new Uint8Array(3)) });
  assertEquals(oob.result.isError, true);
  assertStringIncludes(toolText(oob), "out of range");
  const neg = await call(deps, token, "append_file_chunk", { upload_id: a.upload_id, index: -1, data_base64: "AAAA", sha256: await sha256(new Uint8Array(3)) });
  assertStringIncludes(toolText(neg), "out of range");
  // A short non-final chunk is refused by length.
  const short = file.subarray(0, 100);
  const wrong = await call(deps, token, "append_file_chunk", { upload_id: a.upload_id, index: 0, data_base64: b64(short), sha256: await sha256(short) });
  assertStringIncludes(toolText(wrong), "chunk 0 must be 16384 bytes");
  const junk = await call(deps, token, "append_file_chunk", { upload_id: a.upload_id, index: 0, data_base64: "A", sha256: "0".repeat(64) });
  assertStringIncludes(toolText(junk), "not valid base64");
  const unknown = await call(deps, token, "append_file_chunk", { upload_id: "smu_nope", index: 0, data_base64: "AAAA", sha256: await sha256(new Uint8Array(3)) });
  assertStringIncludes(toolText(unknown), "no such upload");

  // One open upload per connection: a new begin replaces the old.
  await chunk(deps, token, a.upload_id, file, 0);
  const b = JSON.parse(toolText(await begin(deps, token, file)).split("\n")[0]);
  assertEquals(backend.uploadStore.rows.size, 1);
  assert(backend.uploadStore.rows.has(b.upload_id));
  assertStringIncludes(toolText(await chunk(deps, token, a.upload_id, file, 1)), "no such upload");
});

Deno.test("chunked upload: begin refusals", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store);
  const file = randomFile(100);
  assertStringIncludes(toolText(await begin(deps, token, file, { total_bytes: 1_572_865 })), "larger than");
  assertStringIncludes(toolText(await begin(deps, token, file, { total_bytes: 0 })), "at least 1");
  assertStringIncludes(toolText(await begin(deps, token, file, { file_name: "../x.pdf" })), "no path separators");
  assertStringIncludes(toolText(await begin(deps, token, file, { sha256: "abc" })), "64 hex");
  assertStringIncludes(toolText(await begin(deps, token, file, { assignment_id: "zzz" })), "no such assignment");
  // 1.5 MB exactly is 96 chunks, inside the 100-chunk cap.
  assert(!(await begin(deps, token, file, { total_bytes: 1_572_864 })).result.isError);
});

Deno.test("chunked upload: whole-file mismatch is refused and the chunks kept for a resend", async () => {
  const { store, backend, deps } = makeDeps();
  const { token } = await seed(store);
  const file = randomFile(20_000);
  const other = randomFile(20_000);
  const a = JSON.parse(toolText(await begin(deps, token, file)).split("\n")[0]);
  await chunk(deps, token, a.upload_id, file, 0);
  await chunk(deps, token, a.upload_id, other, 1); // checksummed on its own, wrong for the file
  const refused = await call(deps, token, "finish_file_upload", { upload_id: a.upload_id });
  assertEquals(refused.result.isError, true);
  assertStringIncludes(toolText(refused), "file sha256 does not match");
  assertEquals(backend.uploadStore.rows.size, 1);
  assertEquals(backend.uploadStore.chunkRows.get(a.upload_id)!.size, 2);
  await chunk(deps, token, a.upload_id, file, 1);
  assert(!(await call(deps, token, "finish_file_upload", { upload_id: a.upload_id })).result.isError);
});

Deno.test("chunked upload: direct PUT path reads the staged object; a mismatch names it and clears it", async () => {
  const { store, backend, deps } = makeDeps();
  const { token } = await seed(store);
  const file = randomFile(30_000);
  const a = JSON.parse(toolText(await begin(deps, token, file)).split("\n")[0]);
  assertStringIncludes(a.upload_url, "/uploads/" + a.upload_id + "/hw4.pdf");
  const path = [...backend.uploadStore.rows.values()].map((r) => `${r.userId}/uploads/${r.id}/hw4.pdf`)[0];

  backend.uploadStore.staged.set(path, file.subarray(0, 29_999));
  const short = await call(deps, token, "finish_file_upload", { upload_id: a.upload_id });
  assertEquals(short.result.isError, true);
  assertStringIncludes(toolText(short), "uploaded object is 29999 bytes but begin_file_upload said 30000");
  assertEquals(backend.uploadStore.staged.size, 0);

  backend.uploadStore.staged.set(path, randomFile(30_000));
  const wrong = await call(deps, token, "finish_file_upload", { upload_id: a.upload_id });
  assertStringIncludes(toolText(wrong), "does not match the sha256");
  assertEquals(backend.uploadStore.rows.size, 1);

  backend.uploadStore.staged.set(path, file);
  const done = await call(deps, token, "finish_file_upload", { upload_id: a.upload_id });
  assert(!done.result.isError, toolText(done));
  assertStringIncludes(toolText(done), "30000 bytes");
  assertEquals(backend.uploadStore.staged.size, 0);
  assertEquals(backend.uploadStore.rows.size, 0);
});

Deno.test("chunked upload: no signed URL still leaves the chunk path", async () => {
  const { store, backend, deps } = makeDeps();
  backend.uploadStore.signing = false;
  const { token } = await seed(store);
  const began = toolText(await begin(deps, token, randomFile(10)));
  assert(!began.includes("upload_url"));
  assertStringIncludes(began, "send chunks with append_file_chunk");
});

Deno.test("chunked upload: expiry after 30 minutes, and the 20-open-draft cap keeps the staging", async () => {
  let clock = new Date(NOW);
  const store = new MemoryAgentStore();
  const backend = new FixtureToolBackend(NOW, 10, () => clock);
  const deps: McpDeps = { store, backend, publicBase: BASE, now: () => NOW, proposeHint: "false" };
  const { token } = await seed(store);
  const file = randomFile(100);
  const a = JSON.parse(toolText(await begin(deps, token, file)).split("\n")[0]);
  clock = new Date(NOW.getTime() + 29 * 60_000);
  assertEquals(JSON.parse(toolText(await chunk(deps, token, a.upload_id, file, 0))).received, 1);
  clock = new Date(NOW.getTime() + 31 * 60_000);
  const late = await call(deps, token, "finish_file_upload", { upload_id: a.upload_id });
  assertEquals(late.result.isError, true);
  assertStringIncludes(toolText(late), "expired");
  assertEquals(backend.uploadStore.rows.size, 0);

  clock = new Date(NOW);
  for (let i = 0; i < 20; i++) {
    assert(!(await call(deps, token, "propose_submission", { assignment_id: "asg-phys-hw4", kind: "text", body: "x" })).result.isError);
  }
  const b = JSON.parse(toolText(await begin(deps, token, file)).split("\n")[0]);
  await chunk(deps, token, b.upload_id, file, 0);
  const capped = await call(deps, token, "finish_file_upload", { upload_id: b.upload_id });
  assertEquals(capped.result.isError, true);
  assertStringIncludes(toolText(capped), "too many open drafts");
  assertEquals(backend.uploadStore.rows.size, 1);
});

Deno.test("upload tools need the draft scope", async () => {
  const { store, deps } = makeDeps();
  const { token } = await seed(store, { scopes: ["read"] });
  for (const [name, args] of [
    ["begin_file_upload", { assignment_id: "asg-phys-hw4", file_name: "a.pdf", mime_type: "application/pdf", total_bytes: 1, sha256: "0".repeat(64) }],
    ["append_file_chunk", { upload_id: "x", index: 0, data_base64: "AAAA", sha256: "0".repeat(64) }],
    ["finish_file_upload", { upload_id: "x" }],
  ] as const) {
    const r = await call(deps, token, name, args);
    assertEquals(r.result.isError, true, name);
    assertEquals(toolText(r), "this connection cannot propose drafts");
  }
});
