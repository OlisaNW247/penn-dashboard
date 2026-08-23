import SwiftUI
import LowHangingFruitKit

/// "Paste your Canvas calendar link" — a first-class fallback to the
/// WKWebView login (docs/CANVAS_LOGIN_HARDENING.md item 3b), reachable from
/// both onboarding and Settings. Canvas → Calendar → "Calendar Feed" gives
/// every student this exact link without needing to pass Penn SSO inside the
/// app at all, so it's the one path that keeps working even while the
/// embedded-login "Stale Request" bug is being chased down.
///
/// Copy here is deliberately honest about scope: this covers the app's
/// currently-shipped feature set (the assignment/deadline dashboard) and
/// nothing more — it does NOT cover submission status (the ICS feed carries
/// no such field; `CanvasICSClient` always reports `submitted: false`) or
/// Grade Watcher (feature-flagged off in this build, and cookie-authed
/// regardless — a pasted feed link can't power it).
struct PasteFeedLinkSheet: View {
    @EnvironmentObject private var state: AppState
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://canvas.upenn.edu/feeds/calendars/...", text: $draft)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Canvas calendar link")
                } footer: {
                    Text("On canvas.upenn.edu: Calendar → Calendar Feed (bottom right) → copy the link. Paste it here exactly as given — a webcal:// link works too.")
                }

                Section {
                    Text("This connects your assignment and deadline dashboard only. It doesn't show submission status or grades — those need the in-app Canvas login.")
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.v2DateText)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2SpineRed)
                    }
                }
            }
            .navigationTitle("Paste calendar link")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let rewritten = AppState.rewritingWebcalScheme(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url = URL(string: rewritten), let scheme = url.scheme?.lowercased(),
              scheme == "https", url.host != nil else {
            errorMessage = "That doesn't look like a valid link. Copy it again from Canvas \u{2192} Calendar \u{2192} Calendar Feed."
            return
        }
        state.updateCanvasICSURL(rewritten)
        Task {
            await state.sync()
            onSaved()
            dismiss()
        }
    }
}
