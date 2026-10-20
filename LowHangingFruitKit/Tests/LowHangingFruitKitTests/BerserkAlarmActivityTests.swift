import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Berserk mode's Live Activity: the Dynamic Island and lock screen card the
/// widget extension draws for a ringing alarm.
///
/// The activity itself (`LHFWidget/BerserkAlarmActivity.swift`) is a widget
/// extension target and the metadata type sits behind AlarmKit, so `swift test`
/// compiles neither. What can be proven here is the pure half (the plan now
/// carries the class and the due moment the card draws, and the alarm ids moved
/// to a new namespace) and, as source scans like the ones in
/// `BerserkAlarmTests`, that the pieces are wired: the Info.plist key, the
/// project file, the bundle, and the metadata's move into the Kit. That the
/// card looks right, and that iOS shows it at all, only a device on iOS 26
/// proves.
@MainActor
@Suite("Berserk alarm Live Activity")
struct BerserkAlarmActivityTests {

    // MARK: The plan carries what the card draws

    private func item(course: String, id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    @Test("A planned alarm carries the due moment (fire date plus the lead) and the class as the card shows it")
    func plannedAlarmCarriesCourseAndDue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(6 * 3600)
        let hw = item(course: "CIS 1200", id: "hw1", due: due)

        let plain = BerserkAlarmPlan.alarms(for: [hw], now: now, nameOverrides: [:])
        let one = try #require(plain.first)
        #expect(plain.count == 1)
        #expect(one.dueAt == one.fireDate + NotificationScheduler.loudAlertLead)
        #expect(one.dueAt == due)
        #expect(one.course == hw.assignment.displayCourse(overrides: [:]))

        // A student's rename is what the card says, as it is everywhere else.
        let renamed = BerserkAlarmPlan.alarms(for: [hw], now: now, nameOverrides: ["CIS 1200": "Algorithms"])
        let renamedOne = try #require(renamed.first)
        #expect(renamedOne.course == "Algorithms")
    }

    // MARK: The id namespace

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

    private func repoSource(_ path: String) throws -> String {
        try read(repoRoot().appendingPathComponent(path))
    }

    @Test("Alarm ids are in the v2 namespace, so an alarm scheduled before the Live Activity is cancelled and rescheduled once")
    func idNamespaceIsV2() throws {
        let source = try repoSource("LowHangingFruitKit/Sources/LowHangingFruitUI/BerserkAlarmPlan.swift")
        #expect(source.contains("lhf.berserk-alarm.v2|"))
        // The doc comment explains the change in words and may name the old
        // namespace without its trailing bar; only the live string is pinned.
        #expect(!source.contains("lhf.berserk-alarm.v1|"))
    }

    @Test("alarmID is still a stable version-8, variant-1 UUID")
    func alarmIDShape() {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        let a = BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw1", fireDate: fire)
        let b = BerserkAlarmPlan.alarmID(assignmentID: "canvas:hw1", fireDate: fire)
        #expect(a == b)

        // "xxxxxxxx-xxxx-Vxxx-Nxxx-xxxxxxxxxxxx": V is character 14, N is 19.
        let chars = Array(a.uuidString.lowercased())
        #expect(chars.count == 36)
        #expect(chars[14] == "8")
        #expect("89ab".contains(chars[19]))
    }

    // MARK: Where it is wired (source structure)

    @Test("NSSupportsLiveActivities is true in App/Info.plist and in project.yml's app target")
    func liveActivitiesKey() throws {
        let plistData = try Data(contentsOf: repoRoot().appendingPathComponent("App/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["NSSupportsLiveActivities"] as? Bool == true)

        let yml = try repoSource("project.yml")
        let key = try #require(yml.range(of: "NSSupportsLiveActivities: true"))
        let widgetTarget = try #require(yml.range(of: "\n  LHFWidgetExtension:"))
        #expect(key.lowerBound < widgetTarget.lowerBound, "it belongs to the app target, not the widget's")
    }

    @Test("project.pbxproj compiles BerserkAlarmActivity.swift into the project")
    func projectListsTheActivity() throws {
        let pbxproj = try repoSource("LowHangingFruit.xcodeproj/project.pbxproj")
        #expect(pbxproj.contains("BerserkAlarmActivity.swift in Sources"))
        #expect(pbxproj.contains("path = BerserkAlarmActivity.swift"))
    }

    @Test("The widget bundle adds the activity under an iOS 26 check, and the activity uses the Kit's attributes type")
    func bundleAndActivity() throws {
        let bundle = try repoSource("LHFWidget/LHFWidgetBundle.swift")
        let check = try #require(bundle.range(of: "#available(iOS 26.0, *)"))
        let activity = try #require(bundle.range(of: "BerserkAlarmActivity()"))
        #expect(check.lowerBound < activity.lowerBound)

        let source = try repoSource("LHFWidget/BerserkAlarmActivity.swift")
        #expect(source.contains("ActivityConfiguration(for: AlarmAttributes<BerserkAlarmMetadata>.self"))
        // The extension links the Kit only; the UI module is not reachable.
        #expect(!source.contains("import LowHangingFruitUI"))
        #expect(!source.contains("widgetURL"))
    }

    @Test("The metadata type is defined once, in the Kit, and no longer in the scheduler")
    func metadataLivesInTheKit() throws {
        let scheduler = try repoSource("LowHangingFruitKit/Sources/LowHangingFruitUI/BerserkAlarmScheduler.swift")
        #expect(!scheduler.contains("struct BerserkAlarmMetadata"))

        let kit = try repoSource("LowHangingFruitKit/Sources/LowHangingFruitKit/Alarms/BerserkAlarmMetadata.swift")
        #expect(kit.contains("public struct BerserkAlarmMetadata: AlarmMetadata"))
    }
}
