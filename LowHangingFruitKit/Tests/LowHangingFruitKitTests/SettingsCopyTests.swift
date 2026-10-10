import Foundation
import Testing
@testable import LowHangingFruitUI

/// The copy cut of 2026-10-10 ("I still get way too much text"): the Profile
/// page prints one fixed line for any sync failure instead of the system
/// error text, and the sign-in status prose that used to sit under the
/// accounts rows lives behind one collapsed debug-only disclosure.
@Suite("Settings copy cut")
struct SettingsCopyTests {
    private static let allClear =
        "Canvas Scan connected. No recurring syllabus or announcement requirements found yet."

    // MARK: Sync section message

    @Test("no notice and no error prints nothing")
    func nothingToSay() {
        #expect(SettingsPage.syncSectionMessage(notice: nil, error: nil) == nil)
        #expect(SettingsPage.syncSectionMessage(notice: "", error: "") == nil)
    }

    @Test("the scan's all-clear is good news and prints nothing")
    func scanAllClearIsDropped() {
        #expect(SettingsPage.syncSectionMessage(notice: Self.allClear, error: nil) == nil)
    }

    @Test("any failure prints the one fixed line, never the system error text")
    func failureIsOneFixedLine() {
        let notices = [
            "couldn't fully refresh canvas just now. showing your saved assignments.",
            "Canvas Scan needs you to reconnect or open Canvas once.",
            "Gradescope needs you to reconnect.",
        ]
        for notice in notices {
            #expect(SettingsPage.syncSectionMessage(notice: notice, error: nil) == "couldn't sync")
        }
        let raw = "Canvas Scan needs you to reconnect or open Canvas once. The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1009.)"
        #expect(SettingsPage.syncSectionMessage(notice: nil, error: raw) == "couldn't sync")
        #expect(SettingsPage.syncSectionMessage(notice: "x", error: raw) == "couldn't sync")
    }

    @Test("a real error is not hidden behind the scan's all-clear")
    func errorSurvivesAllClear() {
        #expect(SettingsPage.syncSectionMessage(notice: Self.allClear, error: "boom") == "couldn't sync")
    }

    @Test("the all-clear sentence in AppState still opens with the words the page filters on")
    func allClearPrefixMatchesAppState() throws {
        let source = try uiSource("AppState.swift")
        // A prebuilt test bundle run away from the checkout has nothing to scan.
        guard !source.isEmpty else { return }
        #expect(source.contains("\"" + SettingsPage.scanAllClearNoticePrefix),
                "AppState's scan all-clear no longer starts with SettingsPage.scanAllClearNoticePrefix, so Profile would print \"couldn't sync\" after a successful scan")
    }

    // MARK: Sign-in prose is out of the student's page

    @Test("sign-in status and ed status render only inside the collapsed debug disclosure")
    func signInProseIsDebugOnly() throws {
        let source = try uiSource("SettingsPage.swift")
        guard !source.isEmpty else { return }
        let bodyStart = try #require(source.range(of: "var body: some View"))
        let bodyEnd = try #require(source.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<bodyEnd.upperBound])

        let debugStart = try #require(body.range(of: "#if DEBUG"))
        let studentPage = String(body[..<debugStart.lowerBound])
        let debugPage = String(body[debugStart.lowerBound...])
        #expect(!studentPage.contains("signInHealthRows"))
        #expect(!studentPage.contains("edDiscussionStatus"))
        #expect(!studentPage.contains("ed discussion"))
        #expect(debugPage.contains("signInDiagnosticsGroup"))

        // The group itself exists only in a debug build, and starts collapsed
        // (a `DisclosureGroup` with no `isExpanded` binding does).
        let groupDecl = try #require(source.range(of: "private var signInDiagnosticsGroup"))
        let beforeDecl = String(source[..<groupDecl.lowerBound])
        let lastIf = try #require(beforeDecl.range(of: "#if DEBUG", options: .backwards))
        let lastEndif = beforeDecl.range(of: "#endif", options: .backwards)
        #expect(lastEndif == nil || lastEndif!.lowerBound < lastIf.lowerBound,
                "signInDiagnosticsGroup is declared outside #if DEBUG")
        #expect(source.contains("DisclosureGroup(\"sign-in diagnostics\")"))
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
