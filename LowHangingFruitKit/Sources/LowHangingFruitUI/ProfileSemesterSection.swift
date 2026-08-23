import SwiftUI
import LowHangingFruitKit

/// The semester card: detects that a new term has started and *offers* to
/// archive the old one, so last spring's assignments stop crowding the
/// dashboard and stop feeding reminders.
///
/// **This is a placeholder. The body below is not the feature.**
///
/// ## The signature is the contract — don't change it
///
/// `ProfileView` composes this with `ProfileSemesterSection()` and is
/// explicitly never edited again, so:
///
/// - **No init parameters.** Ever. Everything comes from the environment.
/// - **`@EnvironmentObject var state: AppState`** is declared here already and
///   pre-wired by `MainTabView`. `NotificationScheduler` is in the environment
///   too and can be declared if archiving needs to force a reschedule. Anything
///   beyond those two is a crash on first render, so route new data through
///   `AppState` instead.
/// - **Render `Section`s, not a `Form`.** The `Form` belongs to `ProfileView`.
///
/// ## Why this section is first in the Form, and what that obliges you to do
///
/// A rollover offer is worthless below a scrollable class list — you'd never
/// see it. So `ProfileView` puts it at the very top, which is only tolerable
/// because of the other half of the bargain: **when there is no boundary to
/// offer, this must render nothing at all.** Return `EmptyView()` and a `Form`
/// section costs zero pixels. That's the normal state for eleven months of the
/// year; the loud placeholder below is a property of this commit, not of the
/// finished feature.
///
/// ## Two things this must not do
///
/// Rollover is **detected and offered, never automatic** — silently hiding a
/// student's work is the one failure this app cannot have. And archiving is
/// **not deletion**: the v3 ledger's whole thesis is that deleting is how you
/// lose things. Archived terms stay on disk and stay reachable in Done history;
/// they just drop out of the dashboard and out of `reschedule()`.
///
/// The detection and archiving logic is a separate piece of work with no view
/// in it (term-boundary detection, `isArchived` on the ledger row, the term cap
/// that currently only bounds the future). This file is its front end.
struct ProfileSemesterSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Section {
            ProfileSectionPlaceholder(
                headline: "Semester rollover is coming",
                detail: "When a new term starts, this card will offer to archive the last one \u{2014} the old work stays saved and stays in your Done history, it just stops showing up on the dashboard and stops sending reminders. Nothing gets archived without you tapping yes."
            )
        } header: {
            Text("Semester")
        }
    }
}
