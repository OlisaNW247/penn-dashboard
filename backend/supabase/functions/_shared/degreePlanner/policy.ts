// Penn's rules about counting and scheduling courses, kept apart from the
// planner so a rule change is a change here and nowhere else. Read from the
// official SEAS and Wharton pages on 2026-11-15; anything an advisor decides
// case by case lives in `petitionPairs`, never in the main plan.

import type { Degree, Slot } from "./types.ts";

export interface Policy {
  /** A course may fill at most this many slots in each degree (and so counts
   *  toward every degree once). Inside one degree a second slot needs
   *  `withinDegree`. */
  crossDegree: { maxPerDegree: number };
  /** May one course fill both slots inside one degree? */
  withinDegree(a: Slot, b: Slot): boolean;
  /** A ceiling on how many CU of one course-credit may be double counted by
   *  this kind of pair in one degree, or null for no ceiling. */
  withinDegreeCap(a: Slot, b: Slot): { key: string; cu: number } | null;
  /** Within-degree pairs an advisor sometimes approves. Used only for the
   *  "petitions" report. */
  petitionPairs(a: Slot, b: Slot): boolean;
  loads: {
    standard: number;
    approved: number;
    /** The planner's own cautious default for a summer in the ordinary
     *  scenarios: one course per session. It is NOT Penn's limit. */
    summerPerTerm: number;
    /** Penn's limit for one summer (Engineering's handbook, Enrollment page,
     *  read 2026-11-26): 4 cu in the 11-week session, no more than 2 in
     *  Summer Session I or II. There is no cap across summers, so the
     *  old "4 in all" total was invented and is gone; the wrong fix
     *  is to bring a total back. */
    summerCeiling: number;
    /** Who has to approve a semester above the standard load, in words. */
    approvalNote(colleges: string[], load: number): string;
  };
  /** The least total cu a degree combination needs, or null. */
  totalFloor(degrees: Degree[]): { cu: number; reason: string } | null;
  sequences: {
    /** `first` must sit in the semester immediately before `second` (fall to
     *  the following spring), as the two halves of a senior project do. */
    immediatelyBefore(first: Slot, second: Slot): boolean;
    /** A course whose prerequisite text names another planned course comes
     *  after it. */
    prerequisiteOrdering: boolean;
  };
  capstoneRule: {
    isCapstone(slot: Slot): boolean;
    /** Courses filling these slots finish before the capstone course. */
    mustPrecedeCapstone(slot: Slot): boolean;
    /** Wharton's Senior Capstone page (read 2026-11-26): "Wharton-Engineering
     *  dual-degree students (including M&T) will satisfy the capstone
     *  requirement via their BAS or BSE degree design project or thesis
     *  requirements." True when the slot is Wharton's capstone and the
     *  request holds an Engineering degree beside the Wharton one. */
    satisfiedBySeniorDesign(slot: Slot, degrees: Degree[]): boolean;
  };
}

function isPair(a: Slot, b: Slot, g1: string, g2: string): boolean {
  return (a.group === g1 && b.group === g2) || (a.group === g2 && b.group === g1);
}

const isAreaList = (s: Slot) => /^area list/i.test(s.label.trim());

function isAreaListElectivePair(area: Slot, elective: Slot): boolean {
  return area.group.startsWith("seas.") && elective.group === "seas.core" &&
    isAreaList(area) && !isAreaList(elective) && /elective/i.test(elective.label);
}

export const pennPolicy: Policy = {
  crossDegree: { maxPerDegree: 1 },

  withinDegree(a, b) {
    if (a.degreeId !== b.degreeId || a.id === b.id) return false;
    // SEAS: an area list ("Area List - Networking") overlaps the CIS elective
    // by design, so a course from the list also counts as an elective. That
    // is the curriculum's own rule, not a petition. Only the elective that
    // sits with the major (group seas.core) qualifies: the technical, math
    // and free electives are not what the area lists overlap, and a free
    // elective would accept anything.
    if (isAreaListElectivePair(a, b) || isAreaListElectivePair(b, a)) return true;
    // Wharton: cross-cultural with the liberal-arts areas, and a language
    // course with them. Nothing else.
    return (
      isPair(a, b, "wharton.crossCultural", "wharton.liberal") ||
      isPair(a, b, "wharton.language", "wharton.liberal")
    );
  },

  withinDegreeCap(a, b) {
    if (isPair(a, b, "wharton.crossCultural", "wharton.liberal")) {
      return { key: "crossCultural+liberal", cu: 2 };
    }
    return null;
  },

  petitionPairs(a, b) {
    if (a.degreeId !== b.degreeId || a.id === b.id) return false;
    // Business breadth with the concentration is not here on purpose:
    // Wharton allows breadth to share a course only with a *second*
    // concentration, and breadth must sit outside the concentration's
    // department, so offering it as a petition would send the student to
    // ask for something the rule already refuses.
    //
    // The Wharton flex fundamentals with the concentration used to be offered
    // here. Wharton's pages for both Technology, Innovation, and Analytics
    // and Global Economy, Business, and Society (read 2026-11-26) say those
    // courses "may not be counted toward any other requirement" and "(no
    // petitions will be considered)", so the pair was removed. Do not add it
    // back: it sends a student to ask for something Wharton refuses.
    return isPair(a, b, "seas.math", "seas.techElective");
  },

  loads: {
    standard: 5.5,
    approved: 6.5,
    summerPerTerm: 2,
    summerCeiling: 4,
    // Engineering's Enrollment page (2026-11-26): departments may approve up
    // to 1 cu over the preceding semester, "6.5 CU maximum" for dual degree
    // students and seniors. Wharton's Course Load page: more than 5.5 needs
    // approval from its Undergraduate Petitions Committee, which "will not
    // normally approve enrollment more than 1 CU above the total from the
    // semester immediately prior".
    approvalNote(colleges, load) {
      const eng = colleges.includes("EU"), wh = colleges.includes("WU");
      const n = String(load);
      const engText =
        "Engineering's department can approve up to 1 cu above your previous semester (6.5 at most for dual-degree students)";
      if (eng && wh) return `${n} cu semesters need approval: ${engText}, and Wharton needs a petition to its Petitions Committee`;
      if (eng) return `${n} cu semesters need approval: ${engText}`;
      if (wh) return `${n} cu semesters need a petition to Wharton's Petitions Committee`;
      return `${n} cu semesters need your advisor's approval`;
    },
  },

  // Engineering's Dual Degrees page (2026-11-26): "the minimum requirement
  // for any dual degree student with Engineering is 46 course units".
  totalFloor(degrees) {
    const colleges = degrees.map((d) => d.college);
    if (degrees.length >= 2 && colleges.includes("EU") && colleges.some((c) => c && c !== "EU")) {
      return { cu: 46, reason: "a dual degree with Engineering needs at least 46 cu" };
    }
    return null;
  },

  sequences: {
    immediatelyBefore(first, second) {
      if (first.degreeId !== second.degreeId || first.id === second.id) return false;
      if (!/#\s*1\b/.test(first.label)) return false;
      const a = first.label.replace(/#\s*1\b/, "#N").trim().toLowerCase();
      const b = second.label.replace(/#\s*2\b/, "#N").trim().toLowerCase();
      return a === b && /#N/.test(b.toUpperCase());
    },
    prerequisiteOrdering: true,
  },

  capstoneRule: {
    isCapstone(slot) {
      return slot.group.startsWith("wharton.") && /capstone/i.test(slot.label);
    },
    mustPrecedeCapstone(slot) {
      if (!slot.group.startsWith("wharton.")) return false;
      if (/capstone/i.test(slot.label)) return false;
      return slot.group === "wharton.fundamental" || slot.group === "wharton.leadership";
    },
    satisfiedBySeniorDesign(slot, degrees) {
      if (!pennPolicy.capstoneRule.isCapstone(slot)) return false;
      const own = degrees.find((d) => d.id === slot.degreeId);
      const colleges = degrees.map((d) => d.college);
      return own?.college === "WU" && colleges.includes("EU");
    },
  },
};
