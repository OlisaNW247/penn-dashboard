import SwiftUI
import LowHangingFruitKit

/// Collects the student's own PennKey username and password for the optional
/// "stay signed in" auto-login feature (CLAUDE.md's "stay signed in" entry;
/// `PennKeyCredentialStore`'s doc comment has the full data-handling
/// argument). This sheet is the ONLY place in the app a PennKey password is
/// ever typed for this feature — auto-login never scrapes it out of Penn's
/// own login page, which the student would otherwise type it into by hand
/// (`PennKeyLoginForm`'s doc comment records that rejected alternative and
/// why).
///
/// Presented from three places, all sharing this one sheet:
/// - Settings' "stay signed in" toggle, turned on.
/// - Settings' "update password" button, shown once a stored password has
///   been rejected (`AppState.autoLoginDisabledReason`).
/// - Once, automatically, right after a successful interactive Canvas login
///   (`OnboardingView`'s one-time offer) — that caller passes `onCancel` so
///   its own onward flow (to the next onboarding step) isn't blocked on a
///   save that may never happen.
struct PennKeyCredentialsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Called on cancel — never on a successful save. `nil` (Settings' two
    /// presentation sites) means there's nothing else to do beyond
    /// dismissing; `OnboardingView`'s one-time offer supplies one so it can
    /// continue its own step sequence regardless of how the student answered.
    var onCancel: (() -> Void)?

    /// The cancel button's label — "cancel" everywhere this sheet is
    /// reached from a deliberate tap (Settings' toggle, "update password"),
    /// and "not now" for `OnboardingView`'s one-time unsolicited offer,
    /// where "cancel" would misleadingly suggest something was already in
    /// progress to back out of.
    var cancelLabel: String = "cancel"

    @State private var username: String
    @State private var password: String = ""

    init(cancelLabel: String = "cancel", onCancel: (() -> Void)? = nil) {
        self.cancelLabel = cancelLabel
        self.onCancel = onCancel
        // Prefilled from any stored username — the common real-world reason
        // this sheet reopens is "update password" after a rejection, where
        // making the student retype a username the app already has on file
        // would be pure friction. The password is never prefilled, even
        // though `PennKeyCredentialStore` could technically supply the
        // (now-known-wrong, or simply not worth redisplaying) old value —
        // retyping the password is the entire point of this screen.
        _username = State(initialValue: PennKeyCredentialStore.load()?.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Empty title + `.labelsHidden()`, not a literal title
                    // string: on macOS a `TextField`'s title renders as a
                    // leading label in its own column (the columns form
                    // style — see `ProfileSemesterSection`'s own doc comment
                    // for this exact trap), which would put "pennkey
                    // username" to the left of the box instead of inside it
                    // as placeholder text. `prompt:` is the
                    // placeholder-inside-the-field spelling on both
                    // platforms; iOS is unaffected either way, since its
                    // title was already only ever shown as placeholder text.
                    TextField("", text: $username, prompt: Text("pennkey username"))
                        .labelsHidden()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("", text: $password, prompt: Text("password"))
                        .labelsHidden()
                } header: {
                    SmoothSectionHeader("pennkey", accent: .smoothCobalt)
                } footer: {
                    Text("smooth keeps this in this phone's keychain and uses it only to sign you back into canvas when your session expires. it never leaves the phone. tick \u{201c}remember this device\u{201d} at the duo step so duo doesn't ask either.")
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.v2DateText)
                }
                .smoothSectionBackground(.smoothCobalt)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothCobalt)
            .navigationTitle("stay signed in")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelLabel) {
                        onCancel?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save", action: save)
                        .disabled(
                            username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || password.isEmpty
                        )
                }
            }
        }
        .lhfSheetTheme()
    }

    private func save() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { return }
        state.enableStayLoggedIn(username: trimmedUsername, password: password)
        dismiss()
    }
}
