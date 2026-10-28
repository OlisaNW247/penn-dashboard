import Foundation

/// Canvas sites that are never a class, however their names parse.
///
/// Penn enrolls students in program sites that sit in the same Canvas course
/// list as their classes. The one that prompted this is "TAP 2028" (site
/// 1799668, on both owners' phones): a cohort site named for a graduating
/// class, with no section and no term in its name, which `CourseCode.parse`
/// reads as department TAP, number 2028. It then showed up as a class in the
/// megaphone's bubbles, Settings and the dashboard's class filter. The owner's
/// rule, 2026-10-23: "TAP 2028 should never be a class."
///
/// Matched: "TAP" and a four-digit year from 1900 to 2099, nothing else
/// ("TAP 2028", "tap 2029"), whether given the raw Canvas name or the parsed
/// course key. Kept narrow on purpose.
///
/// The wrong fixes look reasonable. "No term in the Canvas name means not a
/// class" fits every real Penn class seen so far ("CIS 2620-001 202630 …",
/// "ACCT 1010 (Hail) - Fall 2026"), but a year-long site, or another
/// school's naming, can leave the term out of a real class. Hiding the site
/// with the student's own hide switch leaves it one tap from coming back, and
/// a fresh install lists it again.
public enum NonClassCanvasSite {
    /// Whether `courseKey` (a parsed course key such as "TAP 2028", or the
    /// raw Canvas site name) names a site that is never a class.
    public static func matches(_ courseKey: String) -> Bool {
        verdicts.value(for: courseKey, compute: compute)
    }

    /// The rebuild asks this of every course key of every item, and the
    /// answer is a function of the key alone (a regex, and a `CourseCode.parse`
    /// that costs more than the regex), so it is remembered per key.
    private static let verdicts = BoundedMemo<Bool>(capacity: 1024)

    private static func compute(_ courseKey: String) -> Bool {
        let raw = courseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isProgramYear(raw) { return true }
        return isProgramYear(CourseCode.parse(raw).code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isProgramYear(_ text: String) -> Bool {
        RegexCache.contains(#"^(?i)TAP\s+(19|20)\d{2}$"#, in: text)
    }
}
