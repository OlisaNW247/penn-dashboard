// Reads the student's Canvas work from their own calendar feed, parsed by the
// ported ICS parser so every item has the phone's exact Assignment.id.
//
// The feed URL embeds a per-user token and is a bearer credential: it lives in
// a local variable for this call only. It is never stored, logged or returned.
import { fetchText } from "./http.js";
import { assignmentsFromICS, calendarItems } from "../core/ics.js";
import { isCanvasRelevant } from "../core/workList.js";

const PROFILE_URL = "https://canvas.upenn.edu/api/v1/users/self/profile";

// Canvas prefixes JSON with `while(1);`.
export function stripXSSI(text) {
  return text.replace(/^\s*while\s*\(\s*1\s*\)\s*;?/, "");
}

// Returns { status: "in" | "out" | "error", items }.
export async function readCanvas({ fetchFn = fetch } = {}) {
  try {
    const profile = await fetchText(PROFILE_URL, { fetchFn, accept: "application/json" });
    if (profile.signedOut) return { status: "out", items: [] };
    if (!profile.ok) return { status: "error", items: [] };
    let feedURL;
    try {
      feedURL = JSON.parse(stripXSSI(profile.text))?.calendar?.ics;
    } catch {
      return { status: "out", items: [] }; // an HTML sign-in page, not JSON
    }
    if (typeof feedURL !== "string" || !feedURL.startsWith("https://")) return { status: "error", items: [] };
    const feed = await fetchText(feedURL, { fetchFn });
    feedURL = null;
    if (feed.signedOut) return { status: "out", items: [] };
    if (!feed.ok) return { status: "error", items: [] };
    return { status: "in", items: calendarItems(feed.text).filter(isCanvasRelevant) };
  } catch {
    return { status: "error", items: [] };
  }
}

export { assignmentsFromICS };
