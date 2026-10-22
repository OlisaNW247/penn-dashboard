import Foundation
import Testing
@testable import LowHangingFruitUI

/// The wiring around pairing and encrypted sync (`AppState+DeviceSync.swift`,
/// `PairLaptopSheet.swift`): what is pure is tested as logic, what lives in
/// views and plists is pinned by source scan, in the style of
/// `VoiceDictationWiringTests`. The sync pass itself needs a backend and a
/// Keychain and is not covered here.
@Suite("Device sync wiring")
struct DeviceSyncWiringTests {

    // MARK: Scheme

    @Test("the smooth:// scheme is declared in App/Info.plist and in project.yml's app target")
    func schemeInBothPlaces() throws {
        let plistData = try Data(contentsOf: repoRoot().appendingPathComponent("App/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        #expect(schemes == ["smooth"])
        let plistName = try #require(types.first?["CFBundleURLName"] as? String)

        let yml = try read(repoRoot().appendingPathComponent("project.yml"))
        let widgetTarget = try #require(yml.range(of: "\n  LHFWidgetExtension:"))
        let found = try #require(yml.range(of: "CFBundleURLTypes:"))
        #expect(found.lowerBound < widgetTarget.lowerBound, "the scheme belongs to the app target, not the widget's")
        #expect(yml.components(separatedBy: "CFBundleURLTypes:").count == 2, "declared once")

        let block = String(yml[found.upperBound...].prefix(400))
        #expect(block.contains("- smooth"))
        #expect(block.contains("CFBundleURLName: \(plistName)"))
    }

    // MARK: The apply gate

    @Test("taps are recorded outside a remote apply, and not inside one")
    func gateSuppressesRecording() {
        let gate = RemoteApplyGate()
        #expect(DeviceSyncRules.shouldRecord(isApplyingRemote: gate.isApplying, isFixtureData: false))
        gate.run {
            #expect(gate.isApplying)
            #expect(!DeviceSyncRules.shouldRecord(isApplyingRemote: gate.isApplying, isFixtureData: false))
        }
        #expect(!gate.isApplying)
        #expect(DeviceSyncRules.shouldRecord(isApplyingRemote: gate.isApplying, isFixtureData: false))
    }

    @Test("the gate clears when the applied work throws, and nests")
    func gateClearsOnThrowAndNests() {
        struct Boom: Error {}
        let gate = RemoteApplyGate()
        _ = try? gate.run { () throws -> Int in throw Boom() }
        #expect(!gate.isApplying)

        let result: Int = gate.run {
            gate.run { #expect(gate.depth == 2) }
            #expect(gate.isApplying, "leaving the inner section must not end the outer one")
            return 7
        }
        #expect(result == 7)
        #expect(!gate.isApplying)
    }

    @Test("fixture data never records a change")
    func fixtureDataNeverRecords() {
        #expect(!DeviceSyncRules.shouldRecord(isApplyingRemote: false, isFixtureData: true))
        #expect(!DeviceSyncRules.shouldRecord(isApplyingRemote: true, isFixtureData: true))
    }

    @Test("every tap path stamps its ids, and the apply path goes through the gate")
    func tapHooksAndGateAreWired() throws {
        let state = try uiSource("AppState.swift")
        guard !state.isEmpty else { return }
        for (start, end, kind) in [
            ("func markCompleted(", "func markActive(", ".completion"),
            ("func markActive(", "private func rowsNeededToComplete", ".completion"),
            ("func addRecurringTask(", "func removeRecurringTask(", ".manual"),
            ("func removeRecurringTask(", "private var manualWorkIsLedgerBacked", ".manual"),
            ("func addManualAssignment(", "func replaceManualAssignment(", ".manual"),
            ("func removeManualAssignment(", "func addCanvasSuggestion(", ".manual"),
        ] {
            let from = try #require(state.range(of: start), "\(start) is gone")
            let to = try #require(state.range(of: end, range: from.upperBound..<state.endIndex), "\(end) is gone")
            let body = String(state[from.lowerBound..<to.lowerBound])
            #expect(body.contains("recordSyncChange(\(kind)"), "\(start) no longer stamps its change")
        }

        let edits = try uiSource("AppState+DueDateEdits.swift")
        let setEdit = try #require(edits.range(of: "func setDueDateEdit("))
        let tail = String(edits[setEdit.lowerBound...])
        #expect(tail.contains("recordSyncChange(.dueEdit, ids: ids)"))

        let sync = try uiSource("AppState+DeviceSync.swift")
        let apply = try #require(sync.range(of: "func applySyncPlan("))
        let applyBody = String(sync[apply.lowerBound...])
        #expect(applyBody.contains("remoteApplyGate.run {"))
        // The remote's own time is recorded after the gate closes, never now.
        let gateAt = try #require(applyBody.range(of: "remoteApplyGate.run {"))
        let adoptAt = try #require(applyBody.range(of: "log.record(kind: adopted.kind, id: adopted.id, at: adopted.at)"))
        #expect(gateAt.lowerBound < adoptAt.lowerBound)
    }

    // MARK: The throttle

    @Test("a pass runs the first time, and then at most once per two minutes")
    func throttle() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ last: Date?, _ now: Date, force: Bool = false) -> Bool {
            DeviceSyncRules.shouldRun(isAvailable: true, hasKey: true, isRunning: false,
                                      isBackground: false, lastRun: last, now: now, force: force)
        }
        #expect(DeviceSyncRules.minimumInterval == 120)
        #expect(run(nil, t0))
        #expect(!run(t0, t0))
        #expect(!run(t0, t0.addingTimeInterval(119.9)))
        #expect(run(t0, t0.addingTimeInterval(120)))
        #expect(run(t0, t0.addingTimeInterval(3_600)))
        // A clock set back must not freeze sync until it catches up.
        #expect(run(t0, t0.addingTimeInterval(-60)))
    }

    @Test("force skips the throttle only: never a missing key, a running pass, a background wake or an unavailable install")
    func forceSkipsOnlyTheThrottle() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func run(available: Bool = true, key: Bool = true, running: Bool = false, background: Bool = false) -> Bool {
            DeviceSyncRules.shouldRun(isAvailable: available, hasKey: key, isRunning: running,
                                      isBackground: background, lastRun: t0, now: t0, force: true)
        }
        #expect(run())
        #expect(!run(available: false))
        #expect(!run(key: false))
        #expect(!run(running: true))
        #expect(!run(background: true))
        // Unforced, each of those also stops a pass whose throttle has passed.
        let later = t0.addingTimeInterval(600)
        #expect(!DeviceSyncRules.shouldRun(isAvailable: true, hasKey: false, isRunning: false,
                                           isBackground: false, lastRun: nil, now: later))
        #expect(!DeviceSyncRules.shouldRun(isAvailable: true, hasKey: true, isRunning: true,
                                           isBackground: false, lastRun: nil, now: later))
        #expect(!DeviceSyncRules.shouldRun(isAvailable: true, hasKey: true, isRunning: false,
                                           isBackground: true, lastRun: nil, now: later))
    }

    @Test("sync is offered only to a real, finished Penn install with a backend")
    func availability() {
        func available(fixture: Bool = false, penn: Bool = true, backend: Bool = true, onboarding: Bool = false) -> Bool {
            DeviceSyncRules.isAvailable(isFixtureData: fixture, isPenn: penn,
                                        hasBackend: backend, needsOnboarding: onboarding)
        }
        #expect(available())
        #expect(!available(fixture: true))
        #expect(!available(penn: false))
        #expect(!available(backend: false))
        #expect(!available(onboarding: true))
    }

    @Test("a pass is called from the foreground refresh and the launch task, never from the background wake")
    func passCallSites() throws {
        let content = try uiSource("ContentView.swift")
        guard !content.isEmpty else { return }
        let refresh = try #require(content.range(of: "private func refresh() async {"))
        let refreshBody = String(content[refresh.lowerBound...].prefix(2_500))
        let pass = try #require(refreshBody.range(of: "await state.deviceSyncPass()"))
        let reload = try #require(refreshBody.range(of: "vm.reload(preservingEdits: true)"))
        let grades = try #require(refreshBody.range(of: "refreshCanvasGrades(state: state)"))
        #expect(grades.lowerBound < pass.lowerBound && pass.lowerBound < reload.lowerBound)

        let root = try uiSource("RootView.swift")
        let background = try uiSource("BackgroundRefresh.swift")
        let syncSource = try uiSource("AppState+DeviceSync.swift")
        #expect(root.contains("await state.deviceSyncPass()"))
        #expect(!background.contains("deviceSyncPass"))
        // And the pass refuses a background AppState on its own.
        #expect(syncSource.contains("isBackground: renewalContext == .background"))
    }

    // MARK: Copy and Profile

    @Test("the pairing sheet and the laptop row use the agreed words, lowercase, with no raw error")
    func copy() {
        #expect(PairLaptopCopy.heading == "pair this laptop?")
        #expect(PairLaptopCopy.pair == "pair")
        #expect(PairLaptopCopy.notNow == "not now")
        #expect(PairLaptopCopy.failure == "couldn't pair")
        #expect(PairLaptopCopy.rowLabel == "laptop")
        #expect(PairLaptopCopy.unpair == "unpair")
        for text in [PairLaptopCopy.heading, PairLaptopCopy.pair, PairLaptopCopy.notNow,
                     PairLaptopCopy.failure, PairLaptopCopy.rowLabel, PairLaptopCopy.unpair,
                     PairLaptopCopy.unpairTitle, PairLaptopCopy.unpairMessage,
                     PairLaptopCopy.unpairFailure, PairLaptopCopy.cancel] {
            #expect(text == text.lowercased(), "\"\(text)\" is not lowercase")
        }
    }

    @Test("the sheet prints only its fixed words and never an error's text")
    func sheetPrintsNoRawErrors() throws {
        let source = try uiSource("PairLaptopSheet.swift")
        guard !source.isEmpty else { return }
        #expect(source.contains("title: PairLaptopCopy.heading"))
        #expect(source.contains("Text(PairLaptopCopy.failure)"))
        #expect(!source.contains("localizedDescription"))
        #expect(!source.contains("catch"))
        #expect(source.contains("await state.pairLaptop(link)"))
        #expect(source.contains("if paired { dismiss() }"))
    }

    @Test("Profile → accounts has a laptop row behind a system confirmation, only while paired, after the sign-in rows")
    func profileRow() throws {
        let page = try uiSource("SettingsPage.swift")
        guard !page.isEmpty else { return }
        let bodyStart = try #require(page.range(of: "var body: some View"))
        let bodyEnd = try #require(page.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<page.endIndex))
        let body = String(page[bodyStart.lowerBound..<bodyEnd.upperBound])
        let accounts = try #require(body.range(of: "SmoothSectionHeader(\"accounts\""))
        let stay = try #require(body.range(of: "stayLoggedInRows"))
        let laptop = try #require(body.range(of: "ProfileLaptopRow()"))
        let appearance = try #require(body.range(of: "SmoothSectionHeader(\"appearance\""))
        #expect(accounts.lowerBound < stay.lowerBound)
        #expect(stay.lowerBound < laptop.lowerBound && laptop.lowerBound < appearance.lowerBound)

        let row = try uiSource("PairLaptopSheet.swift")
        let rowStart = try #require(row.range(of: "struct ProfileLaptopRow"))
        let rowSource = String(row[rowStart.lowerBound...])
        #expect(rowSource.contains("if state.hasPairedLaptop {"))
        #expect(rowSource.contains(".alert(PairLaptopCopy.unpairTitle, isPresented: $confirming)"))
        #expect(rowSource.contains("Button(PairLaptopCopy.unpair, role: .destructive)"))
        #expect(rowSource.contains("Text(PairLaptopCopy.unpairFailure)"))
    }

    @Test("disconnecting Canvas forgets the key and the change times on the phone")
    func disconnectForgets() throws {
        let page = try uiSource("SettingsPage.swift")
        guard !page.isEmpty else { return }
        let disconnect = try #require(page.range(of: "state.disconnectCanvas()\n"))
        let forget = try #require(page.range(of: "state.forgetPairedLaptopLocally()"))
        let delete = try #require(page.range(of: "deleteServerData()\n", range: disconnect.upperBound..<page.endIndex))
        #expect(disconnect.upperBound <= forget.lowerBound && forget.upperBound <= delete.lowerBound)

        let sync = try uiSource("AppState+DeviceSync.swift")
        let body = try #require(sync.range(of: "func forgetPairedLaptopLocally() {"))
        let forgetBody = String(sync[body.lowerBound...].prefix(400))
        #expect(forgetBody.contains("SyncKeyStore.delete()"))
        #expect(forgetBody.contains("syncChangeLog?.clear()"))
    }

    // MARK: Helpers

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()    // .../LowHangingFruitKit
    }

    private func repoRoot() -> URL { packageRoot().deletingLastPathComponent() }

    /// A file that cannot be found is a failure, not a pass.
    private func read(_ url: URL) throws -> String {
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Empty when the sources are not beside the test bundle (a prebuilt bundle
    /// run elsewhere), like the other source-scanning suites.
    private func uiSource(_ filename: String) throws -> String {
        let file = packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
