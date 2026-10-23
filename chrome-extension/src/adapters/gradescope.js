// Reads Gradescope the way GradescopeClient.fetchAssignments does
// (GradescopeClient.swift:51-100): account page, then each current-term course
// page, then a detail page per unsubmitted assignment. Strictly sequential.
import { fetchText } from "./http.js";
import {
  isLoginPage, currentTermCourses, accountPageAssignments, courseAssignments,
  refineWithDetailPage, sortAssignments,
} from "../core/gradescope.js";

const BASE = "https://www.gradescope.com";

class SignedOut extends Error {}

async function page(url, fetchFn) {
  const r = await fetchText(url, { fetchFn });
  if (r.signedOut || r.status === 403) throw new SignedOut();
  if (!r.ok) throw new Error("http");
  // A 200 login page is how Gradescope expires a session (L136-142).
  if (isLoginPage(r.text)) throw new SignedOut();
  return r.text;
}

// Returns { status: "in" | "out" | "error", items }.
export async function readGradescope({ fetchFn = fetch, now = new Date() } = {}) {
  try {
    const accountHTML = await page(`${BASE}/account`, fetchFn);
    const result = currentTermCourses(accountHTML, BASE, now);
    let list = [];
    if (result.courses.length === 0) {
      list = accountPageAssignments(accountHTML, BASE, now);
    } else {
      for (const course of result.courses) {
        const html = await page(course.url, fetchFn);
        list.push(...courseAssignments(html, course, result.isFallback, now));
      }
    }
    const refined = [];
    for (const a of list) {
      if (a.submitted || !a.url) { refined.push(a); continue; }
      try {
        refined.push(refineWithDetailPage(a, await page(a.url, fetchFn)));
      } catch (e) {
        if (e instanceof SignedOut) throw e; // never downgrade a dead session
        refined.push(a);
      }
    }
    return { status: "in", items: sortAssignments(refined) };
  } catch (e) {
    return { status: e instanceof SignedOut ? "out" : "error", items: [] };
  }
}
