import SwiftUI
import WebKit

struct GradescopeLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var isReadingCookies = false

    var body: some View {
        VStack(spacing: 0) {
            GradescopeWebView()
                .frame(minWidth: 860, minHeight: 620)

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

private struct GradescopeWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: "https://www.gradescope.com/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
