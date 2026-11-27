import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

/// The sign-in popup of `PathPortal`, shown to the student when the app cannot
/// finish Penn's sign-in for them: Duo asks for something a hidden page cannot
/// show (a code, a method, "is this your device"), or the saved PennKey may not
/// be typed. The web view is the portal's own popup, never a copy: it was built
/// from the configuration WebKit passed in, which is what keeps `window.opener`
/// alive for the token hand-off, so this file only HOSTS it. It reads nothing
/// the student types. The wrong fix is new wording or a longer wait: the
/// student has to be able to see Duo's page.
///
/// iOS only. On the Mac an attempt never goes interactive
/// (`PathPortal.interactiveSupported`), so nothing here is ever presented.
struct PathSignInSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("finish signing in")
                    .font(.lhfSans(16, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { state.cancelDegreeInteractiveSignIn() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.smoothInk)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider().overlay(Color.smoothRule.opacity(0.6))
            #if os(iOS)
            if let web = state.degreeInteractiveWebView {
                PathPopupHost(webView: web)
            } else {
                Spacer()
            }
            #else
            Spacer()
            #endif
        }
        .background(Color.smoothPaper.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}

#if os(iOS)
/// Hosts the portal's popup in a plain container. Dismantling only takes the
/// hosted view out of the container: the portal owns it and the attempt may
/// still be running, so it is never stopped, reloaded or destroyed here.
struct PathPopupHost: UIViewRepresentable {
    let webView: WKWebView

    final class Coordinator {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        for hosted in uiView.subviews { hosted.removeFromSuperview() }
    }
}
#endif

/// Presents `PathSignInSheet` while a degree sign-in is waiting on the student.
/// Several degree screens are themselves sheets and a sheet cannot present over
/// another presenter's sheet, so each presenter attaches this to itself, and
/// the parent turns it off (`enabled`) while a child sheet is up. The setter
/// cancels the attempt when the system dismisses the sheet while the state is
/// still true, so an attempt can never hang behind a closed page.
private struct PathSignInPresenter: ViewModifier {
    @EnvironmentObject var state: AppState
    let enabled: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { enabled && state.degreeInteractiveSignIn },
            set: { shown in
                if !shown, enabled, state.degreeInteractiveSignIn {
                    state.cancelDegreeInteractiveSignIn()
                }
            }
        )) {
            PathSignInSheet().environmentObject(state)
        }
    }
}

extension View {
    func pathSignInSheet(enabled: Bool = true) -> some View {
        modifier(PathSignInPresenter(enabled: enabled))
    }
}
