import Foundation
import Testing

/// SwiftUI is not run by the package test runner, so these pin, at the source
/// level, the one launch-time ordering contract `ContentView` has to keep.
///
/// The cookie-authenticated half of the refresh (Gradescope's scrape and the
/// Canvas fetch that is the ONLY source of Canvas submission state) used to run
/// only on `scenePhase` -> `.active`, which does not fire for the phase the
/// view starts in, and on a loop whose sleep comes first. `RootView`'s launch
/// sync fetches just the cookieless ICS feed, which carries no submission
/// state, so a cold launch showed work submitted since the last refresh as not
/// done (with its reminders still planned) for about five minutes. The launch
/// task now runs that half once. It must not run the whole `refresh()`: the
/// feed half is already in flight from `RootView`, and `sync()` has no
/// reentrancy guard.
///
/// The checks look for calls and their order, not for indentation or for the
/// exact spelling of the modifier that owns the launch work, so a reformat or a
/// `.task(priority:)` does not break them.
@Suite("ContentView launch refresh")
struct LaunchRefreshStructureTests {

    private static let newFunction = "refreshSessionSourcesAndReplan"
    private static let newCall = "await \(newFunction)()"
    private static let loop = "while !Task.isCancelled"

    @Test("the session-sourced refresh is called once before the five-minute loop, never via refresh()")
    func launchRunsSessionRefreshBeforeLoop() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let loop = try #require(source.range(of: Self.loop))

        let before = Self.ranges(of: Self.newCall, in: source).filter { $0.lowerBound < loop.lowerBound }
        #expect(before.count == 1, "exactly one launch call ahead of the loop")
        let launchCall = try #require(before.first)

        // The launch work: from the closest modifier that starts a task up to
        // the loop. It must hold neither the whole refresh() (a second feed
        // fetch beside RootView's launch sync) nor the feed sync itself.
        let owner = try #require(
            source.range(of: ".task", options: .backwards, range: source.startIndex..<launchCall.lowerBound)
        )
        let launch = String(source[owner.lowerBound..<loop.lowerBound])
        #expect(!launch.contains("await refresh()"))
        #expect(!launch.contains("syncIfConfigured"))
    }

    @Test("refresh() syncs the feed first, then hands off to the session-sourced refresh")
    func refreshIsFeedThenSessionRefresh() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let body = try Self.body(ofFunctionDeclaredWith: "func refresh() async", in: source)
        let feed = try #require(body.range(of: "await state.syncIfConfigured()"))
        let rest = try #require(body.range(of: Self.newCall))
        #expect(feed.lowerBound < rest.lowerBound)
    }

    @Test("the session-sourced refresh keeps every call of the old refresh(), in the old order, without the feed sync")
    func sessionRefreshKeepsOldCallOrder() throws {
        let source = Self.codeOnly(try Self.uiSource("ContentView.swift"))
        let body = try Self.body(ofFunctionDeclaredWith: "func \(Self.newFunction)() async", in: source)
        let calls = [
            "AutoSyncCoordinator.syncConnectedServices(state: state)",
            "AutoSyncCoordinator.refreshCanvasGrades(state: state)",
            "state.refreshCanvasSessionExpiredState()",
            "state.retrySilentRenewalIfDue()",
            "state.refreshDuoRememberSummary()",
            "vm.reload(preservingEdits: true)",
            "scheduler.reschedule(from: vm.items)",
            "announceGradeChanges()",
            "announceTurnedIn()",
        ]
        let positions = try calls.map { call in try #require(body.range(of: call), "missing \(call)").lowerBound }
        #expect(zip(positions, positions.dropFirst()).allSatisfy(<))
        #expect(!body.contains("syncIfConfigured"))
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

    /// Source with whole-line `//` comments dropped, so a comment that names a
    /// call (as the launch task's own explanation does) is not mistaken for
    /// the call.
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
