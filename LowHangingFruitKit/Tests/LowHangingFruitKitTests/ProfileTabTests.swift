import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// v4 turned the app from one `NavigationStack` into a three-tab `TabView` and
/// moved the class list out of Settings into the new Profile tab. SwiftUI views
/// aren't rendered by `swift test`, so what these pin down is the *seam*: the
/// shape of the tab set, and the `AppState` reads the Profile tab is built on.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`, so every test
/// here restores what it touched — see the note in `PreviewModeTests`.
@MainActor
@Suite("Profile tab")
struct ProfileTabTests {

    // MARK: The tab set

    /// Three tabs, in this order, and the dashboard is the one you land on.
    ///
    /// This looks like a test of an enum, and it is — deliberately. Three
    /// later workstreams render into Profile, and the cheapest way for one of
    /// them to quietly break the app's shape is to bolt on a fourth tab or
    /// reorder the existing ones. Grades and the per-course report are
    /// drill-downs off the dashboard, not peers of it, and they must not
    /// appear here.
    @Test("the app has exactly three tabs, dashboard first")
    func tabSet() {
        #expect(MainTab.allCases == [.dashboard, .profile, .settings])
        #expect(MainTab.dashboard.rawValue == "dashboard")
        #expect(MainTab.profile.rawValue == "profile")
        #expect(MainTab.settings.rawValue == "settings")
    }

    // MARK: Preview mode, on the Profile tab

    /// The regression this exists for, in advance. An App Store reviewer can't
    /// pass Penn SSO, so preview mode is the *only* way they see the app — and
    /// the previous time something in this area broke, it stranded them at the
    /// login wall (see commit `c999c38`).
    ///
    /// The trap here is specific and easy to fall into: the dashboard gets its
    /// sample data by calling `loadSampleData()` on the *view model*, which
    /// leaves `AppState` empty. The Profile tab's class list reads `AppState`
    /// directly. If preview mode ever stops seeding `AppState` itself, the
    /// dashboard would look perfect and the Profile tab would be blank — the
    /// hardest kind of demo bug to notice, because two of three tabs are fine.
    @Test("preview mode fills the Profile tab's class list, not just the dashboard's")
    func previewModePopulatesClassList() {
        withPreviewMode { state in
            let courses = state.visibleCourseCodes()
            #expect(!courses.isEmpty)
            // Every listed class is switched on, so the reviewer's Profile tab
            // opens populated rather than looking like a set of disabled rows.
            for course in courses {
                #expect(state.isCourseSelected(course))
            }
            // And nothing is sitting in the "Deleted classes" disclosure.
            #expect(state.deletedCourseCodes().isEmpty)
        }
    }

    /// Each row renders `courseDisplayName(_:)`, which has to produce something
    /// printable for every fixture course — an empty label in the demo reads as
    /// a data bug.
    @Test("every preview class has a display name to render")
    func previewClassesHaveNames() {
        withPreviewMode { state in
            for course in state.visibleCourseCodes() {
                #expect(!state.courseDisplayName(course).isEmpty)
                // No fixture ships a rename, so the code is what shows.
                #expect(state.courseDisplayName(course) == course)
            }
        }
    }

    // MARK: The semantics that moved out of Settings

    /// `ProfileClassesSection` is `SettingsPage.classesSection` relocated, and
    /// the property that makes it safe is that renaming is *cosmetic*: every
    /// action in the row is passed `course` — the code Canvas gave us — and
    /// never the display name. If a future edit ever keys an action on the
    /// label instead, renaming a class would detach it from its own
    /// assignments, its reminders and its grades. This is that guarantee,
    /// asserted from the angle the moved view depends on.
    @Test("renaming a class changes the label and nothing else")
    func renameIsCosmeticOnly() {
        withCourseState { state in
            state.canvasItems = [
                assignment(course: "CIS 1200", id: "1"),
                assignment(course: "MATH 1400", id: "2"),
            ]

            #expect(state.visibleCourseCodes().contains("CIS 1200"))
            state.renameCourse("CIS 1200", to: "Intro Programming")

            // The label changed…
            #expect(state.courseDisplayName("CIS 1200") == "Intro Programming")
            #expect(state.hasCustomName("CIS 1200"))
            // …and the identity did not. The class is still keyed, listed,
            // selected and toggleable by its code.
            #expect(state.visibleCourseCodes().contains("CIS 1200"))
            #expect(state.isCourseSelected("CIS 1200"))

            state.setCourse("CIS 1200", selected: false)
            #expect(!state.isCourseSelected("CIS 1200"))
            #expect(state.courseDisplayName("CIS 1200") == "Intro Programming")
            state.setCourse("CIS 1200", selected: true)

            // Clearing the field goes back to the code, as the alert's copy
            // promises ("Leave it empty to go back to the original").
            state.renameCourse("CIS 1200", to: "")
            #expect(state.courseDisplayName("CIS 1200") == "CIS 1200")
            #expect(!state.hasCustomName("CIS 1200"))
        }
    }

    /// The delete/restore pair the section's swipe action and its "Deleted
    /// classes" disclosure group are built on, including the part that is easy
    /// to lose in a move: a rename survives the round trip, because both are
    /// stored against the code rather than against each other.
    @Test("delete moves a class to the restore list; restore brings it back renamed and all")
    func deleteAndRestoreRoundTrip() {
        withCourseState { state in
            state.canvasItems = [
                assignment(course: "CIS 1200", id: "1"),
                assignment(course: "MATH 1400", id: "2"),
            ]
            state.renameCourse("CIS 1200", to: "Intro Programming")

            state.deleteCourse("CIS 1200")
            #expect(!state.visibleCourseCodes().contains("CIS 1200"))
            #expect(state.deletedCourseCodes() == ["CIS 1200"])
            // The disclosure group labels restore rows with the display name.
            #expect(state.courseDisplayName("CIS 1200") == "Intro Programming")
            // Unrelated class is untouched.
            #expect(state.visibleCourseCodes().contains("MATH 1400"))

            state.restoreCourse("CIS 1200")
            #expect(state.visibleCourseCodes().contains("CIS 1200"))
            #expect(state.isCourseSelected("CIS 1200"))
            #expect(state.deletedCourseCodes().isEmpty)
            #expect(state.courseDisplayName("CIS 1200") == "Intro Programming")
        }
    }

    /// The empty state exists because this is a *tab* now, not a section buried
    /// in Settings that could simply vanish. "No classes" is the ordinary week-
    /// one state — the class list is derived from feed items, so a course that
    /// hasn't posted anything is invisible — and both lists being empty is what
    /// `ProfileClassesSection` keys its explanatory copy on.
    @Test("a student with no feed items yet has genuinely empty class lists")
    func emptyStateIsReachable() {
        withCourseState { state in
            state.canvasItems = []
            #expect(state.visibleCourseCodes().isEmpty)
            #expect(state.deletedCourseCodes().isEmpty)
        }
    }

    // MARK: Helpers

    private func assignment(course: String, id: String) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: "HW\(id)", dueAt: Date(), url: nil)
    }

    /// Runs `body` against a preview-mode `AppState`, then puts the persisted
    /// preview flag back the way it was. Mirrors `PreviewModeTests`.
    private func withPreviewMode(_ body: (AppState) -> Void) {
        let state = AppState()
        let wasPreview = state.isPreviewMode
        state.enterPreviewMode()
        defer {
            if !wasPreview {
                state.restartOnboarding()
                UserDefaults.lhf.set(false, forKey: "isPreviewMode")
            }
        }
        body(state)
    }

    /// A clean slate for the hidden/deleted/renamed sets, restored afterwards.
    /// All three live in the process-wide `UserDefaults.lhf`, so without this a
    /// failed assertion here would leak a deleted course into the developer's
    /// own app and into every later test in the run.
    private func withCourseState(_ body: (AppState) -> Void) {
        let defaults = UserDefaults.lhf
        let keys = [
            SharedDefaults.hiddenCoursesKey,
            SharedDefaults.deletedCoursesKey,
            SharedDefaults.courseNameOverridesKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        // In-memory ledger for the same reason `IntroFlowTests` uses one: the
        // default store resolves to the real on-disk SQLite file on any machine
        // that has actually run the app, and a suite full of `AppState()` then
        // contends on it. None of these tests involve the ledger.
        body(AppState(assignmentStore: try? AssignmentStore(inMemory: true)))
    }
}
