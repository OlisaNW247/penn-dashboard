import SwiftUI

/// The shared look for a Profile section that exists but isn't built yet.
///
/// It is loud on purpose. A half-finished screen that renders as blank space —
/// or worse, as a plausible-looking empty state — is more expensive than one
/// that admits it: the first thing anyone does with a blank section is file it
/// as a bug and go read the code that failed to run. An amber marker and the
/// words "coming in v4" cost one glance and save that entire trip.
///
/// ## Why this is its own file
///
/// Two Profile sections ship as placeholders in the tab-bar commit, and two
/// different agents will later replace their bodies with real features. If
/// this type lived inside either of those files, the first agent to finish
/// would delete the other one's placeholder out from under it. Standing on its
/// own, each section can be gutted independently.
///
/// **Delete this file** once the last `ProfileSectionPlaceholder` call site is
/// gone. Leaving it costs nothing but a stale type; deleting it early is a
/// build error you'll see immediately, which is the safe direction to be wrong
/// in.
struct ProfileSectionPlaceholder: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `Label` rather than a hand-built HStack so the icon scales with
            // the text at accessibility sizes instead of staying pinned at a
            // fixed point size beside enormous type.
            Label(headline, systemImage: "hammer.fill")
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2SpineAmber)

            Text(detail)
                .font(.lhfSans(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("COMING IN V4")
                .font(.lhfSans(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.v2SpineAmber)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.v2SpineAmber.opacity(0.14)))
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
        // One VoiceOver stop instead of three, and the "coming in v4" badge is
        // folded into the spoken label — it's the most important word here and
        // a decorative capsule is exactly the kind of thing a screen reader
        // would otherwise announce last or not at all.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail) Coming in v4.")
    }
}
