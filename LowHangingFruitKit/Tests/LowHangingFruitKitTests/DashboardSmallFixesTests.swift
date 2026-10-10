import Foundation
import Testing
@testable import LowHangingFruitUI

/// Small dashboard and settings fixes from the 2026-10-10 review that no pure
/// function carries, so they are pinned the way `VisualStructureTests` pins
/// layout: by what the source says. Each test names the defect it guards.
@Suite("Dashboard small fixes")
struct DashboardSmallFixesTests {

    @Test("the disconnect confirmation is titled in lowercase like the rest of the app")
    func disconnectTitleIsLowercase() {
        #expect(SettingsPage.DisconnectTarget.canvas.label == "canvas")
        #expect(SettingsPage.DisconnectTarget.gradescope.label == "gradescope")
    }

    @Test("the rename prompt is titled in lowercase")
    func renameTitleIsLowercase() throws {
        let source = try uiSource("ProfileClassesSection.swift")
        guard !source.isEmpty else { return }
        #expect(source.contains(".alert(\"rename class\""))
        #expect(!source.contains(".alert(\"Rename class\""))
    }

    @Test("the add and announcements buttons have the same 44pt hit area as the filter button")
    func controlRowHitAreas() throws {
        let source = try uiSource("ContentView.swift")
        guard !source.isEmpty else { return }
        for name in ["addInlineButton", "announcementFindsButton"] {
            let start = try #require(source.range(of: "private var \(name): some View"))
            let tail = source[start.lowerBound...]
            let end = tail.dropFirst().range(of: "\n    private ")?.lowerBound ?? tail.endIndex
            let body = String(tail[..<end])
            #expect(body.contains(".frame(width: 38, height: 38)"), "\(name) still draws 38pt")
            #expect(body.contains(".contentShape(Circle().inset(by: -3))"), "\(name) lost its 44pt hit area")
            #expect(!body.contains(".contentShape(Circle())"), "\(name) is back to a 38pt hit area")
        }
        // The reference the others copy.
        let controls = try uiSource("DashboardControls.swift")
        #expect(controls.contains(".contentShape(Circle().inset(by: -3))"))
    }

    @Test("the todo empty state does not claim a week, because todo is only overdue plus two days")
    func todoEmptyStateIsNotAWeek() throws {
        let source = try uiSource("ContentView.swift")
        guard !source.isEmpty else { return }
        #expect(!source.contains("nothing due this week"))
        #expect(source.contains("Text(\"nothing due soon\")"))
        #expect(source.contains(".accessibilityLabel(\"nothing due soon. go enjoy life\")"))
    }

    @Test("a failed Canvas connect in onboarding shows the fixed sentence, never a raw sync error")
    func onboardingFailureIsFixedCopy() throws {
        let source = try uiSource("OnboardingView.swift")
        guard !source.isEmpty else { return }
        #expect(source.contains("message = \"couldn't sign in. try again.\""))
        #expect(!source.contains("state.error ?? \"couldn't sign in"))
    }

    @Test("the dashboard shows the not-saving banner below the sync-error banner")
    func notSavingBannerSitsBelowTheSyncErrorBanner() throws {
        let source = try uiSource("ContentView.swift")
        guard !source.isEmpty else { return }
        let sync = try #require(source.range(of: "                    syncErrorBanner\n"))
        let banner = try #require(source.range(of: "                    notSavingBanner\n"))
        #expect(sync.lowerBound < banner.lowerBound)
        #expect(source.contains("Text(\"not saving on this phone\")"))
        #expect(source.contains("if state.showsNotSavingBanner"))
    }

    private func uiSource(_ filename: String) throws -> String {
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
