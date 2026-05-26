import SwiftUI
import WebKit

struct GradescopeLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var isReadingCookies = false

    var body: some View {
        VStack(spacing: 0) {
            GradescopeWebView()
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 620)
                #else
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif

            Divider()

            HStack {
                Text("Log in once. The app will auto-sync Gradescope while your session stays valid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    syncGradescope()
                } label: {
                    if isReadingCookies || state.isGradescopeLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Connect Gradescope", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(isReadingCookies || state.isGradescopeLoading)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private func syncGradescope() {
        isReadingCookies = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let gradescopeCookies = cookies.filter { cookie in
                cookie.domain.localizedCaseInsensitiveContains("gradescope.com")
            }

            Task { @MainActor in
                isReadingCookies = false
                await state.syncGradescope(cookies: gradescopeCookies)
                if state.error == nil {
                    dismiss()
                }
            }
        }
    }
}

private struct GradescopeWebView: View {
    var body: some View { _GradescopeWebViewRepresentable() }
}

#if os(macOS)
private struct _GradescopeWebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct _GradescopeWebViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.load(URLRequest(url: URL(string: "https://www.gradescope.com/login")!))
    return webView
}
