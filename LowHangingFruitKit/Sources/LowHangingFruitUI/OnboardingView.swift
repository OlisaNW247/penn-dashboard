import SwiftUI
import WebKit
import LowHangingFruitKit
import os

/// First-run welcome flow. Blocks the dashboard until both core data sources are
/// connected. The Canvas calendar feed URL is captured automatically from the
/// logged-in session — the user never pastes it.
///
/// Styled to match the LHF redesign (greige surface, white cards, serif
/// wordmark). Logins are presented inline (the view swaps to the WebView).
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var phase: Phase = .steps
    @State private var name: String = ""
    @State private var isResettingLoginData = false
    @State private var showResetConfirmation = false
    @State private var didResetLoginData = false
    /// "Paste your Canvas calendar link" fallback (docs/CANVAS_LOGIN_HARDENING.md
    /// item 3b) — reachable without ever touching the in-app login WebView.
    @State private var showPasteFeedLink = false

    private enum Phase {
        case steps
        case canvasLogin
        case gradescopeLogin
        case classPicker
    }

    var body: some View {
        switch phase {
        case .steps:
            stepList
        case .canvasLogin:
            CanvasLoginPane(
                onConnected: { phase = .steps },
                onCancel: { phase = .steps }
            )
            .environmentObject(state)
        case .gradescopeLogin:
            GradescopeLoginPane(
                onConnected: { phase = .steps },
                onCancel: { phase = .steps }
            )
            .environmentObject(state)
        case .classPicker:
            ClassPickerPane(onDone: { phase = .steps })
                .environmentObject(state)
        }
    }

    /// Canvas is the only required connection; Gradescope and the class picker
    /// are optional refinements.
    private var canContinue: Bool {
        state.isCanvasConnected
    }

    private var stepList: some View {
        ZStack {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                header
                    .padding(.bottom, 28)

                VStack(spacing: 12) {
                    nameCard

                    stepCard(
                        index: 1,
                        title: "Connect Canvas",
                        subtitle: "Log in once. We'll pull in your assignments and deadlines automatically.",
                        connected: state.isCanvasConnected,
                        working: state.isCanvasDiscoveryLoading || state.isLoading
                    ) { phase = .canvasLogin }

                    stepCard(
                        index: 2,
                        title: "Connect Gradescope",
                        subtitle: "Optional. Log in once to fold your Gradescope assignments in too.",
                        connected: state.isGradescopeConnected,
                        working: state.isGradescopeLoading
                    ) { phase = .gradescopeLogin }

                    classPickerCard
                }

                if let error = state.error {
                    Text(error)
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.v2SpineRed)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }

                goToDashboardButton
                    .padding(.top, 20)

                Text("Connect Canvas to build your dashboard.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                // "Preview with sample data" used to sit here, as the smallest
                // text on the busiest screen. It now leads the intro's first
                // pane (`IntroView.previewLink`), where it's a card of its own
                // and arrives *before* the Canvas login ask rather than under it.

                troubleConnectingLink
                    .padding(.top, 10)

                pasteFeedLinkLink
                    .padding(.top, 6)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
        }
        .onAppear { name = state.userName }
        .sheet(isPresented: $showPasteFeedLink) {
            PasteFeedLinkSheet(onSaved: {}).environmentObject(state)
        }
    }

    /// Fallback path for anyone stuck on the in-app login (docs/CANVAS_LOGIN_HARDENING.md
    /// item 3b) — connects the dashboard without touching the WKWebView login
    /// at all. Kept as a plain-language, low-emphasis link (not a button next
    /// to "Connect Canvas") since the login flow is still the primary,
    /// richer path — this is explicitly the fallback.
    private var pasteFeedLinkLink: some View {
        Button {
            showPasteFeedLink = true
        } label: {
            Text("Or paste your Canvas calendar link instead")
                .font(.lhfSans(11, weight: .medium))
                .foregroundStyle(Color.v2DateText)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Paste your Canvas calendar link instead of logging in")
    }

    /// Escape hatch for a stuck login (docs/CANVAS_LOGIN_DIAGNOSIS.md): clears
    /// every stored trace of a Canvas/Gradescope login attempt from this
    /// device — the live WebView cookie/cache jar, the Keychain-persisted
    /// cookie copy, and the connected-service flags — so a user who's stuck
    /// (e.g. Canvas SSO's "Stale Request" screen) always has a way to force a
    /// genuinely clean slate without needing to delete and reinstall the app,
    /// which doesn't fully clear this state anyway (see
    /// `AppState.resetAllLoginData`'s doc comment) and isn't reachable from
    /// this screen in the first place.
    private var troubleConnectingLink: some View {
        VStack(spacing: 4) {
            Button {
                showResetConfirmation = true
            } label: {
                if isResettingLoginData {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Trouble connecting? Reset login data")
                        .font(.lhfSans(11, weight: .medium))
                        .foregroundStyle(Color.v2SpineRed)
                        .underline()
                }
            }
            .buttonStyle(.plain)
            .disabled(isResettingLoginData)
            .accessibilityLabel("Reset stored Canvas and Gradescope login data")
            .confirmationDialog(
                "Reset login data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset and start over", role: .destructive) {
                    didResetLoginData = false
                    isResettingLoginData = true
                    Task {
                        await state.resetAllLoginData()
                        isResettingLoginData = false
                        didResetLoginData = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears any stuck Canvas or Gradescope login on this device, including saved session cookies, so you can start fresh. You'll need to log in again.")
            }

            if didResetLoginData {
                Text("Login data cleared. Try Connect Canvas again.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2SpineGreen)
            }
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR NAME")
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)
            TextField("First name", text: $name)
                .textFieldStyle(.plain)
                .font(.lhfSans(15))
                .foregroundStyle(Color.v2Ink)
                .onChange(of: name) { _, newValue in state.updateName(newValue) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("LHF")
                .font(.lhfSerif(44))
                .foregroundStyle(Color.v2Ink)
            Text("Welcome to Low Hanging Fruit")
                .font(.lhfSans(16, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
            Text("Never miss another assignment")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var goToDashboardButton: some View {
        Button {
            state.completeOnboarding()
        } label: {
            Text("Go to dashboard")
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(canContinue ? Color.v2ToggleActiveTx : Color.v2DateText.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(canContinue ? Color.v2Ink : Color.v2Ink.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canContinue)
        .accessibilityLabel("Go to dashboard")
        .accessibilityHint(canContinue ? "" : "Connect Canvas first")
    }

    private func stepCard(
        index: Int,
        title: String,
        subtitle: String,
        connected: Bool,
        working: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack {
                Circle()
                    .fill(connected ? Color.v2SpineGreen : Color.v2Ink.opacity(0.08))
                    .frame(width: 28, height: 28)
                if connected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.v2DateText)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text(subtitle)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2CourseCode)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if working {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) {
                    Text(connected ? "Reconnect" : "Connect")
                        .font(.lhfSans(12, weight: .semibold))
                        .foregroundStyle(connected ? Color.v2DateText : Color.v2ToggleActiveTx)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(connected ? Color.v2Ink.opacity(0.07) : Color.v2Ink)
                        )
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(16)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }

    /// Optional third step: pick which classes count. Enabled once Canvas is
    /// connected so there are courses to list; everything is on by default.
    private var classPickerCard: some View {
        let courses = state.allCourseCodes()
        let enabled = !courses.isEmpty
        let onCount = courses.filter { state.isCourseSelected($0) }.count

        return Button {
            if enabled { phase = .classPicker }
        } label: {
            HStack(alignment: .center, spacing: 13) {
                ZStack {
                    Circle().fill(Color.v2Ink.opacity(0.08)).frame(width: 28, height: 28)
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.v2DateText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose your classes")
                        .font(.lhfSans(15, weight: .semibold))
                        .foregroundStyle(enabled ? Color.v2Ink : Color.v2Ink.opacity(0.4))
                    Text(enabled
                         ? "All on by default. Turn off any you don't want reminders from."
                         : "Connect Canvas first to see your classes.")
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.v2CourseCode)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                if enabled {
                    Text("\(onCount)/\(courses.count) on")
                        .font(.lhfSans(12, weight: .semibold))
                        .foregroundStyle(Color.v2DateText)
                }
            }
            .padding(16)
            .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Login chrome (shared)

/// The bottom action bar under the login WebView. Stacks the hint above the
/// buttons so it never crowds on a narrow phone screen.
///
/// Carries explicit "Reload" and "Start over" controls (docs/CANVAS_LOGIN_DIAGNOSIS.md
/// item 1a): the login WebView disables swipe back/forward navigation, since
/// swiping back onto an already-consumed login form and resubmitting it is
/// exactly what produces Shibboleth's "Stale Request" — with no chrome and no
/// way forward. These two buttons are the replacement escape hatch: Reload
/// re-requests the current page; Start over purges this login's cookies/cache
/// again and reloads the login page from scratch, without leaving the pane.
private struct LoginActionBar: View {
    let message: String?
    let defaultHint: String
    let connectTitle: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onConnect: () -> Void
    let onReload: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message ?? defaultHint)
                .font(.lhfSans(12))
                .foregroundStyle(message == nil ? Color.v2DateText : Color.v2SpineRed)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button("Reload", action: onReload)
                    .buttonStyle(.plain)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .disabled(isBusy)
                    .accessibilityHint("Reloads the current login page")

                Button("Start over", action: onStartOver)
                    .buttonStyle(.plain)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .disabled(isBusy)
                    .accessibilityHint("Clears this login's cookies and loads a fresh sign-in page")
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.lhfSans(13, weight: .medium))
                    .foregroundStyle(Color.v2DateText)

                Spacer()

                Button(action: onConnect) {
                    Group {
                        if isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(connectTitle)
                                .font(.lhfSans(13, weight: .semibold))
                                .foregroundStyle(Color.v2ToggleActiveTx)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.v2Ink))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(Color.v2Bg)
    }
}

/// Plain-language card shown in place of the WebView when
/// `LoginNavigationObserver` detects a known IdP/Shibboleth error page
/// (docs/CANVAS_LOGIN_DIAGNOSIS.md item 3a). User-initiated recovery only —
/// this never appears as a result of automatic retry logic, and tapping a
/// button here is the only way it goes away.
/// Full-pane notice shown before the Canvas sign-in page loads (see
/// `CanvasLoginPane.showsSignInTips` for why it exists). Same visual family
/// as `LoginErrorCard`, but it fills the pane rather than banner-ing above a
/// WebView — there's nothing behind it yet worth showing.
private struct CanvasSignInTipsCard: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hourglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.v2Ink)
            Text("One thing before you sign in")
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
            Text("Penn\u{2019}s sign-in can pause for up to half a minute after you enter your password. That\u{2019}s normal \u{2014} the screen isn\u{2019}t stuck. Press the sign-in button once and wait; pressing it again is what causes Penn\u{2019}s \u{201C}Stale Request\u{201D} error.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button(action: onContinue) {
                Text("Got it")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoginErrorCard: View {
    let title: String
    let message: String
    let onStartOver: () -> Void
    /// Canvas only — Gradescope has no equivalent feed-link fallback.
    let onUseCalendarLinkInstead: (() -> Void)?
    /// Canvas only, for now — offered when someone's hit the error card
    /// repeatedly and just wants to hand off diagnostics rather than keep
    /// retrying. `nil` hides the action entirely.
    var onReportProblem: (() -> Void)? = nil

    var body: some View {
        // No Spacers and no maxHeight cap here or at the call sites: the
        // card must hug its content. A fixed-height cap already clipped the
        // last action ("Report a problem") clean off the screen once — an
        // invisible action is worse than a taller card.
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.v2SpineRed)
            Text(title)
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button(action: onStartOver) {
                Text("Start over")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)

            if let onUseCalendarLinkInstead {
                Button(action: onUseCalendarLinkInstead) {
                    Text("Use calendar link instead")
                        .font(.lhfSans(12, weight: .medium))
                        .foregroundStyle(Color.v2DateText)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            if let onReportProblem {
                Button(action: onReportProblem) {
                    Text("Report a problem")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DateText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Canvas login pane

/// Canvas login WebView whose "Connect" action captures the ICS feed URL,
/// syncs Canvas, and scans for requirements in one step.
private struct CanvasLoginPane: View {
    @EnvironmentObject private var state: AppState
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var isReadingCookies = false
    @State private var message: String?
    /// True while the pre-login purge (docs/CANVAS_LOGIN_DIAGNOSIS.md item 1c)
    /// is running. The WebView isn't created until this clears, so the purge
    /// always finishes before the first request goes out — never mid-navigation.
    @State private var isPurging = true
    /// Bumping this re-runs the purge-and-load `.task` below ("Start over").
    @State private var purgeGeneration = UUID()
    /// True only for this pane appearance's FIRST attempt. Measured on
    /// device (2026-08-22): during a Penn IdP bad spell the app went 0/8
    /// while Private Safari went 3/4 in the same minutes — Safari fails its
    /// first genuinely-cold handshake too, but recovers on retry because
    /// the failed attempt's IdP cookies survive into the next one. Purging
    /// on every "Start over" forced this app to be permanently
    /// first-contact. So: purge once per pane appearance (a fresh Connect
    /// still starts clean), and let retries keep the cookies exactly like
    /// Safari's retry does.
    @State private var purgeOnNextAttempt = true
    /// Bumping this tells the live WebView to call `.reload()` ("Reload").
    @State private var reloadTick = 0
    /// Observe-only navigation delegate (docs/CANVAS_LOGIN_DIAGNOSIS.md item
    /// 3a) — surfaces load errors and known IdP error pages; never steers
    /// navigation itself.
    @StateObject private var navObserver = LoginNavigationObserver()
    @State private var showPasteFeedLink = false
    /// Shown once per pane appearance, BEFORE the sign-in page: Penn's IdP
    /// can pause noticeably after the password is submitted, and an
    /// impatient second tap is what mints its "Stale Request" error (the
    /// duplicate-POST guard in `LoginNavigationObserver` catches the
    /// machine-made repeats; this card heads off the human-made one). The
    /// purge keeps running behind this card, so dismissing it is usually
    /// instant.
    @State private var showsSignInTips = true

    private var isBusy: Bool {
        isReadingCookies || state.isCanvasDiscoveryLoading || state.isLoading || isPurging
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsSignInTips {
                CanvasSignInTipsCard(onContinue: { showsSignInTips = false })
            } else if isPurging {
                Spacer()
                ProgressView("Preparing a clean sign-in…")
                    .font(.lhfSans(12))
                Spacer()
            } else {
                // The WebView stays mounted even when a known error page has
                // been detected — a single detection (or a stale one from an
                // intermediate SSO hop) must never be the thing that makes
                // login impossible. The card becomes a non-blocking banner
                // above the still-live WebView instead of replacing it.
                VStack(spacing: 0) {
                    if navObserver.detectedKnownErrorPage {
                        LoginErrorCard(
                            title: "Canvas login hit a snag",
                            message: "Penn's sign-in page reported an error partway through, but login may still work — it's worth continuing below. If it doesn't, Start over or the calendar link are still available.",
                            onStartOver: startOver,
                            onUseCalendarLinkInstead: { showPasteFeedLink = true },
                            onReportProblem: {
                                SupportContact.openReportMail(diagnostics: DiagnosticsReport.generate(state: state))
                            }
                        )

                        Divider().overlay(Color.v2Divider)
                    }

                    LoginWebView(
                        url: URL(string: "https://canvas.upenn.edu")!,
                        store: LoginDataStores.canvas,
                        reloadTick: reloadTick,
                        navigationObserver: navObserver
                    )
                }
            }

            Divider().overlay(Color.v2Divider)

            LoginActionBar(
                message: message ?? navObserver.loadError,
                defaultHint: "Log in to Canvas once. We'll capture your calendar feed automatically.",
                connectTitle: "Connect Canvas",
                isBusy: isBusy,
                onCancel: onCancel,
                onConnect: connect,
                onReload: { reloadTick += 1 },
                onStartOver: startOver
            )
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .sheet(isPresented: $showPasteFeedLink) {
            PasteFeedLinkSheet(onSaved: onConnected).environmentObject(state)
        }
        .task(id: purgeGeneration) {
            // Fires exactly once per Connect tap (this view's own appearance,
            // or a "Start over" tap), before the WebView is ever created —
            // never re-entrant with an in-flight login navigation. Targets
            // Canvas's own isolated store (docs/CANVAS_LOGIN_DIAGNOSIS.md
            // item 2a), not the shared `.default()` store. Purges only on
            // the first attempt of this pane appearance — see
            // `purgeOnNextAttempt` for the on-device evidence.
            if purgeOnNextAttempt {
                await WebsiteDataReset.purgeWebsiteData(
                    matchingDomainContains: AppState.canvasLoginDomainHints,
                    in: LoginDataStores.canvas
                )
                purgeOnNextAttempt = false
            }
            isPurging = false
        }
        // Session-longevity Layer 2 guard (`CanvasSessionRenewer`): this pane
        // reads from and writes into `LoginDataStores.canvas` the same live,
        // persistent store the background silent-renewal attempt would use,
        // so it must never run while this pane is on screen. Set true as
        // soon as the pane appears (before the purge/WebView above even
        // starts) and cleared on disappear — there's no separate teardown
        // path for this pane beyond SwiftUI removing it from the tree
        // (`OnboardingView`'s `phase` switch), which `onDisappear` covers.
        .onAppear { state.isCanvasLoginPaneActive = true }
        .onDisappear { state.isCanvasLoginPaneActive = false }
#if os(macOS)
        .frame(minWidth: 860, minHeight: 620)
#endif
    }

    /// Tears down the WebView and loads a fresh sign-in page from the top of
    /// the chain, without leaving the pane — the recovery path now that the
    /// WebView no longer allows a back-swipe onto a consumed login form.
    /// Deliberately does NOT purge cookies anymore (`purgeOnNextAttempt`
    /// stays false): a retry that keeps the failed attempt's IdP cookies is
    /// exactly how Safari recovers from the same "Stale Request" page.
    private func startOver() {
        message = nil
        navObserver.reset()
        isPurging = true
        purgeGeneration = UUID()
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        // Must read from the SAME store instance the WebView above was
        // configured with (`LoginDataStores.canvas`), not `.default()` — see
        // that type's doc comment. Reading the wrong store returns an empty
        // cookie list and every login reports "No session was found yet".
        LoginDataStores.canvas.httpCookieStore.getAllCookies { cookies in
            // Read once to discover the calendar-feed URL, but also persisted
            // (Keychain, same treatment as Gradescope's) so Grade Watcher's
            // cookie-authed refresh survives relaunches — `WKWebsiteDataStore`
            // drops session cookies like Canvas's/Penn SSO's between launches.
            let canvasCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("canvas.upenn.edu") }
            SessionCookieStore.save(canvasCookies, service: .canvas)
            Task { @MainActor in
                isReadingCookies = false
                let connected = await state.connectCanvas(cookies: canvasCookies)
                if connected {
                    // A connect that actually succeeded is proof the session
                    // is alive — clear any earlier "confirmed dead" sticky
                    // record (AppState.canvasSessionConfirmedDead) so it
                    // can't leave a stale reconnect banner up over a session
                    // the user just re-established by hand. Deliberately
                    // INSIDE the success branch: this button can be tapped
                    // mid-Duo with no cookies captured yet (the retry
                    // message below exists for exactly that), and clearing a
                    // server-side-proven dead record on a failed connect
                    // would reopen the silent no-banner state the sticky
                    // flag exists to close.
                    state.noteCanvasLoginSessionCaptured()
                    onConnected()
                } else {
                    message = state.error ?? "Couldn't connect Canvas yet. Finish logging in, then try again."
                }
            }
        }
    }
}

// MARK: - Gradescope login pane

/// Gradescope login WebView. Unlike Canvas (a cookieless feed), Gradescope has
/// no public feed, so we persist the login cookies and replay them each sync.
private struct GradescopeLoginPane: View {
    @EnvironmentObject private var state: AppState
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var isReadingCookies = false
    @State private var message: String?
    /// See `CanvasLoginPane`'s matching properties for why these exist —
    /// same pre-login purge / reload / start-over treatment, item-for-item.
    @State private var isPurging = true
    @State private var purgeGeneration = UUID()
    @State private var reloadTick = 0
    @StateObject private var navObserver = LoginNavigationObserver()

    private var isBusy: Bool { isReadingCookies || state.isGradescopeLoading || isPurging }

    private static let gradescopeLoginDomainHints = ["gradescope"]

    var body: some View {
        VStack(spacing: 0) {
            if isPurging {
                Spacer()
                ProgressView("Preparing a clean sign-in…")
                    .font(.lhfSans(12))
                Spacer()
            } else {
                // The WebView stays mounted even when a known error page has
                // been detected — a single detection (or a stale one from an
                // intermediate SSO hop) must never be the thing that makes
                // login impossible. The card becomes a non-blocking banner
                // above the still-live WebView instead of replacing it.
                VStack(spacing: 0) {
                    if navObserver.detectedKnownErrorPage {
                        LoginErrorCard(
                            title: "Gradescope login hit a snag",
                            message: "The sign-in page reported an error partway through, but login may still work — it's worth continuing below. If it doesn't, Start over is still available.",
                            onStartOver: startOver,
                            onUseCalendarLinkInstead: nil
                        )

                        Divider().overlay(Color.v2Divider)
                    }

                    LoginWebView(
                        url: URL(string: "https://www.gradescope.com/login")!,
                        store: LoginDataStores.gradescope,
                        reloadTick: reloadTick,
                        navigationObserver: navObserver
                    )
                }
            }

            Divider().overlay(Color.v2Divider)

            LoginActionBar(
                message: message ?? navObserver.loadError,
                defaultHint: "Log in to Gradescope once. We'll keep it in sync while your session is valid.",
                connectTitle: "Connect Gradescope",
                isBusy: isBusy,
                onCancel: onCancel,
                onConnect: connect,
                onReload: { reloadTick += 1 },
                onStartOver: startOver
            )
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .task(id: purgeGeneration) {
            await WebsiteDataReset.purgeWebsiteData(
                matchingDomainContains: Self.gradescopeLoginDomainHints,
                in: LoginDataStores.gradescope
            )
            isPurging = false
        }
#if os(macOS)
        .frame(minWidth: 860, minHeight: 620)
#endif
    }

    private func startOver() {
        message = nil
        navObserver.reset()
        isPurging = true
        purgeGeneration = UUID()
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        // Same store the WebView above uses — see `LoginDataStores`' doc comment.
        LoginDataStores.gradescope.httpCookieStore.getAllCookies { cookies in
            let gradescopeCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("gradescope") }
            SessionCookieStore.save(gradescopeCookies, service: .gradescope)
            Task { @MainActor in
                isReadingCookies = false
                guard !gradescopeCookies.isEmpty else {
                    message = "No Gradescope session was found yet. Finish logging in, then try again."
                    return
                }
                await state.syncGradescope(cookies: gradescopeCookies)
                if state.isGradescopeConnected {
                    onConnected()
                } else {
                    message = state.error ?? "Couldn't connect Gradescope yet. Finish logging in, then try again."
                }
            }
        }
    }
}

// MARK: - Class picker pane

/// Lets the user turn classes off. Everything is on by default; turning a class
/// off removes it from the dashboard and its reminders. Also reachable later
/// from Settings.
private struct ClassPickerPane: View {
    @EnvironmentObject private var state: AppState
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Your classes")
                    .font(.lhfSerif(26))
                    .foregroundStyle(Color.v2Ink)
                Text("Turn off any class you don't want on your dashboard or in reminders.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(state.allCourseCodes(), id: \.self) { course in
                        courseRow(course)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Divider().overlay(Color.v2Divider)

            Button(action: onDone) {
                Text("Done")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(Color.v2Bg.ignoresSafeArea())
#if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
#endif
    }

    private func courseRow(_ course: String) -> some View {
        let isOn = Binding(
            get: { state.isCourseSelected(course) },
            set: { state.setCourse(course, selected: $0) }
        )
        return Toggle(isOn: isOn) {
            Text(course)
                .font(.lhfSans(14, weight: .medium))
                .foregroundStyle(Color.v2Ink)
        }
        .toggleStyle(.switch)
        .tint(Color.v2SpineGreen)
        .padding(14)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - Shared WebView (cross-platform)

/// Tracks the last `reloadTick` this representable acted on, so
/// `update{UI,NS}View` can tell "the pane's Reload button was tapped again"
/// apart from an unrelated SwiftUI re-render.
private final class LoginWebViewCoordinator {
    var lastReloadTick = 0
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    let reloadTick: Int
    let navigationObserver: LoginNavigationObserver

    func makeCoordinator() -> LoginWebViewCoordinator { LoginWebViewCoordinator() }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.lastReloadTick = reloadTick
        return makeWebView(url: url, store: store, navigationObserver: navigationObserver)
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard reloadTick != context.coordinator.lastReloadTick else { return }
        context.coordinator.lastReloadTick = reloadTick
        nsView.reload()
    }
}
#else
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    let reloadTick: Int
    let navigationObserver: LoginNavigationObserver

    func makeCoordinator() -> LoginWebViewCoordinator { LoginWebViewCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.lastReloadTick = reloadTick
        return makeWebView(url: url, store: store, navigationObserver: navigationObserver)
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard reloadTick != context.coordinator.lastReloadTick else { return }
        context.coordinator.lastReloadTick = reloadTick
        uiView.reload()
    }
}
#endif

/// Shared WKWebView setup used by both platform representables. WKWebView and
/// its default cookie store exist on iOS and macOS alike.
///
/// The pre-login cookie/cache purge (docs/CANVAS_LOGIN_DIAGNOSIS.md item 1c)
/// happens BEFORE this function is ever called — in the owning pane's
/// `.task(id: purgeGeneration)`, which gates whether the WebView is created
/// at all (`isPurging`). That guarantees it runs exactly once per Connect tap
/// (or "Start over" tap) and can never race an in-flight navigation the way a
/// purge-then-load `Task` fired from inside `makeWebView` itself could.
///
/// Two further hardening pieces (docs/CANVAS_LOGIN_DIAGNOSIS.md items 1a/1d):
/// - `allowsBackForwardNavigationGestures = false` — a full-bleed login pane
///   has no chrome, so swiping back onto an already-consumed login form and
///   resubmitting it is indistinguishable from a real tap, and produces
///   exactly Shibboleth's "Stale Request" with no way forward. The pane's
///   explicit Reload/"Start over" controls are the replacement.
/// - `customUserAgent` — a genuine Mobile Safari UA for this device/iOS
///   version (`LoginUserAgent.mobileSafari`), since Safari itself logs into
///   Canvas fine on the same device but `WKWebView`'s default UA is missing
///   Safari's own version tokens, which is exactly the kind of thing
///   fingerprinting/bot-protection keys on.
///
/// Loads with `.reloadIgnoringLocalAndRemoteCacheData` so a previously cached
/// copy of the login/redirect chain (with a stale embedded flow-execution
/// token) can never be replayed instead of hitting the network.
@MainActor
private func makeWebView(url: URL, store: WKWebsiteDataStore, navigationObserver: LoginNavigationObserver) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = false
    // UA experiment concluded 2026-08-22: spoof off changed nothing (0/3,
    // identical failure signature), so the UA is exonerated for the Stale
    // Request bug and restored for its original purpose (Duo's browser
    // gating). The actual culprit the same round's action log exposed: the
    // PennKey form POST fires twice — see LoginNavigationObserver's
    // duplicate-POST suppression.
    webView.customUserAgent = LoginUserAgent.mobileSafari
    // Observe-only (docs/CANVAS_LOGIN_DIAGNOSIS.md item 3a) — see
    // `LoginNavigationObserver`'s doc comment. The pane's `@StateObject` keeps
    // this instance alive; `WKWebView.navigationDelegate` is a weak reference.
    webView.navigationDelegate = navigationObserver
    navigationObserver.startURL = url
    // One-line dispatch probe: WebKit delivers the response-policy callback
    // (the only source of HTTP statuses in the redirect log) purely based on
    // this respondsToSelector check. Its @objc exposure has silently failed
    // twice, so assert it out loud on every WebView creation — "false" in
    // the console means the redirect log is back to titles only.
    let respondsToPolicy = navigationObserver.responds(
        to: Selector(("webView:decidePolicyForNavigationResponse:decisionHandler:"))
    )
    Logger(subsystem: Bundle.main.bundleIdentifier ?? "LHF", category: "login-redirects")
        .info("delegate responds to decidePolicyForNavigationResponse: \(respondsToPolicy, privacy: .public)")
    webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    return webView
}

#if DEBUG
#Preview {
    OnboardingView()
        .environmentObject(AppState())
        .frame(width: 393, height: 852)
}
#endif
