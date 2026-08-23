import SwiftUI
import LowHangingFruitKit

/// The Profile tab: the one screen that answers "what classes am I taking,
/// which do I want to see, and how do I want to hear about each one."
///
/// **This file is meant to be written once and then left alone.** It is a
/// container and nothing else: it opens a `Form`, drops in three section views,
/// and stops. Everything with an opinion lives in those three files. That is
/// deliberate — three separate agents fill them in, and the only way that
/// works without them fighting over the same lines is if the thing that
/// composes them never has to change. So:
///
/// - Every section is a **no-argument** `View`. Nothing is passed down, so
///   nobody has to come back here to add a parameter. A section that needs
///   more data reaches for it itself — `@EnvironmentObject var state:
///   AppState` is already in scope for anything below this view, and per-course
///   preferences arrive through the `AppState` seam rather than as an init
///   argument, for the same reason.
/// - Every section renders **`Section`s, not a `Form`**. The `Form` is here.
///   A section that wants to disappear entirely returns `EmptyView`.
/// - The **order is fixed here and only here**. See below for why it's this
///   order.
///
/// Three environment objects are guaranteed to any child: `AppState` and
/// `NotificationScheduler` (both injected by `MainTabView`), plus whatever the
/// app-wide environment carries. A section that declares an `@EnvironmentObject`
/// nobody injects crashes at first render, so anything new has to come through
/// an existing object rather than a new one.
struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler

    var body: some View {
        Form {
            // Semester first, and this is the one ordering decision that isn't
            // arbitrary. A rollover offer ("looks like a new term started —
            // want to archive the old one?") is worthless if it's below a class
            // list long enough to scroll. It is also, for eleven months of the
            // year, nothing at all: the section is expected to render
            // `EmptyView` whenever there's no boundary to offer, which costs a
            // `Form` exactly zero pixels. Top placement plus usually-invisible
            // is the combination that works; either one alone doesn't.
            ProfileSemesterSection()

            // Then the answer to "what classes am I taking, and which do I want
            // to see" — moved here out of Settings in v4, because a class list
            // is not a preference.
            ProfileClassesSection()

            // Then "how do I want to hear about each one." Below Classes on
            // purpose: per-course notification settings only make sense once
            // you can see the courses they attach to.
            ProfileNotificationsSection()
        }
        .navigationTitle("Profile")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        // Same treatment the other full-screen `Form`s get: without it a bare
        // Form paints the *system* grouped background, which reads as grey
        // against the app's warm paper. See `SheetTheme.swift`.
        .lhfSheetTheme()
        .frame(minWidth: 360, minHeight: 420)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ProfileView()
            .environmentObject(AppState())
            .environmentObject(NotificationScheduler())
    }
}
#endif
