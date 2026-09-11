// Pure logic for course-website discovery -- the "many Penn courses keep
// their real material on an external site, not Canvas" problem described
// in PROTOCOL.md's course-website section. Nothing here touches the
// network or a database: `discover-websites/index.ts` calls into this
// module (and into `_shared/crawl.ts`, which does the actual fetching) and
// hands the results to `_shared/db.ts`-style Supabase calls, exactly the
// split `_shared/catalog.ts` and `_shared/manifest.ts` already establish
// for the rest of this backend. Kept pure so `websites.test.ts` can drive
// every branch (a stale CIS directory link, a `~cis19x` wildcard, a
// GitHub-repo link mistaken for a course site, ...) without a network call
// or a live Postgres.
//
// The concrete problem this file's `parseCisDirectory`/`conventionURLs`
// solve: CIS course sites live at wildly inconsistent URLs from one course
// to the next -- `~cis2400/current/` off `seas.upenn.edu`, a bare
// `cis1912.org`, a numbered subdomain `cis5550.seas.upenn.edu` -- so no
// single guessed pattern finds them all. The CIS Advising Handbook's own
// directory page is the best single source of truth for "what URL does
// this course actually use this semester", which is why it gets a whole
// parser here rather than being folded into `conventionURLs`' guesswork.

// ---------------------------------------------------------------------
// Small HTML helpers. This codebase has no DOM parser dependency and none
// of these pages need one -- they're simple, mostly-static course sites
// and a wiki-style advising directory, not arbitrary web content, so a
// handful of targeted regexes covers everything the brief's fixtures (and
// real Just-the-Docs/plain-HTML Penn course sites) throw at this.
// ---------------------------------------------------------------------

const NAMED_ENTITIES: Readonly<Record<string, string>> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: "\"",
  apos: "'",
  nbsp: " ",
  mdash: "—",
  ndash: "–",
  hellip: "…",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  copy: "©",
  reg: "®",
};

/** Decodes the handful of HTML entities actually likely to show up on a
 *  course site's title, headings and prose -- named entities from the
 *  table above plus any numeric (`&#8217;`) or hex (`&#x2019;`) reference.
 *  An entity this table doesn't know and that isn't numeric is left as-is
 *  rather than guessed at, the same "don't invent a value the source
 *  didn't give you" posture the rest of this codebase takes toward model
 *  output. */
function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/g, (whole, entity: string) => {
    if (entity.startsWith("#x") || entity.startsWith("#X")) {
      const codePoint = Number.parseInt(entity.slice(2), 16);
      return Number.isFinite(codePoint) ? safeFromCodePoint(codePoint, whole) : whole;
    }
    if (entity.startsWith("#")) {
      const codePoint = Number.parseInt(entity.slice(1), 10);
      return Number.isFinite(codePoint) ? safeFromCodePoint(codePoint, whole) : whole;
    }
    return NAMED_ENTITIES[entity] ?? whole;
  });
}

function safeFromCodePoint(codePoint: number, fallback: string): string {
  try {
    return String.fromCodePoint(codePoint);
  } catch {
    return fallback;
  }
}

function collapseWhitespace(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Tags whose open/close introduces a visual line break -- used by
 *  `htmlToText` to turn "<p>A</p><p>B</p>" into two lines instead of
 *  "A B" run together, which matters for a syllabus's grading table or a
 *  schedule's row-per-week structure reading sensibly as plain text. */
const BLOCK_TAG_NAMES = "p|div|li|tr|h[1-6]|section|article|header|footer|nav|ul|ol|table|br";
const BLOCK_OPEN_PATTERN = new RegExp(`<(?:${BLOCK_TAG_NAMES})\\b[^>]*>`, "gi");
const BLOCK_CLOSE_PATTERN = new RegExp(`<\\/(?:${BLOCK_TAG_NAMES})>`, "gi");

/** Strips tags to plain text without the block-boundary newline handling
 *  `htmlToText` does -- used internally for short fragments (an anchor's
 *  inner text, a `<title>`'s content) where a single collapsed line is
 *  what every caller wants, not a multi-line rendering. */
function stripTagsPlain(html: string): string {
  return decodeEntities(html.replace(/<[^>]+>/g, " "));
}

/**
 * Renders `html` into readable plain text: strips `<script>`, `<style>`
 * and `<noscript>` (content and all -- unlike every other tag, these two
 * carry text a reader never sees and a naive tag-strip would otherwise
 * leave CSS rules or JS source sitting in the output), decodes entities,
 * and inserts a newline at block-element boundaries so the result reads
 * as paragraphs and rows rather than one run-on line. Navigation markup
 * (`<nav>`) is deliberately *not* stripped -- on a course site, the nav is
 * often the assignment/schedule link list itself, exactly the kind of
 * fact `ask` needs to answer "what's due" from a crawled page.
 */
export function htmlToText(html: string): string {
  let work = html;
  work = work.replace(/<!--[\s\S]*?-->/g, " ");
  work = work.replace(/<script\b[\s\S]*?<\/script>/gi, " ");
  work = work.replace(/<style\b[\s\S]*?<\/style>/gi, " ");
  work = work.replace(/<noscript\b[\s\S]*?<\/noscript>/gi, " ");
  work = work.replace(BLOCK_CLOSE_PATTERN, "\n");
  work = work.replace(BLOCK_OPEN_PATTERN, "\n");
  work = work.replace(/<[^>]+>/g, " ");
  work = decodeEntities(work);
  work = work.replace(/[ \t]+/g, " ");
  work = work.replace(/[ \t]*\n[ \t]*/g, "\n");
  work = work.replace(/\n{3,}/g, "\n\n");
  return work.trim();
}

/** The document's `<title>`, decoded and whitespace-collapsed. Empty
 *  string when there is no `<title>` at all -- callers treat that as
 *  "nothing to go on from the title", not an error. */
export function pageTitle(html: string): string {
  const match = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  return match ? collapseWhitespace(stripTagsPlain(match[1])) : "";
}

/** The first `<h1>`'s text, decoded and whitespace-collapsed. Used by
 *  `verifyPage` alongside the title -- a Just-the-Docs page (see the
 *  `cis2400-home.html` fixture) states its course and term in an `<h1
 *  id="cis-2400-fall-2026">` more reliably than in `<title>`, which page
 *  templates sometimes leave generic. */
function firstH1Text(html: string): string {
  const match = html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i);
  return match ? collapseWhitespace(stripTagsPlain(match[1])) : "";
}

// ---------------------------------------------------------------------
// IGNORED_HOSTS / candidateFromLink
// ---------------------------------------------------------------------

/** Hosts that are never a course's *own* website even when a course page
 *  links to them -- LMS/tooling infrastructure (Canvas itself, Gradescope,
 *  Ed, OHQ, Piazza), meeting/recording platforms (Zoom, Panopto, YouTube),
 *  and generic Google product links (Calendar, Docs, Forms, Drive) a
 *  professor drops into a syllabus. Matching is suffix-based (`hostname
 *  === entry` or `hostname.endsWith("." + entry)`) rather than substring,
 *  specifically so a real, unrelated domain that merely happens to
 *  *contain* one of these strings (a hypothetical "notgoogle.com") is
 *  never mistaken for it. */
export const IGNORED_HOSTS: readonly string[] = [
  "canvas.upenn.edu",
  "instructure.com",
  "gradescope.com",
  "edstem.org",
  "piazza.com",
  "ohq.io",
  "zoom.us",
  "upenn.zoom.us",
  "panopto.com",
  "youtube.com",
  "youtu.be",
  "google.com",
  "docs.google.com",
  "calendar.google.com",
  "forms.gle",
  "drive.google.com",
  "canvas-user-content.com",
  "files.canvas",
];

function hostMatchesEntry(hostname: string, entry: string): boolean {
  return hostname === entry || hostname.endsWith(`.${entry}`);
}

/** Whether `url` is on a host (or, for the Just-the-Docs footer credit
 *  link every course site built on that theme carries, a specific path on
 *  `github.com`) this backend never treats as a course's own website. The
 *  Just-the-Docs case is narrower than "ignore all of github.com" on
 *  purpose -- a course repo link (which `parseCisDirectory` separately
 *  drops for a different reason: repos aren't sites) is still a github.com
 *  URL a caller might reasonably want to see, just not from this
 *  function's candidate-scoring path. Exported (as `isIgnoredWebsiteHost`)
 *  so `_shared/crawl.ts` shares this exact rule for "never follow to
 *  ignored hosts" rather than re-deriving it from `IGNORED_HOSTS` on its
 *  own -- the just-the-docs special case in particular is easy to forget
 *  to re-implement. */
export function isIgnoredWebsiteHost(url: URL): boolean {
  const hostname = url.hostname.toLowerCase();
  if (IGNORED_HOSTS.some((entry) => hostMatchesEntry(hostname, entry))) return true;
  if (hostname === "github.com" && url.pathname.toLowerCase().startsWith("/just-the-docs")) return true;
  return false;
}

/** Query parameters that carry no identity information about the page
 *  itself (campaign/referrer tracking) -- stripped by `normalizeURL` so
 *  the same page reached via two differently-tracked links dedupes to one
 *  `course_websites` row instead of two near-identical ones. */
const TRACKING_PARAMS: ReadonlySet<string> = new Set([
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "fbclid",
  "gclid",
  "ref",
]);

/** Strips the fragment and any tracking query parameter from `url`,
 *  leaving everything else -- including a trailing slash on the path --
 *  exactly as given. The trailing slash is preserved deliberately: for a
 *  Just-the-Docs site, `/26fa/` and `/26fa` can be genuinely different
 *  resources (a directory index versus a 404, depending on the server),
 *  so "normalizing" it away would risk turning a working URL into a
 *  broken one. Exported (as `normalizeWebsiteURL`) so `_shared/crawl.ts`
 *  dedupes its BFS queue and visited set by the same notion of "same
 *  page" this file already uses for `course_websites` upserts. */
export function normalizeWebsiteURL(url: URL): string {
  const clone = new URL(url.toString());
  clone.hash = "";
  for (const key of [...clone.searchParams.keys()]) {
    if (TRACKING_PARAMS.has(key.toLowerCase())) clone.searchParams.delete(key);
  }
  return clone.toString().replace(/\?$/, "");
}

interface CompactCode {
  compact: string; // "cis2400"
  dashed: string; // "cis-2400"
  tilde: string; // "~cis2400"
}

/** Splits a Canvas course code ("CIS 2400", "cis-2400", ...) into the
 *  three shapes a course-website URL might spell it as. Returns
 *  `undefined` for anything that isn't recognizably a Penn course code --
 *  the same "don't guess a key nothing else agrees with" discipline
 *  `_shared/catalog.ts`'s `catalogCode` documents at length. */
function compactCode(courseCode: string): CompactCode | undefined {
  const cleaned = courseCode.toUpperCase().replace(/[\s-]+/g, "");
  const match = cleaned.match(/^([A-Z]{2,5})(\d{3,4}[A-Z]?)$/);
  if (!match) return undefined;
  const dept = match[1].toLowerCase();
  const num = match[2].toLowerCase();
  return { compact: `${dept}${num}`, dashed: `${dept}-${num}`, tilde: `~${dept}${num}` };
}

const COURSE_SITE_TEXT_PATTERN = /course\s?(?:web)?site|class\s?(?:web)?site|course\s?(?:home)?page/i;

export interface CandidateLinkInput {
  href: string;
  text: string;
  /** The page this link was found on -- resolves a relative `href` and
   *  distinguishes a same-page anchor (`href="#nav"`) from a real link. */
  origin: string;
  /** The Canvas course code (`courses.code`) this link was found under. */
  courseCode: string;
}

export interface WebsiteCandidate {
  url: string;
  confidence: number;
  source: "canvas-link";
}

/**
 * Scores one link found on a course's Canvas page/assignment/module/
 * syllabus as a possible course-website candidate. Returns `undefined` for
 * an ignored host, a non-http(s) or fragment-only href, or a link that
 * scores zero confidence -- a zero-confidence link (no code match, no
 * "course site" wording, not even a `.upenn.edu` host) is noise, not a
 * weak signal, and storing it would just give `discover-websites` more
 * junk to verify-and-reject every run for no benefit.
 *
 * Scoring is additive, not "first match wins": a link whose URL contains
 * the course code *and* whose anchor text says "course website" *and*
 * whose host is `.upenn.edu` scores all three (3 + 2 + 1 = 6), which is
 * exactly the kind of link `discover-websites` should verify first when
 * several candidates exist for one course.
 */
export function candidateFromLink(input: CandidateLinkInput): WebsiteCandidate | undefined {
  const trimmedHref = input.href.trim();
  if (trimmedHref.length === 0 || trimmedHref.startsWith("#")) return undefined;
  if (/^(javascript|mailto|tel):/i.test(trimmedHref)) return undefined;

  let url: URL;
  try {
    url = new URL(trimmedHref, input.origin);
  } catch {
    return undefined;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return undefined;
  if (isIgnoredWebsiteHost(url)) return undefined;

  const normalized = normalizeWebsiteURL(url);
  const haystack = normalized.toLowerCase();

  let confidence = 0;

  const code = compactCode(input.courseCode);
  if (code && (haystack.includes(code.compact) || haystack.includes(code.dashed) || haystack.includes(code.tilde))) {
    confidence += 3;
  }
  if (COURSE_SITE_TEXT_PATTERN.test(input.text)) {
    confidence += 2;
  }
  if (url.hostname.toLowerCase().endsWith("upenn.edu")) {
    confidence += 1;
  }

  if (confidence === 0) return undefined;
  return { url: normalized, confidence, source: "canvas-link" };
}

// ---------------------------------------------------------------------
// parseCisDirectory
// ---------------------------------------------------------------------

/** The CIS Advising Handbook's course directory -- relative hrefs on that
 *  page (there shouldn't be any, but nothing guarantees it) resolve
 *  against this. */
const CIS_DIRECTORY_BASE_URL = "https://advising.cis.upenn.edu/course-dir/";

const COURSE_CODE_PATTERN = /\b(CIS|CIT|NETS|ESE)\s?-?\s?(\d{3,4}[A-Z]?)\b/i;

function findCodeInText(text: string): string | undefined {
  const match = text.match(COURSE_CODE_PATTERN);
  return match ? `${match[1].toUpperCase()}-${match[2].toUpperCase()}` : undefined;
}

/** A code embedded in the URL itself -- `~cis1210` in the path, or
 *  `cis5550.seas.upenn.edu` / `cis1912.org` where the department+number
 *  *is* the hostname's first label. Requires the number to be all digits,
 *  which is what naturally excludes a `~cis19x`-style wildcard alias (the
 *  handbook's own placeholder for "any 19xx-numbered special topics
 *  course") -- `\d{3,4}` simply never matches the literal letter `x`. */
function codeFromHref(url: URL): string | undefined {
  const hostLabel = url.hostname.toLowerCase().split(".")[0] ?? "";
  const hostMatch = hostLabel.match(/^([a-z]{2,5})(\d{3,4})$/);
  if (hostMatch) return `${hostMatch[1].toUpperCase()}-${hostMatch[2]}`;

  for (const segment of url.pathname.toLowerCase().split("/")) {
    if (!segment.startsWith("~")) continue;
    const match = segment.slice(1).match(/^([a-z]{2,5})(\d{3,4})$/);
    if (match) return `${match[1].toUpperCase()}-${match[2]}`;
  }
  return undefined;
}

/** Whether `url` is directory/handbook furniture rather than a course's
 *  own site -- a link back to the advising site's own navigation, or to
 *  the department's plain index page (as opposed to one of its `~courseN`
 *  personal-page-style course sites, which live on the same host and must
 *  NOT be caught by this). GitHub links are dropped for an unrelated
 *  reason: a course's source-code repository is not a website students
 *  read for assignments and policies. */
function isDirectoryNoise(url: URL): boolean {
  const host = url.hostname.toLowerCase();
  if (host === "github.com" || host.endsWith(".github.com")) return true;
  if (host === "advising.cis.upenn.edu" || host.endsWith(".advising.cis.upenn.edu")) return true;
  if (host === "ugrad.cis.upenn.edu" || host.endsWith(".ugrad.cis.upenn.edu")) return true;
  if ((host === "cis.upenn.edu" || host === "www.cis.upenn.edu") && !url.pathname.includes("~")) return true;
  return false;
}

function extractRowBlocks(html: string): string[] {
  const trBlocks = [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)].map((match) => match[1]);
  if (trBlocks.length > 0) return trBlocks;
  return [...html.matchAll(/<li\b[^>]*>([\s\S]*?)<\/li>/gi)].map((match) => match[1]);
}

function matchAnchors(block: string): Array<{ href: string; text: string }> {
  const anchors: Array<{ href: string; text: string }> = [];
  const pattern = /<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)<\/a>/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(block)) !== null) {
    const href = (match[1] ?? match[2] ?? "").trim();
    if (href.length === 0) continue;
    anchors.push({ href, text: collapseWhitespace(stripTagsPlain(match[3])) });
  }
  return anchors;
}

export interface DirectoryEntry {
  catalogCode: string;
  url: string;
}

/**
 * Parses the CIS Advising Handbook's course directory into
 * `{ catalogCode, url }` pairs. Scans by row (`<tr>`, falling back to
 * `<li>` for a list-style layout) rather than by anchor alone, because the
 * directory's own markup can put the course code and the link in separate
 * cells of the same row -- an anchor's own text is tried first ("CIS
 * 1210" as the link text itself), then the row's whole text as a fallback
 * (a code in a sibling `<td>`), then a code embedded in the href itself
 * (`~cis1210`, `cis5550.`, `cis1912.org`) for the entries that have
 * neither -- see `codeFromHref`. A link with no recoverable code by any
 * of those three means (the handbook's own `~cis19x` wildcard placeholder,
 * a GitHub repo link, a link back to the handbook's own navigation) is
 * silently skipped rather than guessed at.
 */
export function parseCisDirectory(html: string): DirectoryEntry[] {
  const entries: DirectoryEntry[] = [];
  const seen = new Set<string>();

  for (const block of extractRowBlocks(html)) {
    const rowCode = findCodeInText(stripTagsPlain(block));

    for (const anchor of matchAnchors(block)) {
      let url: URL;
      try {
        url = new URL(anchor.href, CIS_DIRECTORY_BASE_URL);
      } catch {
        continue;
      }
      if (url.protocol !== "http:" && url.protocol !== "https:") continue;
      if (isDirectoryNoise(url)) continue;

      const code = findCodeInText(anchor.text) ?? rowCode ?? codeFromHref(url);
      if (!code) continue;

      const normalized = url.toString();
      const key = `${code}|${normalized}`;
      if (seen.has(key)) continue;
      seen.add(key);
      entries.push({ catalogCode: code, url: normalized });
    }
  }

  return entries;
}

// ---------------------------------------------------------------------
// conventionURLs
// ---------------------------------------------------------------------

/**
 * The two URL patterns nearly every CIS/CIT course site follows when
 * nothing else (a Canvas link, the CIS directory) has found it yet --
 * `~courseN/current/` off either of the department's two historical
 * hostnames. Deliberately CIS/CIT-only: this convention is specific to
 * that department's course-site tooling, and guessing the same shape for
 * an arbitrary other department would produce URLs that mostly 404,
 * exactly the "guessed at" failure mode this codebase avoids elsewhere
 * (see `catalogCode`'s and `compactCode`'s doc comments).
 */
export function conventionURLs(catalogCode: string): string[] {
  const match = catalogCode.toUpperCase().replace(/[\s-]+/g, "").match(/^([A-Z]{2,5})(\d{3,4}[A-Z]?)$/);
  if (!match) return [];
  const dept = match[1];
  if (dept !== "CIS" && dept !== "CIT") return [];
  const compact = `${dept.toLowerCase()}${match[2].toLowerCase()}`;
  return [
    `https://www.seas.upenn.edu/~${compact}/current/`,
    `https://www.cis.upenn.edu/~${compact}/current/`,
  ];
}

// ---------------------------------------------------------------------
// termAliases
// ---------------------------------------------------------------------

/**
 * The strings a fall/spring/summer term can plausibly be spelled as, in a
 * page's title/heading/body or in its URL path -- Penn's own `"2026C"`
 * semester code (the shape `catalog_courses.semester` stores) alongside
 * every abbreviation a course site's own URL scheme tends to use ("26fa",
 * "fa26", Just-the-Docs' own "current" branch naming aside). `verifyPage`
 * below is the only caller; a semester string that doesn't parse as
 * `NNNNL` returns `[]` rather than guessing, so an unrecognized or future
 * Penn term code degrades to "nothing verifies as this term" rather than
 * a wrong match.
 */
export function termAliases(semester: string): string[] {
  const match = semester.trim().match(/^(\d{4})([ABC])$/i);
  if (!match) return [];
  const year = match[1];
  const yy = year.slice(2);
  const code = match[2].toUpperCase();

  if (code === "C") {
    return [`fall ${year}`, `${year} fall`, `${yy}fa`, `fa${yy}`, `f${yy}`, `fall${yy}`, `${year}c`.toLowerCase()];
  }
  if (code === "A") {
    return [`spring ${year}`, `${year} spring`, `sp${yy}`, `${yy}sp`, `s${yy}`];
  }
  return [`summer ${year}`, `${year} summer`, `su${yy}`, `${yy}su`];
}

// ---------------------------------------------------------------------
// verifyPage
// ---------------------------------------------------------------------

/** Fixed-size window read from the *front* of the page for term/code
 *  matching -- matches `_shared/profile.ts`'s posture toward long
 *  documents (a course's welcome paragraph and current-term statement are
 *  always near the top; scanning the whole page buys nothing and costs
 *  more CPU per verification call). */
const VERIFY_BODY_HEAD_CHARS = 3000;

function codeAppearsIn(haystackLower: string, catalogCode: string): boolean {
  const match = catalogCode.toUpperCase().replace(/[\s-]+/g, "").match(/^([A-Z]{2,5})(\d{3,4}[A-Z]?)$/);
  if (!match) return false;
  const dept = match[1].toLowerCase();
  const num = match[2].toLowerCase();
  return (
    haystackLower.includes(`${dept} ${num}`) ||
    haystackLower.includes(`${dept}-${num}`) ||
    haystackLower.includes(`${dept}${num}`)
  );
}

export interface VerifyPageInput {
  html: string;
  /** The URL actually served after redirects (`~cis2400/current/` ->
   *  `~cis2400/26fa/`) -- both the code/term text checks and the
   *  URL-path term check use this, never the URL originally requested. */
  finalURL: string;
  catalogCode: string;
  semester: string;
}

export interface VerifyPageResult {
  ok: boolean;
  title: string;
  termHit: boolean;
  codeHit: boolean;
  reason: string;
}

/**
 * Whether a fetched page is actually *this* course's site for *this*
 * term, not merely a page that happens to live at a URL that looked
 * right. Both signals matter independently: a stale `~bhusnur4/cis105/
 * 16fa/` page states its own course code plainly but never mentions the
 * current term, and a department's generic "current courses" listing page
 * might mention the term everywhere but never states any one course's
 * code -- `ok` requires both, `codeHit`/`termHit` are returned separately
 * so `discover-websites` and tests can tell the two failure modes apart
 * (`reason` renders that same distinction as a human-readable string for
 * logging).
 */
export function verifyPage(input: VerifyPageInput): VerifyPageResult {
  const title = pageTitle(input.html);
  const h1 = firstH1Text(input.html);
  const bodyHead = htmlToText(input.html).slice(0, VERIFY_BODY_HEAD_CHARS);
  const haystack = `${title} ${h1} ${bodyHead}`.toLowerCase();

  const codeHit = codeAppearsIn(haystack, input.catalogCode);

  const aliases = termAliases(input.semester);
  const urlLower = input.finalURL.toLowerCase();
  const termHit = aliases.some((alias) => haystack.includes(alias) || urlLower.includes(alias.replace(/\s+/g, "")));

  const ok = codeHit && termHit;
  const reason = ok
    ? "matched course code and term"
    : codeHit
    ? "matched course code but not term"
    : termHit
    ? "matched term but not course code"
    : "matched neither course code nor term";

  return { ok, title, termHit, codeHit, reason };
}

// ---------------------------------------------------------------------
// extractLinks / sideIDs
// ---------------------------------------------------------------------

export interface ExtractedLink {
  href: string;
  text: string;
}

/**
 * Every outbound anchor on a page, hrefs resolved to absolute against
 * `baseURL`. Same-page anchors (`#nav`), `javascript:` and `mailto:`
 * hrefs are skipped -- none of them are a page `_shared/crawl.ts` could
 * ever meaningfully fetch, and keeping them out here means every caller
 * of this function (the crawler's own link-following, `sideIDs` below,
 * `discover-websites`' link-based rediscovery) gets that filtering for
 * free instead of re-implementing it.
 */
export function extractLinks(html: string, baseURL: string): ExtractedLink[] {
  const links: ExtractedLink[] = [];
  const pattern = /<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)<\/a>/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(html)) !== null) {
    const rawHref = (match[1] ?? match[2] ?? "").trim();
    if (rawHref.length === 0 || rawHref.startsWith("#")) continue;
    if (/^(javascript|mailto):/i.test(rawHref)) continue;

    let absolute: string;
    try {
      absolute = new URL(rawHref, baseURL).toString();
    } catch {
      continue;
    }

    links.push({ href: absolute, text: collapseWhitespace(stripTagsPlain(match[3])) });
  }
  return links;
}

/** Pulls a Gradescope and/or Ed course id out of a page's outbound links,
 *  when present -- `discover-websites` stores these on the
 *  `course_websites` row once found so a future feature could, in
 *  principle, cross-link a course's Gradescope/Ed presence without its own
 *  separate discovery pass. Only the *first* match of each kind is kept;
 *  a page linking two different Gradescope course ids would be unusual
 *  and there is no way to know which one is "the" course's from the link
 *  alone, so taking the first (in document order) is a defensible,
 *  deterministic choice rather than an attempt to disambiguate. */
export function sideIDs(links: ExtractedLink[]): { gradescopeCourseID?: string; edCourseID?: string } {
  let gradescopeCourseID: string | undefined;
  let edCourseID: string | undefined;

  for (const link of links) {
    let url: URL;
    try {
      url = new URL(link.href);
    } catch {
      continue;
    }
    const host = url.hostname.toLowerCase();

    if (!gradescopeCourseID && (host === "gradescope.com" || host.endsWith(".gradescope.com"))) {
      const match = url.pathname.match(/\/courses\/(\d+)/);
      if (match) gradescopeCourseID = match[1];
    }
    if (!edCourseID && (host === "edstem.org" || host.endsWith(".edstem.org"))) {
      const match = url.pathname.match(/\/courses\/(\d+)/);
      if (match) edCourseID = match[1];
    }
  }

  const result: { gradescopeCourseID?: string; edCourseID?: string } = {};
  if (gradescopeCourseID) result.gradescopeCourseID = gradescopeCourseID;
  if (edCourseID) result.edCourseID = edCourseID;
  return result;
}

/** The last non-empty path segment of `url`, decoded, or the hostname
 *  when the path is empty (`/` or `""`) -- used as a page's title when it
 *  has none of its own (a PDF, an HTML page missing `<title>`). Shared by
 *  `_shared/crawl.ts` (a PDF's title) and `discover-websites/index.ts` (an
 *  HTML page whose `pageTitle` came back empty). */
export function lastPathSegment(url: URL): string {
  const segments = url.pathname.split("/").filter((segment) => segment.length > 0);
  return segments.length > 0 ? decodeURIComponent(segments[segments.length - 1]) : url.hostname;
}

// ---------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------

async function sha256Hex(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * The `course_documents.id` a crawled page gets:
 * `"website:{courseID}:{first 16 hex chars of sha-256(url)}"`, mirroring
 * the client's own `"{kind}:{courseID}:{sourceID}"` id scheme
 * (`_shared/manifest.ts`) but with the *URL* standing in for a Canvas
 * `sourceID` -- a crawled page has no Canvas id to key on, and the page's
 * own URL is the one thing about it that is both stable across re-crawls
 * and guaranteed unique within a course's site. Sixteen hex characters (64
 * bits) is exactly `_shared/catalog.ts`-adjacent code's usual "collision
 * astronomically unlikely, id stays short" tradeoff, not a security
 * boundary -- nothing about this id needs to be unguessable.
 */
export async function websiteDocumentID(courseID: string, url: string): Promise<string> {
  const hex = await sha256Hex(url);
  return `website:${courseID}:${hex.slice(0, 16)}`;
}

/**
 * `content_hash` for a server-authored `course_documents` row. Explicitly
 * *not* the FNV-1a hash the iOS client computes for its own uploaded
 * documents (see `CourseKnowledgeCollector`/`CourseDocument.contentHash`
 * on the client) -- a crawled page never round-trips through the client's
 * hashing at all, it is written directly by `discover-websites` and read
 * back only by this same backend (the manifest diff in `sync` treats it
 * as an opaque string to compare for equality, never re-derives it), so
 * any stable hash of the same inputs is equally correct here. SHA-256 is
 * used rather than reimplementing FNV-1a specifically to avoid the
 * appearance that the two are meant to match.
 */
export async function websiteContentHash(title: string, text: string): Promise<string> {
  return sha256Hex(`${title} ${text}`);
}

// ---------------------------------------------------------------------
// Staleness windows -- shared by `discover-websites/index.ts` for three
// independent re-check decisions (a verified site's verification, a
// verified site's crawl, the CIS directory page's own cache) that all
// happen to use "how long ago was this last done" as their trigger.
// Pulled out here, once, rather than three ad-hoc `Date` subtractions in
// the function itself, for the same reason `_shared/catalog.ts`'s
// `catalogIsStale` takes `now` as a parameter: deterministic, testable
// without touching the system clock.
// ---------------------------------------------------------------------

export const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
export const ONE_DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Whether `dateISO` (a `verified_at`, `last_crawled_at` or
 * `directory_cache.fetched_at` timestamp, or `null` for "never happened
 * yet") is more than `maxAgeMs` old as of `now`. `null` and an
 * unparseable timestamp both count as stale -- "never done" and "done,
 * but the record of when is corrupt" should both trigger a re-check
 * rather than either silently pinning something as permanently fresh.
 */
export function olderThan(dateISO: string | null, now: Date, maxAgeMs: number): boolean {
  if (dateISO === null) return true;
  const ms = new Date(dateISO).getTime();
  if (Number.isNaN(ms)) return true;
  return now.getTime() - ms > maxAgeMs;
}

// ---------------------------------------------------------------------
// websitesPendingCourses
// ---------------------------------------------------------------------

export interface WebsitePendingCourseInput {
  courseID: string;
  /** Whether this course already has at least one `course_websites` row
   *  of any status -- a course with zero candidates and no CIS/CIT
   *  catalog code has nothing for `discover-websites` to even try. */
  hasCandidate: boolean;
  /** Whether a `course_websites` row for this course is `verified` with a
   *  `verified_at` within `SEVEN_DAYS_MS` -- the caller (`sync/index.ts`)
   *  computes this from `selectCourseWebsites` rows via `olderThan`. */
  recentlyVerified: boolean;
  /** `courses.catalog_code`, when resolved -- undefined when this course's
   *  code never resolved to one (see `_shared/catalog.ts`'s
   *  `catalogCode`). */
  catalogCode?: string;
}

/**
 * `sync`'s `websitesPending` response field: courses the client should
 * immediately follow up on with a `discover-websites` call, per
 * PROTOCOL.md's sync section. A course qualifies when it does *not*
 * already have a website verified in the last week, and there is some
 * reason to think `discover-websites` might find something new -- either
 * a candidate already sitting in `course_websites` waiting to be
 * verified, or the course is CIS/CIT (the one department
 * `conventionURLs` can guess a URL for even with zero candidates and zero
 * directory entry yet). A non-CIS/CIT course with no candidate at all is
 * left out on purpose: there is nothing `discover-websites` could do for
 * it besides a wasted CIS-directory-only pass, and PROTOCOL.md's
 * `sync`-piggyback discipline (see the catalog refresh's own reasoning)
 * is to only ever spend that work where there's a real chance of it
 * finding something.
 */
export function websitesPendingCourses(courses: WebsitePendingCourseInput[]): string[] {
  return courses
    .filter((course) => {
      if (course.recentlyVerified) return false;
      const dept = course.catalogCode?.match(/^([A-Za-z]+)/)?.[1]?.toUpperCase();
      const isCisOrCit = dept === "CIS" || dept === "CIT";
      return course.hasCandidate || isCisOrCit;
    })
    .map((course) => course.courseID);
}
