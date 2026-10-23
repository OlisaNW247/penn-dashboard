import Foundation
import Testing

/// SwiftUI is not run by the package test runner, so these pin, at the source
/// level, the launch-time contract `ContentView` has to keep.
///
/// The cookie-authenticated half of the refresh (Gradescope's scrape and the
/// Canvas fetch that is the ONLY source of Canvas submission state, with the
/// course intel and course-material / Ed sync that ride on it) used to run only
/// on `scenePhase` -> `.active`, which does not fire for the phase the view
/// starts in, and on a loop whose sleep comes first. `RootView`'s launch task
/// fetches just the cookieless ICS feed, so a phone that locked inside the
/// first five minutes ran none of it (seen on a device on 2026-10-23: twenty
/// minutes of silence). The launch task now runs that half once, before the
/// loop. It must not run the whole `refresh()`: the feed fetch and the laptop
/// sync are already in flight from `RootView` (`sync()` has no reentrancy
/// guard), and the two notification drains are not for code that runs before
/// anyone has looked at the dashboard.
///
/// The checks look for calls and their order, not for indentation, and strip
/// whole-line comments first, so a comment that names a call (as the launch
/// task's own explanation does) is not mistaken for the call.
@Suite("ContentView launch refresh")
struct LaunchRefreshStructureTests {

    private static let launchFunction = "refreshSessionSourcesAtLaunch"
    private static let launchCall = "await \(launchFunction)()"
    private static let loop = "while !Task.isCancelled"
    private static let sleep = "Task.sleep"
    private static let excludedAtLaunch = ["announceGradeChanges", "announceTurnedIn", "deviceSyncPass"]

    @Test("the launch pass is called once, before the loop's sleep, and never via refresh()")
    func launchPassPrecedesSleep() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let loop = try #require(source.range(of: Self.loop))
        let sleep = try #require(source.range(of: Self.sleep, range: loop.lowerBound..<source.endIndex))

        let calls = Self.ranges(of: Self.launchCall, in: source)
        #expect(calls.count == 1, "exactly one call to the launch pass in the whole file")
        let call = try #require(calls.first)
        #expect(call.lowerBound < loop.lowerBound)
        #expect(call.lowerBound < sleep.lowerBound)

        // The launch work: from the closest `.task` modifier up to the loop.
        // It holds neither the whole refresh() nor the feed sync.
        let owner = try #require(
            source.range(of: ".task", options: .backwards, range: source.startIndex..<call.lowerBound)
        )
        let launch = String(source[owner.lowerBound..<loop.lowerBound])
        #expect(!launch.contains("await refresh()"))
        #expect(!launch.contains("syncIfConfigured"))
        for name in Self.excludedAtLaunch {
            #expect(!launch.contains(name), "\(name) must not run in the launch task")
        }
    }

    @Test("the launch pass runs the session fetches, the expiry check and the replan, and none of the excluded calls")
    func launchPassBody() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let launch = try Self.body(ofFunctionDeclaredWith: "func \(Self.launchFunction)() async", in: source)
        // Whatever the launch pass delegates to counts as part of it.
        var reachable = launch
        for helper in ["fetchSessionSources", "settleAfterFetch"] {
            #expect(launch.contains("await \(helper)()"), "launch pass should call \(helper)")
            reachable += try Self.body(ofFunctionDeclaredWith: "func \(helper)() async", in: source)
        }
        for name in Self.excludedAtLaunch {
            #expect(!reachable.contains(name), "\(name) must not be reachable from the launch pass")
        }
        #expect(!reachable.contains("syncIfConfigured"))
        #expect(!reachable.contains("await refresh()"))

        let calls = [
            "AutoSyncCoordinator.syncConnectedServices(state: state)",
            "AutoSyncCoordinator.refreshCanvasGrades(state: state)",
            "state.refreshCanvasSessionExpiredState()",
            "state.retrySilentRenewalIfDue()",
            "vm.reload(preservingEdits: true)",
            "state.refreshAnnouncementBadge()",
            "scheduler.reschedule(from: vm.items)",
        ]
        for call in calls {
            #expect(reachable.contains(call), "launch pass should reach \(call)")
        }
    }

    @Test("the periodic refresh() still syncs the feed, fetches, syncs the laptop, settles, then posts both drains, in that order")
    func periodicRefreshKeepsEverything() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let body = try Self.body(ofFunctionDeclaredWith: "func refresh() async", in: source)
        let calls = [
            "await state.syncIfConfigured()",
            "await fetchSessionSources()",
            "await state.deviceSyncPass()",
            "await settleAfterFetch()",
            "await announceGradeChanges()",
            "await announceTurnedIn()",
        ]
        let positions = try calls.map { call in try #require(body.range(of: call), "missing \(call)").lowerBound }
        #expect(zip(positions, positions.dropFirst()).allSatisfy(<))
        #expect(!body.contains(Self.launchFunction))
    }

    @Test("the two halves keep the old refresh() call order")
    func halvesKeepOldOrder() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let fetch = try Self.body(ofFunctionDeclaredWith: "func fetchSessionSources() async", in: source)
        let gradescope = try #require(fetch.range(of: "AutoSyncCoordinator.syncConnectedServices(state: state)"))
        let canvas = try #require(fetch.range(of: "AutoSyncCoordinator.refreshCanvasGrades(state: state)"))
        #expect(gradescope.lowerBound < canvas.lowerBound)

        let settle = try Self.body(ofFunctionDeclaredWith: "func settleAfterFetch() async", in: source)
        let calls = [
            "state.refreshCanvasSessionExpiredState()",
            "state.retrySilentRenewalIfDue()",
            "state.refreshDuoRememberSummary()",
            "vm.reload(preservingEdits: true)",
            "state.refreshAnnouncementBadge()",
            "scheduler.reschedule(from: vm.items)",
        ]
        let positions = try calls.map { call in try #require(settle.range(of: call), "missing \(call)").lowerBound }
        #expect(zip(positions, positions.dropFirst()).allSatisfy(<))
    }

    // MARK: - Helpers

    /// Every range of `needle` in `text`.
    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: needle, range: from..<text.endIndex) {
            found.append(r)
            from = r.upperBound
        }
        return found
    }

    /// The text between the braces of the function whose declaration contains
    /// `signature`, found by matching braces rather than by indentation.
    private static func body(ofFunctionDeclaredWith signature: String, in source: String) throws -> String {
        let header = try #require(source.range(of: signature))
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

    /// Source with whole-line `//` comments dropped (doc comments included).
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
        let file = sources.appendingPathComponent(filename)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
