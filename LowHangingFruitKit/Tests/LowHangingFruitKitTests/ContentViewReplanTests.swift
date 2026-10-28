import Foundation
import Testing

/// SwiftUI is not run by the package test runner, so these pin, at the source
/// level, the order `ContentView` has to keep: the reminders and alarms are
/// re-planned from the ledger before the network, and again after it
/// (hardening plan C7, NOT-12, SYN-08).
///
/// The plan used to be rebuilt only at the end of a pass, behind the feed
/// fetch, the Canvas chain and, at a cold launch, a silent renewal that can
/// wait out thirty seconds. On a slow or dead network the alarms were as old
/// as the last pass that got through. The wrong fix is to move the replan from
/// the end of the pass to the start: the fetch's news still has to reach the
/// plan. `LaunchRefreshStructureTests` pins the rest of the launch contract.
@Suite("ContentView replans before the network")
struct ContentViewReplanTests {

    private static let call = "await replanFromLedger()"

    @Test("the replan reloads from the ledger, waits for the dashboard to be bound, honours the reminders switch, and touches no network")
    func replanBody() throws {
        let code = try HardeningSourceScan.uiCode("ContentView.swift")
        let body = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func replanFromLedger() async", in: code)

        // An unbound view model holds no items, and a plan from an empty list
        // takes every pending reminder and alarm back.
        let order = [
            "guard isDashboardBound else { return }",
            "vm.reload(preservingEdits: true)",
            "if scheduler.isEnabled { await scheduler.reschedule(from: vm.items) }",
        ]
        let found = try HardeningSourceScan.positions(of: order, in: body)
        #expect(zip(found, found.dropFirst()).allSatisfy(<))

        for network in ["syncIfConfigured", "fetchSessionSources", "AutoSyncCoordinator",
                        "deviceSyncPass", "awaitPendingSilentRenewal", "URLSession"] {
            #expect(!body.contains(network), "\(network) is network or waits on it; the replan must not")
        }
    }

    @Test("at launch the replan is the first thing the pass does, before the renewal wait and every fetch, and the replan after the fetch stays")
    func launchOrder() throws {
        let code = try HardeningSourceScan.uiCode("ContentView.swift")
        let launch = try HardeningSourceScan.body(
            ofFunctionDeclaredWith: "func refreshSessionSourcesAtLaunch() async", in: code)
        let order = [
            Self.call,
            "await state.awaitPendingSilentRenewal()",
            "await fetchSessionSources()",
            "await settleAfterFetch()",
        ]
        let found = try HardeningSourceScan.positions(of: order, in: launch)
        #expect(zip(found, found.dropFirst()).allSatisfy(<))

        let settle = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func settleAfterFetch() async", in: code)
        #expect(settle.contains("scheduler.reschedule(from: vm.items)"), "the fetch's news still reaches the plan")
        #expect(!settle.contains("replanFromLedger"))
    }

    @Test("on returning to the foreground the replan runs before the refresh that starts with the network")
    func foregroundOrder() throws {
        let code = try HardeningSourceScan.uiCode("ContentView.swift")
        let start = try #require(code.range(of: ".onChange(of: scenePhase)"))
        let end = try #require(code.range(of: ".onChange(of: state.isReconnecting)", range: start.upperBound..<code.endIndex))
        let block = String(code[start.lowerBound..<end.lowerBound])

        let order = ["await scheduler.refreshAuthStatus()", Self.call, "await refresh()"]
        let found = try HardeningSourceScan.positions(of: order, in: block)
        #expect(zip(found, found.dropFirst()).allSatisfy(<))
    }

    @Test("the five-minute refresh() does not replan twice: it plans after its own fetch")
    func periodicRefreshStaysAsItWas() throws {
        let code = try HardeningSourceScan.uiCode("ContentView.swift")
        let refresh = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func refresh() async", in: code)
        #expect(!refresh.contains("replanFromLedger"))
        #expect(refresh.contains("await settleAfterFetch()"))
    }
}
