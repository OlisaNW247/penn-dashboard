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
                    vaultHeader
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))

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
                        .textContentType(.username)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("", text: $password, prompt: Text("password"))
                        .labelsHidden()
                        #if os(iOS)
                        .textContentType(.password)
                        #endif
                }
                .smoothSectionBackground(.smoothCobalt)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothCobalt)
            .navigationTitle("")
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

    /// The vault and one short line replace a paragraph of footer copy that
    /// made this read like an unexplained pop-up asking for a password. The
    /// promise that matters is the one a student can check: it stays in
    /// this phone's Keychain (`PennKeyCredentialStore`, this-device-only).
    /// The emblem is deliberately heavy: this is the one screen where the
    /// app asks for a password, so it should look like a door that shuts,
    /// not like a settings row. It is decoration only, so VoiceOver skips it
    /// and reads the title and the line beneath as one element.
    private var vaultHeader: some View {
        VStack(spacing: 12) {
            VaultEmblem(size: 80)
                .accessibilityHidden(true)
            Text("the vault")
                .font(.lhfSerif(22))
                .foregroundStyle(Color.smoothInk)
            Text("encrypted in this phone\u{2019}s keychain. never sent to smooth.")
                .font(.lhfSecondary(13))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func save() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { return }
        state.enableStayLoggedIn(username: trimmedUsername, password: password)
        dismiss()
    }
}

/// A vault door drawn from circles and one SF Symbol: a heavy ink disc with a
/// ring of bolts, a cobalt band, a paper face and the lock itself.
///
/// Colour: ink and paper carry the shape, so it holds up in both
/// appearances without a second set of values (ink is near-black on white in
/// light mode and cream on night paper in dark). Cobalt is the only accent,
/// and only as a fill. The glyph sits on the paper face and not on the
/// cobalt band because a pastel fill under an ink-coloured glyph loses its
/// contrast in dark mode, where ink is the light colour.
///
/// Motion: one short "clunk" when the sheet appears. The lock starts open,
/// the door a touch large and the bolt ring turned off its mark, and a quick
/// spring closes the lock, seats the door and turns the ring home. Nothing
/// loops, and with Reduce Motion on it is drawn already shut.
private struct VaultEmblem: View {
    /// The diameter of the whole door, in points. Every other dimension is a
    /// proportion of this, so the emblem can be resized without redrawing it.
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var latched = false

    private var shut: Bool { latched || reduceMotion }
    private let boltCount = 8

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.smoothInk)

            ZStack {
                ForEach(0..<boltCount, id: \.self) { index in
                    Circle()
                        .fill(Color.smoothPaper)
                        .frame(width: size * 0.08, height: size * 0.08)
                        .offset(y: -size * 0.42)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(boltCount)))
                }
            }
            .rotationEffect(.degrees(shut ? 0 : -30))

            Circle()
                .fill(Color.smoothCobalt)
                .frame(width: size * 0.70, height: size * 0.70)

            Circle()
                .fill(Color.smoothPaper)
                .frame(width: size * 0.64, height: size * 0.64)

            Image(systemName: shut ? "lock.fill" : "lock.open.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Color.smoothInk)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 0.46, height: size * 0.46)
        }
        .frame(width: size, height: size)
        .scaleEffect(shut ? 1 : 1.07)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55).delay(0.25)) {
                latched = true
            }
        }
    }
}
