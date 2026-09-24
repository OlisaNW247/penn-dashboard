import Foundation
import Testing
@testable import LowHangingFruitUI

/// SwiftUI is not rendered by the package test runner, so these tests pin the
/// few source-level layout contracts that have regressed during merges.
@MainActor
@Suite("V7 visual structure")
struct VisualStructureTests {
    @Test("dashboard title shares one compact size token")
    func balancedDashboardTitle() throws {
        #expect(ContentView.dashboardTitlePointSize == 27)

        let source = try uiSource("ContentView.swift")
        #expect(source.contains(".font(.lhfWordmark(Self.dashboardTitlePointSize))"))
        #expect(source.contains(".font(.lhfHeaderTitle(Self.dashboardTitlePointSize))"))
    }

    @Test("profile sections stay unified, ordered, and concise")
    func profileOrderAndCopy() throws {
        let source = try uiSource("SettingsPage.swift")
        let bodyStart = try #require(source.range(of: "var body: some View"))
        let bodyEnd = try #require(source.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<bodyEnd.upperBound])
        let markers = [
            "SmoothSectionHeader(\"your name\"",
            "SmoothSectionHeader(\"accounts\"",
            "SmoothSectionHeader(\"appearance\"",
            "remindersSection",
            "ProfileClassesSection",
            "ProfileNotificationsSection",
            "iCloudSyncSection",
        ]
        let positions = try markers.map { marker in
            try #require(body.range(of: marker)?.lowerBound)
        }
        #expect(zip(positions, positions.dropFirst()).allSatisfy(<))
        #expect(!body.localizedCaseInsensitiveContains("semester"))
        #expect(!source.contains("smooth keeps your pennkey password"))
        #expect(!source.contains("Sync is on. Changes appear"))
    }

    @Test("announcement and calendar quick actions have distinct accents")
    func distinctQuickActionAccents() throws {
        let source = try uiSource("ContentView.swift")
        let add = try functionBody(named: "addInlineButton", in: source)
        let announcements = try functionBody(named: "announcementFindsButton", in: source)

        #expect(add.contains("smoothTomato"))
        #expect(!add.contains("smoothAnnouncement"))
        #expect(announcements.contains("smoothAnnouncementAccent"))
        #expect(announcements.contains("smoothAnnouncementFill"))
        #expect(!announcements.contains("smoothGrape"))
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

    private func functionBody(named name: String, in source: String) throws -> String {
        let start = try #require(source.range(of: "private var \(name): some View"))
        let tail = source[start.lowerBound...]
        let next = try #require(tail.dropFirst().range(of: "\n    private "))
        return String(tail[..<next.lowerBound])
    }
}
