import Foundation
import Testing

/// The silent-push wake needs the `remote-notification` background mode in
/// the plist the app ships AND in `project.yml` (`xcodegen generate` rewrites
/// the plist from the yml, CLAUDE.md → Traps), beside `fetch`. It must NOT
/// need the `aps-environment` entitlement yet: that line needs Push
/// Notifications enabled on the App ID first, which is Olisa's step, and a
/// build signed without that capability fails to install.
@Suite("Sweeper wake plist")
struct SweeperWakePlistTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        let url = repoRoot().appendingPathComponent(path)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(url.path) is not there")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Info.plist lists fetch and remote-notification")
    func plist() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("App/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let modes = try #require(plist["UIBackgroundModes"] as? [String])
        #expect(modes.contains("fetch"))
        #expect(modes.contains("remote-notification"))
    }

    @Test("project.yml lists both under the app target's UIBackgroundModes")
    func yml() throws {
        let yml = try read("project.yml")
        let widgetTarget = try #require(yml.range(of: "\n  LHFWidgetExtension:"))
        let key = try #require(yml.range(of: "UIBackgroundModes:"))
        #expect(key.lowerBound < widgetTarget.lowerBound, "the app target's, not the widget's")
        let tail = yml[key.upperBound...]
        var items: [String] = []
        for line in tail.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") { items.append(String(trimmed.dropFirst(2))) } else { break }
        }
        #expect(items == ["fetch", "remote-notification"])
    }

    @Test("the entitlements file has no aps-environment: that line is Olisa's step, after Push is enabled on the App ID")
    func noApsEnvironment() throws {
        let entitlements = try read("App/LHFApp.entitlements")
        #expect(!entitlements.contains("aps-environment"))
    }
}
