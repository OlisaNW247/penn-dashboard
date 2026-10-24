import Foundation
import Testing

/// The Smooth Sweeper switch on the onboarding reminders page, and the name
/// "Smooth Sweeper" wherever the loud 10-minute alert is named to a student.
///
/// It had a page of its own for a few hours on 2026-10-20 (the owner asked
/// for one, then, seeing it beside the reminders page, had the two combined),
/// so some of these tests pin what is *gone*: a sweeper phase, a fourth dot,
/// and a reminders footer that stops one page short of finishing.
///
/// Source scans, in the idiom of `BerserkAlarmTests`: the view is not
/// compiled into a test that can drive it, so these pin that the pieces are
/// *there* and wired in the right order, not that they look right on a phone.
@Suite("Smooth Sweeper onboarding")
struct SweeperOnboardingTests {

    private static let usage =
        "The Smooth Sweeper rings an alarm before work you haven't turned in, at the time you choose."

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()    // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()    // .../Tests
            .deletingLastPathComponent()    // .../LowHangingFruitKit
    }

    private func repoRoot() -> URL { packageRoot().deletingLastPathComponent() }

    /// A file that cannot be found is a failure, not a pass.
    private func read(_ url: URL) throws -> String {
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func ui(_ filename: String) throws -> String {
        try read(packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)"))
    }

    private func onboarding() throws -> String { try ui("OnboardingView.swift") }

    /// The text from `start` up to the first `end` after it.
    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let s = try #require(source.range(of: start), "no \(start)")
        let e = try #require(source.range(of: end, range: s.upperBound..<source.endIndex), "no \(end)")
        return String(source[s.lowerBound..<e.lowerBound])
    }

    private var footerSlice: String {
        get throws {
            try slice(onboarding(), from: "private var remindersFooter", to: "// MARK:")
        }
    }

    private var sectionSlice: String {
        get throws {
            try slice(onboarding(), from: "private var sweeperSection", to: "private func notificationOption")
        }
    }

    @Test("Phase has no sweeper case and stepContent has no sweeper page")
    func noSweeperPhase() throws {
        let source = try onboarding()
        let phase = try slice(source, from: "enum Phase", to: "/// Where the walk starts")
        #expect(phase.contains("case reminders\n"))
        #expect(!phase.contains("sweeper"))
        let content = try slice(source, from: "private var stepContent", to: "private func finishOnboarding")
        #expect(!content.contains(".sweeper"))
        #expect(!content.contains("sweeperStep"))
    }

    @Test("The reminders page holds the sweeper section, after the extras")
    func remindersStepHoldsSection() throws {
        let step = try slice(onboarding(), from: "private var remindersStep", to: "private var remindersHeadline")
        let extras = try #require(step.range(of: "notificationExtrasSection"))
        let section = try #require(step.range(of: "sweeperSection"))
        #expect(extras.lowerBound < section.lowerBound)
    }

    @Test("The section has its header, its two lines and a switch bound to loudAlertEnabled that re-plans")
    func sectionContents() throws {
        let section = try sectionSlice
        #expect(section.contains("SmoothSectionHeader(\"smooth sweeper\""))
        // Two lines since the owner's second look (2026-10-20): the
        // description alone, larger, then the nudge in parentheses.
        #expect(section.contains("Text(\"an alarm 10 minutes before anything you haven't turned in.\")"))
        #expect(section.contains("Text(\"(if you actually never want to miss an assignment, keep this on.)\")"))
        #expect(section.contains(".lhfSans(17)"))
        #expect(section.contains(".lhfSans(14)"))
        #expect(section.contains("notificationOption("))
        #expect(section.contains("title: \"Smooth Sweeper\""))
        #expect(section.contains("scheduler.loudAlertEnabled"))
        #expect(section.contains("scheduler.setLoudAlertEnabled($0)"))
        #expect(section.contains("scheduler.rescheduleAfterPreferenceChange()"))
    }

    @Test("Both reminders buttons finish the walk, and neither goes to a sweeper page")
    func remindersFooterFinishes() throws {
        let footer = try footerSlice
        #expect(footer.components(separatedBy: "finishOnboarding()").count - 1 == 2)
        #expect(!footer.contains("phase = .sweeper"))
        let enable = try #require(footer.range(of: "await scheduler.setEnabled(true)"))
        let finish = try #require(footer.range(of: "finishOnboarding()"))
        #expect(enable.lowerBound < finish.lowerBound)
    }

    @Test("No leftover of the separate page: no step, headline, footer or done button")
    func noLeftovers() throws {
        let source = try onboarding()
        #expect(!source.contains("sweeperStep"))
        #expect(!source.contains("sweeperHeadline"))
        #expect(!source.contains("sweeperFooter"))
        #expect(!source.contains("Text(\"done\")"))
    }

    @Test("The progress dots agree: three dots, and the reminders page is the third")
    func progressDots() throws {
        let source = try onboarding()
        #expect(source.contains("ForEach(1...3, id: \\.self)"))
        #expect(!source.contains("ForEach(1...4, id: \\.self)"))
        #expect(!source.contains("progressDots(current: 4)"))
        #expect(try footerSlice.contains("progressDots(current: 3)"))
    }

    @Test("Settings names the switch Smooth Sweeper, not the loud 10-minute alert")
    func settingsToggle() throws {
        let settings = try ui("SweeperSettingsSection.swift")
        #expect(settings.contains("Toggle(\"Smooth Sweeper\""))
        #expect(!settings.contains("Toggle(\"loud 10-minute alert\""))
    }

    @Test("The takeover screen and the alarm's lock screen card are headed Smooth Sweeper")
    func headings() throws {
        #expect(try ui("BerserkTakeoverView.swift").contains("Text(\"Smooth Sweeper\")"))
        let activity = try read(repoRoot().appendingPathComponent("LHFWidget/BerserkAlarmActivity.swift"))
        #expect(activity.contains("Text(\"Smooth Sweeper\")"))
    }

    @Test("The AlarmKit usage string is the Smooth Sweeper one in Info.plist and project.yml")
    func usageString() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("App/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSAlarmKitUsageDescription"] as? String == Self.usage)
        let yml = try read(repoRoot().appendingPathComponent("project.yml"))
        #expect(yml.contains("NSAlarmKitUsageDescription: \"\(Self.usage)\""))
    }
}
