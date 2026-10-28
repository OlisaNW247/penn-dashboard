import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A Canvas or Gradescope reconnect from a signed-in install is a cover over
/// the still-mounted dashboard (`AppState.isReconnecting`, presented by
/// `ContentView`), not a trip back through onboarding that swaps the root.
/// The state rules are tested against a real `AppState`; the views cannot be
/// driven headlessly in this package, so the wiring is pinned by reading the
/// source, the same seam `PreviewModeTests.previewDoorIsWiredIntoShippedUI`
/// and `LaunchRefreshStructureTests` use. None of that has been seen on a
/// screen; it needs the device pass listed in the commit that added it.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`, so every test
/// restores what it touched (see `IntroFlowTests`).
@MainActor
@Suite("Reconnect cover")
struct ReconnectCoverTests {

    private static let touchedKeys = ["hasSeenIntro", "hasCompletedOnboarding", "isPreviewMode", "userName"]

    /// Runs `body` against a known set of persisted flags and puts the real
    /// ones back. Preview is always off on the way in.
    private func withFlags(onboarded: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.lhf
        let saved = Self.touchedKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(onboarded, forKey: "hasCompletedOnboarding")
        defaults.set(true, forKey: "hasSeenIntro")
        defaults.set(false, forKey: "isPreviewMode")
        try body()
    }

    /// On the student's own in-memory ledger, as `IntroFlowTests` does: the
    /// default store can resolve to the real on-disk one on a dev Mac.
    private func makeState(history: GradeHistoryStore? = nil) -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true), gradeHistoryStore: history)
    }

    // MARK: - State

    @Test("a Canvas reconnect opens the cover and leaves onboarding, in memory and on disk, finished")
    func canvasReconnectKeepsOnboardingFinished() {
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .canvas)

            #expect(state.isReconnecting)
            #expect(state.onboardingDestination == .canvas)
            #expect(!state.needsOnboarding)
            // A kill with the cover open must relaunch onto the dashboard.
            #expect(UserDefaults.lhf.bool(forKey: "hasCompletedOnboarding"))
            #expect(!makeState().needsOnboarding)
            #expect(!makeState().isReconnecting)
        }
    }

    @Test("a Gradescope reconnect opens the cover too")
    func gradescopeReconnectOpensCover() {
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .gradescope)
            #expect(state.isReconnecting)
            #expect(state.onboardingDestination == .gradescope)
            #expect(!state.needsOnboarding)
        }
    }

    @Test("the whole walk still replaces the root")
    func fullWalkTakesTheOldPath() {
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .full)
            #expect(!state.isReconnecting)
            #expect(state.needsOnboarding)
            #expect(!UserDefaults.lhf.bool(forKey: "hasCompletedOnboarding"))
        }
    }

    @Test("a first-run root never gets the cover, so the preview door stays visible")
    func firstRunNeverReconnects() {
        withFlags(onboarded: false) {
            let state = makeState()
            state.restartOnboarding(for: .canvas)
            #expect(!state.isReconnecting)
            #expect(state.needsOnboarding)
            #expect(state.onboardingDestination == .canvas)
        }
    }

    @Test("leaving preview for Canvas takes the old path, not the cover")
    func previewExitTakesTheOldPath() {
        withFlags(onboarded: true) {
            let state = makeState()
            state.enterPreviewMode()
            #expect(state.isPreviewMode)

            state.restartOnboarding(for: .canvas)
            #expect(!state.isReconnecting)
            #expect(!state.isPreviewMode)
            #expect(state.needsOnboarding)
            #expect(state.onboardingDestination == .canvas)
        }
    }

    @Test("completing the walk closes the cover")
    func completionClosesCover() {
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .canvas)
            state.completeOnboarding()
            #expect(!state.isReconnecting)
            #expect(state.onboardingDestination == .full)
            #expect(!state.needsOnboarding)
        }
    }

    @Test("closing the cover forgets the service and changes nothing else")
    func dismissClosesCover() {
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .canvas)
            state.dismissReconnect()

            #expect(!state.isReconnecting)
            #expect(state.onboardingDestination == .full)
            #expect(!state.needsOnboarding)
            #expect(UserDefaults.lhf.bool(forKey: "hasCompletedOnboarding"))
        }
    }

    @Test("closing with no cover open is a no-op, even over a first-run walk aimed at one service")
    func dismissWithoutCoverIsNoOp() {
        withFlags(onboarded: false) {
            let state = makeState()
            state.restartOnboarding(for: .gradescope)
            state.dismissReconnect()
            // The presentation binding's setter calls this on any dismissal;
            // it must not retarget a root walk that has no cover.
            #expect(state.onboardingDestination == .gradescope)
            #expect(state.needsOnboarding)
        }
    }

    // MARK: - Preview exit keeps the student's grade history

    @Test("clearing preview fixtures empties the snapshots and keeps the stored history")
    func clearPreviewFixturesKeepsHistory() throws {
        let history = try GradeHistoryStore(inMemory: true)
        history.record(courseID: "100", percent: 91.5, now: Date(timeIntervalSince1970: 1_700_000_000))
        let store = GradeWatcherStore(historyStore: history)
        #expect(store.history["100"]?.count == 1)

        store.loadPreviewSnapshots(SampleData.gradeSnapshots())
        #expect(!store.snapshots.isEmpty)
        #expect(store.lastRefreshed != nil)

        store.clearPreviewFixtures()
        #expect(store.snapshots.isEmpty)
        #expect(store.lastRefreshed == nil)
        #expect(store.error == nil)
        #expect(store.history["100"]?.count == 1)
        #expect(history.allHistory()["100"]?.count == 1)
    }

    @Test("clearAll still wipes the stored history, which is what disconnect needs")
    func clearAllStillWipesHistory() throws {
        let history = try GradeHistoryStore(inMemory: true)
        history.record(courseID: "100", percent: 91.5, now: Date(timeIntervalSince1970: 1_700_000_000))
        let store = GradeWatcherStore(historyStore: history)
        store.clearAll()
        #expect(store.history.isEmpty)
        #expect(history.allHistory().isEmpty)
    }

    @Test("a student who tried preview and then connects Canvas keeps their observed grade history")
    func leavingPreviewKeepsRealHistory() throws {
        try withFlags(onboarded: true) {
            let history = try GradeHistoryStore(inMemory: true)
            history.record(courseID: "100", percent: 91.5, now: Date(timeIntervalSince1970: 1_700_000_000))
            let state = makeState(history: history)

            state.enterPreviewMode()
            #expect(!state.gradeWatcher.snapshots.isEmpty)

            state.restartOnboarding(for: .canvas)
            #expect(state.gradeWatcher.snapshots.isEmpty)
            #expect(state.gradeWatcher.history["100"]?.count == 1)
            #expect(history.allHistory()["100"]?.count == 1)
        }
    }

    // MARK: - Wiring (source text)

    @Test("ContentView presents the walk as a full-screen cover on iOS and a sheet on macOS, and re-runs the launch pass on close")
    func contentViewWiring() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))

        #expect(
            Self.collapsed(source).contains(
                "#if os(iOS) .fullScreenCover(isPresented: reconnectCoverBinding) { reconnectCover } "
                    + "#else .sheet(isPresented: reconnectCoverBinding) { reconnectCover } #endif"
            ),
            "full-screen cover on iOS, sheet on macOS, in that #if"
        )

        let binding = try Self.body(ofDeclaredWith: "var reconnectCoverBinding: Binding<Bool>", in: source)
        #expect(binding.contains("state.isReconnecting"))
        #expect(binding.contains("state.dismissReconnect()"))

        let cover = try Self.body(ofDeclaredWith: "var reconnectCover: some View", in: source)
        #expect(cover.contains("OnboardingView("))
        #expect(cover.contains("destination: state.onboardingDestination"))
        #expect(cover.contains(".environmentObject(state)"))
        #expect(cover.contains(".environmentObject(scheduler)"))
        #expect(cover.contains(".lhfSheetTheme()"))

        let rerun = try Self.body(ofDeclaredWith: ".onChange(of: state.isReconnecting)", in: source)
        #expect(rerun.contains("await refreshSessionSourcesAtLaunch()"))
        // Only on the way down: opening the cover must not refetch.
        #expect(rerun.contains("guard wasReconnecting, !isReconnecting"))
    }

    @Test("every step a reconnect cover can show carries the close control")
    func closeControlOnEveryStep() throws {
        let source = Self.codeOnly(try Self.uiSource("OnboardingView.swift"))

        let button = try Self.body(ofDeclaredWith: "var reconnectCloseButton: some View", in: source)
        #expect(button.contains("if state.isReconnecting"))
        #expect(button.contains("state.dismissReconnect()"))
        #expect(button.contains("Image(systemName: \"xmark\")"))
        #expect(button.contains(".accessibilityLabel(\"close\")"))
        #expect(!button.contains("Text("), "the control is an icon only")

        // The two chrome builders every phase is wrapped in.
        let header = try Self.body(ofDeclaredWith: "func loginHeader(", in: source)
        #expect(header.contains("reconnectCloseButton"))
        let bar = try Self.body(ofDeclaredWith: "func topBar(", in: source)
        #expect(bar.contains("reconnectCloseButton"))

        // Canvas sign-in and the Gradescope pane use the header; the picker
        // has none, so it takes the top bar while a cover is open; the two
        // confirmation panes use the top bar already.
        let canvas = try Self.body(ofDeclaredWith: "var canvasStep: some View", in: source)
        #expect(canvas.contains("loginHeader("))
        let gradescope = try Self.body(ofDeclaredWith: "var gradescopeStep: some View", in: source)
        #expect(gradescope.contains("loginHeader("))
        #expect(gradescope.contains("connectedStep("))
        let picker = try Self.body(ofDeclaredWith: "var schoolSelectionStep: some View", in: source)
        #expect(Self.collapsed(picker).contains("if state.isReconnecting { topBar(onBack: nil) }"))
        let connected = try Self.body(ofDeclaredWith: "func connectedStep(", in: source)
        #expect(connected.contains("topBar("))
    }

    /// The footer is hidden by `isReconnecting || hasCompletedOnboarding`, not
    /// by `isReconnecting` alone: `completeOnboarding()` clears the first
    /// before the cover's dismiss animation ends. These pin the premise the
    /// condition rests on, against the real flags.
    @Test("a reconnect never lets the preview-door condition lapse, and a first run or a start-over always shows the door")
    func previewDoorConditionAcrossLifecycles() {
        func hidden(_ state: AppState) -> Bool { state.isReconnecting || state.hasCompletedOnboarding }

        // Signed in, reconnecting: hidden while the cover is open, and still
        // hidden in the instant after `completeOnboarding()` has cleared
        // `isReconnecting` but the cover is still sliding away.
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .canvas)
            #expect(state.isReconnecting)
            #expect(hidden(state))

            state.completeOnboarding()
            #expect(!state.isReconnecting)
            #expect(hidden(state), "the footer must not flash back during the dismiss animation")
        }

        // A true first run: nothing is finished, nothing is reconnecting.
        withFlags(onboarded: false) {
            #expect(!hidden(makeState()))
        }

        // "Start over", and leaving preview, both land on the walk with the
        // flag written false: the reviewer's way back to the door.
        withFlags(onboarded: true) {
            let state = makeState()
            state.restartOnboarding(for: .full)
            #expect(!hidden(state))
        }
        withFlags(onboarded: true) {
            let state = makeState()
            state.enterPreviewMode()
            state.restartOnboarding(for: .canvas)
            #expect(!hidden(state))
        }
    }

    @Test("the preview door is hidden for a signed-in install and still wired for everyone else")
    func previewDoorHiddenForSignedInInstall() throws {
        let source = Self.codeOnly(try Self.uiSource("OnboardingView.swift"))
        let canvas = try Self.body(ofDeclaredWith: "var canvasStep: some View", in: source)
        #expect(
            Self.collapsed(canvas).contains(
                "if !(state.isReconnecting || state.hasCompletedOnboarding) { previewFooter }"
            )
        )
        let footer = try Self.body(ofDeclaredWith: "var previewFooter: some View", in: source)
        #expect(footer.contains("state.enterPreviewMode()"))
    }

    // MARK: - Helpers

    /// The text between the braces that follow the first occurrence of
    /// `signature`, matched by depth rather than indentation.
    private static func body(ofDeclaredWith signature: String, in source: String) throws -> String {
        let header = try #require(source.range(of: signature), "missing \(signature)")
        let open = try #require(source.range(of: "{", range: header.upperBound..<source.endIndex))
        var depth = 1
        var index = open.upperBound
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        Issue.record("unbalanced braces after \(signature)")
        return ""
    }

    /// Every run of whitespace squeezed to one space, so a check does not
    /// depend on indentation or line breaks.
    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Source with whole-line `//` comments dropped, so a comment that names a
    /// call is not mistaken for the call.
    private static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        return try String(contentsOf: sources.appendingPathComponent(filename), encoding: .utf8)
    }
}

/// The cover rule is `nonisolated` on purpose (tests, and any caller off the
/// main actor, read it), and a test inside the `@MainActor` suite above calls
/// it from the main actor, which would pass even if the `nonisolated` were
/// dropped. This suite is deliberately unmarked so the call really is made
/// from a nonisolated context: losing `nonisolated` stops this file compiling.
@Suite("Reconnect cover rule")
struct ReconnectCoverRuleTests {

    @Test("only a single-service reconnect from a finished, non-preview install uses the cover")
    func ruleTruthTable() {
        let destinations: [AppState.OnboardingDestination] = [.full, .canvas, .gradescope]
        for destination in destinations {
            for preview in [false, true] {
                for onboarded in [false, true] {
                    let expected = destination != .full && !preview && onboarded
                    #expect(
                        AppState.reconnectsInCover(
                            for: destination, isPreviewMode: preview, hasCompletedOnboarding: onboarded
                        ) == expected,
                        "\(destination) preview=\(preview) onboarded=\(onboarded)"
                    )
                }
            }
        }
    }
}
