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
    static let gradeWatcher = false
}
