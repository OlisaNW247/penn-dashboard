import SwiftUI
import WebKit
import LowHangingFruitKit

/// First-run welcome flow. Blocks the dashboard until both core data sources are
/// connected. The Canvas calendar feed URL is captured automatically from the
/// logged-in session — the user never pastes it.
///
/// Logins are presented inline (the window swaps to the WebView) rather than as
/// sheets, which is far more reliable on macOS than stacking modal sheets.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var phase: Phase = .steps

    private enum Phase {
        case steps
        case canvasLogin
        case gradescopeLogin
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
        }
    }

    private var canContinue: Bool {
        state.isCanvasConnected && state.isGradescopeConnected
    }

    private var stepList: some View {
        VStack(spacing: 28) {
            header

            VStack(spacing: 12) {
                stepCard(
                    index: 1,
                    title: "Connect Canvas",
                    subtitle: "Log in once. We'll pull in your assignments and find recurring requirements automatically.",
                    connected: state.isCanvasConnected,
                    working: state.isCanvasDiscoveryLoading || state.isLoading
                ) { phase = .canvasLogin }

                stepCard(
                    index: 2,
                    title: "Connect Gradescope",
                    subtitle: "Log in once. We'll keep your Gradescope assignments in sync.",
                    connected: state.isGradescopeConnected,
                    working: state.isGradescopeLoading
                ) { phase = .gradescopeLogin }
            }

            if let error = state.error {
                Text(error)
                    .font(.geist(12))
                    .foregroundStyle(Color.lhfPast)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                state.completeOnboarding()
            } label: {
                Text("Go to dashboard")
                    .font(.geist(14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.lhfGraphite)
            .disabled(!canContinue)

            Text("Both connections are required so the dashboard has something to show.")
                .font(.geist(11))
                .foregroundStyle(Color.lhfGraphite.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 520)
        .background(Color.lhfBg.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("LHF")
                .font(.instrumentSerif(40))
                .foregroundStyle(Color.lhfGraphite)
            Text("Welcome to Low Hanging Fruit")
                .font(.geist(16, weight: .semibold))
                .foregroundStyle(Color.lhfGraphite)
            Text("Connect your accounts to build your assignment dashboard.")
                .font(.geist(12))
                .foregroundStyle(Color.lhfGraphite.opacity(0.55))
        }
    }

    private func stepCard(
        index: Int,
        title: String,
        subtitle: String,
        connected: Bool,
        working: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(connected ? Color.lhfFuture : Color.lhfGraphite.opacity(0.12))
                    .frame(width: 30, height: 30)
                if connected {
                    CheckmarkShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                } else {
                    Text("\(index)")
                        .font(.geist(13, weight: .semibold))
                        .foregroundStyle(Color.lhfGraphite.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.geist(14, weight: .semibold))
                    .foregroundStyle(Color.lhfGraphite)
                Text(subtitle)
                    .font(.geist(12))
                    .foregroundStyle(Color.lhfGraphite.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if working {
                ProgressView().controlSize(.small)
            } else {
                Button(connected ? "Reconnect" : "Connect", action: action)
                    .buttonStyle(.bordered)
                    .font(.geist(12, weight: .medium))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.35))
        )
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
            LoginWebView(url: URL(string: "https://canvas.upenn.edu")!)

            Divider()

            HStack {
                Text(message ?? "Log in to Canvas once. We'll capture your calendar feed automatically.")
                    .font(.caption)
                    .foregroundStyle(message == nil ? Color.secondary : Color.orange)
                Spacer()
                Button("Cancel", action: onCancel)
                Button(action: connect) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Connect Canvas", systemImage: "calendar.badge.checkmark")
                    }
                }
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let canvasCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("canvas.upenn.edu") }
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

private struct GradescopeLoginPane: View {
    @EnvironmentObject private var state: AppState
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var isReadingCookies = false
    @State private var message: String?

    private var isBusy: Bool {
        isReadingCookies || state.isGradescopeLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            LoginWebView(url: URL(string: "https://www.gradescope.com/login")!)

            Divider()

            HStack {
                Text(message ?? "Log in to Gradescope once. The app will auto-sync while your session stays valid.")
                    .font(.caption)
                    .foregroundStyle(message == nil ? Color.secondary : Color.orange)
                Spacer()
                Button("Cancel", action: onCancel)
                Button(action: connect) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Connect Gradescope", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let gradescopeCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("gradescope.com") }
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

// MARK: - Shared WebView (cross-platform)

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView { makeWebView(url: url) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct LoginWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView { makeWebView(url: url) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Shared WKWebView setup used by both platform representables. WKWebView and
/// its default cookie store exist on iOS and macOS alike.
@MainActor
private func makeWebView(url: URL) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.load(URLRequest(url: url))
    return webView
}
