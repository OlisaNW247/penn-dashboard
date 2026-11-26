// The degree planner's contracts. Three modules meet here:
//
//   catalog.ts      fetches Penn's public course data (Penn Labs' course API,
//                   the CIS technical-elective list) into a CatalogSnapshot.
//   requirements.ts turns the audits the phone sends into Degree/Slot values.
//   planner.ts      pure: chooses courses (counting one course toward both
//                   degrees where the rules allow) and schedules them.
//
// Why this exists (2026-11-15): asking one model call to read two audits and
// produce a whole plan failed four times on a real dual-degree student. It
// filled placeholder rows, guessed courses into slots they could not fill,
// never counted a course toward both degrees, ignored Penn's load rules, and
// could not tell that the request did not fit. A plan made by hand with real
// catalogue data (attribute lists, the CIS list) and arithmetic got it right.
// So the arithmetic and the matching live in code, and the model only reads
// the student's request and explains the result.
//
import type { PackShare } from "./pack.ts";

// Term codes are Penn's: YYYY10 spring, YYYY20 summer, YYYY30 fall.
// Penn Labs' semester ids are YYYYA (spring), YYYYB (summer), YYYYC (fall).

export type Season = "spring" | "summer" | "fall";

// ---------------------------------------------------------------------------
// Catalogue
// ---------------------------------------------------------------------------

export interface CatalogCourse {
  /** "BEPP 2500" (subject, a space, four digits; normalized upper case). */
  code: string;
  title: string;
  /** Course units. */
  credits: number;
  /** Penn attribute codes, e.g. ["EUCU", "EUSS"]. Empty when unknown. */
  attributes: string[];
  /** Seasons the course was offered in the semesters fetched. */
  offered: { fall: boolean; spring: boolean; summer: boolean };
  /** Penn's free-text prerequisites, when fetched. */
  prerequisites?: string;
  /** Codes cross-listed with this one ("REAL 2360" for "BEPP 2360"). */
  crosslistings?: string[];
}

/** Everything the planner may look up, fetched before it runs, so the planner
 *  itself is pure and synchronous. */
export interface CatalogSnapshot {
  courses: Record<string, CatalogCourse>;
  /** Attribute code -> course codes that carry it (from Penn Labs' search). */
  attributeIndex: Record<string, string[]>;
  /** CIS technical-elective list, status for students entering fall 2024 or
   *  later: "unrestricted" | "restricted" | "no" | "ask". */
  cisTechElective: Record<string, string>;
  /** Penn Labs semesters the data came from, e.g. ["2026C", "2027A", "2026B"]. */
  semesters: string[];
}

// ---------------------------------------------------------------------------
// Requirements
// ---------------------------------------------------------------------------

/** How a course can be eligible for a slot. A slot accepts a course that
 *  matches any `anyOf` entry and no `exclude` entry. */
export type Eligibility =
  | { kind: "courses"; codes: string[] }
  /** Degree Works wildcard: "MGMT @", "CIS 2@", "@ @". */
  | { kind: "pattern"; pattern: string }
  | { kind: "attribute"; codes: string[] }
  /** "Any MGMT 1011-4180 course(s)": inclusive numeric range in one subject. */
  | { kind: "range"; subject: string; from: number; to: number }
  /** "Any ACCT course(s)". */
  | { kind: "subject"; subjects: string[] }
  /** "any 2970 course(s)": a course number in any subject. */
  | { kind: "number"; numbers: number[] };

/** Groups the within-degree double-counting policy reasons about. */
export type SlotGroup =
  | "wharton.fundamental"
  | "wharton.flex"            // Global Economy, Technology/Innovation/Analytics
  | "wharton.leadership"      // MGMT 3010 and the capstone
  | "wharton.liberal"         // humanities, NSME, social science, flex gen ed
  | "wharton.crossCultural"
  | "wharton.language"
  | "wharton.breadth"
  | "wharton.concentration"
  | "seas.core"
  | "seas.math"
  | "seas.techElective"
  | "seas.general"            // SSH / ethics / free electives
  | "other";

/** A share as the slot holds it: where it came from decides its cap's budget. */
export type SlotShare = PackShare & { from: "block" | "rule" };

/** What Penn's template says about one requirement's sharing. */
export interface SlotPack {
  program: string;
  blockType: string;
  blockCode: string;
  /** The template block's Req_id; two slots are in the same block when equal. */
  reqId: string;
  /** The audit block's id equalled the template block's reqId. Otherwise the
   *  block was matched by type and title, so it may be another catalog year of
   *  the same block. */
  exact: boolean;
  /** Block shares + the rule's own + its ancestors', deduplicated. */
  share: SlotShare[];
  /** EXCLUSIVE on the rule, an ancestor rule or the block: shares with nothing. */
  exclusive: boolean;
  /** The slot is a header overlay (an "area list"), not a competing rule. */
  overlay: boolean;
  ruleLabel?: string;
}

export interface Slot {
  /** Unique within a request: `${degreeId}|${blockId}|${ruleId}`. */
  id: string;
  degreeId: string;
  degreeLabel: string;
  /** Penn's own label, e.g. "Global Economy, Business and Society". */
  label: string;
  blockTitle: string;
  /** The audit block's id and type ("MAJOR", "OTHER", ...). */
  blockId: string;
  blockType: string;
  /** Penn's own sharing rules for this requirement, when the program's
   *  published template was joined to the audit (packJoin.ts). */
  pack?: SlotPack;
  /** What is still needed, after courses taken and in progress. */
  need: number;
  unit: "cu" | "courses";
  anyOf: Eligibility[];
  exclude: Eligibility[];
  group: SlotGroup;
  /** Extra rules some slots carry (Wharton business breadth). */
  constraints?: {
    /** Each course from a different subject, and none from these subjects. */
    distinctSubjects?: boolean;
    excludeSubjects?: string[];
    /** Subjects already used by courses applied to this slot. */
    usedSubjects?: string[];
    /** Minimum course number (e.g. 2000 for "upper level"). */
    minNumber?: number;
  };
  /** Penn's words, for the explanation. */
  text?: string;
}

export interface Degree {
  id: string;
  /** "computer science", "management (what if, not declared)". */
  label: string;
  /** Penn school code from the audit's goals: "WU", "EU", "AS", ... */
  college: string;
  slots: Slot[];
  /** Courses Penn already applies to this degree (taken or in progress). */
  applied: string[];
  /** Penn's own count of cu earned plus in progress, read from the audit's
   *  DEGREE block ("You currently have 28.5 CU including ..."). Undefined
   *  when the audit has no such line; never guessed from course lists. */
  creditsSoFar?: number;
  /** The audit's goals object, leniently read. */
  goals?: DegreeGoals;
}

export interface DegreeGoals {
  college: string;
  degree: string;
  program: string;
  majors: string[];
  concentrations: string[];
  minors: string[];
  catalogYear: string;
}

// ---------------------------------------------------------------------------
// Planner input and output
// ---------------------------------------------------------------------------

export interface PlanRequest {
  degrees: Degree[];
  /** Every course already taken or in progress, normalized codes. */
  taken: string[];
  /** Courses taken per term code, for prerequisite checks and load rules. */
  history: Record<string, string[]>;
  /** Credits already registered per future term code (term -> cu). A term's
   *  load is registered plus planned, so the planner seeds each term with
   *  this and offers only what is left under the cap. Omitted: nothing is
   *  registered ahead. The wrong fix is capping the phone's table instead. */
  registered?: Record<string, number>;
  /** The term in progress now, e.g. "202630". */
  currentTerm: string;
  /** The last term the student wants to finish by, if they said. */
  targetTerm?: string;
  /** Load the student said they will take; overrides the scenario caps. */
  maxLoad?: number;
  /** Whether summer terms may be used (default true). */
  allowSummer?: boolean;
  /** Slot ids the student says are already handled (e.g. the language
   *  requirement by a placement exam); they are not filled. */
  waive?: string[];
  /** Codes never to plan. */
  avoid?: string[];
  /** Codes to prefer when choosing between equals. */
  prefer?: string[];
}

export type Approval =
  /** Penn's own rules accept it: an explicit option, the attribute, the range. */
  | "automatic"
  /** Counting it here needs an advisor's approval (a within-degree double
   *  count the policy does not allow by default). */
  | "petition"
  /** Plausible but unverified (no catalogue data for the course). */
  | "check";

export interface PlannedCourseOut {
  code: string;
  title: string;
  credits: number;
  /** Labels of the slots it fills, "computer science · technical electives". */
  countsToward: string[];
  /** Ids of the slots it fills, same order and length as `countsToward`:
   *  `${degreeId}|${blockId}|${ruleId}`, plus `|${courseCode}` for a slot made
   *  per advised course. */
  slotIds: string[];
  approval: Approval;
  note?: string;
}

export interface PlannedTermOut {
  term: string;
  courses: PlannedCourseOut[];
  credits: number;
  /** Credits the student is already registered for in this term (omitted
   *  when none). `credits` is only what the plan adds. */
  registeredCredits?: number;
}

export interface Scenario {
  id: "standard" | "summer" | "approved" | "student" | "best";
  /** "5.5 cu a semester, no summer". */
  label: string;
  maxLoad: number;
  summer: boolean;
  /** Earliest term the plan finishes in under this scenario, or null when it
   *  cannot be placed within the planning horizon. */
  finishTerm: string | null;
  /** Whether it finishes by the target term (true when there is no target). */
  meetsTarget: boolean;
}

export interface Unfilled {
  slotId: string;
  degreeLabel: string;
  label: string;
  /** Why the planner could not fill it: "no eligible course in the catalogue",
   *  "needs a declared concentration", ... */
  reason: string;
}

export interface PlanResult {
  /** CU still to take under the chosen assignment. */
  remainingCredits: number;
  /** CU that would be needed with no course counted twice, for comparison. */
  remainingCreditsWithoutOverlap: number;
  scenarios: Scenario[];
  /** The scenario the schedule below uses: the first that meets the target,
   *  else the one that finishes earliest. */
  chosen: Scenario["id"];
  schedule: PlannedTermOut[];
  unfilled: Unfilled[];
  /** Within-degree double counts that would save credits if an advisor
   *  approved them. */
  petitions: { code: string; slots: string[]; savesCredits: number }[];
  /** Plain-language notes the explanation should mention (prerequisite
   *  ordering, a rule applied, data that was missing). */
  notes: string[];
}
