// Penn's rules about counting and scheduling courses, kept apart from the
// planner so a rule change is a change here and nowhere else. Read from the
// official SEAS and Wharton pages on 2026-11-15; anything an advisor decides
// case by case lives in `petitionPairs`, never in the main plan.

import type { Slot } from "./types.ts";

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
    summerPerTerm: number;
    maxSummerTotal: number;
  };
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
    return (
      isPair(a, b, "wharton.flex", "wharton.concentration") ||
      isPair(a, b, "seas.math", "seas.techElective")
    );
  },

  loads: { standard: 5.5, approved: 6.5, summerPerTerm: 2, maxSummerTotal: 4 },

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
  },
};
