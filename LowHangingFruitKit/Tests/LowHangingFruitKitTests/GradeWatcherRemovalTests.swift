import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The owner removed Grade Watcher on 2026-10-18 (`FeatureFlags.gradeWatcher`).
/// What "removed" means is narrow, and each half is pinned here: no way into
/// the screens in a Release build, and no "grade posted" notification. What it
/// must NOT mean (the Canvas grade fetch stopping) is left to the existing
/// suites that exercise that fetch's outputs.
@Suite("Grade Watcher removal")
struct GradeWatcherRemovalTests {

    private func change(_ id: String) -> AssignmentStore.ScoreChange {
        .init(assignmentID: id, course: "CIS 3200", title: "Midterm",
              previous: nil, earned: 78, max: 100)
    }

    @Test("the flag is off")
    func flagIsOff() {
        #expect(FeatureFlags.gradeWatcher == false)
    }

    @Test("no grade-change notice is posted with Grade Watcher off")
    func noNoticesWhenOff() {
        let changes = [change("1"), change("2")]
        #expect(NotificationScheduler.gradeNoticesToPost(changes, gradeWatcherEnabled: false).isEmpty)
        // And that is what the app gets: the default argument is the real flag.
        #expect(NotificationScheduler.gradeNoticesToPost(changes).isEmpty)
    }

    @Test("with Grade Watcher on the notices pass through untouched")
    func noticesWhenOn() {
        let changes = [change("1"), change("2")]
        #expect(NotificationScheduler.gradeNoticesToPost(changes, gradeWatcherEnabled: true) == changes)
    }

    @Test("the Canvas grade fetch and what hangs off it never read the flag")
    func fetchDoesNotReadTheFlag() throws {
        // `refreshCanvasGrades` is the only source of auto-submitted state,
        // "turned in" notices, the 401 renewal probe, course intel and the
        // course-knowledge refresh. Gating it on "Grade Watcher is off" would
        // silence all of them, and the symptom would not point back here.
        for name in ["AutoSyncCoordinator.swift", "AppState.swift", "AppState+CourseKnowledge.swift",
                     "CanvasSessionRenewer.swift", "BackgroundRefresh.swift"] {
            let text = try Self.uiSource(name)
            #expect(!text.contains("FeatureFlags.gradeWatcher"), "\(name) reads FeatureFlags.gradeWatcher")
        }
    }

    @Test("the header's grades button is the only route in, and it is behind the flag")
    func gradesRouteIsGated() throws {
        let source = try Self.uiSource("ContentView.swift")
        guard !source.isEmpty else { return }

        // Release view of the file: the DEBUG launch-argument seams
        // (`-LHFShowGrades`, `-LHFShowReport`) compile out.
        let release = Self.strippingDebugBlocks(source)
        #expect(!release.contains("path = [.grades"))
        #expect(!release.contains("path.append(.grades"))
        #expect(!release.contains(".report(courseID: course.key"))

        let button = try #require(release.range(of: "navButton(to: .grades"))
        let before = String(release[..<button.lowerBound])
        let gate = try #require(before.range(of: "FeatureFlags.gradeWatcher", options: .backwards))
        #expect(!before[gate.upperBound...].contains("}"),
                "the grades button is no longer directly inside the FeatureFlags.gradeWatcher check")

        // No other view builds the screens (GradeWatcherView itself pushes the
        // report through GradeCourseCardView, which is only reachable from it).
        let others = ["AppState.swift", "SettingsPage.swift", "LHFScenes.swift", "RootView.swift"]
        for name in others {
            let text = try Self.uiSource(name)
            #expect(!text.contains("GradeWatcherView("), "\(name) builds GradeWatcherView")
        }
    }

    // MARK: Helpers

    /// The source as a Release build sees it: `#if DEBUG` blocks removed, and
    /// whole-line comments too, so a comment that names a symbol (as the
    /// comments explaining why it is debug-only do) is not mistaken for a use.
    static func strippingDebugBlocks(_ source: String) -> String {
        var out: [Substring] = []
        var depth = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if DEBUG" { depth += 1; continue }
            if depth > 0 {
                if trimmed == "#endif" { depth -= 1 }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    static func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        let file = sources.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
