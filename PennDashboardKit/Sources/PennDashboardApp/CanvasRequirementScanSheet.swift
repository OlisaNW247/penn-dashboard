import SwiftUI
import WebKit

struct CanvasRequirementScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var isReadingCookies = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            CanvasWebView()
                .frame(minWidth: 860, minHeight: 620)

            Divider()

            HStack {
                Text(message ?? "Log in once. The app will auto-scan syllabus and announcements while your session stays valid.")
                    .font(.caption)
                    .foregroundStyle(messageColor)
                Spacer()
                Button("Close") { dismiss() }
                Button {
                    scan()
                } label: {
                    if isReadingCookies || state.isCanvasDiscoveryLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Connect Canvas Scan", systemImage: "text.magnifyingglass")
                    }
                }
                .disabled(isReadingCookies || state.isCanvasDiscoveryLoading)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var messageColor: Color {
        message == nil ? .secondary : .orange
    }

    private func scan() {
        isReadingCookies = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let canvasCookies = cookies.filter { cookie in
                cookie.domain.localizedCaseInsensitiveContains("canvas.upenn.edu")
            }

            Task { @MainActor in
                isReadingCookies = false
                guard !canvasCookies.isEmpty else {
                    message = "No Canvas session was found yet. Finish logging in, then connect again."
                    return
                }
                await state.scanCanvasRequirements(cookies: canvasCookies)
                if state.error == nil {
                    dismiss()
                } else {
                    message = state.error
                }
            }
        }
    }
}

private struct CanvasWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: "https://canvas.upenn.edu")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
