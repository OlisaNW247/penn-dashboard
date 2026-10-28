import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// One ledger store per process (hardening plan B13, DAT-04, UCR-6, SYN-11).
///
/// A background wake in a process that was only suspended used to build a
/// second `AppState`, and `AppState.init` opens the SwiftData ledger, so two
/// `ModelContainer`s sat on the same file in one process with both able to
/// write. The wake now takes the scene's own `AppState` from
/// `LiveAppStateRegistry` and opens its own only when the process has none.
///
/// Every test builds its own registry: the app's is `shared`, and a test that
/// registered into it would hand another test's wake a stranger's `AppState`.
@Suite("One ledger store per process")
struct LiveAppStateTests {

    /// An `AppState` over its own in-memory store, as the other suites make.
    @MainActor
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @Test("A wake in a warm process works on the live AppState and opens nothing of its own")
    @MainActor
    func warmWakeReusesTheLiveState() {
        let registry = LiveAppStateRegistry()
        let live = makeState()
        registry.register(live)
        var opened = 0

        let wake = registry.beginWake { opened += 1; return makeState() }
        defer { wake.end() }

        #expect(wake.state === live)
        #expect(wake.isShared)
        #expect(opened == 0, "no second AppState, so no second ModelContainer on the ledger file")
    }

    @Test("A wake with no live AppState opens exactly one of its own")
    @MainActor
    func coldWakeOpensItsOwn() {
        let registry = LiveAppStateRegistry()
        var opened = 0

        let wake = registry.beginWake { opened += 1; return makeState() }
        defer { wake.end() }

        #expect(opened == 1)
        #expect(!wake.isShared)
        #expect(registry.current == nil, "the wake's own is not registered as the live one")
    }

    @Test("The wake marks the state background for its length and puts the live app's context back")
    @MainActor
    func contextIsBackgroundThenRestored() {
        let registry = LiveAppStateRegistry()
        let live = makeState()
        registry.register(live)
        #expect(live.renewalContext == .foreground)

        let wake = registry.beginWake()
        #expect(live.renewalContext == .background, "set before beginWake returns, with no suspension in between")

        wake.end()
        #expect(live.renewalContext == .foreground,
                "left at .background the live app would refuse every foreground renewal and device sync")
    }

    @Test("A wake restores the context the state had, whatever it was")
    @MainActor
    func restoresWhatWasThere() {
        let registry = LiveAppStateRegistry()
        let live = makeState()
        live.renewalContext = .background
        registry.register(live)

        registry.beginWake().end()

        #expect(live.renewalContext == .background)
    }

    @Test("makeLive records what it builds, and a later one replaces it")
    @MainActor
    func makeLiveRegisters() {
        let registry = LiveAppStateRegistry()
        let first = registry.makeLive { makeState() }
        #expect(registry.current === first)
        let second = registry.makeLive { makeState() }
        #expect(registry.current === second)
        #expect(second !== first)
    }

    @Test("The registry does not keep an AppState alive")
    @MainActor
    func registryHoldsNothingStrongly() {
        let registry = LiveAppStateRegistry()
        registry.register(makeState())
        // The only strong reference was the argument above.
        #expect(registry.current == nil, "a registry that kept it would outlive the scene that owned it")
        var opened = 0
        let wake = registry.beginWake { opened += 1; return makeState() }
        defer { wake.end() }
        #expect(opened == 1 && !wake.isShared)
    }

    // MARK: Where the live state comes from, and what the wake builds

    /// SwiftUI is not run here, so the two owners and the wake are pinned at
    /// the source level: the scene registers the state it builds, and the wake
    /// never builds one itself.
    @Test("The scene owners register their AppState, and the wake builds none directly")
    func wiring() throws {
        for owner in ["LHFScenes.swift", "RootView.swift"] {
            let code = try HardeningSourceScan.uiCode(owner)
            #expect(code.contains("@StateObject private var state = LiveAppStateRegistry.shared.makeLive()"),
                    "\(owner) must register the AppState it owns")
            #expect(!code.contains("var state = AppState()"), "\(owner) must not build an unregistered one")
        }

        let wake = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        #expect(!wake.contains("AppState()"), "the wake must not open a ledger of its own except through beginWake")
        let run = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func run() async", in: wake)
        let order = [
            "let wake = LiveAppStateRegistry.shared.beginWake()",
            "defer { wake.end() }",
            "let state = wake.state",
            "guard !state.isUsingFixtureData else { return }",
        ]
        let found = try HardeningSourceScan.positions(of: order, in: run)
        #expect(zip(found, found.dropFirst()).allSatisfy(<))
        #expect(!run.contains("renewalContext"), "the context is the registry's to set and restore")
    }
}
