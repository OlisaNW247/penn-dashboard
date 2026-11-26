import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { parseXml } from "../supabase/functions/_shared/degreePlanner/xml.ts";
import {
  type PackBlock,
  type PackRule,
  parseCourseList,
  parseShare,
  parseTemplate,
  toIndexEntry,
  toProgramPack,
} from "../supabase/functions/_shared/degreePlanner/pack.ts";

// Real Penn templates (public Path@Penn data, no student in them) are the
// goldens; small inline XML pins each construct on its own so a failure names
// the construct and not a 60 KB file.
const fixture = (code: string) =>
  Deno.readTextFileSync(new URL(`./fixtures/penn-templates/${code}.xml`, import.meta.url));

function findRule(rules: PackRule[], label: string): PackRule {
  for (const r of rules) {
    if (r.label.trim() === label) return r;
    const f = r.children ? tryFind(r.children, label) : undefined;
    if (f) return f;
  }
  throw new Error(`no rule "${label}"`);
}
function tryFind(rules: PackRule[], label: string): PackRule | undefined {
  try { return findRule(rules, label); } catch { return undefined; }
}
const block = (t: ReturnType<typeof parseTemplate>, code: string): PackBlock => {
  const b = t.blocks.find((x) => x.code === code);
  assert(b, `no block ${code}; have ${t.blocks.map((x) => x.code).join(",")}`);
  return b;
};
const courseStr = (c: { subject: string; number: string; numberEnd?: string }) =>
  `${c.subject} ${c.number}${c.numberEnd ? ":" + c.numberEnd : ""}`;

// ---- inline template builders
const qual = (name: string, attrs: string, text: string, sub = "") =>
  `<Qualifier Name="${name}" ${attrs}><Text>${text}</Text>${sub ? `<SubText>${sub}</SubText>` : ""}</Qualifier>`;
const tpl = (header: string, rules = "") =>
  `<?xml version="1.0"?><Report><Audit><Block Req_id="R1" Req_type="MAJOR" Req_value="X" Title="T" Cat_yr_start="2020" Cat_yr_stop="9999"><Header>${header}</Header>${rules}</Block></Audit></Report>`;
const courseRule = (reqInner: string, attrs = "", reqAttrs = `Class_cred_op="OR" Classes_begin="1"`, ruleInner = "") =>
  `<Rule Label="L" LabelTag="LT" RuleType="Course" Rule_id="1-1" ${attrs}>${ruleInner}<Requirement ${reqAttrs}>${reqInner}</Requirement></Rule>`;
const one = (t: string) => parseTemplate(t).blocks[0];

// ------------------------------------------------------------------ xml.ts

Deno.test("xml: entities, attributes, nesting, text", () => {
  const n = parseXml(`<?xml version="1.0" encoding="ISO-8859-1"?>
<!-- a comment <with> tags -->
<a x="1 &amp; 2" y='q&quot;'><b>R&amp;D &lt;3 &#65;&#x42;</b><c/><d><![CDATA[<raw & ok>]]></d></a>`);
  assertEquals(n.tag, "a");
  assertEquals(n.attrs, { x: "1 & 2", y: 'q"' });
  assertEquals(n.children.map((c) => c.tag), ["b", "c", "d"]);
  assertEquals(n.children[0].text, "R&D <3 AB");
  assertEquals(n.children[1].children, []);
  assertEquals(n.children[2].text, "<raw & ok>");
});

Deno.test("xml: direct text is concatenated across child elements", () => {
  const n = parseXml(`<p>one <i>x</i> two</p>`);
  assertEquals(n.text, "one  two");
});

Deno.test("xml: attribute values may contain >", () => {
  const n = parseXml(`<a v="1 > 0"><b/></a>`);
  assertEquals(n.attrs.v, "1 > 0");
  assertEquals(n.children.length, 1);
});

Deno.test("xml: mismatched, unclosed and rootless input throws", () => {
  assertThrows(() => parseXml(`<a><b></a></b>`), Error, "mismatched tag");
  assertThrows(() => parseXml(`<a><b>`), Error, "never closed");
  assertThrows(() => parseXml(`<a></a><b/>`), Error, "second root");
  assertThrows(() => parseXml(`   `), Error, "no root");
  assertThrows(() => parseXml(`<a x=1/>`), Error, "unquoted");
});

// ---------------------------------------------------------- course lists

Deno.test("course list: bare numbers repeat the subject, ranges, wildcards", () => {
  const r = parseCourseList("MED 0000:9999, NSCI 0000:1019, 1021:2009, CIT @, @ @, MATH 2@");
  assert(r.ok);
  assertEquals(r.courses.map(courseStr), [
    "MED 0000:9999", "NSCI 0000:1019", "NSCI 1021:2009", "CIT @", "@ @", "MATH 2@",
  ]);
});

Deno.test("course list: (With ...) per item and an Except tail", () => {
  const r = parseCourseList(
    "@ 0001:1899 (With  DWTERM > 202221 ) ,  5000:9999 (With  DWTERM > 202221 ) ,  001:189 (With  DWTERM <= 202221 ) Except  WH 1010, 2010",
  );
  assert(r.ok);
  assertEquals(r.courses.map(courseStr), ["@ 0001:1899", "@ 5000:9999", "@ 001:189"]);
  assertEquals(r.courses.map((c) => c.historic ?? false), [false, false, true]);
  assertEquals(r.courses[0].conditions, [{ code: "DWTERM", op: ">", values: ["202221"] }]);
  assertEquals(r.except.map(courseStr), ["WH 1010", "WH 2010"]);
});

Deno.test("course list: ATTRIBUTE With becomes attributes; connectors kept on conditions", () => {
  const r = parseCourseList("MGMT @, @ @ (With ATTRIBUTE = WUMG, WUMH) Except MGMT 2910");
  assert(r.ok);
  assertEquals(r.courses[1], { subject: "@", number: "@", attributes: ["WUMG", "WUMH"] });
  const p = parseCourseList("@ @ (With DWPASSFAIL = Y AND DWTERM <> 202010, 202020, 202030, 202110) Except WH 1010");
  assertEquals(p.courses[0].conditions, [
    { code: "DWPASSFAIL", op: "=", values: ["Y"], connector: "AND" },
    { code: "DWTERM", op: "<>", values: ["202010", "202020", "202030", "202110"] },
  ]);
  assertEquals(p.courses[0].historic, undefined);
});

Deno.test("course list: unreadable text is flagged, not thrown, and keeps what read", () => {
  const r = parseCourseList("CIS 1200, hello world foo, 2100, MATH 1400 (not a with)");
  assertEquals(r.ok, false);
  assertEquals(r.courses.map(courseStr), ["CIS 1200", "CIS 2100"]);
  assertEquals(parseCourseList("2100").ok, false); // no subject to repeat
});

// ------------------------------------------------------------- ShareWith

Deno.test("share: type, block list, thisBlock, caps, two types", () => {
  assertEquals(parseShare("ShareWith (MAJOR)"), [{ scope: "type", type: "MAJOR" }]);
  assertEquals(parseShare("ShareWith (THISBLOCK)"), [{ scope: "thisBlock" }]);
  assertEquals(parseShare("ShareWith (OTHER = U-SEAS-WREE)"), [{ scope: "block", type: "OTHER", code: "U-SEAS-WREE" }]);
  assertEquals(parseShare("ShareWith (MAJOR = AFRC, MAJOR = ANCH, OTHER = U-X)"), [
    { scope: "block", type: "MAJOR", code: "AFRC" },
    { scope: "block", type: "MAJOR", code: "ANCH" },
    { scope: "block", type: "OTHER", code: "U-X" },
  ]);
  assertEquals(parseShare("ShareWith (MINOR, CONC)"), [{ scope: "type", type: "MINOR" }, { scope: "type", type: "CONC" }]);
  assertEquals(parseShare("ShareWith 2 Credits (THISBLOCK)"), [{ scope: "thisBlock", maxCredits: 2 }]);
  assertEquals(parseShare("ShareWith 1 Credits(OTHER = U-MT)"), [{ scope: "block", type: "OTHER", code: "U-MT", maxCredits: 1 }]);
  assertEquals(parseShare("ShareWith 2 CLASSES (CONC)"), [{ scope: "type", type: "CONC", maxClasses: 2 }]);
  assertEquals(parseShare("ShareWith (WHATEVER)"), null);
  assertEquals(parseShare("ShareWith nothing"), null);
});

Deno.test("share: header qualifiers are joined across Text and SubText, deduped, in order", () => {
  const b = one(tpl(
    qual("NONEXCLUSIVE", `Tag="a"`, "ShareWith ", "(MAJOR)") +
      qual("NONEXCLUSIVE", `Tag="b"`, "ShareWith ", "(MINOR, MAJOR)") +
      qual("NONEXCLUSIVE", "", "ShareWith (bogus"),
  ));
  assertEquals(b.share, [{ scope: "type", type: "MAJOR" }, { scope: "type", type: "MINOR" }]);
  assertEquals(b.other, [{ name: "NONEXCLUSIVE", text: "ShareWith (bogus" }]);
});

// ----------------------------------------------------- header qualifiers

Deno.test("header: numbers, limits, overlays, standalone, exclusive, unknown names", () => {
  const b = one(tpl(
    qual("CLASSESCREDITS", `Credits="37" Classes="9"`, "37 Credits") +
      qual("MINRES", `Credits="18.5"`, "MINRES 18.5 Credits") +
      qual("LASTRES", `Needed="5"`, "LASTRES 5 CLASSES") +
      qual("MINGPA", `MinGPA="2.5"`, "MINGPA 2.5") +
      qual("MINGRADE", `MinGrade="1.0"`, "MINGRADE 1.0") +
      qual("STANDALONEBLOCK", "", "StandAloneBlock") +
      qual("EXCLUSIVE", "", "DontShare") +
      qual("MAXCLASS", `Classes="3" Tag="T1"`, "MaxClasses 3 in ", "@ 5000:9999") +
      qual("MAXCREDIT", `Credits="1"`, "MaxCredits 1 in ", "BEPP @ Except BEPP 2080, 2300") +
      qual("SPMAXCREDIT", `Credits="0.5"`, "SPMAXCREDITS 0.5 in ", "FNCE 4010") +
      qual("MAXPASSFAIL", `Classes="0"`, "MAXPASSFAIL 0 CLASSES") +
      qual("MAXTRANSFER", `Credits="4"`, "MAXTRANSFER 4 Credits ") +
      qual("MINCLASS", `Classes="2" Label="Area" LabelTag="AA"`, "MinClasses 2 in ", "CIS 1200, 2100") +
      qual("MINCREDIT", `Credits="28"`, "MinCredits 28 in ", "AAMW @, AFRC @") +
      qual("HEADERTAG", `Code="X" Value="y"`, "HeaderTag X=y") +
      qual("BRANDNEW", "", "BrandNew 7 in somewhere"),
  ));
  assertEquals([b.minCredits, b.minClasses, b.minResidency, b.minGpa, b.minGrade], [37, 9, 18.5, 2.5, "1.0"]);
  assertEquals(b.lastResidency, { classes: 5 });
  assertEquals([b.standalone, b.exclusive], [true, true]);
  assertEquals(b.limits.map((l) => [l.kind, l.max, l.unit, l.courses.length, l.except.length, l.tag]), [
    ["MAXCLASS", 3, "courses", 1, 0, "T1"],
    ["MAXCREDIT", 1, "cu", 1, 2, undefined],
    ["SPMAXCREDIT", 0.5, "cu", 1, 0, undefined],
    ["MAXPASSFAIL", 0, "courses", 0, 0, undefined],
    ["MAXTRANSFER", 4, "cu", 0, 0, undefined],
  ]);
  assertEquals(b.overlays.map((o) => [o.kind, o.need, o.unit, o.label, o.labelTag, o.courses.length]), [
    ["MINCLASS", 2, "courses", "Area", "AA", 2],
    ["MINCREDIT", 28, "cu", undefined, undefined, 2],
  ]);
  assertEquals(b.other.map((o) => o.name), ["HEADERTAG", "BRANDNEW"]);
  assertEquals(b.other[1].text, "BrandNew 7 in somewhere");
});

Deno.test("header: a repeated single-valued field is kept visible in other", () => {
  const b = one(tpl(qual("MINGPA", `MinGPA="2"`, "MINGPA 2") + qual("MINGPA", `MinGPA="3"`, "MINGPA 3")));
  assertEquals(b.minGpa, 2);
  assertEquals(b.other, [{ name: "MINGPA", text: "MINGPA 3" }]);
});

Deno.test("header: an unparseable list is flagged unparsed and keeps its text", () => {
  const b = one(tpl(qual("MAXCLASS", `Classes="1"`, "MaxClasses 1 in ", "this is ?? not a list")));
  assertEquals(b.limits.length, 1);
  assertEquals(b.limits[0].unparsed, true);
  assertEquals(b.limits[0].text, "MaxClasses 1 in this is ?? not a list");
});

// ------------------------------------------------------------- rules

Deno.test("rule: needs, decide, courses with ranges, historic DWTERM, Except", () => {
  const rule = one(tpl("", courseRule(
    `<Course Disc="CIS" Num="2000" Num_end="9999"/>
     <Course Disc="ECON" Num="@"><With Code="DWTERM" Connector="AND" Operator="&lt;"><Value>Summer 2022</Value></With><With Code="DWCOURSENUMBER" Connector="AND" Operator="="><Value>010</Value></With></Course>
     <Course Disc="ESE" Num="3500"><With Code="DWTERM" Connector="" Operator="&lt;="><Value>202330</Value></With></Course>
     <Except><Course Disc="@" Num="2960"/></Except>`,
    "", `Class_cred_op="OR" Credits_begin="3" Credits_end="4" Decide="ORDER"`,
  ))).rules[0];
  assertEquals(rule.need, { credits: 3, creditsEnd: 4, op: "OR" });
  assertEquals(rule.decide, "ORDER");
  assertEquals(rule.courses!.map(courseStr), ["CIS 2000:9999", "ECON @", "ESE 3500"]);
  assertEquals(rule.courses![1].historic, true);
  assertEquals(rule.courses![1].conditions, [
    { code: "DWTERM", op: "<", values: ["Summer 2022"], connector: "AND" },
    { code: "DWCOURSENUMBER", op: "=", values: ["010"] },
  ]);
  assertEquals(rule.courses![2].historic, undefined); // "<= 202330" runs into 2023
  assertEquals(rule.except!.map(courseStr), ["@ 2960"]);
  assertEquals(rule.id, "1-1");
  assertEquals(rule.labelTag, "LT");
});

Deno.test("rule: historic reads both term spellings and the boundary", () => {
  const hist = (op: string, v: string) =>
    one(tpl("", courseRule(`<Course Disc="A" Num="1"><With Code="DWTERM" Operator="${op}"><Value>${v}</Value></With></Course>`))).rules[0].courses![0].historic === true;
  assertEquals(hist("&lt;", "202220"), true);
  assertEquals(hist("&lt;", "Fall 2022"), true);
  assertEquals(hist("&lt;=", "202221"), true);
  assertEquals(hist("&lt;", "202310"), true); // before spring 2023 is before 2023
  assertEquals(hist("&lt;=", "202310"), false);
  assertEquals(hist("&gt;", "202221"), false);
  assertEquals(hist("&lt;&gt;", "202010"), false);
});

Deno.test("rule: ATTRIBUTE with several values; two ANDed ATTRIBUTE Withs stay conditions", () => {
  const rule = one(tpl("", courseRule(
    `<Course Disc="@" Num="@"><With Code="ATTRIBUTE" Connector="" Operator="="><Value>WUCN</Value><Value>WUCU</Value></With></Course>
     <Course Disc="@" Num="0000:4999"><With Code="ATTRIBUTE" Connector="AND" Operator="="><Value>A</Value></With><With Code="ATTRIBUTE" Connector="AND" Operator="="><Value>B</Value></With></Course>`,
  ))).rules[0];
  assertEquals(rule.courses![0], { subject: "@", number: "@", attributes: ["WUCN", "WUCU"] });
  assertEquals(rule.courses![1].attributes, undefined);
  assertEquals(rule.courses![1].conditions!.map((c) => c.values), [["A"], ["B"]]);
  assertEquals(rule.courses![1].conditions![1].connector, undefined);
});

Deno.test("rule: Group pick, IfElsePart branch, nesting, empty optional fields omitted", () => {
  const rule = one(tpl("", `<Rule Label="G" RuleType="Group" Rule_id="2"><IfElsePart>IfPart</IfElsePart><Requirement NumGroups="1" NumRules="2"/>
      <Rule Label="C" RuleType="Course" Rule_id="2-0"><IfElsePart>ElsePart</IfElsePart><Requirement Class_cred_op="OR" Classes_begin="1"><Course Disc="PHYS" Num="0150"/></Requirement></Rule>
      <Rule Label="C2" RuleType="Complete" Rule_id="2-1"><Requirement/></Rule></Rule>`)).rules[0];
  assertEquals(rule.type, "group");
  assertEquals(rule.pick, { groups: 1, of: 2 });
  assertEquals(rule.branch, "if");
  assertEquals(rule.children!.map((c) => [c.label, c.type, c.branch]), [["C", "course", "else"], ["C2", "complete", undefined]]);
  assertEquals(Object.keys(rule.children![1]).sort(), ["id", "label", "type"]);
  assertEquals(rule.children![0].need, { classes: 1, op: "OR" });
});

Deno.test("rule: Block and Blocktype references", () => {
  const rules = one(tpl("", `<Rule Label="Gen Ed" RuleType="Block" Rule_id="3"><Requirement><NumBlocks>1</NumBlocks><Type>OTHER</Type><Value>U-X</Value></Requirement><Advice><BlockID>RA123</BlockID></Advice></Rule>
     <Rule Label="Conc" RuleType="Blocktype" Rule_id="4"><Requirement><NumBlocktypes>1</NumBlocktypes><Type>MAJOR</Type></Requirement></Rule>`)).rules;
  assertEquals(rules[0].ref, { type: "OTHER", code: "U-X", blockId: "RA123" });
  assertEquals(rules[1].ref, { type: "MAJOR" });
});

Deno.test("rule: qualifiers (share, limit, overlay, priority, hidden, grade) and an unknown one in other", () => {
  const rule = one(tpl("", courseRule(
    `<Course Disc="@" Num="@"/>` +
      qual("NONEXCLUSIVE", "", "ShareWith 2 Credits ", "(THISBLOCK)") +
      qual("MAXPASSFAIL", `Classes="0"`, "MAXPASSFAIL 0 CLASSES") +
      qual("MINCLASS", `Classes="2"`, "MinClasses 2 in ", "@ @ (With ATTRIBUTE = WUCN)") +
      qual("LOWESTPRIORITY", "", "LowestPriority") +
      qual("HIDERULE", "", "HideRule") +
      qual("MINGRADE", `MinGrade="2.0"`, "MINGRADE 2.0") +
      qual("EXCLUSIVE", "", "DontShare") +
      qual("MAXSPREAD", `Spread="1"`, "MAXSPREAD 1"),
  ))).rules[0];
  assertEquals(rule.share, [{ scope: "thisBlock", maxCredits: 2 }]);
  assertEquals(rule.limits![0].max, 0);
  assertEquals(rule.overlays![0].courses[0].attributes, ["WUCN"]);
  assertEquals([rule.priority, rule.hidden, rule.minGrade, rule.exclusive], ["lowest", true, "2.0", true]);
  assertEquals(rule.other, [{ name: "MAXSPREAD", text: "MAXSPREAD 1" }]);
});

Deno.test("template: goals, names, determinism, not-a-template throws", () => {
  const xml = `<Report><Audit><Block Req_id="R" Req_type="MAJOR" Req_value="X" Title="T" Cat_yr_start="1" Cat_yr_stop="2"><Header/></Block></Audit>
    <Deginfo><Goal Code="COLLEGE" Value="EU" ValueLit="SEAS"/><Goal Code="MAJOR" Value="CSCI" ValueLit="Computer Science"/><Goal Code="MAJOR" Value="OTHER" ValueLit="x"/></Deginfo>
    <DegreeData Degree="BSE" DegreeLit="Bachelor"/></Report>`;
  const t = parseTemplate(xml);
  assertEquals(t.goals, { college: "EU", major: "CSCI", degree: "BSE" });
  assertEquals(t.goalNames, { COLLEGE: "SEAS", MAJOR: "Computer Science", DEGREE: "Bachelor" });
  assertEquals(JSON.stringify(parseTemplate(xml)), JSON.stringify(t));
  assertThrows(() => parseTemplate(`<errors><error>nope</error></errors>`), Error, "not an audit template");
});

// -------------------------------------------------- golden: real fixtures

Deno.test("golden CSCI-BSE-NCON", () => {
  const t = parseTemplate(fixture("CSCI-BSE-NCON"));
  assertEquals(t.goals, { college: "EU", program: "EU_BSE", major: "CSCI", conc: "NCON", degree: "BSE" });

  const major = block(t, "CSCI");
  assertEquals([major.type, major.reqId, major.title, major.minCredits], ["MAJOR", "RA002291", "Major in Computer Science", 29]);
  assertEquals(major.share, [{ scope: "type", type: "MAJOR" }, { scope: "type", type: "MINOR" }, { scope: "type", type: "CONC" }]);
  assertEquals(major.overlays.map((o) => o.label), [
    "Area List - Networking", "Area List - Databases", "Area List - Distributed Systems",
    "Area List - Machine Learning/AI", "Area List - Project",
  ]);
  const net = major.overlays[0];
  assertEquals([net.kind, net.need, net.unit, net.courses.length], ["MINCLASS", 1, "courses", 9]);
  const names = net.courses.map(courseStr);
  for (const c of ["NETS 1500", "NETS 2120", "CIS 3310"]) assert(names.includes(c), c);

  const elective = findRule(major.rules, "CIS Elective at the 2000 Level or Above");
  assertEquals(elective.need?.credits, 3);
  const inc = elective.courses!.map(courseStr);
  for (const c of ["CIS 2000:9999", "NETS 2000:5999", "ESE 3500"]) assert(inc.includes(c), c);
  const exc = elective.except!.map(courseStr);
  assert(exc.includes("CIS 2610"));
  assert(elective.except!.some((c) => c.subject === "@" && c.number === "2960"));

  const ssh = block(t, "U-SEAS-SSH");
  assertEquals([ssh.type, ssh.title], ["OTHER", "General Electives"]);
  assert(ssh.share.some((s) => s.scope === "block" && s.type === "OTHER" && s.code === "U-SEAS-WREE"));
  assert(ssh.share.some((s) => s.scope === "type" && s.type === "CONC"));
  for (const m of ["AFRC", "PPE"]) assert(ssh.share.some((s) => s.scope === "block" && s.type === "MAJOR" && s.code === m), m);
  assertEquals(findRule(ssh.rules, "Writing Course").share, [{ scope: "thisBlock" }]);

  const bse = block(t, "BSE");
  assertEquals([bse.type, bse.minCredits, bse.minResidency], ["DEGREE", 37, 18.5]);
  const cap0 = bse.limits.find((l) => l.kind === "MAXCLASS" && l.max === 0 && l.courses.some((c) => c.subject === "CIT" && c.number === "@"));
  assert(cap0, "MAXCLASS 0 including CIT @");
  assert(!cap0.unparsed);
  const pf = bse.limits.find((l) => l.kind === "MAXCREDIT" && l.max === 4);
  assert(pf);
  assert(pf.courses[0].conditions!.some((c) => c.code === "DWPASSFAIL"));
  assertEquals(bse.rules.find((r) => r.type === "block")!.ref, { type: "OTHER", code: "U-SEAS-SSH", blockId: "RA002195" });
});

Deno.test("golden MGMT-BS-GEN", () => {
  const t = parseTemplate(fixture("MGMT-BS-GEN"));

  const wbus = block(t, "U-WBUS");
  assertEquals(wbus.share, [{ scope: "type", type: "MINOR" }, { scope: "block", type: "OTHER", code: "U-SCHOLARS" }]);
  const cap = findRule(wbus.rules, "Senior Capstone");
  assertEquals(cap.priority, "high");
  assertEquals(cap.courses![0], { subject: "@", number: "@", attributes: ["WUCP"] });
  assert(cap.courses!.some((c) => courseStr(c) === "WH 3991"));
  assertEquals(cap.except!.map(courseStr), ["STAT 001@"]);

  const intro = findRule(block(t, "U-WFYF").rules, "Introductory Economics");
  const names = intro.courses!.map(courseStr);
  assert(names.includes("BEPP 1000") && names.includes("ECON 0110"));
  const econ = intro.courses!.find((c) => c.subject === "ECON" && c.number === "@");
  assert(econ, "ECON @");
  assertEquals(econ.historic, true);
  assertEquals(intro.courses!.filter((c) => c.historic).length, 1);

  const las = block(t, "U-WLAS");
  const cross = findRule(las.rules, "Cross-Cultural Non-U.S. or U.S.");
  assertEquals(cross.share, [{ scope: "thisBlock", maxCredits: 2 }]);
  assertEquals(cross.overlays!.map((o) => [o.kind, o.need, o.courses[0].attributes]), [["MINCLASS", 2, ["WUCN"]]]);
  assertEquals(cross.limits!.map((l) => [l.kind, l.max]), [["MAXPASSFAIL", 0]]);
  assertEquals(findRule(las.rules, "Foreign Language Proficiency").share, [{ scope: "thisBlock" }]);

  const bbr = block(t, "U-WBBR2");
  assert(bbr.share.some((s) => s.scope === "block" && s.type === "OTHER" && s.code === "U-MT" && s.maxCredits === 1));
  assert(bbr.share.some((s) => s.scope === "type" && s.type === "MINOR"));
  const bepp = bbr.limits.find((l) => l.kind === "MAXCREDIT" && l.max === 1 && l.courses.length === 1 && courseStr(l.courses[0]) === "BEPP @");
  assert(bepp, "MAXCREDIT 1 on BEPP @");
  assertEquals(bepp.except.map(courseStr), ["BEPP 2080", "BEPP 2300", "BEPP 2360"]);

  const deg = block(t, "BS");
  assertEquals([deg.type, deg.minCredits, deg.minResidency], ["DEGREE", 37, 19]);
  assert(deg.limits.some((l) => l.kind === "MAXCLASS" && l.max === 3 && courseStr(l.courses[0]) === "@ 5000:9999"));
  const refs = deg.rules.filter((r) => r.type === "block").map((r) => [r.ref!.code, r.ref!.blockId]);
  assertEquals(refs, [["U-WFYF", "RA002079"], ["U-WBUS", "RA000456"], ["U-WLAS", "RA000453"], ["U-WBBR2", "RA001329"]]);
  assertEquals(deg.rules.find((r) => r.type === "blocktype")!.ref, { type: "MAJOR" });

  const mgmt = block(t, "MGMT");
  assertEquals([mgmt.minCredits, mgmt.minGpa], [4, 2.5]);
  assertEquals(mgmt.share, [
    { scope: "type", type: "MINOR" }, { scope: "type", type: "CONC" }, { scope: "block", type: "OTHER", code: "U-SCHOLARS" },
  ]);
});

Deno.test("golden FNCS-BS (pinned from the file)", () => {
  const t = parseTemplate(fixture("FNCS-BS"));
  const fncs = block(t, "FNCS");
  assertEquals([fncs.type, fncs.reqId, fncs.title], ["MAJOR", "RA001189", "Concentration in Finance (FNCS)"]);
  assertEquals(fncs.minCredits, 4);
  assertEquals(fncs.minGpa, 2.5);
  assertEquals(fncs.share, [
    { scope: "type", type: "MINOR" }, { scope: "type", type: "CONC" }, { scope: "block", type: "OTHER", code: "U-SCHOLARS" },
  ]);
  assertEquals(t.blocks.map((b) => b.type), ["DEGREE", "OTHER", "OTHER", "OTHER", "OTHER", "MAJOR"]);
  // Nothing in any fixture may fall through the cracks silently: every list read.
  for (const f of ["CSCI-BSE-NCON", "MGMT-BS-GEN", "FNCS-BS"]) {
    for (const b of parseTemplate(fixture(f)).blocks) {
      for (const l of [...b.limits, ...b.overlays]) assert(!l.unparsed, `${f} ${b.code}: ${l.text}`);
    }
  }
});

Deno.test("program pack: shape, provenance and index entry from MGMT-BS-GEN", () => {
  const prov = { source: "https://example.test/x", srcdb: "202630", fetched: "2026-11-26" };
  const pack = toProgramPack("MGMT-BS-GEN", "Management BS", parseTemplate(fixture("MGMT-BS-GEN")), prov);
  assertEquals([pack.code, pack.title, pack.goals.major, pack.blocks.length], ["MGMT-BS-GEN", "Management BS", "MGMT", 6]);
  assertEquals(pack.provenance, prov);
  assertEquals(pack.goalNames.MAJOR !== undefined, true);
  const idx = toIndexEntry(pack);
  assertEquals(idx.blocks.length, 6);
  assertEquals(idx.blocks[0], { reqId: "RA002124", type: "DEGREE", code: "BS", title: "Degree in Bachelor of Science in Economics" });
  assertEquals(Object.keys(idx).sort(), ["blocks", "code", "goals", "title"]);
});
