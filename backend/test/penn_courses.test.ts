import { strict as assert } from "node:assert";
import { lookupSemesters, nextSemester, verifyPennCourses } from "../supabase/functions/_shared/pennCourses.ts";

const NOW = new Date("2026-11-14T12:00:00Z"); // 2026C, next 2027A

const ok = (o: Record<string, unknown>) => new Response(JSON.stringify(o), { status: 200 });

function fakeFetch(handler: (url: string, init?: RequestInit) => Promise<Response> | Response) {
  const calls: string[] = [];
  const impl = ((input: Request | URL | string, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    return Promise.resolve(handler(url, init));
  }) as typeof fetch;
  return { impl, calls };
}

Deno.test("pennCourses: nextSemester skips summer", () => {
  assert.equal(nextSemester("2026A"), "2026C");
  assert.equal(nextSemester("2026B"), "2026C");
  assert.equal(nextSemester("2026C"), "2027A");
});

Deno.test("pennCourses: found in the first semester stops there; semester order from now", async () => {
  const f = fakeFetch(() => ok({ id: "MGMT-2380", title: "Negotiations", credits: 1 }));
  const r = await verifyPennCourses(["MGMT 2380"], { fetchImpl: f.impl, now: NOW });
  assert.deepEqual(r.get("MGMT 2380"), { title: "Negotiations", credits: 1 });
  assert.deepEqual(f.calls, ["https://penncoursereview.com/api/base/2026C/courses/MGMT-2380/"]);
});

Deno.test("pennCourses: found only in the second semester; numeric-string credits", async () => {
  const f = fakeFetch((url) =>
    url.includes("/2027A/") ? ok({ id: "X", title: "T", credits: "0.50" }) : new Response("{}", { status: 404 })
  );
  const r = await verifyPennCourses(["CIS 4710"], { fetchImpl: f.impl, now: NOW });
  assert.deepEqual(r.get("CIS 4710"), { title: "T", credits: 0.5 });
  assert.equal(f.calls.length, 2);
  assert.ok(f.calls[0].includes("/2026C/") && f.calls[1].includes("/2027A/"));
});

Deno.test("pennCourses: lookup order for a fixed now, deduped, at most four", () => {
  assert.deepEqual(lookupSemesters(NOW), ["2026C", "2027A", "2025C", "2026A"]);
  assert.deepEqual(lookupSemesters(new Date("2026-03-01T12:00:00Z")), ["2026A", "2026C", "2025A", "2025C"]);
});

Deno.test("pennCourses: found only in an older semester, tried in order", async () => {
  const f = fakeFetch((url) =>
    url.includes("/2026A/") ? ok({ id: "X", title: "Old", credits: 1 }) : new Response("{}", { status: 404 })
  );
  const r = await verifyPennCourses(["CIS 1200"], { fetchImpl: f.impl, now: NOW });
  assert.deepEqual(r.get("CIS 1200"), { title: "Old", credits: 1 });
  assert.equal(f.calls.length, 4);
  assert.ok(f.calls[3].includes("/2026A/"));
});

Deno.test("pennCourses: 404 in both is unverified; missing credits is null", async () => {
  const none = await verifyPennCourses(["CIS 9999"], { fetchImpl: fakeFetch(() => new Response("", { status: 404 })).impl, now: NOW });
  assert.equal(none.size, 0);
  const noCredits = await verifyPennCourses(["CIS 1200"], { fetchImpl: fakeFetch(() => ok({ id: "a", title: "b" })).impl, now: NOW });
  assert.deepEqual(noCredits.get("CIS 1200"), { title: "b", credits: null });
});

Deno.test("pennCourses: malformed JSON and shapeless 200s are not found", async () => {
  const bad = await verifyPennCourses(["CIS 1200"], { fetchImpl: fakeFetch(() => new Response("<html>", { status: 200 })).impl, now: NOW });
  assert.equal(bad.size, 0);
  const noTitle = await verifyPennCourses(["CIS 1200"], { fetchImpl: fakeFetch(() => ok({ id: "a" })).impl, now: NOW });
  assert.equal(noTitle.size, 0);
  const noId = await verifyPennCourses(["CIS 1200"], { fetchImpl: fakeFetch(() => ok({ title: "a" })).impl, now: NOW });
  assert.equal(noId.size, 0);
  const arr = await verifyPennCourses(["CIS 1200"], { fetchImpl: fakeFetch(() => ok([] as any)).impl, now: NOW });
  assert.equal(arr.size, 0);
});

Deno.test("pennCourses: a timeout or a throw leaves the code unverified and never throws", async () => {
  const hang = ((_u: unknown, init?: RequestInit) =>
    new Promise<Response>((_res, rej) => {
      init?.signal?.addEventListener("abort", () => rej(new Error("aborted")));
    })) as typeof fetch;
  const r = await verifyPennCourses(["CIS 1200"], { fetchImpl: hang, now: NOW, timeoutMs: 20 });
  assert.equal(r.size, 0);
  const boom = (() => Promise.reject(new Error("net"))) as typeof fetch;
  assert.equal((await verifyPennCourses(["CIS 1200"], { fetchImpl: boom, now: NOW })).size, 0);
});

Deno.test("pennCourses: distinct codes, at most 60 looked up", async () => {
  const codes = Array.from({ length: 80 }, (_, i) => `CIS ${1000 + i}`);
  const f = fakeFetch(() => ok({ id: "a", title: "b", credits: 1 }));
  const r = await verifyPennCourses([...codes, ...codes], { fetchImpl: f.impl, now: NOW });
  assert.equal(r.size, 60);
  assert.equal(f.calls.length, 60);
  assert.ok(!r.has("CIS 1060"));
});
