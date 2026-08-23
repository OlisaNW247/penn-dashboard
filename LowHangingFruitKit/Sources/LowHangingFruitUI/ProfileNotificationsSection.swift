import SwiftUI
import LowHangingFruitKit

/// Per-course notification preferences: which lead times a given class uses,
/// whether its recurring non-assignment work (weekly readings, check-ins) gets
/// reminders at all, and whether the class is muted outright.
///
/// **This is a placeholder. The body below is not the feature.**
///
/// ## The signature is the contract — don't change it
///
/// `ProfileView` composes this with `ProfileNotificationsSection()` and is
/// explicitly never edited again, so:
///
/// - **No init parameters.** Ever. Everything comes from the environment.
/// - **`@EnvironmentObject var state: AppState`** and **`@EnvironmentObject
///   var scheduler: NotificationScheduler`** are both declared here already,
///   pre-wired by `MainTabView`. The scheduler is the one you want: it owns
///   the *global* `leadOffsets` and the daily digest, which are the defaults a
///   per-course setting inherits from and overrides. Declaring a fourth
///   environment object nobody injects is a crash on first render, so don't.
/// - **Render `Section`s, not a `Form`.** The `Form` belongs to `ProfileView`.
///   Several sections are fine. `EmptyView` is fine.
///
/// ## Where per-course preferences come from
///
/// `CoursePreferences` and its store are being built in parallel with this
/// file and deliberately are **not referenced here** — the type does not exist
/// in this commit, and a placeholder that mentioned it wouldn't compile. Reach
/// it through the `AppState` seam once it lands; do not add another
/// `@EnvironmentObject` and do not thread it in as an init argument.
///
/// The course list itself already works today and needs nothing new:
/// `state.visibleCourseCodes()` for the rows, `state.courseDisplayName(_:)`
/// for the label, and — this is the one that bites — the course **code** as the
/// key for anything persisted. Renaming is cosmetic (see
/// `ProfileClassesSection`); a preference keyed on a display name detaches the
/// moment someone renames the class.
struct ProfileNotificationsSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler

    var body: some View {
        Section {
            ProfileSectionPlaceholder(
                headline: "Per-class reminders are coming",
                detail: "Right now every class uses the same reminder times, set under Settings \u{2192} Reminders. This is where you\u{2019}ll be able to give each class its own \u{2014} more warning for the ones that need it, silence for the ones that don\u{2019}t."
            )
        } header: {
            Text("Notifications")
        }
    }
}
