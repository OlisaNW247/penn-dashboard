import Foundation
import Testing

/// The Smooth Sweeper page that ends the onboarding walk, and the name
/// "Smooth Sweeper" wherever the loud 10-minute alert is named to a student.
///
/// Source scans, in the idiom of `BerserkAlarmTests`: the view is not
/// compiled into a test that can drive it, so these pin that the pieces are
/// *there* and wired in the right order, not that they look right on a phone.
@Suite("Smooth Sweeper onboarding page")
struct SweeperOnboardingTests {

    private static let usage =
        "The Smooth Sweeper rings an alarm 10 minutes before work you haven't turned in."

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

    private var sweeperSlice: String {
        get throws {
            let source = try onboarding()
            let start = try #require(source.range(of: "private var sweeperStep"))
            return String(source[start.lowerBound...])
        }
    }

    @Test("Phase declares sweeper after reminders, and stepContent shows sweeperStep")
    func phaseOrder() throws {
        let source = try onboarding()
        let reminders = try #require(source.range(of: "        case reminders\n"))
        let sweeper = try #require(source.range(of: "        case sweeper\n"))
        #expect(reminders.lowerBound < sweeper.lowerBound)
        let content = try slice(source, from: "private var stepContent", to: "private func finishOnboarding")
        #expect(content.contains("case .sweeper:"))
        #expect(content.contains("sweeperStep"))
    }

    @Test("Both reminders buttons go to the sweeper page and neither finishes the walk")
    func remindersFooterGoesOn() throws {
        let footer = try footerSlice
        #expect(footer.components(separatedBy: "phase = .sweeper").count - 1 == 2)
        #expect(!footer.contains("finishOnboarding()"))
        #expect(footer.contains("await scheduler.setEnabled(true)"))
    }

    @Test("The sweeper switch is bound to loudAlertEnabled and re-plans on change")
    func switchBinding() throws {
        let step = try sweeperSlice
        #expect(step.contains("scheduler.loudAlertEnabled"))
        #expect(step.contains("scheduler.setLoudAlertEnabled($0)"))
        #expect(step.contains("scheduler.rescheduleAfterPreferenceChange()"))
        #expect(step.contains("notificationOption("))
        #expect(step.contains("title: \"Smooth Sweeper\""))
    }

    @Test("The sweeper page has its headline, its one body line and a back chevron to reminders")
    func headlineAndBody() throws {
        let step = try sweeperSlice
        #expect(step.contains("Text(\"Smooth Sweeper\")"))
        #expect(step.contains("an alarm 10 minutes before anything you haven't turned in. if you actually never want to miss an assignment, keep this on."))
        #expect(step.contains("topBar(onBack: { phase = .reminders })"))
    }

    @Test("The done button asks for notification permission only when the sweeper is on, then finishes")
    func doneButton() throws {
        let step = try sweeperSlice
        #expect(step.contains("Text(\"done\")"))
        let gate = try #require(step.range(of: "if scheduler.loudAlertEnabled"))
        let enable = try #require(step.range(of: "await scheduler.setEnabled(true)"))
        let finish = try #require(step.range(of: "finishOnboarding()"))
        #expect(gate.lowerBound < enable.lowerBound)
        #expect(enable.lowerBound < finish.lowerBound)
    }

    @Test("The progress dots agree: four dots, and the sweeper page is the fourth")
    func progressDots() throws {
        let source = try onboarding()
        #expect(source.contains("ForEach(1...4, id: \\.self)"))
        #expect(!source.contains("ForEach(1...3, id: \\.self)"))
        #expect(try footerSlice.contains("progressDots(current: 3)"))
        #expect(try sweeperSlice.contains("progressDots(current: 4)"))
    }

    @Test("Settings names the switch Smooth Sweeper, not the loud 10-minute alert")
    func settingsToggle() throws {
        let settings = try ui("SettingsPage.swift")
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
