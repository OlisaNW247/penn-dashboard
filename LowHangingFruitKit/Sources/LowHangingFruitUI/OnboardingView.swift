import SwiftUI
import WebKit
import LowHangingFruitKit
import os

/// First-run welcome flow. Blocks the dashboard until Canvas is connected. The
/// Canvas calendar feed URL is captured automatically from the logged-in
/// session — the user never pastes it.
///
/// Styled to match the LHF redesign (greige surface, white cards, serif
/// wordmark). Logins are presented inline (the view swaps to the WebView).
///
/// **This used to be one long scrolling checklist** — a single screen with a
/// name field and four cards ("Connect Canvas", "Connect Gradescope", "Choose
/// your classes", a per-course reminder walk) that each opened a full-screen
/// pane and, on completion or cancel, dropped the student straight back on
/// the same checklist. That hub-and-spoke shape read as a chore list rather
/// than a walk: everything was visible at once, nothing signaled how far
/// along you were, and "Connect Gradescope" sat at the same visual weight as
/// the one connection that actually matters, so an optional step could look
/// exactly as urgent as the required one. It is now a straight line — one
/// step, one screen, one ask instead of a checklist a student re-reads after
/// every pane. The first setup screen now goes directly from the intro to
/// Penn's Canvas sign-in. If
/// a future change needs the old "see everything, do it in any order" shape
/// back, that is a deliberate reversion, not a bug fix — write down why,
/// the way this comment does.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The notification step reads and writes the exact same global lead-time
    /// settings Settings → Reminders and Profile → Notifications do,
    /// which means it has to be the *same instance* those screens will later
    /// see — `NotificationScheduler`'s published properties are loaded from
    /// `UserDefaults.lhf` once, at `init`, and never re-read afterward,
    /// so a scheduler this view constructed for itself would go stale the
    /// moment `RootCore` handed `ContentView` its own separate instance at
    /// the onboarding → dashboard handoff, and Profile would show whatever
    /// was on disk *before* this step ran rather than what the student just
    /// chose. So this is `@EnvironmentObject`, supplied by the same
    /// `RootCore` that owns the one scheduler for the rest of the app's
    /// lifetime (see `RootView.swift`), not a locally-owned `@StateObject`.
    @EnvironmentObject var scheduler: NotificationScheduler
    @State private var phase: Phase = .canvasLogin
    /// Presents `PennKeyCredentialsSheet` once, right after a successful
    /// interactive Canvas login — see `canvasConnected()`'s doc comment for
    /// the "why here" and `AppState.hasOfferedStayLoggedIn` for why this
    /// never fires a second time.
    @State private var showStayLoggedInOffer = false

    /// One case per screen in the linear walk, plus the per-course walk that
    /// can follow it. Order here is the order a student walks them in; there
    /// is no case for "the hub" any more; see this type's doc comment for
    /// what used to live there.
    private enum Phase: Hashable {
        case canvasLogin
        case gradescopeLogin
        case reminders
    }

    init(destination: AppState.OnboardingDestination = .full) {
        #if DEBUG
        let initialPhase: Phase = ProcessInfo.processInfo.arguments.contains("-LHFRemindersOnboardingHarness")
            ? .reminders
            : (destination == .gradescope ? .gradescopeLogin : .canvasLogin)
        #else
        let initialPhase: Phase = destination == .gradescope ? .gradescopeLogin : .canvasLogin
        #endif
        _phase = State(initialValue: initialPhase)
    }

    var body: some View {
        ZStack {
            stepContent
                .id(phase)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: phase)
            // The walk has to declare that it fills. `RootCore` hosts this
            // inside a `ZStack` — it shares that stack with the splash — and a
            // ZStack centres any child that reports back a smaller size than
            // the proposal it was handed. Several steps embed login panes whose
            // content is intrinsically sized rather than expanding, so without
            // this the entire step, chrome included, floats vertically centred
            // while its `.ignoresSafeArea()` background still paints
            // full-bleed. That combination is deceptive: the screen looks like
            // a correctly coloured full-screen view with a third of its top
            // mysteriously empty and the back chevron and progress dots
            // stranded partway down, rather than like a view that is simply
            // too short. Two earlier fixes went hunting inside the panes for
            // the missing height; the height was never missing, the step just
            // never claimed it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Attached here, at the OUTER body level, rather than inside
            // `canvasStep`'s `CanvasLoginPane` branch: the instant
            // `state.isCanvasConnected` flips true (which happens inside
            // `CanvasLoginPane.connect()` BEFORE it calls `onConnected()` —
            // i.e. before `canvasConnected()` even runs), `canvasStep`'s own
            // `@ViewBuilder` switches from the `CanvasLoginPane` branch to
            // the `connectedStep(...)` branch, which would tear down any
            // `.sheet` modifier attached to the pane branch specifically
            // before `showStayLoggedInOffer` even had a chance to present
            // it. This level of the view tree survives that branch swap (and
            // the `phase` change `advancePastCanvasStep` makes once the
            // sheet closes) untouched, so the presentation is reliable
            // regardless of which branch is on screen when it's triggered.
            .sheet(isPresented: $showStayLoggedInOffer, onDismiss: advancePastCanvasStep) {
                // `onDismiss` (not `onCancel`) is what actually advances the
                // walk — it fires whether the student saved or tapped "not
                // now", so both answers land on the same next step. The
                // sheet's own "not now" button just closes it; there is
                // nothing else for it to do here.
                PennKeyCredentialsSheet(cancelLabel: "not now")
                    .environmentObject(state)
            }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch phase {
        case .canvasLogin:
            canvasStep
        case .gradescopeLogin:
            gradescopeStep
        case .reminders:
            remindersStep
        }
    }

    /// The class list is deliberately not part of first-run setup. Canvas can
    /// still be filling it in when this screen appears, so asking the student
    /// to curate that partial snapshot makes missing classes look intentional.
    /// Class visibility and per-course reminders remain available in Settings
    /// once the first sync has had time to settle.
    private func finishOnboarding() {
        OnboardingCourseSetup.markCompleted()
        if reduceMotion {
            state.completeOnboarding()
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                state.completeOnboarding()
            }
        }
    }

    // MARK: - Connect Canvas (required, not skippable)

    /// Canvas is the only required step. If it's already connected — the
    /// student stepped forward once and then used the back chevron on a
    /// later step to glance backward — this shows a plain confirmation
    /// instead of re-mounting `CanvasLoginPane`. Without that check, going
    /// back "just to look" would re-run the pane's own pre-login cookie
    /// purge and load a fresh WebView for a login that already succeeded:
    /// harmless, but a needless network round trip and a confusing
    /// "log in again?" prompt for a login that isn't being redone.
    @ViewBuilder
    private var canvasStep: some View {
        if state.isCanvasConnected && state.onboardingDestination != .canvas {
            connectedStep(
                step: 1,
                message: "canvas is connected.",
                onBack: nil,
                onContinue: { phase = .gradescopeLogin }
            )
        } else {
            CanvasLoginPane(onConnected: canvasConnected)
            .environmentObject(state)
            .safeAreaInset(edge: .top, spacing: 0) {
                loginHeader(title: "Connect Canvas")
            }
            // The reviewer's door, restored here after a regression
            // (`358bc5f`) deleted it along with the old checklist's name
            // step. `IntroView`'s first screen carries the same link, but
            // that one is reachable only while `hasSeenIntro` is still
            // false — Skip sets it permanently, and this Canvas step is
            // exactly where Skip lands, forever, with no way back to the
            // intro short of reinstalling. One door is not enough; see
            // `c999c38`. Pinned to the bottom safe area, below the entire
            // login pane above it, so it never competes with actually
            // connecting a real account.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                previewFooter
            }
            .background(Color.v2Bg.ignoresSafeArea())
        }
    }

    /// Same door as `IntroView.previewLink`, on the screen a reviewer
    /// actually lands on after skipping the intro.
    private var previewFooter: some View {
        Button {
            lhfHapticLight()
            state.enterPreviewMode()
        } label: {
            VStack(spacing: 3) {
                Text("just exploring?")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.v2DateText)
                Text("preview with sample data")
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                    .underline()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(Color.v2Card)
        .accessibilityLabel("preview the app with sample data")
        .accessibilityHint("explore a demo dashboard without logging in")
    }

    /// Called once Canvas is actually connected (cookies captured, the pane's
    /// `onChange` fired `connect()` successfully). Before moving on, this is
    /// the one-time hook for offering "stay signed in"
    /// (`PennKeyCredentialsSheet`) — right after a real interactive login is
    /// the one moment the student has just proven they know their PennKey
    /// password and are already thinking about Canvas access, which makes it
    /// the least intrusive place to ask, once, whether Smooth should
    /// remember it. `AppState.hasOfferedStayLoggedIn` is what keeps this to
    /// exactly once ever — Settings is the only way back after this.
    private func canvasConnected() {
        if !state.stayLoggedInEnabled && !state.hasOfferedStayLoggedIn {
            state.noteStayLoggedInOffered()
            showStayLoggedInOffer = true
            return
        }
        advancePastCanvasStep()
    }

    /// The actual "Canvas step is done" transition — pulled out of
    /// `canvasConnected()` so both the ordinary path (offer already shown,
    /// or feature already on) and the offer sheet's `onDismiss` (however the
    /// student answered: saved, or "not now") land on the same next step.
    private func advancePastCanvasStep() {
        if state.onboardingDestination == .canvas {
            state.completeOnboarding()
        } else {
            phase = .gradescopeLogin
        }
    }

    // MARK: - Step 2: Connect Gradescope (optional, skippable)

    @ViewBuilder
    private var gradescopeStep: some View {
        if state.isGradescopeConnected {
            connectedStep(
                step: 2,
                message: "gradescope is connected.",
                onBack: { phase = .canvasLogin },
                onContinue: gradescopeConnected
            )
        } else {
            GradescopeLoginPane(
                onConnected: gradescopeConnected
            )
            .environmentObject(state)
            .safeAreaInset(edge: .top, spacing: 0) {
                loginHeader(
                    title: "Connect Gradescope",
                    skip: (label: "Skip", action: gradescopeSkipped)
                )
            }
            .background(Color.v2Bg.ignoresSafeArea())
        }
    }

    private func gradescopeConnected() {
        if state.onboardingDestination == .gradescope {
            state.completeOnboarding()
        } else {
            phase = .reminders
        }
    }

    private func gradescopeSkipped() {
        if state.onboardingDestination == .gradescope {
            state.completeOnboarding()
        } else {
            phase = .reminders
        }
    }

    // MARK: - Step 3: pick notifications (optional, always reachable forward)

    /// Writes directly into the shared scheduler used by Settings and
    /// Profile, so onboarding never creates a second notification preference.
    private var remindersStep: some View {
        VStack(spacing: 0) {
            topBar(onBack: { phase = .gradescopeLogin })

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    remindersHeadline
                    syncNotice
                    leadTimeSection
                    notificationExtrasSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }

            remindersFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg.ignoresSafeArea())
    }

    private var remindersHeadline: some View {
        Text("Pick your notifications")
            .font(.lhfSerif(34))
            .foregroundStyle(Color.v2Ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A soft, borderless pastel field — the same flat `opacity(0.13)` treatment
    /// `smoothSectionBackground` gives every Settings group, rather than the
    /// filled-pill-with-a-stroke look this used before the redesign. Teal
    /// because that's the color Settings already uses for "connected, in
    /// progress" states (the account rows' checkmarks), not a color picked
    /// fresh for this one banner.
    private var syncNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.smoothTealInk)
                .padding(.top, 1)

            Text("Your classes and assignments may take a few minutes to appear.")
                .font(.lhfSans(12, weight: .medium))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.smoothTeal.opacity(0.13))
        )
        .accessibilityElement(children: .combine)
    }

    private var leadTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmoothSectionHeader("remind me", accent: .smoothCobalt)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(NotificationScheduler.LeadOffset.allCases) { offset in
                    leadTimePill(offset)
                }
            }

        }
    }

    /// Tomato is the same accent Settings' own "reminders" section is tinted
    /// with (`SettingsPage.remindersSection`'s `.smoothSectionBackground(.smoothTomato)`)
    /// — picked to match that section rather than to taste, so this screen's
    /// lead-time picker and Settings' later read as the same feature. The
    /// unselected border is a faint wash of that same tomato, never
    /// `Color.v2Divider`/`smoothRule` — that tan is a different, unrelated
    /// token that happens to be visually close enough to pass a glance, which
    /// is exactly the trap CLAUDE.md's "no tan smoothRule borders" line
    /// exists to head off.
    private func leadTimePill(_ offset: NotificationScheduler.LeadOffset) -> some View {
        let isOn = scheduler.leadOffsets.contains(offset)
        return Button {
            lhfHapticLight()
            scheduler.setOffset(offset, on: !isOn)
        } label: {
            Text(offset.label)
                .font(.lhfSans(14, weight: .semibold))
                .foregroundStyle(isOn ? Color.smoothTomatoInk : Color.v2Ink)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(isOn ? Color.smoothTomato.opacity(0.26) : Color.v2Card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.smoothTomato.opacity(isOn ? 0.55 : 0.18), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// Submission confirmations live directly below the lead times so the
    /// first-run default is visible rather than hidden until Profile.
    private var notificationExtrasSection: some View {
        VStack(spacing: 10) {
            notificationOption(
                title: "turned in notifications",
                detail: "confirm when Canvas sees a submission",
                isOn: Binding(
                    get: { scheduler.turnedInEnabled },
                    set: { scheduler.setTurnedInEnabled($0) }
                )
            )
        }
    }

    private func notificationOption(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text(detail)
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2DateText)
            }
        }
        .toggleStyle(.switch)
        // Cobalt: the same `.tint` `SettingsPage.smoothFormChrome` applies to
        // every toggle in the app, reminders included, regardless of which
        // pastel a given section's background happens to be tinted.
        .tint(Color.smoothCobalt)
        .padding(.horizontal, 15)
        .frame(minHeight: 64)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    /// Two ways off this screen, and each means something different:
    /// "turn on reminders" requests authorization (a no-op if already
    /// granted or denied — see below) and proceeds; "skip reminders for now"
    /// proceeds without ever requesting it, leaving `scheduler.isEnabled`
    /// however it already was. Both go straight to the dashboard; class setup
    /// is intentionally deferred until Canvas has finished its first sync.
    ///
    /// Denial is never treated as an error here. `requestAuthorization`
    /// (inside `scheduler.setEnabled`) resolves immediately either way —
    /// granted, denied, or already-decided — and this screen proceeds on
    /// every outcome. Blocking onboarding on a permission the student is
    /// entitled to refuse would be the actual bug.
    private var remindersFooter: some View {
        VStack(spacing: 10) {
            progressDots(current: 3)

            Button {
                lhfHapticLight()
                Task {
                    await scheduler.setEnabled(true)
                    finishOnboarding()
                }
            } label: {
                Text("turn on reminders")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)

            Button {
                finishOnboarding()
            } label: {
                Text("skip reminders for now")
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    // MARK: - Shared chrome

    private func loginHeader(
        title: String,
        skip: (label: String, action: () -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.lhfSerif(34))
                .foregroundStyle(Color.v2Ink)

            Spacer(minLength: 0)

            if let skip {
                Button(skip.label, action: skip.action)
                    .buttonStyle(.plain)
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Color.v2Bg)
    }

    /// Shared back/skip chrome for the non-login steps.
    private func topBar(
        onBack: (() -> Void)?,
        skip: (label: String, action: () -> Void)? = nil
    ) -> some View {
        HStack {
            backButton(onBack)
                .frame(width: 44, height: 32, alignment: .leading)
            Spacer()
            skipButton(skip)
                .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func backButton(_ onBack: (() -> Void)?) -> some View {
        if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("back")
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func skipButton(_ skip: (label: String, action: () -> Void)?) -> some View {
        if let skip {
            Button(action: skip.action) {
                Text(skip.label)
                    .font(.lhfSans(13, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(skip.label)
        } else {
            // Sized here, at the source. `Color.clear` has no intrinsic size
            // and expands to fill whatever it is offered, and the caller's
            // `.frame(minWidth:minHeight:)` sets a floor, not a ceiling — so
            // an unsized placeholder stretched to the full height on offer,
            // inflating the whole `topBar` HStack. On device that centred the
            // back chevron a third of the way down the screen and pushed
            // everything below the top bar down with it, which read as a
            // broken, half-empty step rather than as an oversized spacer.
            // Three separate fixes went looking for that missing height in
            // the login panes before the cause turned out to be an invisible
            // placeholder in the chrome.
            Color.clear.frame(width: 44, height: 32)
        }
    }

    /// Three dots, with the current step filled in green — the same
    /// vocabulary `IntroView.dots` uses, just re-tinted: `IntroView` marks
    /// its current page in ink, this walk marks it in `v2SpineGreen`, the
    /// app's one accent color, to read as progress made rather than merely
    /// "which page."
    private func progressDots(current: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(1...3, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.v2SpineGreen : Color.v2Ink.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    /// Shown instead of the live login pane when a required/optional
    /// connection step is revisited after it already succeeded earlier in
    /// this same walk (via the back chevron on a later step) — see
    /// `canvasStep`'s doc comment for why re-mounting the pane itself would
    /// be the wrong fix.
    private func connectedStep(
        step: Int,
        message: String,
        onBack: (() -> Void)?,
        onContinue: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            topBar(onBack: onBack)

            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.v2SpineGreen)
                Text(message)
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
            }

            Spacer()

            VStack(spacing: 14) {
                progressDots(current: step)

                Button(action: onContinue) {
                    Text("continue")
                        .font(.lhfSans(15, weight: .semibold))
                        .foregroundStyle(Color.v2ToggleActiveTx)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.v2Ink))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg.ignoresSafeArea())
    }
}

// MARK: - Canvas login pane

/// Canvas login WebView whose "Connect" action captures the ICS feed URL,
/// syncs Canvas, and scans for requirements in one step.
private struct CanvasLoginPane: View {
    @EnvironmentObject private var state: AppState
    let onConnected: () -> Void

    @State private var isReadingCookies = false
    @State private var isPurging = true
    @StateObject private var navObserver: LoginNavigationObserver = {
        let observer = LoginNavigationObserver()
        observer.signedInHostMarker = "canvas.upenn.edu"
        // Canvas Student claims universal links for canvas.upenn.edu, which
        // hijacks the SAML return hop away from this WebView on a device
        // that has it installed — see `appLinkGuardHost`'s doc comment.
        // Gradescope's pane below leaves this `nil`: no Gradescope iOS app
        // claims those links, so there is nothing to guard against there.
        observer.appLinkGuardHost = "canvas.upenn.edu"
        return observer
    }()

    var body: some View {
        Group {
            if isPurging || isReadingCookies || navObserver.reachedSignedInDestination {
                VStack {
                    Spacer()
                    ProgressView()
                        .accessibilityLabel(isPurging ? "Preparing Canvas sign-in" : "Connecting Canvas")
                    Spacer()
                }
            } else {
                LoginWebView(
                    url: URL(string: "https://canvas.upenn.edu/login/saml")!,
                    store: LoginDataStores.canvas,
                    navigationObserver: navObserver
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .onChange(of: navObserver.reachedSignedInDestination) { _, reachedDestination in
            if reachedDestination {
                connect()
            }
        }
        .task {
            await WebsiteDataReset.purgeWebsiteData(
                matchingDomainContains: AppState.canvasLoginDomainHints,
                in: LoginDataStores.canvas
            )
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
        .onAppear {
            state.isCanvasLoginPaneActive = true
            // "Stay signed in" visible-pane auto-fill (CLAUDE.md's "stay
            // signed in" entry). Handed to the observer only when
            // `AppState.canAutoLogin` says the feature is actually usable
            // right now — off, missing credentials, or an unresolved prior
            // rejection all mean this pane behaves exactly as it did before
            // this feature existed, with the student typing their password
            // in by hand as always. `.rejected` is the one outcome this pane
            // reacts to; `.submitted` needs no handling here because success
            // is already what `reachedSignedInDestination`'s own
            // `onChange`/`connect()` path reports.
            if state.canAutoLogin, let credentials = PennKeyCredentialStore.load() {
                navObserver.autoLoginCredentials = credentials
            }
            navObserver.onAutoLoginOutcome = { event in
                switch event {
                case .submitted:
                    break
                case .rejected:
                    state.noteAutoLoginRejected()
                }
            }
        }
        .onDisappear { state.isCanvasLoginPaneActive = false }
#if os(macOS)
        .frame(minWidth: 860, minHeight: 620)
#endif
    }

    private func connect() {
        guard !isReadingCookies else { return }
        isReadingCookies = true
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

                    // Silently mint a Canvas personal access token from
                    // inside this still-live, already-authenticated login
                    // WebView, so the student doesn't have to do this again
                    // for the token's lifetime (`CanvasAccessTokenPolicy
                    // .lifetime`, Canvas's own ~120-day ceiling for a
                    // student account — see `CanvasAccessToken.swift`'s doc
                    // comment in the Kit). Three alternatives were
                    // considered and rejected:
                    //   - Storing the PennKey password: Penn's own policy
                    //     plus Duo's second factor make a stored password
                    //     useless for silent reauthentication — there is no
                    //     way to drive a fresh login without a human tapping
                    //     through Duo, so nothing would actually get
                    //     automated by holding onto it.
                    //   - Minting from inside `CanvasSessionRenewer`:
                    //     deferred. That class's rule 1 is GET-only — no
                    //     JavaScript that submits a form, no re-POST, ever —
                    //     because a double-POSTed SAML form is the exact
                    //     historical bug it exists to never repeat, and a
                    //     token mint is a POST. Running the mint here
                    //     instead, in the visible pane, is safe against that
                    //     same rule for a different reason: this `fetch` is
                    //     issued by the PAGE itself (see
                    //     `CanvasAccessTokenMint.script`), not a
                    //     `WKWebView.load`/form-submit navigation, so it
                    //     cannot re-POST the SAML login form no matter when
                    //     it runs — and it only ever runs once, right after
                    //     a login the user just performed themselves, never
                    //     unattended.
                    //   - A process-wide "current Canvas credential"
                    //     provider inside the Kit, so every client could
                    //     reach for the token itself instead of taking it as
                    //     a parameter: rejected by `CanvasAuth.apply`'s own
                    //     doc comment in the Kit — hidden shared state read
                    //     from more than one place at once is the exact
                    //     shape of this repo's two pre-existing test flakes
                    //     (CLAUDE.md, "Two known flakes"). `accessToken` is
                    //     threaded explicitly from here down instead, the
                    //     same way `cookies` already is.
                    //
                    // Gated on `needsMint` (not "mint every login"): a token
                    // already minted this semester and nowhere near its
                    // renewal window needs nothing from this login beyond
                    // the cookies it already captured above. `navObserver
                    // .webView` can be nil in principle (deallocated between
                    // the login completing and this line running) — in that
                    // case there is simply nothing to mint from and cookie
                    // mode continues exactly as it does today.
                    if FeatureFlags.canvasAccessTokens,
                       let webView = navObserver.webView,
                       CanvasAccessTokenPolicy.needsMint(existing: CanvasAccessTokenStore.load(), now: Date()) {
                        let outgoing = CanvasAccessTokenStore.load()
                        switch await CanvasAccessTokenMinter.mint(in: webView) {
                        case let .success(token):
                            state.noteCanvasAccessTokenMinted(token)
                            if let outgoing {
                                // Best-effort, detached so a slow/failed
                                // revoke of the OLD token can never delay
                                // reaching the dashboard — the new token is
                                // already saved and in use by the time this
                                // starts.
                                Task.detached {
                                    await CanvasAccessTokenMinter.revoke(outgoing)
                                }
                            }
                        case let .failure(failure):
                            let status: Int?
                            switch failure {
                            case let .httpStatus(code, _): status = code
                            case .malformed: status = nil
                            }
                            // Canvas can refuse to mint outright (Penn is
                            // known to gate student tokens off entirely,
                            // 403) — logging the status and moving on is the
                            // whole of the handling. The login above already
                            // succeeded on cookies, and nothing about this
                            // failure should be allowed to look like a
                            // failed Canvas connection to the student.
                            state.noteCanvasAccessTokenMintFailed(status: status)
                        }
                    }

                    onConnected()
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

    @State private var isReadingCookies = false
    @State private var isPurging = true
    @StateObject private var navObserver: LoginNavigationObserver = {
        let observer = LoginNavigationObserver()
        observer.signedInHostMarker = "gradescope.com"
        observer.signedInRequiresForeignHost = false
        return observer
    }()

    private static let gradescopeLoginDomainHints = ["gradescope"]

    var body: some View {
        Group {
            if isPurging || isReadingCookies || navObserver.reachedSignedInDestination {
                VStack {
                    Spacer()
                    ProgressView()
                        .accessibilityLabel(isPurging ? "Preparing Gradescope sign-in" : "Connecting Gradescope")
                    Spacer()
                }
            } else {
                LoginWebView(
                    url: URL(string: "https://www.gradescope.com/login")!,
                    store: LoginDataStores.gradescope,
                    navigationObserver: navObserver
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .onChange(of: navObserver.reachedSignedInDestination) { _, reachedDestination in
            if reachedDestination {
                connect()
            }
        }
        .task {
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

    private func connect() {
        guard !isReadingCookies else { return }
        isReadingCookies = true
        // Same store the WebView above uses — see `LoginDataStores`' doc comment.
        LoginDataStores.gradescope.httpCookieStore.getAllCookies { cookies in
            let gradescopeCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("gradescope") }
            SessionCookieStore.save(gradescopeCookies, service: .gradescope)
            Task { @MainActor in
                isReadingCookies = false
                guard !gradescopeCookies.isEmpty else { return }
                await state.syncGradescope(cookies: gradescopeCookies)
                if state.isGradescopeConnected {
                    onConnected()
                }
            }
        }
    }
}

// MARK: - Shared WebView (cross-platform)

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    let navigationObserver: LoginNavigationObserver

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(url: url, store: store, navigationObserver: navigationObserver)
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    let navigationObserver: LoginNavigationObserver

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(url: url, store: store, navigationObserver: navigationObserver)
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Shared WKWebView setup used by both platform representables. WKWebView and
/// its default cookie store exist on iOS and macOS alike.
///
/// The owning pane purges its pre-login cookie/cache state before creating
/// this view, so cleanup cannot race an in-flight navigation.
///
/// Two further hardening pieces (docs/CANVAS_LOGIN_DIAGNOSIS.md items 1a/1d):
/// - `allowsBackForwardNavigationGestures = false` prevents revisiting and
///   resubmitting an already-consumed sign-in form. Navigation stays linear;
///   Gradescope's optional exit remains the native Skip button above the web
///   view.
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
    // Lets `CanvasLoginPane.connect()` reach this exact WebView after a
    // successful login to run `CanvasAccessTokenMinter.mint(in:)` — see
    // `LoginNavigationObserver.webView`'s doc comment. Harmless for the
    // Gradescope pane, which shares this function but never reads the
    // property back.
    navigationObserver.webView = webView
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
        .environmentObject(NotificationScheduler())
        .frame(width: 393, height: 852)
}
#endif
