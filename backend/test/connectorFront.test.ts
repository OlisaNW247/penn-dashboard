import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { handle } from "../connector-front/main.ts";

const env = { upstreamBase: "https://up.supabase.co/functions/v1", publicBase: "https://front.example/functions/v1", apikey: "KEY" };
const envNoKey = { upstreamBase: env.upstreamBase, publicBase: env.publicBase };

interface Seen { url: string; method: string; headers: Headers; body: string; redirect?: string }

async function withStub<T>(answer: () => Response, run: (seen: Seen[]) => Promise<T>): Promise<T> {
  const original = globalThis.fetch;
  const seen: Seen[] = [];
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const body = init?.body ? await new Response(init.body as BodyInit).text() : "";
    seen.push({ url: String(input), method: init?.method ?? "GET", headers: new Headers(init?.headers), body, redirect: init?.redirect });
    return answer();
  }) as typeof fetch;
  try {
    return await run(seen);
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test("root discovery documents carry the public host", async () => {
  for (const p of [
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-protected-resource/functions/v1/mcp",
    "/.well-known/oauth-authorization-server/functions/v1/agent-auth/",
    "/.well-known/openid-configuration",
  ]) {
    const res = await handle(new Request("https://front.example" + p), env);
    assertEquals(res.status, 200, p);
    assertEquals(res.headers.get("cache-control"), "public, max-age=300");
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
    assert((await res.text()).includes("https://front.example/functions/v1/"), p);
  }
});

Deno.test("mcp POST is forwarded with method, body, authorization, query and apikey", async () => {
  await withStub(() => new Response("ok"), async (seen) => {
    const req = new Request("https://front.example/functions/v1/mcp?a=1&b=2", {
      method: "POST",
      headers: { authorization: "Bearer t", "content-type": "application/json", host: "front.example" },
      body: '{"x":1}',
    });
    await handle(req, env);
    assertEquals(seen.length, 1);
    assertEquals(seen[0].url, "https://up.supabase.co/functions/v1/mcp?a=1&b=2");
    assertEquals(seen[0].method, "POST");
    assertEquals(seen[0].body, '{"x":1}');
    assertEquals(seen[0].headers.get("authorization"), "Bearer t");
    assertEquals(seen[0].headers.get("apikey"), "KEY");
    assertEquals(seen[0].headers.get("x-forwarded-host"), "front.example");
    assertEquals(seen[0].headers.get("x-forwarded-proto"), "https");
    assertFalse(seen[0].headers.has("host"));
    assertEquals(seen[0].redirect, "manual");
    await handle(new Request("https://front.example/functions/v1/mcp", { method: "POST", body: "{}" }), envNoKey);
    assertFalse(seen[1].headers.has("apikey"));
  });
});

Deno.test("upstream status and headers come back unchanged", async () => {
  const answer = () => {
    const h = new Headers({ "WWW-Authenticate": 'Bearer resource_metadata="https://front.example/x"', Location: "https://claude.ai/cb?code=1" });
    h.append("Set-Cookie", "a=1; Path=/");
    h.append("Set-Cookie", "b=2; Path=/");
    return new Response(null, { status: 302, headers: h });
  };
  await withStub(answer, async () => {
    const res = await handle(new Request("https://front.example/functions/v1/agent-auth/authorize?x=y"), env);
    assertEquals(res.status, 302);
    assertEquals(res.headers.get("location"), "https://claude.ai/cb?code=1");
    assertEquals(res.headers.get("www-authenticate"), 'Bearer resource_metadata="https://front.example/x"');
    assertEquals(res.headers.getSetCookie(), ["a=1; Path=/", "b=2; Path=/"]);
  });
});

Deno.test("root /register maps to agent-auth/register; root token too", async () => {
  await withStub(() => new Response("{}", { status: 201 }), async (seen) => {
    const res = await handle(new Request("https://front.example/register", { method: "POST", body: "{}" }), env);
    assertEquals(res.status, 201);
    assertEquals(seen[0].url, "https://up.supabase.co/functions/v1/agent-auth/register");
    await handle(new Request("https://front.example/token?q=1", { method: "POST", body: "a=b" }), env);
    assertEquals(seen[1].url, "https://up.supabase.co/functions/v1/agent-auth/token?q=1");
  });
});

Deno.test("unknown path is 404 and nothing is forwarded", async () => {
  await withStub(() => new Response("no"), async (seen) => {
    const res = await handle(new Request("https://front.example/nope"), env);
    assertEquals(res.status, 404);
    assertEquals(await res.json(), { error: "not_found" });
    assertEquals(seen.length, 0);
  });
});

Deno.test("a 7 MB content-length is 413 before forwarding", async () => {
  await withStub(() => new Response("no"), async (seen) => {
    const res = await handle(
      new Request("https://front.example/functions/v1/mcp", { method: "POST", headers: { "content-length": String(7 * 1024 * 1024) }, body: "x" }),
      env,
    );
    assertEquals(res.status, 413);
    assertEquals(seen.length, 0);
  });
});

const CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'";
const markedAnswer = () =>
  new Response("<p>hi</p>", {
    status: 200,
    headers: {
      "Content-Type": "text/plain",
      "Content-Security-Policy": "default-src 'none'; sandbox",
      "X-Smooth-Content-Type": "text/html; charset=utf-8",
      "X-Smooth-CSP": CSP,
    },
  });

Deno.test("agent-auth marker headers restore content-type and CSP and are removed", async () => {
  await withStub(markedAnswer, async () => {
    const res = await handle(new Request("https://front.example/functions/v1/agent-auth/authorize?x=y"), env);
    assertEquals(res.headers.get("content-type"), "text/html; charset=utf-8");
    assertEquals(res.headers.get("content-security-policy"), CSP);
    assertEquals(res.headers.get("x-smooth-content-type"), null);
    assertEquals(res.headers.get("x-smooth-csp"), null);
    assertEquals(await res.text(), "<p>hi</p>");
  });
});

Deno.test("mcp responses with marker headers are left alone", async () => {
  await withStub(markedAnswer, async () => {
    const res = await handle(new Request("https://front.example/functions/v1/mcp"), env);
    assertEquals(res.headers.get("content-type"), "text/plain");
    assertEquals(res.headers.get("content-security-policy"), "default-src 'none'; sandbox");
    assertEquals(res.headers.get("x-smooth-content-type"), "text/html; charset=utf-8");
    assertEquals(res.headers.get("x-smooth-csp"), CSP);
  });
});

Deno.test("connector-front: the root is a one-paragraph page naming the MCP URL", async () => {
  const env = { upstreamBase: "https://up.example/functions/v1", publicBase: "https://front.example/functions/v1" };
  const res = await handle(new Request("https://front.example/"), env);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "text/html; charset=utf-8");
  const text = await res.text();
  assert(text.includes("https://front.example/functions/v1/mcp"));
  const miss = await handle(new Request("https://front.example/nothing"), env);
  assertEquals(miss.status, 404);
});

Deno.test("the student's address goes to agent-auth with the secret; callers cannot send either header", async () => {
  await withStub(() => new Response("ok"), async (seen) => {
    const spoofed = { "x-forwarded-for": "198.51.100.20, 10.0.0.1", "x-smooth-client-ip": "1.2.3.4", "x-smooth-front-secret": "guess" };
    await handle(new Request("https://front.example/functions/v1/agent-auth/authorize?x=1", { headers: spoofed }), { ...env, clientIPSecret: "s3cret" });
    assertEquals(seen[0].headers.get("x-smooth-client-ip"), "198.51.100.20");
    assertEquals(seen[0].headers.get("x-smooth-front-secret"), "s3cret");
    // Without the secret configured, neither header goes upstream at all.
    await handle(new Request("https://front.example/functions/v1/agent-auth/authorize?x=1", { headers: spoofed }), env);
    assertFalse(seen[1].headers.has("x-smooth-client-ip"));
    assertFalse(seen[1].headers.has("x-smooth-front-secret"));
    // Never to mcp, which has no use for it.
    await handle(new Request("https://front.example/functions/v1/mcp", { method: "POST", headers: spoofed, body: "{}" }), { ...env, clientIPSecret: "s3cret" });
    assertFalse(seen[2].headers.has("x-smooth-client-ip"));
    assertFalse(seen[2].headers.has("x-smooth-front-secret"));
    // The root /register fallback is agent-auth too.
    await handle(new Request("https://front.example/register", { method: "POST", headers: spoofed, body: "{}" }), { ...env, clientIPSecret: "s3cret" });
    assertEquals(seen[3].headers.get("x-smooth-client-ip"), "198.51.100.20");
  });
});

Deno.test("envFromDeno reads CLIENT_IP_SECRET", async () => {
  const { envFromDeno } = await import("../connector-front/main.ts");
  const e = envFromDeno((k) => ({ UPSTREAM_BASE: "https://u/functions/v1", PUBLIC_BASE: "https://p/functions/v1", CLIENT_IP_SECRET: " s " } as Record<string, string>)[k]);
  assertEquals(e.clientIPSecret, "s");
  assertEquals(envFromDeno((k) => ({ UPSTREAM_BASE: "https://u", PUBLIC_BASE: "https://p" } as Record<string, string>)[k]).clientIPSecret, undefined);
});
