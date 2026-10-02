import Foundation

/// Compile-time feature gates for the shipping build.
///
/// One constant per feature, flipped in one place — deliberately not a
/// UserDefaults setting, because these gate what App Review sees and that must
/// not depend on device state.
enum FeatureFlags {
    /// **Grade Watcher is off in the 1.0 submission.**
    ///
    /// The grading engine itself is well tested, but the feature has never been
    /// verified end to end against a real Canvas session — grades need a live
    /// cookie session that the cookieless ICS feed the dashboard runs on
    /// doesn't provide — and it does not currently work reliably on device.
    /// Shipping a headline feature in that state is worse than shipping
    /// without it.
    ///
    /// This hides only the **entry points**. Everything behind them stays
    /// compiled and tested so the `v3` branch (where Grade Watcher, the grade
    /// report and syllabus ingestion continue) keeps merging cleanly, and so
    /// re-enabling is a one-line change once it's verified on device.
    ///
    /// Note this does **not** stop Canvas grade data being fetched:
    /// `AutoSyncCoordinator.refreshCanvasGrades` still runs, because automatic
    /// submission detection (work you've already turned in filing itself under
    /// Done) is derived from that same payload. The privacy policy and review
    /// notes disclose that accordingly.
    /// **true on `v6`.** The `false` that sat here through the 2.0.0 line was
    /// a merge artifact, not a decision: the doc comment above it said "on
    /// this branch the entry points are on" while the value said off — v4's
    /// value survived the v3.5+v4 merge and v3.5's comment came along with
    /// it, so Grade Watcher silently vanished from the UI while remaining
    /// fully compiled, tested, and fed by every sync. v6 turns the entry
    /// points back on deliberately (owner's call, 2026-08-31). The runtime
    /// gate is still `state.canUseGradeWatcher` — a calendar-link-only
    /// install with no cookie session never shows the button regardless of
    /// this flag, which is what makes it safe to leave on.
    static let gradeWatcher = true

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
