import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A failed Penn connect used to leave a spinner that never cleared: the
/// observer's `reachedSignedInDestination` stays latched, `onChange` only
/// fires on a change, and the pane showed neither a message nor a button.
/// The rules behind the fix are pure and pinned here; the pane's wiring is
/// pinned by reading its source, since a SwiftUI pane cannot be built
/// without a window.
@Suite("Connect failure recovery")
struct ConnectFailureRecoveryTests {

    // MARK: Retry cap

    @Test("Penn never resets the observer after a failed connect, however few retries have run")
    func pennNeverResets() {
        for soFar in 0...6 {
            #expect(CanvasConnectRetryRule.failedConnectAction(for: .penn, automaticResetsSoFar: soFar)
                    == .showFailureKeepingCounter, "Penn after \(soFar) resets")
        }
    }

    @Test("every other school resets and retries twice, then stops")
    func otherSchoolsAreCappedAtTwo() throws {
        #expect(CanvasConnectRetryRule.maxAutomaticResets == 2)
        let custom = try #require(CanvasInstallation.custom(address: "https://canvas.example.edu"))
        let others = CanvasInstallation.verifiedSchools.filter { $0.id != CanvasInstallation.penn.id } + [custom]
        #expect(!others.isEmpty)
        for school in others {
            #expect(CanvasConnectRetryRule.failedConnectAction(for: school, automaticResetsSoFar: 0) == .resetAndRetry, "\(school.id) first failure")
            #expect(CanvasConnectRetryRule.failedConnectAction(for: school, automaticResetsSoFar: 1) == .resetAndRetry, "\(school.id) second failure")
            #expect(CanvasConnectRetryRule.failedConnectAction(for: school, automaticResetsSoFar: 2) == .showFailureKeepingCounter, "\(school.id) third failure")
            #expect(CanvasConnectRetryRule.failedConnectAction(for: school, automaticResetsSoFar: 9) == .showFailureKeepingCounter, "\(school.id) long after")
        }
    }

    @Test("a bouncing single sign-on ends: if every attempt fails, the pane resets twice and no more")
    func loopTerminates() throws {
        let school = try #require(CanvasInstallation.verifiedSchools.first { $0.id != CanvasInstallation.penn.id })
        var resets = 0
        // Every attempt "arrives signed in" and fails to connect.
        for _ in 0..<50 {
            guard CanvasConnectRetryRule.failedConnectAction(for: school, automaticResetsSoFar: resets) == .resetAndRetry else { break }
            resets += 1
        }
        #expect(resets == CanvasConnectRetryRule.maxAutomaticResets)
    }

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
        // The spinner is gated on the pane's own record of a failure, not just the latched flag.
        #expect(body.contains("navObserver.reachedSignedInDestination && !connectFailed"))
        #expect(body.contains("Button(\"try again\", action: reloadLogin)"))
        // "try again" reloads the start URL and touches no counters.
        let reload = try #require(body.range(of: "private func reloadLogin() {"))
        let reloadBody = String(body[reload.lowerBound...].prefix(400))
        #expect(reloadBody.contains("startURL"))
        #expect(!reloadBody.contains("reset()"))
        // The one place the failure branch resets is the capped case.
        let failure = try #require(body.range(of: "switch CanvasConnectRetryRule.failedConnectAction("))
        let tail = String(body[failure.lowerBound...])
        let keep = try #require(tail.range(of: "case .showFailureKeepingCounter:"))
        let keepBody = String(tail[keep.lowerBound...].prefix(1_800))
        #expect(keepBody.contains("connectFailed = true"))
        let keepCode = keepBody.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(!keepCode.contains("navObserver.reset()"))
        // A successful connect saves the captured PennKey itself; there is no
        // separate credentials sheet or stay-signed-in offer left to show.
        #expect(body.contains("navObserver.credentialCapture"))
        #expect(body.contains("state.enableStayLoggedIn(username:"))
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
