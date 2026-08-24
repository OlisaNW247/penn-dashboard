import SwiftUI
import LowHangingFruitKit

// MARK: - The step's own gate

/// The rules deciding whether the per-course walk runs, where its suggestions
/// come from, and what a skip leaves behind.
///
/// **Why this is a namespace and not three properties on `AppState`.** Every
/// v4 workstream wants `AppState`, and `docs/v4-plan.md` names it as the
/// bottleneck that made v3's parallel experiment collapse. The walk needs
/// exactly one piece of new persisted state — "has this student been offered
/// the per-course step yet" — and that is a single `UserDefaults` key with a
/// derivation rule attached. Putting the key and its rule here rather than on
/// `AppState` costs nothing and keeps this whole feature inside two files.
///
/// Everything else the walk needs already exists on `AppState`
/// (`scanCanvasRequirements`, `canvasRequirementSuggestions`,
/// `addCanvasSuggestion`, `dismissCanvasSuggestion`, `coursePreferences`), so
/// nothing here duplicates state that lives there.
enum OnboardingCourseSetup {

    /// Whether the student has already been through — or deliberately past —
    /// the per-course step.
    ///
    /// Deliberately *not* `hasCompletedOnboarding`. The Settings reconnect rows
    /// call `AppState.restartOnboarding()`, which clears that flag to put the
    /// student back on the connect checklist. `IntroFlowTests` pins down why the
    /// intro keeps its own `hasSeenIntro` flag rather than sharing that one: a
    /// student who only wanted to reconnect Canvas must not be handed the
    /// product pitch again. A four-screen walk through every class they are
    /// taking is the same imposition wearing a different hat, so it gets the
    /// same treatment — its own key, which `restartOnboarding()` does not touch
    /// and, because it lives out here rather than on `AppState`, *cannot* touch
    /// by accident.
    static let completedKey = "hasCompletedCourseSetup"

    /// Read directly rather than through `AppState` so `needsCourseSetup` stays
    /// a pure function of stored values and can be tested without building one.
    /// Same key `AppState.completeOnboarding()` writes.
    static let onboardingCompletedKey = "hasCompletedOnboarding"

    /// Whether the checklist's primary action should route into the walk.
    ///
    /// Three cases, and the third is the one worth explaining:
    ///
    /// - Key present: it answers the question, and it is only ever written by a
    ///   student finishing or skipping the step.
    /// - Key absent, onboarding not finished: a genuine first run. Offer it.
    /// - **Key absent, onboarding already finished**: someone who installed an
    ///   earlier build and has been using the app for weeks. This step did not
    ///   exist when they onboarded, and while they are simply using the app it
    ///   correctly reads as settled.
    ///
    /// **The limit of that third case, stated plainly.** `restartOnboarding()`
    /// clears `hasCompletedOnboarding` on its way to the checklist, so on that
    /// screen the derivation flips and an upgrading student *is* offered the
    /// step. The intro avoids the equivalent by latching in `AppState.init`,
    /// before any Settings tap can move the input; this step has no such hook,
    /// since `AppState` belongs to another workstream.
    ///
    /// That is a deliberate acceptance rather than a gap. An existing student
    /// with six classes has never once been asked how each should reach them,
    /// so being offered it is a feature; being asked *again on every reconnect*
    /// would not be. The "at most once" guarantee that matters is structural:
    /// the offer is the checklist's primary button, and both ways out of it
    /// write this key — the walk marks on finish or skip, and the "Skip for
    /// now" link beside it marks before completing onboarding. There is no
    /// third exit, so an answered offer cannot come back.
    ///
    /// Derived rather than backfilled-by-writing on purpose: a read that
    /// silently mutates storage would have to pick a moment to latch, and every
    /// moment available to this file is already after `restartOnboarding()` has
    /// moved the input — so it would buy nothing and cost testability.
    static func needsCourseSetup(in defaults: UserDefaults = .lhf) -> Bool {
        if defaults.object(forKey: completedKey) != nil {
            return !defaults.bool(forKey: completedKey)
        }
        return !defaults.bool(forKey: onboardingCompletedKey)
    }

    /// Records that the student has been through the step — **whether they
    /// configured every class or skipped the whole thing on the first screen.**
    ///
    /// Skipping counts. The alternative is a step that reappears every time the
    /// student reconnects Canvas until they submit to it, which is a worse
    /// product than not shipping the step at all. Skipping leaves every course
    /// on `CoursePreferences`' defaults — reminders on, lead times inheriting
    /// the global, recurring items on — because a skip writes no record, and no
    /// record *is* the defaults (see `CoursePreferences.isDefault` and the
    /// pruning in `CoursePreferencesStore.commit`).
    static func markCompleted(in defaults: UserDefaults = .lhf) {
        defaults.set(true, forKey: completedKey)
    }

    // MARK: Where suggestions come from

    /// How this run of the walk should populate its suggestions.
    ///
    /// This exists as a value, computed by a pure function, for one reason: it
    /// is the seam a test can hold to assert that **preview mode never reaches
    /// the network**. `swift test` does not render SwiftUI, so a decision buried
    /// in a `.task` closure is a decision nothing can check — and the last time
    /// something in this area went wrong it stranded App Store reviewers at the
    /// login wall (commit `c999c38`), which is not a bug worth rediscovering.
    enum SuggestionPlan: Equatable {
        /// Preview/demo. Bundled fixtures, no `URLSession`, no cookies read.
        case fixtures
        /// A real account with a live Canvas session. Run the scanner.
        case scan
        /// A real account with no usable session — a student who pasted their
        /// calendar feed link instead of logging in
        /// (docs/CANVAS_LOGIN_HARDENING.md item 3b) never had cookies to begin
        /// with, and must not be nagged about a scan that was never available
        /// to them. The walk still runs; it just has nothing to suggest.
        case noSession
    }

    /// `isUsingFixtureData` is checked **first and unconditionally**, so no
    /// combination of the other inputs can route a demo run into `.scan`. The
    /// ordering is the guarantee; `previewNeverScans` in the tests is what keeps
    /// it that way.
    static func suggestionPlan(
        isUsingFixtureData: Bool,
        hasCanvasSession: Bool
    ) -> SuggestionPlan {
        if isUsingFixtureData { return .fixtures }
        return hasCanvasSession ? .scan : .noSession
    }

    /// Demo suggestions, shaped exactly like real scanner output — same type,
    /// same fields, same `evidence` sentence the UI quotes back.
    ///
    /// Held here rather than in `SampleData` because `SampleData` is shared
    /// ground several workstreams are editing, and because these fixtures are
    /// meaningless outside this screen. They are keyed by position rather than
    /// by course code so the demo shows the three states a reviewer needs to
    /// see — a course with two findings, a course with one, and a course with
    /// none — no matter which fixture courses preview mode happens to seed.
    static func previewSuggestions(for courses: [String]) -> [CanvasRequirementSuggestion] {
        guard !courses.isEmpty else { return [] }

        var result: [CanvasRequirementSuggestion] = []

        if let first = courses.first {
            result.append(CanvasRequirementSuggestion(
                course: first,
                title: "Weekly discussion post",
                weekday: 5,
                hour: 23,
                minute: 59,
                source: .syllabus,
                evidence: "Each week you must post a response to the discussion prompt by Thursday at 11:59pm"
            ))
            result.append(CanvasRequirementSuggestion(
                course: first,
                title: "Weekly reading response",
                weekday: 2,
                hour: 10,
                minute: 0,
                source: .announcement,
                evidence: "A short reading response is required before class every Monday at 10am"
            ))
        }

        if courses.count > 1 {
            result.append(CanvasRequirementSuggestion(
                course: courses[1],
                title: "Weekly reflection",
                weekday: 1,
                hour: 20,
                minute: 0,
                source: .syllabus,
                evidence: "Students should submit a weekly reflection journal by Sunday 8pm"
            ))
        }

        // Every remaining course is left deliberately empty. "No recurring
        // requirements found" is the ordinary case in week one — the scanner
        // reads a syllabus that may not be posted yet — and the demo showing
        // only the happy path would misrepresent what a real student sees.
        return result
    }
}

// MARK: - The walk

/// The per-course setup step: one screen per class, offering whatever
/// `CanvasRequirementScanner` turned up for it and that class's own reminder
/// settings.
///
/// **What this screen is actually for.** The scanner, `RecurringTask`, and
/// `AppState.addCanvasSuggestion` have all existed and been tested since v3, and
/// were reachable from exactly one place: Settings → Tasks, behind a gear icon,
/// which no new student opens. So the app has always been able to notice "a
/// weekly discussion post, due Thursdays" in a syllabus and has essentially
/// never been asked to. This screen is the wiring, not the machinery.
///
/// **Why it can be abandoned at every single point.** It runs before the
/// student has seen the dashboard do one useful thing. Anything mandatory here
/// is bargaining with someone who has no reason yet to believe the bargain is
/// worth it, and a six-class wizard standing between a stranger and the thing
/// they installed the app for is how onboarding gets abandoned. So: "Skip
/// setup" sits in the header on every screen, "Not now" advances without
/// writing anything, and the primary button is never disabled — not while the
/// scan is running, not when it failed, not when it found nothing. Skipping
/// costs the student nothing, because `CoursePreferences`' defaults are already
/// the sensible answer (reminders on, lead times inheriting the global setting,
/// recurring items on) and a skip simply writes no record.
///
/// **Why nothing is written on appear.** Every control below binds
/// *through* `CoursePreferencesStore` — read on get, write on set — so a course
/// the student looks at and leaves alone never acquires a record. That is not
/// tidiness: `leadOffsets` is optional precisely so a course can keep inheriting
/// the global setting, and seeding it with a copy of the global on render would
/// silently freeze every class the student walked past onto today's value and
/// make the global control in Settings a no-op forever. `CoursePreferences`'
/// own doc comment spells that trap out; this screen is the one most likely to
/// step in it, since it renders a control for every class at once.
struct OnboardingCourseSetupPane: View {
    @EnvironmentObject private var state: AppState

    /// Called when the student leaves the walk by any route — finishing the
    /// last class, or skipping from any screen. The checklist marks the step
    /// completed and takes it from there.
    let onFinish: () -> Void

    /// The classes to walk, captured once on appear.
    ///
    /// Snapshotted rather than recomputed per render because `selectedCourseCodes()`
    /// is derived from feed items, and a background sync landing mid-walk would
    /// otherwise renumber "Class 2 of 4" under the student's finger, or move the
    /// screen they are on to a different class.
    @State private var courses: [String] = []
    @State private var index = 0

    @State private var scan: ScanState = .idle
    /// Set when the scan has been running long enough that the student deserves
    /// to be told they do not have to wait for it.
    @State private var scanIsSlow = false

    /// The suggestions this screen displays, held locally rather than read from
    /// `state.canvasRequirementSuggestions` on each render.
    ///
    /// `addCanvasSuggestion` removes the accepted suggestion from that published
    /// array, so binding rows to it directly would make a row vanish the instant
    /// it was tapped — no confirmation, and the list jumping under a finger
    /// mid-decision. A local copy lets an accepted row stay put and say
    /// "Added", which is also what makes accepting two of three suggestions
    /// feel like a decision rather than a disappearing act.
    @State private var suggestions: [CanvasRequirementSuggestion] = []
    @State private var decisions: [String: Decision] = [:]

    private enum Decision { case added, skipped }

    private enum ScanState: Equatable {
        case idle
        case scanning
        /// Finished cleanly. May still have found nothing, which is normal.
        case finished
        /// The scan could not run or did not come back. Carries the plain-language
        /// reason; never an error dump, and never presented as the student's
        /// problem to fix right now.
        case unavailable(String)
    }

    private var course: String { index < courses.count ? courses[index] : "" }
    private var isLastCourse: Bool { index >= courses.count - 1 }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 12) {
                    courseCard
                    suggestionsSection
                    remindersSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }

            Divider().overlay(Color.v2Divider)

            footer
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .task { await start() }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
#endif
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text(courses.isEmpty ? "Set up your classes" : "Class \(index + 1) of \(courses.count)")
                    .font(.lhfSans(11, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(Color.v2CourseCode)

                Spacer(minLength: 10)

                // On every screen, not just the first. A student who set up two
                // classes and lost patience on the third should not have to
                // press Next twice more to escape — and the two they did set up
                // are already saved, since every control writes as it is
                // touched rather than on some final commit.
                Button(action: finish) {
                    Text("Skip setup")
                        .font(.lhfSans(12, weight: .semibold))
                        .foregroundStyle(Color.v2DateText)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip class setup")
                .accessibilityHint("Goes to your dashboard. Every class keeps its default reminders.")
            }

            // A plain proportion rather than a step-by-step dot row: a student
            // with seven classes gets seven dots that all look the same, where
            // a bar answers the only question being asked of it ("how much of
            // this is left").
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.v2RingTrack)
                    Capsule()
                        .fill(Color.v2Ink)
                        .frame(width: geo.size.width * progressFraction)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var progressFraction: CGFloat {
        guard !courses.isEmpty else { return 0 }
        return CGFloat(index + 1) / CGFloat(courses.count)
    }

    // MARK: The class

    private var courseCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.courseDisplayName(course))
                .font(.lhfSerif(26))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("How should this class reach you?")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    // MARK: What the scan found

    private var courseSuggestions: [CanvasRequirementSuggestion] {
        suggestions.filter { $0.course == course }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        sectionCard(title: "RECURRING WORK") {
            switch scan {
            case .idle, .scanning:
                scanningRow

            case .unavailable(let reason):
                // Deliberately not styled as an error. A scan that could not
                // run is a missing convenience, not a broken app, and the
                // student can still set reminders on this screen and add
                // recurring items later from Settings → Tasks.
                explanatoryRow(
                    symbol: "text.magnifyingglass",
                    text: reason
                )

            case .finished:
                if courseSuggestions.isEmpty {
                    // The ordinary week-one outcome, not a failure: the class
                    // list comes from the calendar feed, so a course can be
                    // real and present here while its syllabus page is still
                    // empty. Saying so plainly is what stops it reading as
                    // "the app didn't work".
                    explanatoryRow(
                        symbol: "checkmark.circle",
                        text: "Nothing recurring found in this class's syllabus or announcements yet. If your professor posts a weekly reading later, you can add it any time."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(courseSuggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }
            }
        }
    }

    private var scanningRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading this class's syllabus and announcements…")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if scanIsSlow {
                // The footer's Next button was never disabled, but a spinner
                // reads as "wait", so after a while we say outright that it
                // isn't one. Anything the scan finds after the student has
                // moved on is still theirs — it lands in
                // `state.canvasRequirementSuggestions` and stays reachable
                // from Settings → Tasks.
                Text("Canvas is taking its time. You don't have to wait — carry on, and anything it finds will be waiting in Settings → Tasks.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2CourseCode)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explanatoryRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.v2CourseCode)
                .padding(.top, 1)
            Text(text)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One suggestion, with the sentence it came from.
    ///
    /// The `evidence` line is the whole reason this is a decision the student
    /// can make rather than something the app does silently. The scanner is a
    /// keyword matcher over syllabus prose — it is right often enough to be
    /// worth offering and wrong often enough that acting on it unasked would
    /// put invented weekly homework on someone's dashboard. Quoting the
    /// sentence turns "trust us" into a judgement the only person who can
    /// actually make it gets to make in about a second.
    private func suggestionRow(_ suggestion: CanvasRequirementSuggestion) -> some View {
        let decision = decisions[suggestion.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.lhfSans(14, weight: .semibold))
                        .foregroundStyle(Color.v2Ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.scheduleLabel(for: suggestion))
                        .font(.lhfSans(12))
                        .foregroundStyle(Color.v2DateText)
                }
                Spacer(minLength: 8)
                Text(suggestion.source.rawValue)
                    .font(.lhfSans(9, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Color.v2CourseCode)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("“\(suggestion.evidence)”")
                .font(.lhfSans(11))
                .italic()
                .foregroundStyle(Color.v2CourseCode)
                .fixedSize(horizontal: false, vertical: true)

            switch decision {
            case .added:
                decisionBadge(symbol: "checkmark", text: "Added to your dashboard", tint: Color.v2SpineGreen)
            case .skipped:
                decisionBadge(symbol: "xmark", text: "Skipped", tint: Color.v2CourseCode)
            case nil:
                HStack(spacing: 10) {
                    Button {
                        lhfHapticLight()
                        state.addCanvasSuggestion(suggestion)
                        decisions[suggestion.id] = .added
                    } label: {
                        Text("Add it")
                            .font(.lhfSans(12, weight: .semibold))
                            .foregroundStyle(Color.v2ToggleActiveTx)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.v2Ink))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(suggestion.title) for \(course)")
                    .accessibilityHint(Self.scheduleLabel(for: suggestion))

                    Button {
                        state.dismissCanvasSuggestion(suggestion)
                        decisions[suggestion.id] = .skipped
                    } label: {
                        Text("Not this one")
                            .font(.lhfSans(12, weight: .medium))
                            .foregroundStyle(Color.v2DateText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.v2Ink.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip \(suggestion.title) for \(course)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.v2Bg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func decisionBadge(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.lhfSans(12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Thursdays at 11:59 PM" — the rule `RecurringTask` will generate
    /// occurrences from, said the way a person would say it.
    static func scheduleLabel(for suggestion: CanvasRequirementSuggestion) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale.current
        // `weekday` is Foundation's 1-based Sunday-first index, matching what
        // `RecurringTask` feeds `DateComponents`; the symbol array is 0-based.
        let symbols = calendar.weekdaySymbols
        let dayIndex = suggestion.weekday - 1
        let day = symbols.indices.contains(dayIndex) ? symbols[dayIndex] : "Sunday"

        var components = DateComponents()
        components.hour = suggestion.hour
        components.minute = suggestion.minute
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = calendar.date(from: components).map { formatter.string(from: $0) }
            ?? String(format: "%02d:%02d", suggestion.hour, suggestion.minute)

        return "\(day)s at \(time)"
    }

    // MARK: This class's reminders

    private var prefs: CoursePreferences {
        state.coursePreferences.preferences(for: course)
    }

    private var remindersSection: some View {
        sectionCard(title: "REMINDERS") {
            VStack(spacing: 14) {
                Toggle(isOn: Binding(
                    get: { prefs.notificationsEnabled },
                    set: { state.coursePreferences.setNotificationsEnabled(course, $0) }
                )) {
                    settingLabel(
                        "Remind me about this class",
                        detail: "Turn this off to keep the class on your dashboard but stop its notifications."
                    )
                }
                .toggleStyle(.switch)
                .tint(Color.v2SpineGreen)

                if prefs.notificationsEnabled {
                    Divider().overlay(Color.v2Divider)
                    leadTimeControl
                    Divider().overlay(Color.v2Divider)

                    Toggle(isOn: Binding(
                        get: { prefs.recurringEnabled },
                        set: { state.coursePreferences.setRecurringEnabled(course, $0) }
                    )) {
                        settingLabel(
                            "Readings and check-ins",
                            detail: "Recurring work like the items above. Separate from assignments, because “keep telling me about assignments, stop telling me about the weekly reading” is a real request."
                        )
                    }
                    .toggleStyle(.switch)
                    .tint(Color.v2SpineGreen)
                }
            }
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.lhfSans(14, weight: .medium))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2CourseCode)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Lead times, with "inherit" as a first-class choice rather than an
    /// absence.
    ///
    /// `CoursePreferences.leadOffsets` is optional, and `nil` (inherit the
    /// global) is genuinely different from `[]` (this class explicitly gets no
    /// lead-time reminders). Both round-trip through storage; both are things a
    /// student might mean. A control that only offered a set of chips could not
    /// express the first — the moment it wrote anything, the class would stop
    /// tracking the global setting forever, which is the exact failure that
    /// property's doc comment warns about. So the choice is made explicitly
    /// first, and only then are there chips.
    private var leadTimeControl: some View {
        let isCustom = prefs.leadOffsets != nil

        return VStack(alignment: .leading, spacing: 10) {
            settingLabel(
                "When to remind me",
                detail: isCustom
                    ? "Just for this class. Your other classes are unaffected."
                    : "Following your default, so changing it later changes this class too."
            )

            HStack(spacing: 8) {
                choiceChip(title: "Use my default", selected: !isCustom) {
                    state.coursePreferences.setLeadOffsets(course, nil)
                }
                choiceChip(title: "Just for this class", selected: isCustom) {
                    // Seeded from the global default rather than from nothing,
                    // so switching to custom starts from what the student
                    // already had instead of silently turning every reminder
                    // for this class off.
                    state.coursePreferences.setLeadOffsets(course, LeadOffset.defaults)
                }
            }

            if let offsets = prefs.leadOffsets {
                FlowLayout {
                    ForEach(LeadOffset.allCases) { offset in
                        choiceChip(title: offset.label, selected: offsets.contains(offset)) {
                            var next = offsets
                            if next.contains(offset) { next.remove(offset) } else { next.insert(offset) }
                            // An empty set is kept as an empty set, never folded
                            // back to `nil`. "No lead-time reminders for this
                            // class" is a thing a student can mean, and turning
                            // it into "inherit" would hand them back the
                            // reminders they just switched off.
                            state.coursePreferences.setLeadOffsets(course, next)
                        }
                    }
                }

                if offsets.isEmpty {
                    Text("No advance reminders for this class. You'll still see it on your dashboard.")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DateText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(LeadOffset.defaults.sorted { $0.rawValue < $1.rawValue }.map(\.label)
                    .joined(separator: ", "))
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2CourseCode)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            lhfHapticLight()
            action()
        } label: {
            Text(title)
                .font(.lhfSans(12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.v2ToggleActiveTx : Color.v2DateText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.v2Ink : Color.v2Ink.opacity(0.07)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if index > 0 {
                Button {
                    index -= 1
                } label: {
                    Text("Back")
                        .font(.lhfSans(14, weight: .medium))
                        .foregroundStyle(Color.v2DateText)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Button {
                advance()
            } label: {
                // Never disabled — not while the scan runs, not when it failed.
                // The footer is the student's way out of this screen, and a
                // greyed-out primary button while a network call they did not
                // ask for finishes is precisely how someone gets stranded.
                Text(isLastCourse ? "Done" : "Next class")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLastCourse ? "Done, go to dashboard" : "Next class")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: Flow

    private func advance() {
        lhfHapticLight()
        if isLastCourse {
            finish()
        } else {
            index += 1
        }
    }

    private func finish() {
        OnboardingCourseSetup.markCompleted()
        onFinish()
    }

    /// Captures the class list, then populates suggestions according to the
    /// plan. Runs once, from `.task`.
    private func start() async {
        if courses.isEmpty {
            courses = state.selectedCourseCodes()
        }
        guard !courses.isEmpty else {
            // Nothing to walk. Rather than render an empty shell, hand control
            // straight back — the checklist will not have offered this step
            // with no classes, but a class list emptied by a sync landing
            // between the tap and this line is possible, and a blank screen
            // with a Done button is a worse answer than none.
            finish()
            return
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LHFCourseSetupHarness") {
            suggestions = OnboardingCourseSetup.previewSuggestions(for: courses)
            scan = .finished
            return
        }
        #endif

        // Preview is decided *before* any cookie is read. `suggestionPlan` puts
        // `isUsingFixtureData` first for the same reason, but the ordering only
        // holds end-to-end if the demo run never evaluates the session argument
        // either — `AutoSyncCoordinator.canvasCookies()` reaches into the login
        // WebView's cookie jar and the Keychain, and a demo has no business
        // touching either.
        if state.isUsingFixtureData {
            // No cookies read, no `URLSession`, no `AppState.scanCanvasRequirements`.
            // A reviewer exploring with sample data reaches this branch and
            // nothing else.
            suggestions = OnboardingCourseSetup.previewSuggestions(for: courses)
            scan = .finished
            return
        }

        let cookies = await AutoSyncCoordinator.canvasCookies()
        switch OnboardingCourseSetup.suggestionPlan(
            isUsingFixtureData: false,
            hasCanvasSession: !cookies.isEmpty
        ) {
        case .fixtures:
            suggestions = OnboardingCourseSetup.previewSuggestions(for: courses)
            scan = .finished

        case .noSession:
            scan = .unavailable(Self.noSessionMessage)

        case .scan:
            await runScan(cookies: cookies)
        }
    }

    /// A student who pasted their calendar feed link instead of logging in
    /// (docs/CANVAS_LOGIN_HARDENING.md item 3b) sees this every time, and has
    /// done nothing wrong — so it names the limitation and moves on rather than
    /// asking them to go and fix something.
    private static let noSessionMessage = "We couldn't check your syllabus for weekly readings or check-ins — that needs a Canvas login. You can still set reminders below, and add recurring work later from Settings → Tasks."

    private func runScan(cookies: [HTTPCookie]) async {
        scan = .scanning

        // The scan is one network request per course and the student may have
        // finished logging in seconds ago. This timer does not cancel anything
        // — it just stops the spinner from implying they have to wait.
        let slowTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8 * NSEC_PER_SEC)
            if !Task.isCancelled { scanIsSlow = true }
        }
        defer { slowTimer.cancel() }

        // `reportErrors: false` on purpose. The error-reporting form writes
        // `AppState.error`, which the connect checklist renders in red under
        // its step cards — so a scan that failed during a step the student
        // never asked for would paint a failure over a checklist that is, in
        // fact, fine. The quiet form routes to `syncNotice` instead, and this
        // screen says what happened in its own words.
        await state.scanCanvasRequirements(cookies: cookies, reportErrors: false)

        suggestions = state.canvasRequirementSuggestions
        // `scanCanvasRequirements` records success by marking Canvas Scan
        // connected and failure by clearing it — the only signal it exposes,
        // since it returns nothing.
        scan = state.isCanvasDiscoveryConnected
            ? .finished
            : .unavailable("Canvas didn't answer when we looked for weekly readings and check-ins. Nothing is lost — you can set reminders below, and try again later from Settings → Tasks.")
    }

    // MARK: Chrome

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.lhfSans(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.v2CourseCode)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }
}

// MARK: - Wrapping chip row

/// A wrapping row of chips.
///
/// `LazyVGrid` with adaptive columns would give every chip the width of the
/// widest one, which for lead times ("1 hour before" next to "1 week before")
/// leaves visible gaps and, at the larger Dynamic Type sizes, forces one chip
/// per row long before it needs to. This measures each chip and wraps when the
/// next one would not fit, so the row stays dense at every text size.
///
/// Written as a `Layout` rather than with the `alignmentGuide` wrapping trick
/// that circulates for this. That trick mutates captured `var`s from inside
/// guide closures, which Swift 6 correctly flags as mutation of captured state
/// in concurrently-executing code — and it is genuinely order-dependent, not
/// merely noisy: it only works while SwiftUI evaluates guides in subview order,
/// which is not a documented guarantee. `Layout` asks the same question with an
/// API built for it.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
