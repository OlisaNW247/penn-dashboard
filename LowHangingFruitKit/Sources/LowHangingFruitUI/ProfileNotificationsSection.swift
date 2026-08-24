import SwiftUI
import LowHangingFruitKit

/// Per-course notification preferences: which lead times a given class uses,
/// whether its recurring non-assignment work (weekly readings, check-ins) gets
/// reminders at all, and whether the class is muted outright.
///
/// ## The one design problem this screen has
///
/// Every class starts out **inheriting** the global reminder times from
/// Settings → Reminders. That is what makes the global control worth having:
/// a student sets "1 day and 1 hour before" once, and six classes follow it
/// without anyone configuring six classes. `CoursePreferences.leadOffsets` is
/// optional for exactly this reason, and `nil` — inherit — is the state almost
/// every course is in almost all of the time.
///
/// Which means the obvious UI is a trap. Draw five lead-time toggles per class,
/// pre-ticked from the global setting, and the screen tells a lie every time it
/// renders: it shows a per-class choice where none was made. The student reads
/// their own settings back off it, believes they configured that class, and then
/// changes the global — and either nothing happens (if the toggles really were
/// per-class) or the class they "set up" silently changes underneath them (if
/// they weren't). Both readings are available from the same picture, and that is
/// the definition of an ambiguous control.
///
/// So inheritance is stated, never implied, in three places at once:
///
/// 1. **The collapsed row carries a badge** — `DEFAULT` or `CUSTOM` — so the
///    student can see which of their classes they have actually touched without
///    opening any of them. This is the view that answers "what did I set up?".
/// 2. **Inheriting is its own switch** ("Use my default times"), not an absence.
///    Turning it off is the deliberate act that creates an override, and it
///    seeds the override from the current global so the student starts from
///    where they already were rather than from nothing.
/// 3. **While inheriting, the lead times are not controls.** They render as a
///    flat, dimmed, non-tappable read-out with the words "from Settings →
///    Reminders" underneath. Nothing on screen looks settable unless setting it
///    is what it does. That is the whole point — a disabled-looking toggle still
///    reads as *this class's* toggle, so there are no toggles here at all until
///    the student asks for them.
///
/// ## The signature is the contract
///
/// `ProfileView` composes this as `ProfileNotificationsSection()` and is never
/// edited again: no init parameters, everything from the environment, `Section`s
/// rather than a `Form`. Per-course state comes through `state.coursePreferences`
/// — the `AppState` seam — rather than a fourth `@EnvironmentObject` that nobody
/// injects.
///
/// Every preference is keyed on the course **code**, never on
/// `courseDisplayName`. Renaming is cosmetic (see `ProfileClassesSection`); a
/// preference keyed on the label detaches the moment someone renames the class.
struct ProfileNotificationsSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler

    /// Which course rows are expanded. View state for one visit — a student who
    /// comes back to this screen wants the overview, not whatever they left
    /// open, and persisting it would mean a migration for a disclosure arrow.
    @State private var expanded: Set<String> = []

    private var preferences: CoursePreferencesStore { state.coursePreferences }

    var body: some View {
        Section {
            if !scheduler.isEnabled {
                remindersOffNotice
            }

            let courses = state.visibleCourseCodes()
            if courses.isEmpty {
                emptyState
            } else {
                ForEach(courses, id: \.self) { course in
                    if state.isCourseSelected(course) {
                        courseRow(course)
                    } else {
                        switchedOffRow(course)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Each class starts out following your default reminder times from Settings \u{2192} Reminders. Give a class its own times only when you want it to stop following them.")
        }
    }

    // MARK: Whole-section states

    /// Per-class settings are still worth editing while the global switch is
    /// off — they persist, and they take effect the moment reminders come back
    /// on — but a screen full of reminder controls that cannot currently fire
    /// anything owes the student an explanation at the top.
    private var remindersOffNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Reminders are off", systemImage: "bell.slash")
                .font(.lhfSans(14, weight: .semibold))
                .foregroundStyle(Color.v2SpineAmber)
            Text("Nothing below will send anything until you turn on due-date reminders in Settings \u{2192} Reminders. What you set here is kept and takes effect when you do.")
                .font(.lhfSans(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Same reasoning as `ProfileClassesSection.emptyState`: an empty section on
    /// a tab reads as a broken tab, and "no classes yet" is the ordinary week-one
    /// state rather than a fault.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No classes to set up yet")
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
            Text("Once a class shows up in the list above, it gets its own row here \u{2014} its own reminder times, or none at all.")
                .font(.lhfSans(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// A class the student switched off in Classes contributes no dashboard
    /// items and therefore no reminders, whatever is configured here. Showing it
    /// with live controls would be offering a setting that provably does
    /// nothing, so it shows as a flat line saying why instead.
    private func switchedOffRow(_ course: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.courseDisplayName(course))
                .font(.lhfSans(15))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("Class is off")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2CourseCode)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.courseDisplayName(course)). This class is switched off in Classes, so it sends no reminders.")
    }

    // MARK: One course

    private func courseRow(_ course: String) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(course)) {
            courseControls(course)
        } label: {
            courseSummary(course)
        }
    }

    /// The collapsed line: the class, one plain-language sentence about what it
    /// currently does, and the inherited-or-overridden badge.
    private func courseSummary(_ course: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.courseDisplayName(course))
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text(summary(for: course))
                    .font(.lhfSans(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            badge(for: course)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.courseDisplayName(course)). \(summary(for: course)) \(badgeText(for: course)).")
    }

    @ViewBuilder
    private func courseControls(_ course: String) -> some View {
        Toggle("Reminders for this class", isOn: Binding(
            get: { preferences.notificationsEnabled(course) },
            set: { newValue in
                preferences.setNotificationsEnabled(course, newValue)
                scheduler.rescheduleAfterPreferenceChange()
            }
        ))
        .font(.lhfSans(14))

        if preferences.notificationsEnabled(course) {
            leadTimeControls(course)

            Toggle("Readings and check-ins", isOn: Binding(
                get: { preferences.recurringEnabled(course) },
                set: { newValue in
                    preferences.setRecurringEnabled(course, newValue)
                    scheduler.rescheduleAfterPreferenceChange()
                }
            ))
            .font(.lhfSans(14))

            // The two switches above are easy to mistake for each other, and the
            // distinction is the entire reason there are two: this one leaves
            // assignment reminders running.
            Text(preferences.recurringEnabled(course)
                 ? "Weekly readings, check-ins and discussion posts remind you too. Turn this off to hear only about assignments."
                 : "Only assignments remind you. Weekly readings, check-ins and discussion posts stay silent.")
                .font(.lhfSans(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Lead times — the inherited/overridden distinction

    @ViewBuilder
    private func leadTimeControls(_ course: String) -> some View {
        let isInheriting = preferences.leadOffsets(for: course) == nil

        Toggle("Use my default times", isOn: Binding(
            get: { isInheriting },
            set: { useDefaults in
                // Turning inheritance *off* seeds the override from the global
                // set rather than from nothing. Starting an override empty would
                // silently switch the class's reminders off at the moment the
                // student asked to customise them — the opposite of what
                // "customise" means — and they would have to rebuild a selection
                // they had never chosen to lose. Turning it back on stores `nil`,
                // which resumes following Settings rather than freezing today's
                // value.
                preferences.setLeadOffsets(course, useDefaults ? nil : scheduler.leadOffsets)
                scheduler.rescheduleAfterPreferenceChange()
            }
        ))
        .font(.lhfSans(14))

        if isInheriting {
            inheritedLeadTimes
        } else {
            overriddenLeadTimes(course)
        }
    }

    /// The inherited times, as a read-out rather than as controls. See this
    /// type's note: a disabled toggle still reads as *this class's* toggle, so
    /// while a class is inheriting there are no toggles at all.
    private var inheritedLeadTimes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(NotificationScheduler.LeadOffset.allCases) { offset in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: scheduler.leadOffsets.contains(offset)
                          ? "checkmark.circle.fill" : "circle")
                    Text(offset.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.lhfSans(13))
                .foregroundStyle(.secondary)
            }

            Text("From Settings \u{2192} Reminders. Change it there and this class follows.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2CourseCode)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inherited reminder times: \(offsetList(scheduler.leadOffsets)). Set in Settings, Reminders. This class follows them.")
    }

    @ViewBuilder
    private func overriddenLeadTimes(_ course: String) -> some View {
        let chosen = preferences.leadOffsets(for: course) ?? []

        ForEach(NotificationScheduler.LeadOffset.allCases) { offset in
            Toggle(offset.label, isOn: Binding(
                get: { chosen.contains(offset) },
                set: { isOn in
                    var next = chosen
                    if isOn { next.insert(offset) } else { next.remove(offset) }
                    // Stays a `Set`, never collapses to `nil` when it empties.
                    // An empty override is a real answer — "remind me about this
                    // class, but not ahead of time" — and folding it back to
                    // inheritance would make the last toggle the student turns
                    // off silently restore all of them.
                    preferences.setLeadOffsets(course, next)
                    scheduler.rescheduleAfterPreferenceChange()
                }
            ))
            .font(.lhfSans(13))
        }

        // An empty set is allowed and is not an error, but it is invisible in a
        // list of five unticked switches — it looks identical to "I haven't
        // finished setting this up". Say what it currently means.
        if chosen.isEmpty {
            Label("No reminder times \u{2014} this class won\u{2019}t warn you before something is due.",
                  systemImage: "exclamationmark.triangle")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2SpineAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Summary vocabulary

    private func badgeText(for course: String) -> String {
        if !preferences.notificationsEnabled(course) { return "Muted" }
        return preferences.leadOffsets(for: course) == nil ? "Default" : "Custom"
    }

    @ViewBuilder
    private func badge(for course: String) -> some View {
        let muted = !preferences.notificationsEnabled(course)
        let overridden = preferences.leadOffsets(for: course) != nil
        // Muted is amber because it is the state most worth noticing on a screen
        // you opened to find out why a class went quiet. Custom is blue —
        // marked, not alarming. Default is the greige used for course codes
        // elsewhere: present, legible, and clearly the resting state.
        let tint: Color = muted ? .v2SpineAmber : (overridden ? .v2SpineBlue : .v2CourseCode)

        Text(badgeText(for: course).uppercased())
            .font(.lhfSans(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
    }

    private func summary(for course: String) -> String {
        guard preferences.notificationsEnabled(course) else {
            return "No reminders at all."
        }
        let effective = preferences.effectiveLeadOffsets(for: course, global: scheduler.leadOffsets)
        let inheriting = preferences.leadOffsets(for: course) == nil
        let recurring = preferences.recurringEnabled(course)
            ? ""
            : " Readings and check-ins are off."

        if effective.isEmpty {
            return inheriting
                ? "No reminder times are set in Settings.\(recurring)"
                : "No reminder times.\(recurring)"
        }
        let times = offsetList(effective)
        return (inheriting ? "Your default times: \(times)." : "Its own times: \(times).") + recurring
    }

    /// "1 day, 1 hour" — `LeadOffset.label` with the trailing "before" trimmed,
    /// so the vocabulary stays defined in exactly one place (the Kit) rather
    /// than being restated here and drifting from the toggles it describes.
    private func offsetList(_ offsets: Set<NotificationScheduler.LeadOffset>) -> String {
        NotificationScheduler.LeadOffset.allCases
            .filter { offsets.contains($0) }
            .map { $0.label.replacingOccurrences(of: " before", with: "") }
            .joined(separator: ", ")
    }

    private func expansionBinding(_ course: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(course) },
            set: { isOpen in
                if isOpen { expanded.insert(course) } else { expanded.remove(course) }
            }
        )
    }
}
