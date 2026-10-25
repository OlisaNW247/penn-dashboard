import Foundation

/// Splits the course ids a sync upload reported as `websitesPending` into the
/// calls `discover-websites` will accept.
///
/// The server refuses a request naming more than three courses with a 400
/// (`backend/supabase/functions/discover-websites/index.ts`), and refuses all
/// of it: there is no partial success for the first three. The phone used to
/// send the whole list in one call under `try?`, so a student with four or
/// more pending courses (every student in four CIS classes) got a 400 nobody
/// saw, and discovery never ran for any of them. On 2026-10-24 the live
/// table held 213 candidate websites, three verified and none ever crawled.
/// The Chrome extension already batches by three
/// (`chrome-extension/src/collectRun.js`, `DISCOVER_BATCH`).
///
/// The wrong fix is raising the server's cap: the cap exists because each
/// course in a call is a crawl of an external site, and one call that crawls
/// ten of them would outlive the function's time limit.
public enum WebsiteDiscoveryBatches {
    /// The server's cap on course ids per `discover-websites` call. Keep in
    /// step with `backend/supabase/functions/discover-websites/index.ts`.
    public static let maxCoursesPerCall = 3

    /// `ids` with repeats removed (first-seen order kept) and cut into groups
    /// of at most `size`. Repeats come from the upload loop: the same course
    /// can be reported pending by more than one 200-document batch, and asking
    /// twice would crawl it twice. An empty list gives no groups.
    public static func chunks(of ids: [String], size: Int = maxCoursesPerCall) -> [[String]] {
        guard size > 0 else { return [] }
        var seen = Set<String>()
        let distinct = ids.filter { seen.insert($0).inserted }
        var groups: [[String]] = []
        var start = 0
        while start < distinct.count {
            let end = min(start + size, distinct.count)
            groups.append(Array(distinct[start..<end]))
            start = end
        }
        return groups
    }
}
