import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A failed Penn connect used to leave a spinner that never cleared: the
/// observer's `reachedSignedInDestination` stays latched, `onChange` only
/// fires on a change, and the pane showed neither a message nor a button.
/// Authentication now gates connection before it starts. These checks pin
/// the retained-session retry path and prevent the old second credential
/// sheet from returning during onboarding.
@Suite("Connect failure recovery")
struct ConnectFailureRecoveryTests {

    // MARK: "save pennkey" row

    @Test("the row shows only at Penn, connected, with nothing saved")
    func saveRowTruthTable() throws {
        let other = try #require(CanvasInstallation.verifiedSchools.first { $0.id != CanvasInstallation.penn.id })
        #expect(SettingsPage.showsSavePennKey(installation: .penn, isCanvasConnected: true, credentialSaved: false))
        #expect(!SettingsPage.showsSavePennKey(installation: .penn, isCanvasConnected: true, credentialSaved: true))
        #expect(!SettingsPage.showsSavePennKey(installation: .penn, isCanvasConnected: false, credentialSaved: false))
        #expect(!SettingsPage.showsSavePennKey(installation: other, isCanvasConnected: true, credentialSaved: false))
        #expect(!SettingsPage.showsSavePennKey(installation: other, isCanvasConnected: true, credentialSaved: true))
    }

    // MARK: Wiring

    @Test("the connect pane clears its spinner on failure, offers try again, and still never resets at Penn")
    func paneWiring() throws {
        let source = try uiSource("OnboardingView.swift")
        guard !source.isEmpty else { return }
        let pane = try #require(source.range(of: "private struct CanvasLoginPane: View {"))
        let body = String(source[pane.lowerBound...])
        // The spinner follows in-flight work; the fallback follows authenticated failure.
        #expect(body.contains("if isPurging || isReadingCookies"))
        #expect(body.contains("if connectFailed && navObserver.reachedSignedInDestination"))
        #expect(body.contains("defer { isReadingCookies = false }"))
        #expect(body.contains("Button(\"try again\", action: reloadLogin)"))
        // "try again" reloads the start URL and touches no counters.
        let reload = try #require(body.range(of: "private func reloadLogin() {"))
        let reloadBody = String(body[reload.lowerBound...].prefix(400))
        #expect(reloadBody.contains("startURL"))
        #expect(!reloadBody.contains("reset()"))
        let connect = try #require(body.range(of: "private func connect() {"))
        let connectBody = String(body[connect.lowerBound..<reload.lowerBound])
        #expect(connectBody.contains("connectFailed = true"))
        #expect(!connectBody.contains("navObserver.reset()"))
        #expect(connectBody.contains("navObserver.credentialCapture"))
        #expect(connectBody.contains("state.enableStayLoggedIn(username:"))
        // A successful Canvas login saves the submitted credential directly;
        // onboarding must never ask for it again in the old vault sheet.
        #expect(!source.contains("PennKeyCredentialsSheet("))
        #expect(!source.contains("showStayLoggedInOffer"))

    }

    @Test("Settings offers save pennkey beside the repair row and reads the Keychain outside body")
    func settingsWiring() throws {
        let source = try uiSource("SettingsPage.swift")
        guard !source.isEmpty else { return }
        #expect(source.contains("Button(\"save pennkey\")"))
        #expect(source.contains("stayLoggedInRows\n                    savePennKeyRow"))
        // The sheet is the existing one.
        let row = try #require(source.range(of: "private var savePennKeyRow: some View {"))
        #expect(String(source[row.lowerBound...].prefix(500)).contains("showStayLoggedInSheet = true"))
        // Cached, never read in a view body.
        let rowBody = String(source[row.lowerBound...].prefix(500))
        #expect(!rowBody.contains("PennKeyCredentialStore"))
    }

    private func uiSource(_ filename: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI").appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
