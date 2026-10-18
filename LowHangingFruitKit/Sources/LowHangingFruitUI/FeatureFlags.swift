import Foundation

/// Compile-time feature gates for the shipping build.
///
/// One constant per feature, flipped in one place — deliberately not a
/// UserDefaults setting, because these gate what App Review sees and that must
/// not depend on device state.
enum FeatureFlags {
    /// **Grade Watcher is off: the owner removed it on 2026-10-18.**
    ///
    /// This hides the **entry points** and the **grade-change notices**, and
    /// nothing else. The header's grades button is the only route into
    /// `GradeWatcherView` (and from it `GradeReportView`); it is gated on
    /// this flag in `ContentView.header`, so with the flag false no Release
    /// build can reach either screen. The DEBUG launch arguments
    /// (`-LHFShowGrades`, `-LHFShowReport`) still seed the navigation path
    /// for screenshots, and compile out of Release. The "grade posted"
    /// notification is held back at the point it is posted
    /// (`NotificationScheduler.gradeNoticesToPost`), not by changing the fetch.
    /// The announcements megaphone took the grades button's place in the
    /// header.
    ///
    /// **The Canvas grade fetch deliberately keeps running.**
    /// `AutoSyncCoordinator.refreshCanvasGrades` is the only source of
    /// auto-submitted state (work already turned in filing itself under
    /// Done), of the "turned in" notices, of the session-renewal probe that
    /// runs on a 401, of course intel and announcements, and of the
    /// course-knowledge refresh that feeds ask. The wrong fix is to gate
    /// that fetch on this flag because "Grade Watcher is off": all of the
    /// above would go quiet with it, and the symptom (work that never moves
    /// to Done, a session that never renews) would not point back here. The
    /// privacy policy and review notes disclose the fetch accordingly.
    ///
    /// Nothing is deleted. The grading engine, the report, the category
    /// editor and their tests stay compiled so that re-enabling is a
    /// one-line change. History, since the value has flipped before: it was
    /// false in the 1.0 submission because the feature had never been
    /// verified against a real Canvas session; a merge artifact kept it
    /// false through the 2.0.0 line by accident (v4's value survived the
    /// v3.5+v4 merge with v3.5's comment); `v6` turned it back on
    /// deliberately (owner's call, 2026-08-31). The runtime gate
    /// `state.canUseGradeWatcher` is separate and still means "there is a
    /// Canvas credential", which the fetch above uses.
    static let gradeWatcher = false

    /// **Canvas personal access tokens are off.** The whole mint-at-login
    /// path (`CanvasAccessTokenMinter`, `CanvasAccessTokenStore`, the
    /// `accessToken:` parameter on every `/api/v1` client) was built on
    /// 2026-09-16 so a student would log in once per semester instead of
    /// once a day -- and the same day Olisa's own Canvas settings page
    /// showed the "+ New Access Token" button disabled with "Your Canvas
    /// administrators have chosen to limit your ability to generate your
    /// own access token." That is Canvas's restrict-students-from-tokens
    /// account setting, and it makes every mint a 403 for every Penn
    /// student. Minting anyway would cost one doomed POST per login and
    /// log a failure nobody can act on, so the call is gated here rather
    /// than deleted: the code is correct, tested, and worth keeping for
    /// the day Penn issues a developer key (the OAuth route the Canvas
    /// Student app uses) or lifts the restriction. Everything downstream
    /// of the mint is inert without a stored token, so with this false the
    /// app behaves exactly as it did before the token work.
    static let canvasAccessTokens = false

    /// **Ed Discussion ingestion is on.** Olisa's call: classes that run
    /// their Q&A on Ed (the instructor's pinned posts and announcements
    /// often carry the policy that never reaches the syllabus) should feed
    /// ask without the student doing anything. `EdDiscussionCoordinator`
    /// finds each course's "Ed Discussion" nav tool, performs its LTI launch
    /// in a hidden WebView on the Canvas session the app already holds, and
    /// reads Ed's API with the cookies that launch produced. On is a
    /// decision, not a verification: the next step is proving it on his own
    /// phone (`docs/ED_DISCUSSION.md`), and nothing here has yet run against
    /// real Canvas or Ed data.
    ///
    /// Penn-only at runtime, independent of this flag: the backend pools
    /// course material by numeric Canvas course id, which two schools would
    /// share (see `refreshCourseKnowledge`), so every call site also checks
    /// `canvasInstallation.id == CanvasInstallation.penn.id`.
    ///
    /// **This is the kill switch.** Ed's API is private and undocumented; if
    /// Ed changes it and the sync starts failing or misbehaving, flipping
    /// this to `false` removes the whole path (the launch, the fetch, the
    /// Settings row) without touching anything the Canvas sync does. Ed
    /// documents already stored stay in the knowledge base until the next
    /// Canvas resync of their course drops them.
    static let edDiscussion = true

    /// Evaluates a token-store read only while the experiment is enabled.
    /// Keeping the guard around the closure (rather than around its result)
    /// is load-bearing: Keychain reads are synchronous and must not happen at
    /// launch for a feature that cannot work for Penn students.
    static func canvasAccessTokenValue<T>(_ load: () -> T?) -> T? {
        guard canvasAccessTokens else { return nil }
        return load()
    }
}
