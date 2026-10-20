import Foundation
import Testing
@testable import LowHangingFruitUI

/// The copy cut of 2026-10-10 ("I still get way too much text"): the Profile
/// page prints one fixed line for any sync failure instead of the system
/// error text, and the sign-in status prose that used to sit under the
/// accounts rows renders in debug builds only. (Between 2026-10-10 and
/// 2026-10-18 it sat inside one collapsed disclosure; the co-owner asked for it
/// back in plain view under the canvas row, still debug-only.)
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

    @Test("the profile diagnostics are switched off, and the flag is the one way back")
    func profileDiagnosticsAreOff() {
        #expect(FeatureFlags.profileDiagnostics == false)
    }

    @Test("every diagnostic row is still defined, and each call site sits behind FeatureFlags.profileDiagnostics")
    func diagnosticsAreGatedNotDeleted() throws {
        let source = try uiSource("SettingsPage.swift")
        guard !source.isEmpty else { return }

        // Nothing was deleted on 2026-10-20: the flag hides the rows, it does
        // not remove them.
        for name in ["private var signInHealthRows", "private var edDiscussionStatusRow",
                     "private var syncSummaryRows", "private func syncSummaryRow(",
                     "private var probeEdDiscussionRow", "private var simulateCanvasLogoutRow"] {
            #expect(source.contains(name), "\(name) was deleted instead of gated")
        }

        // Whitespace collapsed, so the scan does not care about indentation.
        let flat = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let gate = "if FeatureFlags.profileDiagnostics {"
        #expect(flat.components(separatedBy: gate).count - 1 == 4,
                "expected exactly four gated call sites in SettingsPage.swift")
        #expect(flat.contains("\(gate) signInHealthRows }"))
        #expect(flat.contains("\(gate) edDiscussionStatusRow }"))
        #expect(flat.contains("\(gate) syncSummaryRows }"))
        #expect(flat.contains("\(gate) Section { simulateCanvasLogoutRow probeEdDiscussionRow }"))

        // Gated inside `#if DEBUG`, never instead of it: a Release build must
        // not compile any of them whatever the flag says.
        let bodyStart = try #require(source.range(of: "var body: some View"))
        let bodyEnd = try #require(source.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<bodyEnd.upperBound])
        let studentPage = GradeWatcherRemovalTests.strippingDebugBlocks(body)
        for name in ["profileDiagnostics", "signInHealthRows", "edDiscussionStatusRow",
                     "syncSummaryRows", "probeEdDiscussionRow", "simulateCanvasLogoutRow"] {
            #expect(!studentPage.contains(name), "\(name) is reachable from a Release build's page")
        }
    }

    @Test("sign-in status and ed status render only in debug builds, under their account rows")
    func signInProseIsDebugOnly() throws {
        let source = try uiSource("SettingsPage.swift")
        guard !source.isEmpty else { return }
        let bodyStart = try #require(source.range(of: "var body: some View"))
        let bodyEnd = try #require(source.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<bodyEnd.upperBound])

        // What a student's page contains: the body with every `#if DEBUG`
        // block removed. None of the sign-in prose may be left in it.
        let studentPage = GradeWatcherRemovalTests.strippingDebugBlocks(body)
        #expect(!studentPage.contains("signInHealthRows"))
        #expect(!studentPage.contains("edDiscussionStatus"))
        #expect(!studentPage.contains("ed discussion"))

        // In a debug build the health lines follow the canvas row and the ed
        // row follows the gradescope row, as at ba75e97.
        let canvas = try #require(body.range(of: "label: \"canvas\""))
        let health = try #require(body.range(of: "signInHealthRows"))
        let gradescope = try #require(body.range(of: "label: \"gradescope\""))
        let ed = try #require(body.range(of: "edDiscussionStatusRow"))
        #expect(canvas.lowerBound < health.lowerBound)
        #expect(health.lowerBound < gradescope.lowerBound)
        #expect(gradescope.lowerBound < ed.lowerBound)

        // The collapsed disclosure is gone, so nothing shows twice.
        #expect(!source.contains("signInDiagnosticsGroup"))
        #expect(!source.contains("DisclosureGroup(\"sign-in diagnostics\")"))

        // Both rows are declared only in a debug build.
        for name in ["private var signInHealthRows", "private var edDiscussionStatusRow"] {
            let decl = try #require(source.range(of: name))
            let beforeDecl = String(source[..<decl.lowerBound])
            let lastIf = try #require(beforeDecl.range(of: "#if DEBUG", options: .backwards))
            let lastEndif = beforeDecl.range(of: "#endif", options: .backwards)
            #expect(lastEndif == nil || lastEndif!.lowerBound < lastIf.lowerBound,
                    "\(name) is declared outside #if DEBUG")
        }
    }

    // MARK: Sign in to canvas

    @Test("the sign-in row shows for a canvas connected without a saved login, never in preview")
    func signInToCanvasRule() {
        #expect(SettingsPage.showsSignInToCanvas(isLinkOnly: true, isPreviewMode: false))
        #expect(!SettingsPage.showsSignInToCanvas(isLinkOnly: false, isPreviewMode: false))
        #expect(!SettingsPage.showsSignInToCanvas(isLinkOnly: true, isPreviewMode: true))
        #expect(!SettingsPage.showsSignInToCanvas(isLinkOnly: false, isPreviewMode: true))
    }

    @Test("the sign-in row ships in Release and restarts onboarding at the canvas step")
    func signInToCanvasRowShips() throws {
        let source = try uiSource("SettingsPage.swift")
        guard !source.isEmpty else { return }
        let bodyStart = try #require(source.range(of: "var body: some View"))
        let bodyEnd = try #require(source.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<bodyEnd.upperBound])
        let studentPage = GradeWatcherRemovalTests.strippingDebugBlocks(body)
        let canvas = try #require(studentPage.range(of: "label: \"canvas\""))
        let row = try #require(studentPage.range(of: "signInToCanvasRow"))
        let gradescope = try #require(studentPage.range(of: "label: \"gradescope\""))
        #expect(canvas.lowerBound < row.lowerBound && row.lowerBound < gradescope.lowerBound)

        let declStart = try #require(source.range(of: "private var signInToCanvasRow"))
        let decl = String(source[declStart.lowerBound...].prefix(500))
        #expect(decl.contains("Button(\"sign in to canvas\")"))
        #expect(decl.contains("state.restartOnboarding(for: .canvas)"))
        // Declared outside any `#if DEBUG`.
        let beforeDecl = String(source[..<declStart.lowerBound])
        let lastIf = beforeDecl.range(of: "#if DEBUG", options: .backwards)
        let lastEndif = beforeDecl.range(of: "#endif", options: .backwards)
        #expect(lastIf == nil || (lastEndif != nil && lastIf!.lowerBound < lastEndif!.lowerBound))
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
