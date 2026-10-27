import SwiftUI

/// The shared root content: onboarding/intro or the dashboard, depending on
/// `state`. Extracted out of `RootView` so `LHFScenes` (the
/// macOS-aware `@main` entry, see `LHFScenes.swift`) can hand it an
/// `AppState`/`NotificationScheduler` pair that lives at the *Scene* level —
/// above any individual `WindowGroup` — rather than one scoped to a single
/// window. That's what lets the menu-bar extra and the main window share one
/// `AppState` instead of each spinning up its own.
///
/// `state`/`scheduler` are `@ObservedObject` here (not owned) precisely so
/// this view has no opinion about who creates them or how long they live —
/// see `OwnedRootView` below and `LHFScenes` for the two current owners.
struct RootCore: View {
    @ObservedObject var state: AppState
    @ObservedObject var scheduler: NotificationScheduler

    /// Owns the forced-update version gate end to end: the synchronous
    /// cached-policy check at construction, the fetch-and-recompute in
    /// `refresh()`, and the per-version banner-dismissal state. See
    /// `UpdateGate.swift` for the fail-open contract this store guarantees.
    @StateObject private var updateGate = UpdateGateStore()

    @Environment(\.scenePhase) private var scenePhase

    /// The `smooth://pair` link the phone was opened with, while the sheet that
    /// asks "pair this laptop?" is up (`AppState+DeviceSync.swift`).
    @State private var pendingPairing: PendingPairing?

    var body: some View {
        ZStack {
            mainContent
                // Nested inside `mainContent`'s own layer rather than a
                // sibling `ZStack` child: `.overlay` respects the safe area
                // by default (nothing here calls `.ignoresSafeArea()`), so
                // this floats above the dashboard/onboarding content without
                // sitting under the status bar or a notch, and it stays
                // beneath the wall and the splash below simply because it's
                // painted as part of the first child, not a later one.
                .overlay(alignment: .top) {
                    if case .updateAvailable(let latest) = updateGate.verdict,
                       !updateGate.isAvailableBannerDismissed {
                        UpdateAvailableBanner(latest: latest) {
                            updateGate.dismissAvailableBanner()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                // The Berserk takeover (`BerserkTakeoverHost`) covers the
                // whole window while an alarm rings or a loud buzz has just
                // landed. It is applied after the banner so it is above it,
                // and it is still part of this first child, so the update
                // wall and the splash, which come later in the ZStack, stay
                // above it.
                .berserkTakeoverHost(state: state, scheduler: scheduler)

            // Above the app, below the splash: a build under the enforced
            // floor should do nothing at all — including onboarding, which
            // is why this sits above `mainContent` rather than only inside
            // the dashboard branch of it — but the splash still gets to play
            // first (`.zIndex(1)` below), so the wall is what the student is
            // left looking at once it finishes, not what flashes underneath it.
            if case .updateRequired(let minimum, let message) = updateGate.verdict {
                UpdateRequiredView(
                    minimum: minimum,
                    message: message,
                    appStoreURL: updateGate.appStoreURL
                )
                .transition(.opacity)
            }

        }
        .task {
            await updateGate.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await updateGate.refresh() }
            }
        }
        // Applied at the root so both the dashboard and the splash (which
        // lives in this same ZStack, ahead of onboarding/dashboard) pick up
        // the user's Light/Dark choice. Sheets are a separate presentation
        // context that doesn't inherit this automatically — see
        // `SheetTheme.swift`, which re-applies it there.
        .preferredColorScheme(state.appearanceMode.colorScheme)
        // The Chrome extension's pairing QR opens `smooth://pair?c=...#k=...`.
        // Anything that is not a well-formed link, and any install that cannot
        // pair (not Penn, no backend, preview, mid-onboarding), is ignored
        // silently: the scheme is a custom one, so any app or web page can
        // hand this one a URL.
        .onOpenURL { url in
            if let pending = state.pendingPairing(from: url) { pendingPairing = pending }
        }
        .sheet(item: $pendingPairing) { pending in
            PairLaptopSheet(link: pending.link).environmentObject(state)
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
#endif
    }

    @ViewBuilder
    private var mainContent: some View {
        if state.needsOnboarding {
            // The mission panes come first on a true first run, then the
            // linear connect walk (`OnboardingView`). Nested rather than a
            // sibling `else if` on purpose: the intro is only ever reachable
            // *inside* onboarding, so a Settings reconnect (which clears
            // `hasCompletedOnboarding` but not `hasSeenIntro`) lands on the
            // walk, not the pitch.
            if state.needsIntro {
                IntroView()
                    .environmentObject(state)
                    .transition(.opacity)
            } else {
                // `.environmentObject(scheduler)` matters here, not just in
                // the dashboard branch below: the notification step reads
                // and writes this exact instance, and
                // it has to be the same one `ContentView` gets a few lines
                // down, since `NotificationScheduler`'s published properties
                // are loaded from `UserDefaults.lhf` once at construction and
                // never re-read — a second, locally-owned scheduler would let
                // onboarding's choices sit in `UserDefaults` while the
                // dashboard kept showing whatever was on disk before
                // onboarding ran.
                OnboardingView(
                    destination: state.onboardingDestination,
                    hasChosenSchool: state.hasChosenCanvasInstallation
                )
                    .environmentObject(state)
                    .environmentObject(scheduler)
                    .transition(.opacity)
            }
        } else {
            ContentView()
                .environmentObject(state)
                .environmentObject(scheduler)
                .transition(.opacity)
                .task {
                    // Canvas-only: refresh from the cookieless calendar feed.
                    // Fires once at the onboarding -> app handoff.
                    await state.syncIfConfigured()
                    // Foreground only (this view never exists in a background
                    // wake), throttled and silent; see `deviceSyncPass`.
                    await state.deviceSyncPass()
                }
        }
    }
}

/// The app's root view. The `@main` entry point lives in the Xcode app target
/// (which owns the `WindowGroup`) and simply presents `RootView()`. Keeping the
/// UI in a library lets a real, shippable app target import it.
///
/// This is now a thin compatibility wrapper: the shipping app (`App/LHFApp
/// .swift`) uses `LHFScenes` directly, whose `AppState`/`NotificationScheduler`
/// live at the Scene level so the menu-bar extra can share them with the main
/// window. `RootView` still owns its own pair via `OwnedRootView` below, so
/// previews and any other caller that only wants a single window keep
/// compiling unchanged.
public struct RootView: View {
    public init() {}

    public var body: some View {
        OwnedRootView()
    }
}

/// Owns the `AppState`/`NotificationScheduler` for a standalone `RootView()`.
/// Split out so `RootView` itself can stay a trivial, stable wrapper type.
private struct OwnedRootView: View {
    @StateObject private var state = LiveAppStateRegistry.shared.makeLive()
    @StateObject private var scheduler = NotificationScheduler()

    var body: some View {
        RootCore(state: state, scheduler: scheduler)
    }
}
