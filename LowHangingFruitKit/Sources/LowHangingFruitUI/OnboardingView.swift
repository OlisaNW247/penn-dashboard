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
/// step, one screen, one ask — with a back chevron and a five-dot progress
/// indicator instead of a checklist a student re-reads after every pane. If
/// a future change needs the old "see everything, do it in any order" shape
/// back, that is a deliberate reversion, not a bug fix — write down why,
/// the way this comment does.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    /// Reminders (step 5) reads and writes the exact same global lead-time/
    /// digest settings Settings → Reminders and Profile → Notifications do,
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
    @State private var phase: Phase = .name
    @State private var name: String = ""
    @State private var isResettingLoginData = false
    @State private var showResetConfirmation = false
    @State private var didResetLoginData = false
    /// "Paste your Canvas calendar link" fallback (docs/CANVAS_LOGIN_HARDENING.md
    /// item 3b) — reachable without ever touching the in-app login WebView.
    @State private var showPasteFeedLink = false

    /// One case per screen in the linear walk, plus the per-course walk that
    /// can follow it. Order here is the order a student walks them in; there
    /// is no case for "the hub" any more; see this type's doc comment for
    /// what used to live there.
    private enum Phase {
        case name
        case canvasLogin
        case gradescopeLogin
        case classPicker
        case reminders
        case courseSetup
    }

    /// Whether the primary action should route through the per-course walk
    /// rather than straight to the dashboard.
    ///
    /// Three conditions, all of which have to hold. Canvas connected, because
    /// the walk has nothing to say without it. At least one class switched on,
    /// because the class list is derived from feed items and in week one it is
    /// routinely empty — a "set up your classes" button that opens on nothing
    /// is worse than no button. And `OnboardingCourseSetup.needsCourseSetup`,
    /// which is what keeps a Settings reconnect from replaying the walk; see
    /// its doc comment for why that flag is separate from
    /// `hasCompletedOnboarding`.
    ///
    /// Recomputed rather than cached in `@State` so that connecting Canvas —
    /// which populates the class list — flips the button without needing an
    /// invalidation path.
    private var shouldOfferCourseSetup: Bool {
        state.isCanvasConnected
            && !state.selectedCourseCodes().isEmpty
            && OnboardingCourseSetup.needsCourseSetup()
    }

    var body: some View {
        stepContent
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
    }

    @ViewBuilder
    private var stepContent: some View {
        switch phase {
        case .name:
            nameStep
        case .canvasLogin:
            canvasStep
        case .gradescopeLogin:
            gradescopeStep
        case .classPicker:
            classesStep
        case .reminders:
            remindersStep
        case .courseSetup:
            // Finishing *or* skipping the walk goes straight to the dashboard
            // rather than back to an earlier step. The walk is the last thing
            // between the student and the app, and depositing someone who just
            // tapped "Skip setup" back on a screen they were trying to leave
            // is how a skip stops reading as a skip.
            OnboardingCourseSetupPane(onFinish: { state.completeOnboarding() })
                .environmentObject(state)
        }
    }

    /// Exactly the branch the old checklist's single "Go to dashboard" button
    /// used at the very end — preserved verbatim (same two conditions, same
    /// order) so the destination after this walk never diverges from what
    /// `shouldOfferCourseSetup`'s own gating expects. Called from both of
    /// Reminders' forward actions (`remindersFooter`), since turning
    /// notifications on or skipping them is orthogonal to whether the
    /// per-course walk comes next.
    private func finishOnboarding() {
        if shouldOfferCourseSetup {
            phase = .courseSetup
        } else {
            state.completeOnboarding()
        }
    }

    // MARK: - Step 1: name

    /// The mission header ("LHF" / "never miss another assignment") and the
    /// reviewer's door (`previewCard`) both live only here — see that
    /// property's doc comment for why "just exploring?" has to be reachable
    /// from the very first screen rather than five steps in.
    private var nameStep: some View {
        ZStack {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 56)

                header
                    .padding(.bottom, 28)

                nameCard

                previewCard
                    .padding(.top, 18)

                if let error = state.error {
                    Text(error)
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.v2SpineRed)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }

                Spacer(minLength: 24)

                VStack(spacing: 14) {
                    progressDots(current: 1)

                    Button {
                        lhfHapticLight()
                        phase = .canvasLogin
                    } label: {
                        Text("continue")
                            .font(.lhfSans(15, weight: .semibold))
                            .foregroundStyle(Color.v2ToggleActiveTx)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Color.v2Ink))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
        }
        .onAppear {
            name = state.userName
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-LHFCourseSetupHarness") {
                state.canvasItems = SampleData.items().map(\.assignment)
                state.updateCanvasICSURL("https://example.com/harness.ics")
            }
            #endif
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("your name")
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)
            TextField("first name", text: $name)
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
            Text("welcome to low hanging fruit")
                .font(.lhfSans(16, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
            Text("never miss another assignment")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The same door as `IntroView.previewLink`, on the first screen of this
    /// walk — the screen a reviewer actually lands on after skipping the
    /// intro, and now the only screen in this file that doesn't require
    /// walking forward through anything to reach.
    private var previewCard: some View {
        Button {
            lhfHapticLight()
            state.enterPreviewMode()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("just exploring?")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.v2CourseCode)
                Text("preview with sample data")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                    .underline()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("preview the app with sample data")
        .accessibilityHint("explore a demo dashboard without logging in")
    }

    // MARK: - Step 2: Connect Canvas (required, not skippable)

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
        if state.isCanvasConnected {
            connectedStep(
                step: 2,
                message: "canvas is connected.",
                onBack: { phase = .name },
                onContinue: { phase = .gradescopeLogin }
            )
        } else {
            // Chrome is a `.safeAreaInset(edge: .top)` over the pane, not a
            // `VStack` sibling beside it. `CanvasLoginPane` was written as the
            // root view of this phase: it lays itself out top-to-bottom with
            // its own `Spacer()`s and its own bottom action bar, sized against
            // the *whole* screen. Stack `topBar`/`canvasEscapeHatches` above it
            // as ordinary siblings and the pane no longer gets the whole
            // screen — it gets whatever's left under two fixed-height views in
            // the same `VStack`, which is a fraction of the height its
            // internal `Spacer()`s were written against. On device that
            // measured out to the WebView getting squeezed into roughly the
            // bottom quarter of the screen while the top ~55% sat empty,
            // because the top bar and escape hatches, having no `Spacer` of
            // their own, hugged the pane instead of pinning to the actual top
            // of the screen. `safeAreaInset` keeps the pane as the one full-
            // size view — it lays out exactly as it did as a standalone
            // phase — and reserves screen space at the top for the chrome
            // without the chrome and the pane ever competing for height in
            // the same stack.
            CanvasLoginPane(
                onConnected: { phase = .gradescopeLogin },
                onCancel: { phase = .name }
            )
            .environmentObject(state)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topBar(onBack: { phase = .name }, dots: 2)
                    canvasEscapeHatches
                }
                .background(Color.v2Bg)
            }
            .background(Color.v2Bg.ignoresSafeArea())
            .sheet(isPresented: $showPasteFeedLink) {
                // Advances the walk on a successful save, unlike the old
                // hub's no-op `onSaved` — the hub could afford to do nothing
                // because the checklist stayed on screen and the "Connect
                // Canvas" card just flipped to "connected" underneath the
                // closed sheet. There is no checklist to fall back on now:
                // without this, a student who pastes a working link would
                // close the sheet and land right back on the Canvas
                // WebView/tips card with no forward control in sight, since
                // `CanvasLoginPane.onConnected` only ever fires from an
                // actual WebView login.
                PasteFeedLinkSheet(onSaved: { phase = .gradescopeLogin })
                    .environmentObject(state)
            }
        }
    }

    /// Fallback path for anyone stuck on the in-app login (docs/CANVAS_LOGIN_HARDENING.md
    /// item 3b) — connects the dashboard without touching the WKWebView login
    /// at all. Kept as a plain-language, low-emphasis link (not a button next
    /// to "Connect Canvas") since the login flow is still the primary,
    /// richer path — this is explicitly the fallback.
    private var pasteFeedLinkLink: some View {
        Button {
            showPasteFeedLink = true
        } label: {
            Text("or paste your canvas calendar link instead")
                .font(.lhfSans(11, weight: .medium))
                .foregroundStyle(Color.v2DateText)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("paste your canvas calendar link instead of logging in")
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
                    Text("trouble connecting? reset login data")
                        .font(.lhfSans(11, weight: .medium))
                        .foregroundStyle(Color.v2SpineRed)
                        .underline()
                }
            }
            .buttonStyle(.plain)
            .disabled(isResettingLoginData)
            .accessibilityLabel("reset stored canvas and gradescope login data")
            .confirmationDialog(
                "Reset login data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("reset and start over", role: .destructive) {
                    didResetLoginData = false
                    isResettingLoginData = true
                    Task {
                        await state.resetAllLoginData()
                        isResettingLoginData = false
                        didResetLoginData = true
                    }
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text("clears any stuck canvas or gradescope login on this device, including saved session cookies, so you can start fresh. you'll need to log in again.")
            }

            if didResetLoginData {
                Text("login data cleared. try connect canvas again.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2SpineGreen)
            }
        }
    }

    /// Both Canvas escape hatches, stacked above the WebView so neither
    /// competes with the pane's own bottom action bar for the literal bottom
    /// of the screen.
    private var canvasEscapeHatches: some View {
        VStack(spacing: 8) {
            troubleConnectingLink
            pasteFeedLinkLink
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .padding(.horizontal, 24)
    }

    // MARK: - Step 3: Connect Gradescope (optional, skippable)

    @ViewBuilder
    private var gradescopeStep: some View {
        if state.isGradescopeConnected {
            connectedStep(
                step: 3,
                message: "gradescope is connected.",
                onBack: { phase = .canvasLogin },
                onContinue: { phase = .classPicker }
            )
        } else {
            // Same `safeAreaInset` treatment as `.canvasLogin` above, and for
            // the identical reason: `GradescopeLoginPane` is its own root
            // view with its own `Spacer()`s and bottom action bar, so a
            // `VStack` sibling on top of it collapses the WebView into a thin
            // band and leaves the top bar floating over empty background
            // instead of pinned to the top of the screen. See the comment at
            // `.canvasLogin` for the on-device symptom.
            GradescopeLoginPane(
                onConnected: { phase = .classPicker },
                onCancel: { phase = .canvasLogin }
            )
            .environmentObject(state)
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar(
                    onBack: { phase = .canvasLogin },
                    skip: (label: "skip for now", action: { phase = .classPicker }),
                    dots: 3
                )
                .background(Color.v2Bg)
            }
            .background(Color.v2Bg.ignoresSafeArea())
        }
    }

    // MARK: - Step 4: choose classes (optional, skippable)

    private var classesStep: some View {
        // Same `safeAreaInset` treatment as `.canvasLogin`/`.gradescopeLogin`
        // above: `ClassPickerPane` is its own root view (header, scrollable
        // list, "done" bar), so stacking the top bar above it as a `VStack`
        // sibling would squeeze its scroll area the same way it squeezed the
        // Canvas WebView.
        ClassPickerPane(onDone: { phase = .reminders })
            .environmentObject(state)
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar(
                    onBack: { phase = .gradescopeLogin },
                    skip: (label: "skip for now", action: { phase = .reminders }),
                    dots: 4
                )
                .background(Color.v2Bg)
            }
            .background(Color.v2Bg.ignoresSafeArea())
    }

    // MARK: - Step 5: set reminders (optional content, always reachable forward)

    /// The main reason this step exists at all: asking for notification
    /// permission here, after the student has already seen four screens'
    /// worth of "here's what this app is going to do for you," converts far
    /// better than the cold, first-launch ask most apps lead with — by the
    /// time this screen shows up there's something concrete to say yes to.
    ///
    /// Writes into `scheduler` exactly the way Settings → Reminders
    /// (`SettingsPage.remindersSection`) and Profile → Notifications
    /// (`ProfileNotificationsSection.leadTimeControls`) already do — the
    /// global `leadOffsets` set and the `digestEnabled`/`digestTime` pair —
    /// so nothing set here can ever disagree with what those two screens
    /// show later. There is no separate "onboarding reminder preference";
    /// there is only the one the rest of the app already reads.
    ///
    /// `LeadOffset` has no case for "the morning of," which briefs for this
    /// screen sometimes reach for as a third example alongside "the day
    /// before" and "two days before": every lead-time reminder fires at a
    /// fixed offset *before the due timestamp itself*
    /// (`NotificationScheduler.plannedRequests`), so it can land at any hour
    /// depending on when the assignment is actually due — there is no
    /// "always in the morning" variant to offer honestly. The one thing in
    /// this app that *does* have a fixed clock time is the daily digest
    /// (`digestSection` below), which is the real mechanism behind a
    /// "morning of" reminder — a single daily notification arriving at
    /// whatever hour the student picks. Rather than mislabel `.h1` as
    /// "morning of" to hit three example strings, this screen offers the
    /// real five `LeadOffset` cases as they're spelled everywhere else in
    /// the app, plus the digest's own time picker for the part of the ask
    /// that's genuinely about a time of day.
    private var remindersStep: some View {
        VStack(spacing: 0) {
            topBar(onBack: { phase = .classPicker })

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    remindersHeadline
                    leadTimeSection
                    digestSection
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
        VStack(alignment: .leading, spacing: 8) {
            Text("One heads-up before it\u{2019}s due.")
                .font(.lhfSerif(28))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("We\u{2019}ll remind you before things are due. Turn on notifications so it can actually reach you, then pick when you want the first nudge.")
                .font(.lhfSans(14))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var leadTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("remind me")
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(NotificationScheduler.LeadOffset.allCases) { offset in
                    leadTimePill(offset)
                }
            }

            Text("every class follows these times until you give it its own in profile.")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2CourseCode)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func leadTimePill(_ offset: NotificationScheduler.LeadOffset) -> some View {
        let isOn = scheduler.leadOffsets.contains(offset)
        return Button {
            lhfHapticLight()
            scheduler.setOffset(offset, on: !isOn)
        } label: {
            Text(offset.label)
                .font(.lhfSans(12, weight: .medium))
                .foregroundStyle(isOn ? Color.v2ToggleActiveTx : Color.v2Ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(isOn ? Color.v2Ink : Color.v2Ink.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("and when")
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)

            Toggle("also send a daily heads-up", isOn: Binding(
                get: { scheduler.digestEnabled },
                set: { scheduler.setDigestEnabled($0) }
            ))
            .font(.lhfSans(14, weight: .medium))
            .tint(Color.v2SpineGreen)

            if scheduler.digestEnabled {
                DatePicker("what time", selection: digestTimeBinding, displayedComponents: .hourAndMinute)
                    .font(.lhfSans(13))
            }
        }
    }

    /// Same shape as `SettingsPage.digestTimeBinding` — a `DateComponents`
    /// can't back a `DatePicker` directly, so this round-trips through
    /// today's date purely to get a `Date` the picker can bind to; only the
    /// hour/minute ever survive back into `scheduler`.
    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: scheduler.digestTime) ?? Date() },
            set: { scheduler.setDigestTime(Calendar.current.dateComponents([.hour, .minute], from: $0)) }
        )
    }

    /// Three ways off this screen, and each means something different:
    /// "turn on reminders" requests authorization (a no-op if already
    /// granted or denied — see below) and proceeds; "skip reminders for now"
    /// proceeds without ever requesting it, leaving `scheduler.isEnabled`
    /// however it already was; and — only when the per-course walk is about
    /// to open — `skipCourseSetupLink` bypasses that walk too. The first two
    /// converge on the exact same `finishOnboarding()`, because whether
    /// notifications got turned on has nothing to do with whether the walk
    /// comes next.
    ///
    /// Denial is never treated as an error here. `requestAuthorization`
    /// (inside `scheduler.setEnabled`) resolves immediately either way —
    /// granted, denied, or already-decided — and this screen proceeds on
    /// every outcome. Blocking onboarding on a permission the student is
    /// entitled to refuse would be the actual bug.
    private var remindersFooter: some View {
        VStack(spacing: 10) {
            progressDots(current: 5)

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

            if shouldOfferCourseSetup {
                skipCourseSetupLink
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    /// The one-tap way past the per-course walk, on the same screen as the
    /// button ("turn on reminders") that can lead into it — moved here from
    /// the old hub, where it sat under the same button for the same reason.
    /// See `finishOnboarding()`: the walk it's skipping is entered from
    /// there, never from this link directly.
    ///
    /// Marks the step completed on the way out, so a student who declines it
    /// here is not asked again the next time a Settings reconnect drops them
    /// back on this walk. Declining costs them nothing — every class keeps
    /// `CoursePreferences`' defaults, which is reminders on and lead times
    /// following the global setting.
    private var skipCourseSetupLink: some View {
        Button {
            OnboardingCourseSetup.markCompleted()
            state.completeOnboarding()
        } label: {
            Text("skip class setup too. go to dashboard")
                .font(.lhfSans(12, weight: .medium))
                .foregroundStyle(Color.v2DateText)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("skip class setup and go to the dashboard")
        .accessibilityHint("every class keeps its default reminders")
    }

    // MARK: - Shared chrome

    /// Back chevron, an optional "skip" for the steps that allow one, and —
    /// only for the three steps whose screen is a full-bleed pane this file
    /// must not edit (`CanvasLoginPane`, `GradescopeLoginPane`,
    /// `ClassPickerPane` each already own their own bottom action bar) — the
    /// progress dots too, since there's no bottom left on those screens to
    /// put dots in. Steps 1 and 5, the two screens this file builds from
    /// scratch, put the dots in their own footer next to the primary button
    /// instead, matching `IntroView`'s footer — see `nameStep`/`remindersFooter`.
    /// Passing `nil` for `dots` (Reminders' case, which has its own footer
    /// dots) omits them here rather than showing two progress indicators on
    /// one screen.
    private func topBar(
        onBack: (() -> Void)?,
        skip: (label: String, action: () -> Void)? = nil,
        dots step: Int? = nil
    ) -> some View {
        HStack {
            backButton(onBack)
                .frame(width: 44, height: 32, alignment: .leading)
            Spacer(minLength: 8)
            if let step {
                progressDots(current: step)
            }
            Spacer(minLength: 8)
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

    /// Five dots, filled in green up to the current step — the same
    /// vocabulary `IntroView.dots` uses, just re-tinted: `IntroView` marks
    /// its current page in ink, this walk marks it in `v2SpineGreen`, the
    /// app's one accent color, to read as progress made rather than merely
    /// "which page."
    private func progressDots(current: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(1...5, id: \.self) { index in
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
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            topBar(onBack: onBack, dots: step)

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

            Button(action: onContinue) {
                Text("continue")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg.ignoresSafeArea())
    }
}

// MARK: - Login chrome (shared)

/// The bottom action bar under the login WebView. Stacks the hint above the
/// buttons so it never crowds on a narrow phone screen.
///
/// Carries explicit "Reload" and "Start over" controls (docs/CANVAS_LOGIN_DIAGNOSIS.md
/// item 1a): the login WebView disables swipe back/forward navigation, since
/// swiping back onto an already-consumed login form and resubmitting it is
/// exactly what produces Shibboleth's "Stale Request" — with no chrome and no
/// way forward. These two buttons are the replacement escape hatch: Reload
/// re-requests the current page; Start over purges this login's cookies/cache
/// again and reloads the login page from scratch, without leaving the pane.
private struct LoginActionBar: View {
    let message: String?
    let defaultHint: String
    let connectTitle: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onConnect: () -> Void
    let onReload: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message ?? defaultHint)
                .font(.lhfSans(12))
                .foregroundStyle(message == nil ? Color.v2DateText : Color.v2SpineRed)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button("reload", action: onReload)
                    .buttonStyle(.plain)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .disabled(isBusy)
                    .accessibilityHint("reloads the current login page")

                Button("start over", action: onStartOver)
                    .buttonStyle(.plain)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .disabled(isBusy)
                    .accessibilityHint("clears this login's cookies and loads a fresh sign-in page")
            }

            HStack(spacing: 12) {
                Button("cancel", action: onCancel)
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

/// Plain-language card shown in place of the WebView when
/// `LoginNavigationObserver` detects a known IdP/Shibboleth error page
/// (docs/CANVAS_LOGIN_DIAGNOSIS.md item 3a). User-initiated recovery only —
/// this never appears as a result of automatic retry logic, and tapping a
/// button here is the only way it goes away.
/// Full-pane notice shown before the Canvas sign-in page loads (see
/// `CanvasLoginPane.showsSignInTips` for why it exists). Same visual family
/// as `LoginErrorCard`, but it fills the pane rather than banner-ing above a
/// WebView — there's nothing behind it yet worth showing.
private struct CanvasSignInTipsCard: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hourglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.v2Ink)
            Text("One thing before you sign in")
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
            Text("Penn\u{2019}s sign-in can pause for up to half a minute after you enter your password. That\u{2019}s normal \u{2014} the screen isn\u{2019}t stuck. Press the sign-in button once and wait; pressing it again is what causes Penn\u{2019}s \u{201C}Stale Request\u{201D} error.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button(action: onContinue) {
                Text("Got it")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoginErrorCard: View {
    let title: String
    let message: String
    let onStartOver: () -> Void
    /// Canvas only — Gradescope has no equivalent feed-link fallback.
    let onUseCalendarLinkInstead: (() -> Void)?
    /// Canvas only, for now — offered when someone's hit the error card
    /// repeatedly and just wants to hand off diagnostics rather than keep
    /// retrying. `nil` hides the action entirely.
    var onReportProblem: (() -> Void)? = nil

    var body: some View {
        // No Spacers and no maxHeight cap here or at the call sites: the
        // card must hug its content. A fixed-height cap already clipped the
        // last action ("Report a problem") clean off the screen once — an
        // invisible action is worse than a taller card.
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.v2SpineRed)
            Text(title)
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button(action: onStartOver) {
                Text("start over")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)

            if let onUseCalendarLinkInstead {
                Button(action: onUseCalendarLinkInstead) {
                    Text("use calendar link instead")
                        .font(.lhfSans(12, weight: .medium))
                        .foregroundStyle(Color.v2DateText)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            if let onReportProblem {
                Button(action: onReportProblem) {
                    Text("Report a problem")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DateText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
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
    /// True while the pre-login purge (docs/CANVAS_LOGIN_DIAGNOSIS.md item 1c)
    /// is running. The WebView isn't created until this clears, so the purge
    /// always finishes before the first request goes out — never mid-navigation.
    @State private var isPurging = true
    /// Bumping this re-runs the purge-and-load `.task` below ("Start over").
    @State private var purgeGeneration = UUID()
    /// True only for this pane appearance's FIRST attempt. Measured on
    /// device (2026-08-22): during a Penn IdP bad spell the app went 0/8
    /// while Private Safari went 3/4 in the same minutes — Safari fails its
    /// first genuinely-cold handshake too, but recovers on retry because
    /// the failed attempt's IdP cookies survive into the next one. Purging
    /// on every "Start over" forced this app to be permanently
    /// first-contact. So: purge once per pane appearance (a fresh Connect
    /// still starts clean), and let retries keep the cookies exactly like
    /// Safari's retry does.
    @State private var purgeOnNextAttempt = true
    /// Bumping this tells the live WebView to call `.reload()` ("Reload").
    @State private var reloadTick = 0
    /// Observe-only navigation delegate (docs/CANVAS_LOGIN_DIAGNOSIS.md item
    /// 3a) — surfaces load errors and known IdP error pages; never steers
    /// navigation itself.
    @StateObject private var navObserver = LoginNavigationObserver()
    @State private var showPasteFeedLink = false
    /// Shown once per pane appearance, BEFORE the sign-in page: Penn's IdP
    /// can pause noticeably after the password is submitted, and an
    /// impatient second tap is what mints its "Stale Request" error (the
    /// duplicate-POST guard in `LoginNavigationObserver` catches the
    /// machine-made repeats; this card heads off the human-made one). The
    /// purge keeps running behind this card, so dismissing it is usually
    /// instant.
    @State private var showsSignInTips = true

    private var isBusy: Bool {
        isReadingCookies || state.isCanvasDiscoveryLoading || state.isLoading || isPurging
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsSignInTips {
                // Told to fill, not left at its intrinsic height. Without
                // this the whole pane collapses to card + divider + action
                // bar, SwiftUI centres that stack vertically, and the result
                // on device is a tips card floating in the middle of an empty
                // screen with the step's back chevron and progress dots
                // stranded a third of the way down beside it. Layout only —
                // nothing here touches the login, cookie or navigation
                // handling.
                CanvasSignInTipsCard(onContinue: { showsSignInTips = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isPurging {
                Spacer()
                ProgressView("Preparing a clean sign-in…")
                    .font(.lhfSans(12))
                Spacer()
            } else {
                // The WebView stays mounted even when a known error page has
                // been detected — a single detection (or a stale one from an
                // intermediate SSO hop) must never be the thing that makes
                // login impossible. The card becomes a non-blocking banner
                // above the still-live WebView instead of replacing it.
                VStack(spacing: 0) {
                    if navObserver.detectedKnownErrorPage {
                        LoginErrorCard(
                            title: "Canvas login hit a snag",
                            message: "Penn's sign-in page reported an error partway through, but login may still work — it's worth continuing below. If it doesn't, Start over or the calendar link are still available.",
                            onStartOver: startOver,
                            onUseCalendarLinkInstead: { showPasteFeedLink = true },
                            onReportProblem: {
                                SupportContact.openReportMail(diagnostics: DiagnosticsReport.generate(state: state))
                            }
                        )

                        Divider().overlay(Color.v2Divider)
                    }

                    LoginWebView(
                        url: URL(string: "https://canvas.upenn.edu")!,
                        store: LoginDataStores.canvas,
                        reloadTick: reloadTick,
                        navigationObserver: navObserver
                    )
                }
                // `LoginWebView` is a UIViewRepresentable and reports no
                // intrinsic size, so in a VStack that isn't told to fill it
                // is handed almost no height and renders as a thin band with
                // empty background above it. This is what gives the WebView
                // the whole area between the step chrome and the action bar.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Color.v2Divider)

            LoginActionBar(
                message: message ?? navObserver.loadError,
                defaultHint: "Log in to Canvas once. We'll capture your calendar feed automatically.",
                connectTitle: "Connect Canvas",
                isBusy: isBusy,
                onCancel: onCancel,
                onConnect: connect,
                onReload: { reloadTick += 1 },
                onStartOver: startOver
            )
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .sheet(isPresented: $showPasteFeedLink) {
            PasteFeedLinkSheet(onSaved: onConnected).environmentObject(state)
        }
        .task(id: purgeGeneration) {
            // Fires exactly once per Connect tap (this view's own appearance,
            // or a "Start over" tap), before the WebView is ever created —
            // never re-entrant with an in-flight login navigation. Targets
            // Canvas's own isolated store (docs/CANVAS_LOGIN_DIAGNOSIS.md
            // item 2a), not the shared `.default()` store. Purges only on
            // the first attempt of this pane appearance — see
            // `purgeOnNextAttempt` for the on-device evidence.
            if purgeOnNextAttempt {
                await WebsiteDataReset.purgeWebsiteData(
                    matchingDomainContains: AppState.canvasLoginDomainHints,
                    in: LoginDataStores.canvas
                )
                purgeOnNextAttempt = false
            }
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
        .onAppear { state.isCanvasLoginPaneActive = true }
        .onDisappear { state.isCanvasLoginPaneActive = false }
#if os(macOS)
        .frame(minWidth: 860, minHeight: 620)
#endif
    }

    /// Tears down the WebView and loads a fresh sign-in page from the top of
    /// the chain, without leaving the pane — the recovery path now that the
    /// WebView no longer allows a back-swipe onto a consumed login form.
    /// Deliberately does NOT purge cookies anymore (`purgeOnNextAttempt`
    /// stays false): a retry that keeps the failed attempt's IdP cookies is
    /// exactly how Safari recovers from the same "Stale Request" page.
    private func startOver() {
        message = nil
        navObserver.reset()
        isPurging = true
        purgeGeneration = UUID()
    }

    private func connect() {
        isReadingCookies = true
        message = nil
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
    /// See `CanvasLoginPane`'s matching properties for why these exist —
    /// same pre-login purge / reload / start-over treatment, item-for-item.
    @State private var isPurging = true
    @State private var purgeGeneration = UUID()
    @State private var reloadTick = 0
    @StateObject private var navObserver = LoginNavigationObserver()

    private var isBusy: Bool { isReadingCookies || state.isGradescopeLoading || isPurging }

    private static let gradescopeLoginDomainHints = ["gradescope"]

    var body: some View {
        VStack(spacing: 0) {
            if isPurging {
                Spacer()
                ProgressView("Preparing a clean sign-in…")
                    .font(.lhfSans(12))
                Spacer()
            } else {
                // The WebView stays mounted even when a known error page has
                // been detected — a single detection (or a stale one from an
                // intermediate SSO hop) must never be the thing that makes
                // login impossible. The card becomes a non-blocking banner
                // above the still-live WebView instead of replacing it.
                VStack(spacing: 0) {
                    if navObserver.detectedKnownErrorPage {
                        LoginErrorCard(
                            title: "Gradescope login hit a snag",
                            message: "The sign-in page reported an error partway through, but login may still work — it's worth continuing below. If it doesn't, Start over is still available.",
                            onStartOver: startOver,
                            onUseCalendarLinkInstead: nil
                        )

                        Divider().overlay(Color.v2Divider)
                    }

                    LoginWebView(
                        url: URL(string: "https://www.gradescope.com/login")!,
                        store: LoginDataStores.gradescope,
                        reloadTick: reloadTick,
                        navigationObserver: navObserver
                    )
                }
                // Same reason as the Canvas pane: `LoginWebView` has no
                // intrinsic size, so without an explicit fill it collapses to
                // a thin band under a screenful of empty background.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Color.v2Divider)

            LoginActionBar(
                message: message ?? navObserver.loadError,
                defaultHint: "Log in to Gradescope once. We'll keep it in sync while your session is valid.",
                connectTitle: "Connect Gradescope",
                isBusy: isBusy,
                onCancel: onCancel,
                onConnect: connect,
                onReload: { reloadTick += 1 },
                onStartOver: startOver
            )
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .task(id: purgeGeneration) {
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

    private func startOver() {
        message = nil
        navObserver.reset()
        isPurging = true
        purgeGeneration = UUID()
    }

    private func connect() {
        isReadingCookies = true
        message = nil
        // Same store the WebView above uses — see `LoginDataStores`' doc comment.
        LoginDataStores.gradescope.httpCookieStore.getAllCookies { cookies in
            let gradescopeCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("gradescope") }
            SessionCookieStore.save(gradescopeCookies, service: .gradescope)
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
                Text("your classes")
                    .font(.lhfSerif(26))
                    .foregroundStyle(Color.v2Ink)
                Text("turn off any class you don't want on your dashboard or in reminders.")
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
                Text("done")
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

/// Tracks the last `reloadTick` this representable acted on, so
/// `update{UI,NS}View` can tell "the pane's Reload button was tapped again"
/// apart from an unrelated SwiftUI re-render.
private final class LoginWebViewCoordinator {
    var lastReloadTick = 0
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    let reloadTick: Int
    let navigationObserver: LoginNavigationObserver

    func makeCoordinator() -> LoginWebViewCoordinator { LoginWebViewCoordinator() }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.lastReloadTick = reloadTick
        return makeWebView(url: url, store: store, navigationObserver: navigationObserver)
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard reloadTick != context.coordinator.lastReloadTick else { return }
        context.coordinator.lastReloadTick = reloadTick
        nsView.reload()
    }
}
#else
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    let reloadTick: Int
    let navigationObserver: LoginNavigationObserver

    func makeCoordinator() -> LoginWebViewCoordinator { LoginWebViewCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.lastReloadTick = reloadTick
        return makeWebView(url: url, store: store, navigationObserver: navigationObserver)
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard reloadTick != context.coordinator.lastReloadTick else { return }
        context.coordinator.lastReloadTick = reloadTick
        uiView.reload()
    }
}
#endif

/// Shared WKWebView setup used by both platform representables. WKWebView and
/// its default cookie store exist on iOS and macOS alike.
///
/// The pre-login cookie/cache purge (docs/CANVAS_LOGIN_DIAGNOSIS.md item 1c)
/// happens BEFORE this function is ever called — in the owning pane's
/// `.task(id: purgeGeneration)`, which gates whether the WebView is created
/// at all (`isPurging`). That guarantees it runs exactly once per Connect tap
/// (or "Start over" tap) and can never race an in-flight navigation the way a
/// purge-then-load `Task` fired from inside `makeWebView` itself could.
///
/// Two further hardening pieces (docs/CANVAS_LOGIN_DIAGNOSIS.md items 1a/1d):
/// - `allowsBackForwardNavigationGestures = false` — a full-bleed login pane
///   has no chrome, so swiping back onto an already-consumed login form and
///   resubmitting it is indistinguishable from a real tap, and produces
///   exactly Shibboleth's "Stale Request" with no way forward. The pane's
///   explicit Reload/"Start over" controls are the replacement.
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
