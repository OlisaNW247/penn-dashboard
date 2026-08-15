import SwiftUI
import WebKit
import LowHangingFruitKit

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

                Button {
                    state.enterPreviewMode()
                } label: {
                    Text("Just exploring? Preview with sample data")
                        .font(.lhfSans(12, weight: .medium))
                        .foregroundStyle(Color.v2DateText)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview the app with sample data")
                .padding(.top, 16)

                troubleConnectingLink
                    .padding(.top, 10)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
        }
        .onAppear { name = state.userName }
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
private struct LoginActionBar: View {
    let message: String?
    let defaultHint: String
    let connectTitle: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message ?? defaultHint)
                .font(.lhfSans(12))
                .foregroundStyle(message == nil ? Color.v2DateText : Color.v2SpineRed)
                .fixedSize(horizontal: false, vertical: true)

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

// MARK: - Canvas login pane

/// Canvas login WebView whose "Connect" action captures the ICS feed URL,
/// syncs Canvas, and scans for requirements in one step.
private struct CanvasLoginPane: View {
    @EnvironmentObject private var state: AppState
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var isReadingCookies = false
    @State private var message: String?

    private var isBusy: Bool {
        isReadingCookies || state.isCanvasDiscoveryLoading || state.isLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            LoginWebView(
                url: URL(string: "https://canvas.upenn.edu")!,
                purgingDomainContains: AppState.canvasLoginDomainHints
            )

            Divider().overlay(Color.v2Divider)

            LoginActionBar(
                message: message,
                defaultHint: "Log in to Canvas once. We'll capture your calendar feed automatically.",
                connectTitle: "Connect Canvas",
                isBusy: isBusy,
                onCancel: onCancel,
                onConnect: connect
            )
        }
        .background(Color.v2Bg.ignoresSafeArea())
#if os(macOS)
        .frame(minWidth: 860, minHeight: 620)
#endif
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            // Read once to discover the calendar-feed URL, but also persisted
            // (Keychain, same treatment as Gradescope's) so Grade Watcher's
            // cookie-authed refresh survives relaunches — `WKWebsiteDataStore`
            // drops session cookies like Canvas's/Penn SSO's between launches.
            let canvasCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("canvas.upenn.edu") }
            SessionCookieStore.save(canvasCookies)
            Task { @MainActor in
                isReadingCookies = false
                let connected = await state.connectCanvas(cookies: canvasCookies)
                if connected {
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

    private var isBusy: Bool { isReadingCookies || state.isGradescopeLoading }

    var body: some View {
        VStack(spacing: 0) {
            LoginWebView(
                url: URL(string: "https://www.gradescope.com/login")!,
                purgingDomainContains: ["gradescope"]
            )

            Divider().overlay(Color.v2Divider)

            LoginActionBar(
                message: message,
                defaultHint: "Log in to Gradescope once. We'll keep it in sync while your session is valid.",
                connectTitle: "Connect Gradescope",
                isBusy: isBusy,
                onCancel: onCancel,
                onConnect: connect
            )
        }
        .background(Color.v2Bg.ignoresSafeArea())
#if os(macOS)
        .frame(minWidth: 860, minHeight: 620)
#endif
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let gradescopeCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("gradescope") }
            SessionCookieStore.save(gradescopeCookies)
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

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let url: URL
    let purgingDomainContains: [String]

    func makeNSView(context: Context) -> WKWebView { makeWebView(url: url, purgingDomainContains: purgingDomainContains) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let purgingDomainContains: [String]

    func makeUIView(context: Context) -> WKWebView { makeWebView(url: url, purgingDomainContains: purgingDomainContains) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Shared WKWebView setup used by both platform representables. WKWebView and
/// its default cookie store exist on iOS and macOS alike.
///
/// Two pieces of cookie/cache hygiene, added per
/// docs/CANVAS_LOGIN_DIAGNOSIS.md: every fresh "Connect" attempt (a) purges
/// any cookies/cache left in the shared `WKWebsiteDataStore.default()` for
/// this login's domains before the first request goes out, so Canvas/Penn
/// SSO never sees a session it thinks it should try to resume, and (b) loads
/// with `.reloadIgnoringLocalAndRemoteCacheData` so a previously cached copy
/// of the login/redirect chain (with a stale embedded flow-execution token)
/// can never be replayed instead of hitting the network.
@MainActor
private func makeWebView(url: URL, purgingDomainContains needles: [String]) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true

    Task {
        await WebsiteDataReset.purgeWebsiteData(matchingDomainContains: needles)
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    }
    return webView
}

#if DEBUG
#Preview {
    OnboardingView()
        .environmentObject(AppState())
        .frame(width: 393, height: 852)
}
#endif
