import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  buildCatalogSnapshot,
  catalogSemesters,
  clearCatalogCache,
  normalizeCourseCode,
} from "../supabase/functions/_shared/degreePlanner/catalog.ts";

const NOW = new Date("2026-11-15T17:00:00Z"); // fall 2026 -> 2026C, 2027A, 2026B
const B = "https://penncoursereview.com/api/base";

function fakeFetch(routes: Record<string, unknown>, calls: string[] = []): typeof fetch {
  return ((input: string | URL | Request) => {
    const url = String(input);
    calls.push(url);
    if (!(url in routes)) return Promise.resolve(new Response("nope", { status: 404 }));
    const v = routes[url];
    if (v === "THROW") return Promise.reject(new Error("net"));
    if (v === "BADJSON") return Promise.resolve(new Response("<html>", { status: 200 }));
    return Promise.resolve(new Response(JSON.stringify(v), { status: 200 }));
  }) as typeof fetch;
}

const routes = (): Record<string, unknown> => ({
  [`${B}/2026C/courses/`]: [
    { id: "BEPP-2500", title: "Managerial Economics", credits: 1 },
    { id: "CIS-1200", title: "Programming", credits: "1.0" },
    { id: "ART-0100", title: "Drawing", credits: 1 },
  ],
  [`${B}/2027A/courses/`]: [
    { id: "BEPP-2500", title: "Managerial Economics", credits: 1 },
    { id: "CIS-2400", title: "Computer Systems", credits: 1 },
  ],
  [`${B}/2026B/courses/`]: [{ id: "CIS-1200", title: "Programming", credits: 1 }],
  [`${B}/2026C/search/courses/?attributes=WUGE`]: [{ id: "BEPP-2300", title: "Intl", credits: 1 }],
  [`${B}/2027A/search/courses/?attributes=WUGE`]: [{ id: "ECON-2100", title: "Global", credits: 1 }, { id: "BEPP-2300", title: "Intl", credits: 1 }],
  [`${B}/2026C/courses/CIS-2400/`]: { id: "CIS-2400" },
  [`${B}/2027A/courses/CIS-2400/`]: {
    id: "CIS-2400", title: "Computer Systems", credits: 1, prerequisites: "CIS 1200 and CIS 1210",
    attributes: [{ code: "EUCU", school: "EU", description: "x" }],
    crosslistings: [{ id: "ESE-3500" }, "NETS-2400"],
  },
  ["https://advising.cis.upenn.edu/assets/json/37cu_csci_tech_elective_list.json"]: [
    { course4d: "ACCT 1010", title: "Acct", status: "restricted" },
    { course4d: "bad", status: "x" },
  ],
});

Deno.test("code normalization", () => {
  assertEquals(normalizeCourseCode("BEPP-2500"), "BEPP 2500");
  assertEquals(normalizeCourseCode(" cis  1200 "), "CIS 1200");
  assertEquals(normalizeCourseCode("CIS1200"), "CIS 1200");
  assertEquals(normalizeCourseCode("nonsense"), null);
  assertEquals(normalizeCourseCode(5), null);
});

Deno.test("semesters: current, next fall/spring, latest summer", () => {
  assertEquals(catalogSemesters(NOW), ["2026C", "2027A", "2026B"]);
  assertEquals(catalogSemesters(new Date("2027-02-01T12:00:00Z")), ["2027A", "2027C", "2026B"]);
});

Deno.test("list parsing, filtering and offered seasons", async () => {
  clearCatalogCache();
  const s = await buildCatalogSnapshot({
    fetchImpl: fakeFetch(routes()), now: NOW, attributes: [], subjects: ["CIS", "BEPP"], codes: [],
  });
  assertEquals(Object.keys(s.courses).sort(), ["BEPP 2500", "CIS 1200", "CIS 2400"]);
  assertEquals(s.courses["BEPP 2500"].offered, { fall: true, spring: true, summer: false });
  assertEquals(s.courses["CIS 1200"].offered, { fall: true, spring: false, summer: true });
  assertEquals(s.courses["CIS 1200"].credits, 1);
  assertEquals(s.courses["CIS 2400"].offered, { fall: false, spring: true, summer: false });
  assertEquals(s.courses["BEPP 2500"].title, "Managerial Economics");
  assertEquals(s.semesters, ["2026C", "2027A", "2026B"]);
});

Deno.test("attribute index adds courses outside the subjects", async () => {
  clearCatalogCache();
  const s = await buildCatalogSnapshot({
    fetchImpl: fakeFetch(routes()), now: NOW, attributes: ["WUGE"], subjects: ["CIS"], codes: [],
  });
  assertEquals(s.attributeIndex["WUGE"], ["BEPP 2300", "ECON 2100"]);
  assertEquals(s.courses["ECON 2100"].attributes, ["WUGE"]);
  assertEquals(s.courses["ECON 2100"].offered, { fall: false, spring: true, summer: false });
  assertEquals(s.courses["BEPP 2300"].offered, { fall: true, spring: true, summer: false });
  assert(!("ART 0100" in s.courses));
});

Deno.test("detail merge tries semesters in order", async () => {
  clearCatalogCache();
  const s = await buildCatalogSnapshot({
    fetchImpl: fakeFetch(routes()), now: NOW, attributes: [], subjects: [], codes: ["cis-2400"],
  });
  // The 2026C detail is a 200 without fields, so it wins (first 200); merge keeps list data.
  const c = s.courses["CIS 2400"];
  assert(c);
  assertEquals(c.offered.fall, true);
});

Deno.test("detail fields: prerequisites, attributes, crosslistings", async () => {
  clearCatalogCache();
  const r = routes();
  delete r[`${B}/2026C/courses/CIS-2400/`]; // 404 in fall, found in spring
  const s = await buildCatalogSnapshot({
    fetchImpl: fakeFetch(r), now: NOW, attributes: [], subjects: [], codes: ["CIS 2400"],
  });
  const c = s.courses["CIS 2400"];
  assertEquals(c.prerequisites, "CIS 1200 and CIS 1210");
  assertEquals(c.attributes, ["EUCU"]);
  assertEquals(c.crosslistings, ["ESE 3500", "NETS 2400"]);
});

Deno.test("CIS tech elective list", async () => {
  clearCatalogCache();
  const s = await buildCatalogSnapshot({
    fetchImpl: fakeFetch(routes()), now: NOW, attributes: [], subjects: [], codes: [],
  });
  assertEquals(s.cisTechElective, { "ACCT 1010": "restricted" });
});

Deno.test("failures leave holes and never throw", async () => {
  clearCatalogCache();
  const r = routes();
  r[`${B}/2026C/courses/`] = "THROW";
  r[`${B}/2027A/courses/`] = "BADJSON";
  r[`${B}/2026C/search/courses/?attributes=WUGE`] = "THROW";
  const s = await buildCatalogSnapshot({
    fetchImpl: fakeFetch(r), now: NOW, attributes: ["WUGE"], subjects: ["CIS"], codes: ["CIS 9999"],
  });
  assertEquals(Object.keys(s.courses).sort(), ["BEPP 2300", "CIS 1200", "ECON 2100"].sort());
  assertEquals(s.semesters, ["2027A", "2026B"]);
  clearCatalogCache();
  const all = await buildCatalogSnapshot({
    fetchImpl: (() => Promise.reject(new Error("down"))) as typeof fetch,
    now: NOW, attributes: ["WUGE"], subjects: ["CIS"], codes: ["CIS 1200"],
  });
  assertEquals(all, { courses: {}, attributeIndex: {}, cisTechElective: {}, semesters: [] });
});

Deno.test("module cache: a second build within 6 h does not refetch", async () => {
  clearCatalogCache();
  const calls: string[] = [];
  const opts = { fetchImpl: fakeFetch(routes(), calls), now: NOW, attributes: [], subjects: ["CIS"], codes: [] };
  await buildCatalogSnapshot(opts);
  const first = calls.length;
  assert(first > 0);
  await buildCatalogSnapshot(opts);
  assertEquals(calls.length, first);
  await buildCatalogSnapshot({ ...opts, now: new Date(NOW.getTime() + 7 * 3600 * 1000) });
  assert(calls.length > first);
});
